"""Push-based mail collection: IMAP IDLE in, one committed replica state out.

The far side is TutaBridge (``units/quadlet/agent-tmail.container``), a local IMAP
server on the collectors' network. It reports the whole mailbox's metadata over
IMAP and pushes ``EXISTS``/``EXPUNGE`` to an IDLE-ing session, but only for the
folder that session selected, which is why the service holds one connection per
folder and why every pass still enumerates all of them.

Three properties matter more than the happy path:

* The UID is the object key. Within one UIDVALIDITY a UID never changes and never
  comes back, so ``mail::<folder>::<uid>`` is stable for as long as "this key is
  gone" means anything. A UIDVALIDITY that differs from the one the replica
  recorded raises ``EpochError``: every UID was renumbered, and publishing that as
  deletion would record a mass tombstone that never happened.
* A body is fetched only when no live row holds its object. The rest are left
  in place -- the row keeps its bytes, so a pass over a steady mailbox costs one
  LIST, one SEARCH and one FLAGS fetch per folder, not a re-download. A flag
  change is a row update, and only when the flags actually moved.
* A UID that disappeared from a folder whose UIDVALIDITY did not change is an
  expunge, and the only thing this collector tombstones. A whole folder that
  disappeared is a refusal: nothing on this host can remove one, so the mailbox
  was replaced or is half written.

``collect_mailbox`` commits one complete pass into the replica state: the
folder's rows, its expunges as explicit tombstones and the next UIDVALIDITY map
land together or not at all.
"""

from __future__ import annotations

import argparse
import imaplib
import itertools
import json
import re
import signal
import socket
import ssl
import sys
import threading
import time
from abc import ABC, abstractmethod
from dataclasses import dataclass
from datetime import datetime, timezone
from urllib.parse import quote
from pathlib import Path
from typing import Callable, Iterable

from ...errors import DataPlaneError, EpochError, PublishError, ValidationError
from ..raw.mail import SOURCE_ID, UIDVALIDITY_OBJECT, _headers, epoch_map
from ..raw.replica import CollectReport, canonical_json
from ..state import ReplicaState

#: Tuta exposes a handful of folders. One thread and one socket per folder is the
#: point of IDLE, but it must not scale with a mailbox that somehow grew
#: thousands: past this the collector sweeps instead of idling.
MAX_IDLE_FOLDERS = 32

#: RFC 2177 caps an idle session at 29 minutes, and a socket silent that long may
#: be dead without having said so. A read timeout forces a reconnect, which
#: re-issues IDLE and is also the liveness probe.
IDLE_READ_TIMEOUT = 1800.0

#: Publication latency while events keep arriving: a folder that changes every
#: second would otherwise push the debounce deadline out forever.
BURST_SECONDS = 300.0

#: How often the publisher wakes to look at its clock. Events are counted, not
#: awaited, so a short poll is both simpler than a condition variable and enough
#: for a debounce measured in seconds.
PUBLISH_POLL = 0.5

BACKOFF_BASE = 1.0
BACKOFF_CAP = 60.0

_LIST_NAME = re.compile(rb'"((?:[^"\\]|\\.)*)"\s*$')
_LIST_ESCAPE = re.compile(rb"\\(.)")
_LINE_UID = re.compile(rb"\bUID (\d+)\b")
_LINE_FLAGS = re.compile(rb"FLAGS \(([^)]*)\)")
_IDLE_TAGS = itertools.count(1)


# --------------------------------------------------------------------------- #
# Pure rules: object keys, UIDs, flags, headers
# --------------------------------------------------------------------------- #


def validate_folder(folder: str) -> str:
    """A folder name this replica can carry, as itself, in metadata.

    The name is recorded verbatim: it is what a reader searches and what the
    epoch map is keyed by. Only the *key* has constraints, and those are
    ``folder_key``'s.
    """

    if not isinstance(folder, str) or not folder.strip():
        raise ValidationError("an IMAP folder name is empty")
    if folder in {".", ".."}:
        raise ValidationError(f"folder name {folder!r} is a path segment")
    if "\x00" in folder:
        raise ValidationError(f"folder {folder!r} contains NUL")
    return folder


