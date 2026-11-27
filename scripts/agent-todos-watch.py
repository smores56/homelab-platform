#!/usr/bin/env python3
"""The personal workspace's one live signal (SDLC #979, T1).

Watches the todos root and appends one JSON line per change to the feed the
workspace reads at /feed/changes.jsonl. It is a watcher, not a log: the ring
buffer is bounded, an event that has scrolled off costs nothing, and nothing
replays. Every path in a record is still on disk to be read, which is the whole
point of a current-state plane.

What is watched is the *todos root only*. A recursive watch of the vault would
make every synced file a wakeup and every restore a storm, and the design says
the vault is read on use (SDLC #979, "Watch and freshness").

`inotifywait` is not used and cannot be: the server image installs no
distribution package (bootc/server/Containerfile, "No package layer"), so the
watch is inotify(7) through ctypes, which needs nothing but CPython.

The sequence continues across restarts, so a reader can tell "nothing happened"
from "the watcher restarted": a gap in `seq` is a restart, not a lost edit.
"""

import ctypes
import errno
import json
import os
import select
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

libc = ctypes.CDLL(None, use_errno=True)


def die(message):
    print(f"agent-todos-watch: {message}", file=sys.stderr)
    raise SystemExit(1)


def kind_of(mask):
    """Collapse an inotify mask onto the three kinds a reader can act on.

    `moved_to` is a create and `moved_from` is a delete because that is what the
    path now is; `attrib` is an update because a chmod or a touch changed the
    same content.
    """
    if mask & (IN_CREATE | IN_MOVED_TO):
        return "create"
    if mask & (IN_DELETE | IN_MOVED_FROM):
        return "delete"
    return "update"


class Feed:
    """The append-only JSONL file and its ring buffer.

    The buffer is trimmed by rewriting to a temporary file and renaming, so a
    reader that is mid-read either sees the old file or the new one and never a
    half line.
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
        if lines:
            try:
                self.seq = int(json.loads(lines[-1]).get("seq", 0))
            except (ValueError, AttributeError):
                self.seq = 0

    def append(self, source, path, kind):
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
        # The high-water mark is checked on every append: the count is in memory,
        # so this is a comparison, not a scan, and a burst of edits trims once
        # rather than after a multiple that may never arrive.
        if self.lines > self.trim_at:
            self.trim()

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
    """A recursive inotify watch over one directory tree."""

    def __init__(self, root):
        self.root = root
        self.paths = {}
        self.fd = libc.inotify_init1(os.O_NONBLOCK | os.O_CLOEXEC)
        if self.fd < 0:
            die(f"inotify_init1: {os.strerror(ctypes.get_errno())}")
        self.add_tree(root)

    def add(self, directory):
        wd = libc.inotify_add_watch(self.fd, os.fsencode(directory), WATCH_MASK)
        if wd < 0:
            error = ctypes.get_errno()
            # A directory that vanished between the walk and the watch is not a
            # failure; its deletion is already an event.
            if error == errno.ENOENT:
                return None
            die(f"inotify_add_watch {directory}: {os.strerror(error)}")
        self.paths[wd] = directory
        return wd

    def add_tree(self, root):
        self.add(root)
        for directory, subdirs, _ in os.walk(root):
            for name in subdirs:
                self.add(os.path.join(directory, name))

    def events(self):
        """Read one batch of events, yielding (path, kind).

        inotify hands over whole records, but read() can still stop mid-record,
        so the tail of a batch is carried into the next one.
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
                if mask & IN_IGNORED:
                    self.paths.pop(wd, None)
                    continue
                directory = self.paths.get(wd)
                if directory is None:
                    continue
                path = os.path.join(directory, os.fsdecode(name)) if name else directory
                if mask & IN_ISDIR and mask & (IN_CREATE | IN_MOVED_TO):
                    self.add_tree(path)
                yield path, kind_of(mask)
            pending = data[offset:]


def main():
    root = os.environ.get("SMORTRESS_AGENT_TODOS_ROOT", "/srv/files/todos")
    feed_dir = os.environ.get("SMORTRESS_AGENT_FEED_DIR", "/var/lib/agent/local/mirage/feed")
    keep = int(os.environ.get("SMORTRESS_AGENT_FEED_KEEP", "1000"))
    trim_at = int(os.environ.get("SMORTRESS_AGENT_FEED_TRIM_AT", "2000"))

    if not os.path.isdir(root):
        die(f"{root} is missing; zfs-ready@raw-files.service did not run")
    os.makedirs(feed_dir, mode=0o750, exist_ok=True)
    feed_path = os.path.join(feed_dir, "changes.jsonl")

    watcher = Watcher(root)
    # The watch is live before the file exists: the file is the readiness marker a
    # reader (and the suite) waits for, so nobody has to guess how long inotify
    # takes to install a watch.
    open(feed_path, "a", encoding="utf-8").close()
    feed = Feed(feed_path, keep, trim_at)
    print(f"agent-todos-watch: watching {root}, appending {feed_path}", file=sys.stderr, flush=True)

    for event in watcher.events():
        if event is None:
            continue
        path, kind = event
        feed.append("todos", path, kind)


if __name__ == "__main__":
    main()
