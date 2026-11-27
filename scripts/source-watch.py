#!/usr/bin/env python3
"""The agent plane's one live signal: inotify over the source roots, into a feed.

SDLC #995 settles the access layer as a shell over the datasets, so the only
thing the host still owes the agent is *when to look*. This program is that: one
process, one inotify fd, one bounded JSONL file.

The contract a reader can rely on:

* A record names a path that exists when the record is read, except the `delete`
  records, which name the path that is gone. Nothing is replayed from history.
* `rescan` means the feed may have missed edits in that tree -- the watcher
  started, a directory arrived already populated, or the kernel queue overflowed.
  A reader that sees it sweeps the tree instead of trusting the gap.
* `seq` increases within a run. A restart continues from the last parseable
  record in the file, so `seq` never rewinds; `rescan` is what marks a restart.
* The feed is bounded. An event that scrolled off the ring costs nothing,
  because the state it described is still on disk.
* Read the file by name, not through a descriptor held open across turns: a trim
  replaces the inode, and a reader still on the old one sees nothing further.

Autostart is the unit's job (``smortress-source-watch.service``), not the agent's.
A watch established inside the agent container dies with that container, while
this process keeps its watches across agent restarts and outlives whichever
runtime consumes the feed.

``inotifywait`` is not used and cannot be: the server image installs no
distribution package (``bootc/server/Containerfile``, "No package layer"), so the
watch is inotify(7) through ctypes, which needs nothing but CPython.

Verified on smortress' ZFS datasets (OpenZFS 2.4.4): create, modify, close-write,
moved-from/moved-to and delete all arrive, and a watch established inside a bind
mount in another mount namespace sees writes made on the other side -- which is
what lets a reader inside a container trust the feed. A directory created after
the watch is installed delivers ``CREATE|ISDIR`` and nothing from inside it, so
the tree is re-walked on every such event and a `rescan` follows: an archive
unpacked or a clone made between the create and the walk is otherwise invisible.
"""

from __future__ import annotations

import argparse
import ctypes
import errno
import fnmatch
import json
import os
import select
import signal
import struct
import sys
import time

IN_MODIFY = 0x00000002
IN_ATTRIB = 0x00000004
IN_MOVED_FROM = 0x00000040
IN_MOVED_TO = 0x00000080
IN_CREATE = 0x00000100
IN_DELETE = 0x00000200
IN_DELETE_SELF = 0x00000400
IN_MOVE_SELF = 0x00000800
IN_Q_OVERFLOW = 0x00004000
IN_IGNORED = 0x00008000
IN_ISDIR = 0x40000000

WATCH_MASK = (
    IN_MODIFY
    | IN_ATTRIB
    | IN_MOVED_FROM
    | IN_MOVED_TO
    | IN_CREATE
    | IN_DELETE
    | IN_DELETE_SELF
    | IN_MOVE_SELF
)

EVENT = struct.Struct("iIII")  # wd, mask, cookie, len

#: Syncthing writes its bookkeeping next to the file it is syncing, an office
#: lock file is not a change to the document, and a git checkout inflates the
#: watch count by every directory it owns. These are the defaults a root gets
#: when the config names none; a root that names its own list replaces them.
DEFAULT_EXCLUDE = (
    ".git",
    ".git/*",
    ".stfolder",
    ".stversions",
    ".stversions/*",
    ".syncthing.*.tmp",
    "~$*",
    "*.swp",
    "tmp",
    "tmp/*",
    "*/tmp/*",
)

#: One path that changes five times in a second -- a Syncthing temp rename, a
#: git index rewrite -- is one change to a reader, so a repeated (path, kind) is
#: dropped inside this window. It never drops a *different* kind: create then
#: delete is still two records.
DEBOUNCE_SECONDS = 1.0

DEFAULT_ROOTS = "/etc/smortress/agent/watch-roots.json"
DEFAULT_FEED = "/var/lib/agent/local/watch/changes.jsonl"

libc = ctypes.CDLL(None, use_errno=True)


class ConfigError(Exception):
    """The roots file is missing or does not describe roots."""


def die(message):
    print(f"source-watch: {message}", file=sys.stderr, flush=True)
    raise SystemExit(1)


def warn(message):
    print(f"source-watch: {message}", file=sys.stderr, flush=True)