def folder_key(folder: str) -> str:
    """The folder as it appears inside an object id.

    A provider nests folders, so the name may contain ``/`` or ``:``; an id may
    carry neither raw -- the replica's object id refuses a ``/`` outright, and a
    ``::`` inside a folder makes one id match two folders' prefixes, which is
    how a folder gets silently emptied. Such a name is percent-encoded behind a
    leading ``%``, which no plain name can start with, so the encoded and the
    plain forms cannot collide and every flat folder keeps the id it had before.
    """

    if not any(character in folder for character in ("/", ":", "%")):
        return folder
    return "%" + quote(folder, safe="")


def _uids(values: Iterable[str]) -> set[str]:
    result: set[str] = set()
    for value in values:
        if not isinstance(value, str) or not value.isdigit() or int(value) < 1:
            raise ValidationError(f"IMAP UID {value!r} is not a positive integer")
        result.add(value)
    return result


def _uid_order(uid: str) -> int:
    return int(uid)


def uid_diff(
    previous: Iterable[str], current: Iterable[str]
) -> tuple[list[str], list[str]]:
    """``(added, removed)`` UIDs, each in numeric order.

    Numeric, not lexicographic: UID 10 follows UID 9, and a string sort would put
    it between 1 and 2 in every report and every tombstone list.
    """

    earlier = _uids(previous)
    now = _uids(current)
    return (
        sorted(now - earlier, key=_uid_order),
        sorted(earlier - now, key=_uid_order),
    )


def normalize_flags(values: Iterable[str]) -> tuple[str, ...]:
    """Sorted and deduplicated, with the padding IMAP's list syntax leaves."""

    return tuple(sorted({flag for flag in (value.strip() for value in values) if flag}))


def message_headers(raw: bytes) -> tuple[str, str]:
    """``(Message-ID, Date)`` from the stored bytes, as the Maildir collector reads them."""

    return _headers(raw)


# --------------------------------------------------------------------------- #
# The collector
# --------------------------------------------------------------------------- #


class Mailbox(ABC):
    """The IMAP operations one collection pass needs.

    The seam is deliberately this small. The tests script a mailbox instead of
    mocking ``imaplib``, so every branch of the collector runs against a
    provider-shaped object, and the real implementation is the thin wrapper below.
    """

    @abstractmethod
    def folders(self) -> list[str]:
        """Every selectable folder, in LIST order."""

    @abstractmethod
    def select(self, folder: str) -> int:
        """Select ``folder`` read-only and return its UIDVALIDITY."""

    @abstractmethod
    def uid_search_all(self) -> list[str]:
        """Every UID in the selected folder, as decimal strings."""

    @abstractmethod
    def uid_fetch(self, uid: str) -> bytes:
        """The selected folder's message body for ``uid``, as the provider sent it."""

    @abstractmethod
    def uid_flags(self) -> dict[str, tuple[str, ...]]:
        """Every UID in the selected folder mapped to its flags."""


@dataclass(frozen=True)
class FolderReport:
    """What one folder contributed to a pass."""

    folder: str
    uidvalidity: int
    objects: int
    carried: int
    deleted: int


def collect_folder(
    mailbox: Mailbox,
    folder: str,
    state: ReplicaState,
    captured_at: str,
    earlier: dict[str, int],
) -> FolderReport:
    """Write one folder's changes into ``state``; the caller commits."""

    validate_folder(folder)
    epoch = mailbox.select(folder)
    if isinstance(epoch, bool) or not isinstance(epoch, int) or epoch < 1:
        raise PublishError(f"folder {folder}: SELECT returned no positive UIDVALIDITY")

    prefix = f"mail::{folder_key(folder)}::"
    held = {row["object_id"]: row for row in state.live_rows(prefix)}
    recorded = {
        int(row["metadata"]["uidvalidity"])
        for row in held.values()
        if isinstance(row["metadata"].get("uidvalidity"), int)
    }
    known = earlier.get(folder)
    if known is not None and known != epoch:
        raise EpochError(
            f"folder {folder} uidvalidity changed {known} -> {epoch}; "
            "every UID was renumbered, so reconcile the source as a new epoch"
        )
    if recorded - {epoch}:
        raise EpochError(
            f"folder {folder} holds messages of uidvalidity "
            f"{sorted(recorded)} but the provider reports {epoch}; reconcile the "
            "source as a new epoch"
        )
    # The map is the authority, but the rows carry the same epoch, so a map that
    # lost an entry must not turn every expunge into a missing tombstone that
    # refuses the pass forever.
    stable = known is not None or bool(recorded)

    previous_uids = [object_id[len(prefix) :] for object_id in held]
    current = _uids(mailbox.uid_search_all())
    added, removed = uid_diff(previous_uids, current)
    added_set = set(added)

    # One FLAGS fetch for the whole folder, before any body: a per-UID call is N
    # round trips for the same information, and flags change without the bytes.
    flags = {uid: normalize_flags(values) for uid, values in mailbox.uid_flags().items()}

    carried = 0
    for uid in sorted(current, key=_uid_order):
        object_id = prefix + uid
        wanted = list(flags.get(uid, ()))
        if uid not in added_set:
            # The body is the provider's bytes and the capture time is when this
            # UID first arrived, so neither moves. Flags are the one field an
            # existing object updates: reading a message has to be visible
            # without a re-fetch -- and a UID the FLAGS response did not mention
            # keeps the flags it had rather than being read as flagless.
            metadata = dict(held[object_id]["metadata"])
            if uid in flags:
                metadata["flags"] = wanted
            # Every row the pass still holds is recorded as seen, so a complete
            # commit can tell "unchanged" from "gone"; an unchanged row writes
            # nothing, because the store compares it before it updates.
            state.seen(held[object_id], metadata)
            carried += 1
            continue
        raw = mailbox.uid_fetch(uid)
        message_id, date = message_headers(raw)
        state.put(
            object_id,
            raw,
            {
                "source_id": SOURCE_ID,
                "folder": folder,
                "key": uid,
                "flags": wanted,
                "uidvalidity": epoch,
                "size": len(raw),
                "message_id": message_id,
                "date": date,
                "captured_at": captured_at,
            },
        )

    deleted = 0
    if stable:
        # The epoch did not move, so a key that is gone was expunged by the
        # provider. This is the only tombstone this collector writes.
        for uid in removed:
            state.tombstone(prefix + uid, "provider expunge")
            deleted += 1

    return FolderReport(
        folder=folder,
        uidvalidity=epoch,
        objects=len(current),
        carried=carried,
        deleted=deleted,
    )