def kind_of(mask):
    """Collapse an inotify mask onto the kinds a reader can act on.

    ``moved_to`` is a create and ``moved_from`` is a delete because that is what
    the path now is; ``attrib`` is an update because a chmod or a touch changed
    the same content; ``delete_self`` is a delete because the path is gone, and
    emitting it as an update would name a path a reader can no longer open.
    """

    if mask & (IN_CREATE | IN_MOVED_TO):
        return "create"
    if mask & (IN_DELETE | IN_MOVED_FROM | IN_DELETE_SELF):
        return "delete"
    return "update"


def load_roots(path):
    """Parse the roots file into ``[(source, root, exclude)]``.

    A source name is the reader's handle for a root, so two roots may not share
    one and two roots may not be the same directory: either would make a record
    ambiguous about which tree it came from.
    """

    try:
        with open(path, "r", encoding="utf-8") as handle:
            config = json.load(handle)
    except FileNotFoundError as error:
        raise ConfigError(f"{path} is missing") from error
    except ValueError as error:
        raise ConfigError(f"{path} is not JSON: {error}") from error
    roots = config.get("roots") if isinstance(config, dict) else None
    if not isinstance(roots, list) or not roots:
        raise ConfigError(f"{path} names no roots")
    defaults = config.get("exclude", list(DEFAULT_EXCLUDE))
    if not isinstance(defaults, list) or not all(isinstance(p, str) for p in defaults):
        raise ConfigError(f"{path}: exclude must be a list of patterns")
    seen_sources, seen_paths, parsed = set(), set(), []
    for entry in roots:
        if not isinstance(entry, dict):
            raise ConfigError(f"{path}: a root is not an object")
        source, root = entry.get("source"), entry.get("path")
        if not isinstance(source, str) or not source.strip():
            raise ConfigError(f"{path}: a root has no source")
        if not isinstance(root, str) or not os.path.isabs(root):
            raise ConfigError(f"{path}: {source} has no absolute path")
        exclude = entry.get("exclude", defaults)
        if not isinstance(exclude, list) or not all(isinstance(p, str) for p in exclude):
            raise ConfigError(f"{path}: {source} exclude must be a list of patterns")
        if source in seen_sources:
            raise ConfigError(f"{path}: source {source!r} is named twice")
        if root in seen_paths:
            raise ConfigError(f"{path}: path {root!r} is named twice")
        seen_sources.add(source)
        seen_paths.add(root)
        parsed.append((source, root.rstrip("/") or "/", tuple(exclude)))
    return parsed


class Feed:
    """The append-only JSONL file and its ring buffer.

    The buffer is trimmed by rewriting to a temporary file and renaming, so a
    reader that opens the file by name either sees the old file or the new one
    and never a half line. ``seq`` continues across restarts because it is read
    back from the last parseable record, which is how a reader sees that the
    watcher restarted even when no line was lost.
    """

    def __init__(self, path, keep, trim_at):
        self.path = path
        self.keep = keep
        self.trim_at = trim_at
        self.seq = 0
        self.lines = 0
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as feed:
                lines = feed.readlines()
        except FileNotFoundError:
            lines = []
        self.lines = len(lines)
        # A stop in the middle of a line leaves a fragment; the last *parseable*
        # record is the only safe place to continue from, and a fragment is not
        # one.
        for line in reversed(lines):
            try:
                self.seq = int(json.loads(line).get("seq", 0))
            except (ValueError, AttributeError):
                continue
            break

    def append(self, source, path, kind):
        # A signal lands at a bytecode boundary, which can be inside the write
        # below; blocking it for the duration keeps a record whole.
        signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM, signal.SIGINT})
        try:
            self.seq += 1
            record = {
                "seq": self.seq,
                "source": source,
                "path": path,
                "kind": kind,
                "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            }
            with open(self.path, "a", encoding="utf-8") as feed:
                feed.write(json.dumps(record, sort_keys=True) + "\n")
                feed.flush()
                os.fsync(feed.fileno())
            self.lines += 1
            if self.lines > self.trim_at:
                self.trim()
        finally:
            signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGTERM, signal.SIGINT})

    def trim(self):
        try:
            with open(self.path, "r", encoding="utf-8") as feed:
                lines = feed.readlines()
        except FileNotFoundError:
            return
        if len(lines) <= self.trim_at:
            return
        tmp = f"{self.path}.tmp"
        with open(tmp, "w", encoding="utf-8") as feed:
            feed.writelines(lines[-self.keep :])
        os.replace(tmp, self.path)
        self.lines = min(self.lines, self.keep)