def collect_mailbox(
    mailbox: Mailbox,
    state: ReplicaState,
    captured_at: str,
    progress: Callable[[str], None] | None = None,
) -> CollectReport:
    """Enumerate every folder, then commit the pass into ``state``.

    ``objects`` counts the messages the mailbox currently holds; ``carried`` is
    the subset the replica already held, so the two numbers describe one pass
    without being disjoint. ``progress`` is told what each folder produced: the
    first pass over a real mailbox is tens of thousands of bodies and commits
    nothing until the last one lands, so without a line per folder a working
    pass and a wedged one look alike.
    """

    folders = [validate_folder(name) for name in mailbox.folders()]
    if not folders:
        raise PublishError("the mailbox has no folder to collect")
    if len(folders) != len(set(folders)):
        raise PublishError("the mailbox lists a folder twice")
    folders.sort(key=lambda name: (name != "INBOX", name))

    earlier = epoch_map(state)
    vanished = sorted(set(earlier) - set(folders))
    if vanished:
        # Nothing this host does can remove a folder, so its absence means the
        # mailbox was replaced or is half written. Tombstoning every message in
        # it would record that as a mass deletion.
        raise PublishError(
            "folders disappeared from the mailbox: "
            + ", ".join(vanished)
            + "; a folder cannot be removed by this host, so the mailbox was "
            "replaced or is half written"
        )

    epochs: dict[str, int] = {}
    counts: dict[str, int] = {}
    carried = 0
    deleted = 0
    total = len(folders)
    for index, folder in enumerate(folders, start=1):
        started = time.monotonic()
        if progress is not None:
            progress(f"folder {index}/{total} {folder}: collecting")
        report = collect_folder(mailbox, folder, state, captured_at, earlier)
        epochs[folder] = report.uidvalidity
        counts[folder] = report.objects
        carried += report.carried
        deleted += report.deleted
        if progress is not None:
            progress(
                f"folder {index}/{total} {folder}: {report.objects} messages, "
                f"{report.carried} carried, {time.monotonic() - started:.1f}s"
            )

    state.put(
        UIDVALIDITY_OBJECT,
        canonical_json(epochs),
        {
            "source_id": SOURCE_ID,
            "kind": "epoch-map",
            "captured_at": captured_at,
        },
    )

    # Every message row the replica holds was seen in this pass or tombstoned by
    # an expunge, so no absence reason is needed: anything unaccounted for is a
    # refusal, and a loud one is what a mailbox that changed shape deserves.
    stats = state.commit(complete=True, captured_at=captured_at)

    return CollectReport(
        source_id=SOURCE_ID,
        objects=sum(counts.values()),
        carried=carried,
        deleted=stats.tombstoned,
        details={"folders": counts},
        version=stats.version,
        changed=stats.changed,
    )


# --------------------------------------------------------------------------- #
# IDLE
# --------------------------------------------------------------------------- #


@dataclass(frozen=True)
class IdleLine:
    """What one response line of an IDLE conversation means."""

    changed: bool = False
    terminated: bool = False


def parse_idle_line(line: bytes, tag: bytes) -> IdleLine:
    """Classify one line read while an IDLE command is outstanding.

    TutaBridge pushes ``* 3 EXISTS`` and ``* 4 EXPUNGE`` for the selected folder.
    A line tagged with the command's own tag ends the command: that is an ``OK``
    after a refusal or the answer to a ``DONE``. Anything else (``* OK Still
    here``) is keepalive noise.
    """

    stripped = line.strip()
    if not stripped:
        return IdleLine()
    if stripped.startswith(tag + b" "):
        return IdleLine(terminated=True)
    if stripped.startswith(b"* "):
        upper = stripped.upper()
        if upper.endswith(b" EXISTS") or upper.endswith(b" EXPUNGE"):
            return IdleLine(changed=True)
    return IdleLine()


# --------------------------------------------------------------------------- #
# The real mailbox
# --------------------------------------------------------------------------- #


def _list_name(line: bytes) -> str:
    """The mailbox name from one LIST response line.

    A LIST line is ``(\\HasNoChildren) "/" "INBOX"``; the name is the final quoted
    string, with ``\\"`` and ``\\\\`` unescaped. A literal-form response is refused
    rather than guessed at: nothing in this deployment produces one, and a wrong
    split would name a folder that does not exist.
    """

    match = _LIST_NAME.search(line.rstrip())
    if match is None:
        raise PublishError(f"IMAP LIST returned a line without a quoted name: {line!r}")
    raw = _LIST_ESCAPE.sub(rb"\1", match.group(1))
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise PublishError(
            f"IMAP LIST returned a folder name this collector cannot encode: {raw!r}"
        ) from exc