class Watcher:
    """One inotify fd over every root, each walk pruned by its own exclusions."""

    def __init__(self, roots):
        self.roots = roots  # [(source, root, exclude)]
        self.paths = {}  # wd -> (source, directory, root, exclude)
        self.fd = libc.inotify_init1(os.O_NONBLOCK | os.O_CLOEXEC)
        if self.fd < 0:
            die(f"inotify_init1: {os.strerror(ctypes.get_errno())}")
        # The feed fsyncs every line and blocks the stop signal while it writes,
        # so a stop between lines loses nothing and a stop mid-batch loses at
        # most the records this process had not read yet.
        signal.signal(signal.SIGTERM, self._stop)
        signal.signal(signal.SIGINT, self._stop)

    @staticmethod
    def _stop(_signum, _frame):
        raise SystemExit(0)

    @staticmethod
    def excluded(root, exclude, path):
        """Whether ``path`` is outside the reader's interest for this root.

        A pattern is tried against the path relative to the root and against the
        bare name, and fnmatch lets ``*`` cross a separator, so ``tmp`` prunes a
        root-level tmp, ``*/tmp/*`` prunes a nested one, and ``.stversions``
        prunes the directory wherever it appears.
        """

        relative = os.path.relpath(path, root) if root != "/" else path[1:]
        name = os.path.basename(path.rstrip("/")) or "/"
        for pattern in exclude:
            if fnmatch.fnmatch(name, pattern) or fnmatch.fnmatch(relative, pattern):
                return True
        return False

    def add_tree(self, source, root, exclude):
        """Walk ``root`` and watch every directory the exclusions allow.

        A directory the kernel will not watch (ENOSPC, the per-uid limit) is
        reported and skipped rather than fatal: losing one subtree must not stop
        the other roots, and the reader's sweep covers what this missed.
        """

        self._add_one(source, root, root, exclude)
        for directory, subdirs, _ in os.walk(root):
            kept = []
            for name in subdirs:
                path = os.path.join(directory, name)
                if self.excluded(root, exclude, path):
                    continue
                kept.append(name)
                self._add_one(source, path, root, exclude)
            subdirs[:] = kept

    def _add_one(self, source, directory, root, exclude):
        if self.excluded(root, exclude, directory):
            return None
        wd = libc.inotify_add_watch(self.fd, os.fsencode(directory), WATCH_MASK)
        if wd < 0:
            error = ctypes.get_errno()
            # A directory that vanished between the walk and the watch is not a
            # failure; its deletion is already an event.
            if error == errno.ENOENT:
                return None
            warn(f"{directory}: not watched: {os.strerror(error)}")
            return None
        self.paths[wd] = (source, directory, root, exclude)
        return wd

    def _drop_subtree(self, path):
        """Forget every watch at or below ``path``; the kernel keeps its own."""

        prefix = path.rstrip("/") + os.sep
        for wd in [
            wd
            for wd, (_, directory, _, _) in self.paths.items()
            if directory == path or directory.startswith(prefix)
        ]:
            self.paths.pop(wd, None)

    def events(self):
        """Read one batch, yielding ``(source, path, kind)`` or ``None`` on idle.

        inotify hands over whole records, but read() can still stop mid-record,
        so the tail of a batch is carried into the next one. A queue overflow
        arrives with ``wd == -1`` and costs every event in the gap, so it is
        answered with one `rescan` per root: that record is the only way a
        reader learns it must sweep.
        """

        pending = b""
        while True:
            ready, _, _ = select.select([self.fd], [], [], 1.0)
            if not ready:
                yield None
                continue
            try:
                chunk = os.read(self.fd, 65536)
            except BlockingIOError:
                continue
            if not chunk:
                return
            data = pending + chunk
            offset = 0
            while offset + EVENT.size <= len(data):
                wd, mask, _, length = EVENT.unpack_from(data, offset)
                offset += EVENT.size
                name = data[offset : offset + length].split(b"\0", 1)[0]
                offset += length
                if mask & IN_Q_OVERFLOW:
                    warn("inotify queue overflowed; every root needs a sweep")
                    for source, root, _ in self.roots:
                        yield source, root, "rescan"
                    continue
                if mask & IN_IGNORED:
                    self.paths.pop(wd, None)
                    continue
                entry = self.paths.get(wd)
                if entry is None:
                    continue
                source, directory, root, exclude = entry
                path = os.path.join(directory, os.fsdecode(name)) if name else directory
                if mask & IN_MOVE_SELF:
                    # The directory left the tree: its parent's MOVED_FROM
                    # already told the reader, and this watch's path would
                    # otherwise stamp later writes with the old name.
                    self._drop_subtree(path)
                    continue
                # A directory created after the watch went in delivers this event
                # and nothing from inside it, so its tree is walked here and a
                # `rescan` follows: content that landed before the walk began is
                # otherwise invisible.
                if mask & IN_ISDIR and mask & (IN_CREATE | IN_MOVED_TO):
                    if not self.excluded(root, exclude, path):
                        self.add_tree(source, path, exclude)
                        yield source, path, "rescan"
                if mask & IN_DELETE_SELF:
                    self._drop_subtree(path)
                elif self.excluded(root, exclude, path):
                    continue
                yield source, path, kind_of(mask)
            pending = data[offset:]