def pinned_tls_context(ca_file: str | Path) -> ssl.SSLContext:
    """A context that trusts exactly the certificate in ``ca_file``, by bytes.

    TutaBridge hardcodes its certificate's subject alternative names to
    ``localhost`` and ``127.0.0.1`` (``crates/bridge/src/tls.rs`` in
    ``spartanz51/tutabridge``), so no DNS name this container could dial can
    pass a hostname check -- ``smortress-agent-tmail`` included. The pin
    replaces that check: only a peer presenting that exact certificate
    verifies, which is the guarantee the bridge's own healthcheck relies on and
    the one the LOGIN credential needs on the collectors' network.
    """

    context = ssl.create_default_context(cafile=str(ca_file))
    context.check_hostname = False
    return context


class ImapMailbox(Mailbox):
    """``imaplib`` behind the collector's seam, pinned to the bridge's certificate.

    The connection is TLS verified against the certificate the bridge generated
    (``--ca-file``), and authentication is plain ``LOGIN`` with the bridge
    password: the certificate is what protects the credential on this network.
    """

    def __init__(
        self,
        host: str,
        port: int,
        user: str,
        password: str,
        ca_file: str | Path,
    ) -> None:
        self._client = imaplib.IMAP4_SSL(
            host, port, ssl_context=pinned_tls_context(ca_file), timeout=IDLE_READ_TIMEOUT
        )
        try:
            status, data = self._client.login(user, password)
        except BaseException:
            self.close()
            raise
        if status != "OK":
            self.close()
            raise PublishError(f"IMAP LOGIN was refused: {data!r}")

    def folders(self) -> list[str]:
        status, data = self._client.list()
        if status != "OK":
            raise PublishError(f"IMAP LIST failed: {data!r}")
        names: list[str] = []
        for line in data:
            if not isinstance(line, bytes):
                continue
            if b"\\noselect" in line.lower():
                # A hierarchy node for nested folders: LIST names it, SELECT
                # cannot open it.
                continue
            names.append(_list_name(line))
        return names

    def select(self, folder: str) -> int:
        status, data = self._client.select(folder, readonly=True)
        if status != "OK":
            raise PublishError(f"cannot select folder {folder}: {data!r}")
        _, values = self._client.response("UIDVALIDITY")
        if not values or not isinstance(values[0], bytes):
            raise PublishError(f"folder {folder} reported no UIDVALIDITY")
        try:
            epoch = int(values[0])
        except ValueError as exc:
            raise PublishError(
                f"folder {folder} reported a non-integer UIDVALIDITY {values[0]!r}"
            ) from exc
        if epoch < 1:
            raise PublishError(f"folder {folder} reported UIDVALIDITY {epoch}")
        return epoch

    def uid_search_all(self) -> list[str]:
        status, data = self._client.uid("SEARCH", "ALL")
        if status != "OK":
            raise PublishError(f"IMAP SEARCH failed: {data!r}")
        found: list[str] = []
        for item in data:
            if isinstance(item, bytes):
                found.extend(token.decode("ascii") for token in item.split())
        return found

    def uid_fetch(self, uid: str) -> bytes:
        if not isinstance(uid, str) or not uid.isdigit():
            raise ValidationError(f"IMAP UID {uid!r} is not a positive integer")
        # BODY.PEEK[], never BODY[]: reading the replica must not set \Seen on the
        # provider's copy, or every collection would change the mailbox it reads.
        status, data = self._client.uid("FETCH", uid, "(BODY.PEEK[])")
        if status != "OK":
            raise PublishError(f"IMAP FETCH of UID {uid} failed: {data!r}")
        for item in data:
            if isinstance(item, tuple) and len(item) == 2 and isinstance(item[1], bytes):
                return item[1]
        raise PublishError(f"IMAP returned no body for UID {uid}")

    def uid_flags(self) -> dict[str, tuple[str, ...]]:
        status, data = self._client.uid("FETCH", "1:*", "(UID FLAGS)")
        if status != "OK":
            raise PublishError(f"IMAP FLAGS fetch failed: {data!r}")
        flags: dict[str, tuple[str, ...]] = {}
        for item in data:
            line = item[0] if isinstance(item, tuple) else item
            if not isinstance(line, bytes):
                continue
            uid_match = _LINE_UID.search(line)
            flags_match = _LINE_FLAGS.search(line)
            if uid_match is None or flags_match is None:
                continue
            flags[uid_match.group(1).decode("ascii")] = normalize_flags(
                token.decode("ascii", "replace")
                for token in flags_match.group(1).split()
            )
        return flags

    def idle(self, on_change: Callable[[], None], stop: threading.Event) -> None:
        """Hold one IDLE command until the server ends it or the socket dies.

        ``imaplib`` has no IDLE helper, so the exchange is written out. The wire,
        byte for byte::

            >>> A1 IDLE\\r\\n
            <<< + idling\\r\\n
            <<< * 3 EXISTS\\r\\n
            <<< * 4 EXPUNGE\\r\\n

        The continuation is read by hand, then the loop blocks in ``readline()``
        on unsolicited responses. There is no ``DONE``: the collector either lets
        the read timeout break the connection (reconnect re-issues IDLE, which is
        how the 29-minute limit is kept) or shuts the socket down for a clean
        stop. A tagged line also ends the loop, and the caller reconnects.
        """

        tag = b"IDLE" + str(next(_IDLE_TAGS)).encode("ascii")
        self._client.send(tag + b" IDLE\r\n")
        while True:
            line = self._client.readline()
            if not line:
                raise OSError("the bridge closed the connection before IDLE was accepted")
            if line.startswith(b"+"):
                break
            if line.startswith(tag + b" "):
                raise OSError(
                    "the bridge refused IDLE: " + line.decode("ascii", "replace").strip()
                )
        while not stop.is_set():
            line = self._client.readline()
            if not line:
                raise OSError("the bridge closed the IDLE connection")
            parsed = parse_idle_line(line, tag)
            if parsed.changed:
                on_change()
            if parsed.terminated:
                return

    def close(self) -> None:
        try:
            self._client.logout()
        except (OSError, imaplib.IMAP4.error):
            pass

    def shutdown(self) -> None:
        """Break a blocked ``readline`` so a stop does not wait for the timeout."""

        sock = self._client.sock
        if sock is None:
            return
        try:
            sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            sock.close()
        except OSError:
            pass


# --------------------------------------------------------------------------- #
# The service
# --------------------------------------------------------------------------- #


def _captured_at() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def backoff_delay(attempt: int) -> float:
    """Reconnect delay: 1, 2, 4, ... capped, because the bridge restarts."""

    return min(BACKOFF_CAP, BACKOFF_BASE * (2**attempt))


def _classify(error: Exception) -> str:
    """``transient``, ``fatal`` or ``unexpected``.

    A socket error is a bridge that will come back. A data-plane refusal is a
    mailbox that will not: the epoch moved, a folder vanished, the replica could
    not publish. Retrying that merely hides the human's task.
    """

    if isinstance(error, imaplib.IMAP4.abort):
        return "transient"
    if isinstance(error, (DataPlaneError, imaplib.IMAP4.error)):
        return "fatal"
    if isinstance(error, (OSError, EOFError)):
        return "transient"
    return "unexpected"


class StreamCollector:
    """One long-running process: initial pass, IDLE watchers, debounced passes."""

    def __init__(
        self,
        *,
        root: str | Path,
        host: str,
        port: int,
        user: str,
        password: str,
        ca_file: str | Path,
        debounce: float,
        reconcile: float,
    ) -> None:
        self._root = Path(root)
        self._host = host
        self._port = port
        self._user = user
        self._password = password
        self._ca_file = Path(ca_file)
        self._debounce = debounce
        self._reconcile = reconcile
        self._stop = threading.Event()
        self._lock = threading.Lock()
        self._first_event: float | None = None
        self._last_event: float | None = None
        self._failure: Exception | None = None
        self._watchers: dict[str, threading.Thread] = {}
        self._idle_lock = threading.Lock()
        self._idle_boxes: set[ImapMailbox] = set()
        self._idle_cap_logged = False

    # -- the wire ---------------------------------------------------------- #

    def connect(self) -> ImapMailbox:
        return ImapMailbox(
            self._host, self._port, self._user, self._password, self._ca_file
        )

    def run(self) -> int:
        self._install_signal_handlers()
        try:
            folders = self._retrying(self._pass, "initial pass")
            if folders is not None:
                self._ensure_watchers(folders)
                self._publish_loop()
        finally:
            self._stop.set()
            self._shutdown_idle_boxes()
            for thread in list(self._watchers.values()):
                thread.join(timeout=10)
        if self._failure is not None:
            print(f"mail-stream: {self._failure}", file=sys.stderr, flush=True)
            return 1
        return 0

    def _install_signal_handlers(self) -> None:
        # The handler only raises the flag; sockets are shut down by run()'s
        # finally, where it is safe to take the locks the watchers also use.
        for number in (signal.SIGTERM, signal.SIGINT):
            signal.signal(number, lambda *_: self._stop.set())

    # -- passes ------------------------------------------------------------ #

    def _pass(self) -> list[str]:
        state = ReplicaState(self._root, source_id=SOURCE_ID)
        try:
            mailbox = self.connect()
            try:
                # collect_mailbox commits; a refusal leaves the rows and the
                # epoch map untouched, and only unreferenced bytes behind, which
                # the next complete pass collects.
                report = collect_mailbox(
                    mailbox, state, _captured_at(), self._progress
                )
            finally:
                mailbox.close()
        finally:
            state.close()

        payload = {
            "source_id": report.source_id,
            "version": report.version,
            "changed": report.changed,
            "objects": report.objects,
            "carried": report.carried,
            "deleted": report.deleted,
            "details": dict(report.details),
            "published": str(state.path),
        }
        print(json.dumps(payload, sort_keys=True), flush=True)
        return list(report.details.get("folders", {}))

    @staticmethod
    def _progress(line: str) -> None:
        print(f"mail-stream: {line}", file=sys.stderr, flush=True)

    def _retrying(
        self, action: Callable[[], list[str]], label: str
    ) -> list[str] | None:
        attempt = 0
        while not self._stop.is_set():
            try:
                return action()
            except Exception as error:
                kind = _classify(error)
                if kind == "unexpected":
                    raise
                if kind == "fatal":
                    self._failure = error
                    self._stop.set()
                    return None
                delay = backoff_delay(attempt)
                print(
                    f"mail-stream: {label} failed: {error}; retrying in {delay:.0f}s",
                    file=sys.stderr,
                    flush=True,
                )
                self._stop.wait(delay)
                attempt += 1
        return None

    # -- cadence ----------------------------------------------------------- #

    def notify(self) -> None:
        """Record a pushed EXISTS/EXPUNGE; the publisher decides when to act."""

        now = time.monotonic()
        with self._lock:
            if self._first_event is None:
                self._first_event = now
            self._last_event = now

    def _due(self, last_pass: float) -> bool:
        with self._lock:
            first, last = self._first_event, self._last_event
        now = time.monotonic()
        if first is None or last is None:
            return now - last_pass >= self._reconcile
        return now >= min(last + self._debounce, first + BURST_SECONDS)

    def _consume_events(self) -> None:
        with self._lock:
            self._first_event = None
            self._last_event = None

    def _publish_loop(self) -> None:
        last_pass = time.monotonic()
        while not self._stop.is_set():
            self._stop.wait(PUBLISH_POLL)
            if self._stop.is_set() or not self._due(last_pass):
                continue
            self._consume_events()
            folders = self._retrying(self._pass, "incremental pass")
            if folders is None:
                return
            last_pass = time.monotonic()
            self._ensure_watchers(folders)

    # -- watchers ---------------------------------------------------------- #

    def _ensure_watchers(self, folders: Iterable[str]) -> None:
        for folder in folders:
            with self._lock:
                if folder in self._watchers:
                    continue
                if len(self._watchers) >= MAX_IDLE_FOLDERS:
                    if not self._idle_cap_logged:
                        self._idle_cap_logged = True
                        print(
                            f"mail-stream: more than {MAX_IDLE_FOLDERS} folders; "
                            "idling the first ones and sweeping the rest",
                            file=sys.stderr,
                            flush=True,
                        )
                    continue
                thread = threading.Thread(
                    target=self._watch, args=(folder,), name=f"idle {folder}", daemon=True
                )
                self._watchers[folder] = thread
                thread.start()

    def _watch(self, folder: str) -> None:
        attempt = 0
        while not self._stop.is_set():
            mailbox: ImapMailbox | None = None
            try:
                mailbox = self.connect()
                with self._idle_lock:
                    self._idle_boxes.add(mailbox)
                mailbox.select(folder)
                attempt = 0
                mailbox.idle(self.notify, self._stop)
            except Exception as error:
                kind = _classify(error)
                if kind == "unexpected":
                    self._failure = error
                    self._stop.set()
                    return
                if self._stop.is_set():
                    return
                if kind == "fatal":
                    self._failure = error
                    self._stop.set()
                    return
                delay = backoff_delay(attempt)
                print(
                    f"mail-stream: idle {folder} lost: {error}; "
                    f"reconnecting in {delay:.0f}s",
                    file=sys.stderr,
                    flush=True,
                )
                self._stop.wait(delay)
                attempt += 1
            finally:
                if mailbox is not None:
                    with self._idle_lock:
                        self._idle_boxes.discard(mailbox)
                    mailbox.close()

    def _shutdown_idle_boxes(self) -> None:
        with self._idle_lock:
            boxes = list(self._idle_boxes)
        for mailbox in boxes:
            mailbox.shutdown()


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="data_plane.collectors.stream",
        description=(
            "Collect Tuta mail from the local IMAP bridge, committing one "
            "replica pass at a time, woken by IDLE."
        ),
    )
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, default=1143)
    parser.add_argument("--user", required=True)
    parser.add_argument("--password-file", required=True)
    parser.add_argument("--ca-file", required=True)
    parser.add_argument("--root", required=True)
    parser.add_argument(
        "--events-debounce",
        type=float,
        default=30.0,
        metavar="SECONDS",
        help="quiet time after a pushed event before the next pass (default: 30)",
    )
    parser.add_argument(
        "--reconcile-interval",
        type=float,
        default=3600.0,
        metavar="SECONDS",
        help="safety pass with no events at all (default: 3600)",
    )
    return parser


def main(argv: Iterable[str] | None = None) -> int:
    parser = _parser()
    args = parser.parse_args(list(sys.argv[1:] if argv is None else argv))
    if args.port < 1 or args.port > 65535:
        parser.error("--port is not a TCP port")
    if args.events_debounce <= 0:
        parser.error("--events-debounce must be positive")
    if args.reconcile_interval <= 0:
        parser.error("--reconcile-interval must be positive")

    try:
        password = Path(args.password_file).read_text(encoding="utf-8").strip()
    except OSError as error:
        print(
            f"mail-stream: cannot read {args.password_file}: {error}",
            file=sys.stderr,
        )
        return 2
    if not password:
        print(f"mail-stream: {args.password_file} is empty", file=sys.stderr)
        return 2
    if not Path(args.ca_file).is_file():
        print(f"mail-stream: {args.ca_file} is not a file", file=sys.stderr)
        return 2

    collector = StreamCollector(
        root=args.root,
        host=args.host,
        port=args.port,
        user=args.user,
        password=password,
        ca_file=args.ca_file,
        debounce=args.events_debounce,
        reconcile=args.reconcile_interval,
    )
    return collector.run()


if __name__ == "__main__":
    raise SystemExit(main())