def parse_args(argv):
    parser = argparse.ArgumentParser(
        prog="source-watch",
        description="Append inotify events from the agent source roots to one feed.",
    )
    parser.add_argument(
        "--roots",
        default=os.environ.get("SMORTRESS_SOURCE_WATCH_ROOTS", DEFAULT_ROOTS),
        help=f"JSON roots file (default {DEFAULT_ROOTS})",
    )
    parser.add_argument(
        "--feed",
        default=os.environ.get("SMORTRESS_SOURCE_WATCH_FEED", DEFAULT_FEED),
        help=f"JSONL feed to append (default {DEFAULT_FEED})",
    )
    parser.add_argument(
        "--keep",
        type=int,
        default=int(os.environ.get("SMORTRESS_SOURCE_WATCH_KEEP", "1000")),
        help="records kept when the feed is trimmed",
    )
    parser.add_argument(
        "--trim-at",
        type=int,
        default=int(os.environ.get("SMORTRESS_SOURCE_WATCH_TRIM_AT", "2000")),
        help="record count that triggers a trim",
    )
    args = parser.parse_args(argv)
    if args.keep < 1 or args.trim_at <= args.keep:
        parser.error("--trim-at must be greater than --keep, and --keep positive")
    return args


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        roots = load_roots(args.roots)
    except ConfigError as error:
        die(str(error))

    feed_dir = os.path.dirname(args.feed)
    try:
        os.makedirs(feed_dir, mode=0o750, exist_ok=True)
    except OSError as error:
        die(f"cannot create {feed_dir}: {error.strerror}")

    watcher = Watcher(roots)
    live = []
    for source, root, exclude in roots:
        if not os.path.isdir(root):
            # One dataset that is not mounted yet must not stop the others; the
            # unit's ConditionPathIsDirectory covers the common case, and a
            # restart picks a late mount up because the walk is redone here.
            warn(f"{source}: {root} is missing, not watched")
            continue
        watcher.add_tree(source, root, exclude)
        live.append((source, root))

    if not live:
        die("no configured root exists")

    # The file is the readiness marker a reader (and the suite) waits for: the
    # watches are installed before it appears, so the first write cannot land
    # before there is anything watching.
    open(args.feed, "a", encoding="utf-8").close()
    feed = Feed(args.feed, args.keep, args.trim_at)
    # A restart resumed a sequence with a hole in it: whatever happened while the
    # watcher was down is not in the feed, and this record is how a reader knows
    # to sweep rather than trust the quiet.
    for source, root in live:
        feed.append(source, root, "rescan")
    warn(f"watching {', '.join(source for source, _ in live)}; appending {args.feed}")

    seen = {}
    for event in watcher.events():
        if event is None:
            # The debounce table is per-burst: a long run of unrelated paths must
            # not grow it without bound, and an idle second is not a burst.
            if len(seen) > 4096:
                seen.clear()
            # A remount replaces the root inode and the kernel drops the watches
            # with it, without an event this process can answer. The unit's
            # Restart=always is the recovery, so an empty watch table ends the
            # run instead of sitting silent with nothing watched.
            if not watcher.paths:
                warn("every watch is gone; restarting to re-walk the roots")
                return 0
            continue
        source, path, kind = event
        now = time.monotonic()
        key = (path, kind)
        if now - seen.get(key, 0.0) < DEBOUNCE_SECONDS:
            continue
        seen[key] = now
        feed.append(source, path, kind)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
