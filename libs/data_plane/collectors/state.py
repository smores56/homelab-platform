"""One live replica state: content-addressed objects and a transactional index.

A pass writes only bytes it does not already hold, records the rows it
enumerated, and commits them together with the cursor and the version in one
SQLite transaction. There is no generation tree and no manifest: the latest
state is the only state, and Restic is the history.

Deletion is still never inferred. A complete pass must name every live row it
did not see, either with an explicit ``tombstone`` when the provider supplied
evidence or with an absence reason when it did not. A delta pass may not infer
absence at all.

Two rules make a crash harmless:

* object bytes are written (temp file plus rename) before the transaction, so a
  crash leaves an unreferenced object, never a row whose bytes are missing;
* garbage collection runs after the commit and never deletes a file written
  during the pass that is still running.
"""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
import re
import sqlite3
import time
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Mapping
from urllib.parse import quote

from ..errors import (
    CursorError,
    EpochError,
    ManifestError,
    PublishError,
    ValidationError,
)

OBJECTS_DIR = "objects"
STATE_NAME = "state.sqlite"
#: One pass at a time per source; the writer holds it for its whole life.
LOCK_NAME = ".pass.lock"
#: Set when object bytes are written, cleared by a sweep: a refused pass that
#: wrote bodies leaves it behind for the next pass that commits.
GC_MARKER = ".gc-pending"

#: Set on a row the current enumeration did not see. It is the first time any
#: pass saw the object missing, so the marker does not move on later runs.
ABSENT_SINCE = "absent_since"
#: Why the object is absent. Never a synonym for "deleted": the only deletion
#: evidence this layer accepts is an explicit provider tombstone.
ABSENCE_REASON = "absence_reason"

_UNSAFE_IDS = frozenset({".", ".."})
_DIGEST = re.compile(r"[0-9a-f]{64}")
#: Bookkeeping that changes on every pass and is therefore not row identity.
_VOLATILE_META = ("captured_at",)

_SCHEMA = """
CREATE TABLE IF NOT EXISTS object (
    id TEXT PRIMARY KEY,
    sha256 TEXT,
    size INTEGER,
    meta TEXT,
    present INTEGER NOT NULL CHECK (present IN (0, 1)),
    absent_since TEXT,
    absence_reason TEXT,
    updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS object_sha256 ON object (sha256, present);
CREATE TABLE IF NOT EXISTS cursor (
    source_id TEXT PRIMARY KEY,
    cursor INTEGER NOT NULL,
    epoch INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS version (v INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
"""

_UPSERT_PUT = """
INSERT INTO object
    (id, sha256, size, meta, present, absent_since, absence_reason, updated_at)
VALUES (?, ?, ?, ?, 1, NULL, NULL, ?)
ON CONFLICT(id) DO UPDATE SET
    sha256 = excluded.sha256,
    size = excluded.size,
    meta = excluded.meta,
    present = 1,
    absent_since = NULL,
    absence_reason = NULL,
    updated_at = excluded.updated_at
"""

_UPSERT_TOMBSTONE = """
INSERT INTO object
    (id, sha256, size, meta, present, absent_since, absence_reason, updated_at)
VALUES (?, NULL, NULL, NULL, 0, NULL, ?, ?)
ON CONFLICT(id) DO UPDATE SET
    sha256 = NULL,
    size = NULL,
    meta = NULL,
    present = 0,
    absence_reason = excluded.absence_reason,
    updated_at = excluded.updated_at
"""

#: Databases this process has already integrity-checked, keyed by identity.
_VERIFIED: dict[tuple[str, int, int], None] = {}


@dataclass(frozen=True)
class CommitStats:
    """What one commit did. ``absent`` counts live rows absent after it."""

    version: int
    written: int
    absent: int
    tombstoned: int
    collected: int
    #: Whether this pass moved any row, and so whether ``version`` moved with it.
    changed: bool


def _check_object_id(object_id: str) -> None:
    if (
        not isinstance(object_id, str)
        or not object_id.strip()
        or object_id in _UNSAFE_IDS
        or "/" in object_id
        or "\x00" in object_id
    ):
        raise ValidationError(f"invalid object id {object_id!r}")


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _prefix_bounds(prefix: str) -> tuple[str, str] | None:
    """The half-open id range holding every id that starts with ``prefix``.

    ``substr`` would match the same rows but scan the whole table: the id range
    is a seek on the primary key, which is what a 300k-message pass needs.
    """

    if not prefix:
        return None
    last = ord(prefix[-1])
    if last >= 0x10FFFF:
        return None
    return prefix, prefix[:-1] + chr(last + 1)


def _serialize(metadata: dict) -> str:
    if not isinstance(metadata, dict):
        raise ValidationError("object metadata must be a dict")
    try:
        return json.dumps(metadata, sort_keys=True, separators=(",", ":"))
    except (TypeError, ValueError) as exc:
        raise ValidationError("object metadata is not JSON serializable") from exc


def _without_volatile(metadata: Mapping[str, Any]) -> dict:
    """A row's metadata without the fields that change on every pass."""

    return {key: value for key, value in metadata.items() if key not in _VOLATILE_META}


def _identity(meta: str) -> dict:
    return _without_volatile(json.loads(meta))


class ReplicaState:
    """The live state of one replica source: bytes, rows, cursor and version.

    A writer opens the database read-write, buffers one pass in memory, and
    commits it whole. A reader opens it ``mode=ro`` with ``query_only`` and
    verifies every object's size and sha256 against its content-addressed name.
    """

    def __init__(
        self,
        root: str | Path,
        *,
        source_id: str = "",
        read_only: bool = False,
        dry_run: bool = False,
    ) -> None:
        if read_only and dry_run:
            raise ValidationError("a replica state cannot be read-only and a dry run")
        if not isinstance(source_id, str):
            raise ValidationError("source id must be a string")
        self._root = Path(root)
        self._source_id = source_id
        self._read_only = read_only
        self._dry_run = dry_run
        self._pass_started_at = time.time()
        self._puts: dict[str, tuple[str, int, str]] = {}
        self._seen: set[str] = set()
        self._tombstones: dict[str, str] = {}
        self._closed = False
        self._connection: sqlite3.Connection | None = None
        self._lock: Any | None = None
        self._epoch = 1
        if dry_run:
            return
        if read_only:
            self._connection = self._open()
            if not self._source_id:
                self._source_id = self._stored_source_id()
            self._epoch = self._stored_epoch()
            return
        self._acquire_lock()
        try:
            if self.path.is_file():
                # Bind the source and the epoch now, so a database that belongs
                # to another source is refused before any byte is written.
                self._database()
        except BaseException:
            self.close()
            raise

    # -- identity ---------------------------------------------------------

    @property
    def root(self) -> Path:
        return self._root

    @property
    def path(self) -> Path:
        return self._root / STATE_NAME

    @property
    def source_id(self) -> str:
        return self._source_id

    @property
    def read_only(self) -> bool:
        return self._read_only

    @property
    def dry_run(self) -> bool:
        return self._dry_run

    @property
    def version(self) -> int:
        if self._dry_run:
            return 0
        row = self._database().execute("SELECT v FROM version").fetchone()
        return int(row[0]) if row is not None else 0

    @property
    def state_id(self) -> str:
        if self._dry_run:
            return ""
        row = self._database().execute(
            "SELECT value FROM meta WHERE key = 'state_id'"
        ).fetchone()
        return str(row[0]) if row is not None else ""

    @property
    def snapshot(self) -> str:
        """One name for one committed state, safe to cache a derivation under."""

        identifier = self.state_id
        return f"{identifier[:12]}-v{self.version}" if identifier else f"v{self.version}"

    @property
    def epoch(self) -> int:
        return self._epoch

    @property
    def cursor(self) -> int | None:
        if self._dry_run:
            return None
        row = self._database().execute(
            "SELECT cursor FROM cursor WHERE source_id = ?", (self._source_id,)
        ).fetchone()
        if row is None or int(row[0]) < 1:
            return None
        return int(row[0])

    # -- writing ----------------------------------------------------------

    def put(self, object_id: str, data: bytes, metadata: dict) -> None:
        """Record one object for this pass; its bytes are written immediately."""

        self._require_writable()
        _check_object_id(object_id)
        if not isinstance(data, bytes):
            raise ValidationError("object data must be bytes")
        meta = _serialize(metadata)

        digest = hashlib.sha256(data).hexdigest()
        if not self._dry_run:
            self._write_object(digest, data)
        self._puts[object_id] = (digest, len(data), meta)
        self._seen.add(object_id)
        self._tombstones.pop(object_id, None)

    def seen(self, row: Mapping[str, Any], metadata: dict | None = None) -> None:
        """Record that this pass still holds ``row``, which it read already.

        A complete pass has to account for every live row, and a mailbox pass
        accounts for all of them at once: taking the row from :meth:`live_rows`
        costs one set insert per message instead of one query per message. The
        row is only queued for a write when its metadata actually moved, which
        makes a flag change one row and an unchanged message none.
        """

        self._require_writable()
        if not isinstance(row, Mapping) or "object_id" not in row:
            raise ValidationError("seen needs a row from live_rows or get")
        object_id = row["object_id"]
        _check_object_id(object_id)
        if not row["present"]:
            raise ManifestError(f"{object_id!r} is not a live object")
        if object_id in self._puts:
            raise ManifestError(
                f"{object_id!r} was written in this pass; seen() would revert its bytes"
            )
        self._require_object(row)
        clean = {
            key: value
            for key, value in (metadata if metadata is not None else row["metadata"]).items()
            if key not in (ABSENT_SINCE, ABSENCE_REASON)
        }
        self._seen.add(object_id)
        self._tombstones.pop(object_id, None)
        if row["absent_since"] is not None or _without_volatile(clean) != _without_volatile(
            row["metadata"]
        ):
            self._puts[object_id] = (row["sha256"], row["size"], _serialize(clean))

    def update(self, object_id: str, metadata: dict) -> None:
        """Record new metadata for an object whose bytes have not changed."""

        self._require_writable()
        _check_object_id(object_id)
        row = self.get(object_id)
        if row is None:
            raise ManifestError(f"replica state has no live object {object_id!r}")
        self.seen(row, metadata)

    def tombstone(self, object_id: str, reason: str) -> None:
        """Name an object as deleted, on evidence the provider supplied."""

        self._require_writable()
        _check_object_id(object_id)
        if not isinstance(reason, str) or not reason.strip():
            raise ValidationError("a tombstone needs a reason")
        self._tombstones[object_id] = reason
        self._puts.pop(object_id, None)

    def commit(
        self,
        *,
        complete: bool = False,
        absence_reason: str | None = None,
        captured_at: str | None = None,
        cursor: int | None = None,
    ) -> CommitStats:
        """Publish this pass in one transaction, then collect garbage.

        ``complete`` means the pass enumerated the whole source, so every live
        row it did not see must be accounted for: by a tombstone, or by
        ``absence_reason``. ``cursor`` defaults to one past the stored cursor;
        a provider cursor may jump forward, never back.

        ``version`` moves only when the pass moved a row, so ``snapshot`` -- the
        name a derived artifact is cached under, and part of the facade's cache
        identity -- stays put for an enumeration that matched the replica. The
        cursor still moves: it is the provider's position, not the state.
        """

        self._require_writable()
        if self._dry_run:
            raise PublishError("a dry run has nothing to commit")
        if not isinstance(complete, bool):
            raise ValidationError("complete must be a boolean")
        if absence_reason is not None:
            if not complete:
                raise ValidationError("a delta pass may not infer absence")
            if not isinstance(absence_reason, str) or not absence_reason.strip():
                raise ValidationError("an absence reason must be a non-empty string")
        stamped = captured_at if captured_at is not None else _now()
        if not isinstance(stamped, str) or not stamped.strip():
            raise ValidationError("captured_at must be a non-empty string")

        connection = self._database()
        try:
            connection.execute("BEGIN IMMEDIATE")
        except sqlite3.DatabaseError as exc:
            raise PublishError(f"replica state {self.path} cannot be written") from exc
        try:
            stored_epoch = self._stored_epoch()
            if stored_epoch != self._epoch:
                raise EpochError(
                    "replica epoch changed; reconcile the source before publishing"
                )
            target = self._next_cursor(cursor)
            live = {
                row[0]
                for row in connection.execute(
                    "SELECT id FROM object WHERE present = 1"
                )
            }
            seen = set(self._puts) | set(self._tombstones) | self._seen
            unseen = live - seen
            if complete and unseen and absence_reason is None:
                raise PublishError(
                    "missing tombstones or an absence reason for: "
                    + ", ".join(sorted(unseen))
                )

            written = 0
            for object_id, (digest, size, meta) in self._puts.items():
                if not self._is_new(connection, object_id, digest, size, meta):
                    continue
                connection.execute(
                    _UPSERT_PUT, (object_id, digest, size, meta, stamped)
                )
                written += 1

            tombstoned = 0
            for object_id, reason in self._tombstones.items():
                connection.execute(
                    _UPSERT_TOMBSTONE, (object_id, reason, stamped)
                )
                tombstoned += 1

            if complete:
                newly_absent = 0
                for object_id in sorted(unseen):
                    newly_absent += connection.execute(
                        "UPDATE object SET absent_since = ?, absence_reason = ?, "
                        "updated_at = ? WHERE id = ? AND present = 1 "
                        "AND absent_since IS NULL",
                        (stamped, absence_reason, stamped, object_id),
                    ).rowcount
            else:
                newly_absent = 0
            absent = int(
                connection.execute(
                    "SELECT COUNT(*) FROM object "
                    "WHERE present = 1 AND absent_since IS NOT NULL"
                ).fetchone()[0]
            )

            # A pass that moved no row is not a new state: the snapshot names
            # the derived index file and is part of the facade's cache identity,
            # so advancing it would rebuild both for nothing.
            changed = bool(written or tombstoned or newly_absent)
            current = int(
                connection.execute("SELECT v FROM version").fetchone()[0]
            )
            version = current + 1 if changed else current
            if changed:
                connection.execute("UPDATE version SET v = ?", (version,))
            connection.execute(
                "INSERT INTO cursor (source_id, cursor, epoch) VALUES (?, ?, ?) "
                "ON CONFLICT(source_id) DO UPDATE SET "
                "cursor = excluded.cursor, epoch = excluded.epoch",
                (self._source_id, target, self._epoch),
            )
            connection.execute("COMMIT")
        except BaseException:
            try:
                connection.execute("ROLLBACK")
            except sqlite3.DatabaseError:
                pass
            # The pass may have written object bytes before it rolled back. No
            # row references them now, so the next pass collects them even when
            # that pass changes nothing itself, which is what the marker asks.
            self._mark_collection_pending()
            raise

        marker = self._root / GC_MARKER
        collected = (
            self._collect_garbage()
            if complete and (written or tombstoned or marker.exists())
            else 0
        )
        self._puts.clear()
        self._seen.clear()
        self._tombstones.clear()
        self._pass_started_at = time.time()
        return CommitStats(
            version=version,
            written=written,
            absent=absent,
            tombstoned=tombstoned,
            collected=collected,
            changed=changed,
        )

    def rebuild(self, epoch: int | None = None) -> int:
        """Start a new epoch with no cursor, for a source rebuilt underneath us."""

        self._require_writable()
        connection = self._database()
        try:
            connection.execute("BEGIN IMMEDIATE")
            stored = self._stored_epoch()
            next_epoch = stored + 1 if epoch is None else epoch
            if isinstance(next_epoch, bool) or not isinstance(next_epoch, int):
                raise ValidationError("epoch must be an integer")
            if next_epoch <= stored:
                raise EpochError(f"epoch {next_epoch} does not advance {stored}")
            connection.execute(
                "INSERT INTO cursor (source_id, cursor, epoch) VALUES (?, 0, ?) "
                "ON CONFLICT(source_id) DO UPDATE SET "
                "cursor = 0, epoch = excluded.epoch",
                (self._source_id, next_epoch),
            )
            # A reader polls the version to decide freshness, so a rebuild must
            # be visible there, not only in the epoch.
            connection.execute("UPDATE version SET v = v + 1")
            connection.execute("COMMIT")
        except BaseException:
            try:
                connection.execute("ROLLBACK")
            except sqlite3.DatabaseError:
                pass
            raise
        self._epoch = next_epoch
        return next_epoch

    # -- reading ----------------------------------------------------------

    def rows(self) -> tuple[Mapping[str, Any], ...]:
        """Every row, tombstones included, in object-id order."""

        cursor = self._database().execute(
            "SELECT id, sha256, size, meta, present, absent_since, "
            "absence_reason, updated_at FROM object ORDER BY id"
        )
        return tuple(self._row(row) for row in cursor)

    def live_rows(self, prefix: str = "") -> tuple[Mapping[str, Any], ...]:
        """Every live row whose object id starts with ``prefix``, in id order."""

        if not isinstance(prefix, str):
            raise ValidationError("prefix must be a string")
        statement = (
            "SELECT id, sha256, size, meta, present, absent_since, "
            "absence_reason, updated_at FROM object WHERE present = 1"
        )
        parameters: tuple = ()
        bounds = _prefix_bounds(prefix)
        if bounds is not None:
            statement += " AND id >= ? AND id < ?"
            parameters = bounds
        elif prefix:
            # An id may contain "%" or "_", so LIKE is out; substr matches the
            # same rows, it just cannot use the index.
            statement += " AND substr(id, 1, ?) = ?"
            parameters = (len(prefix), prefix)
        cursor = self._database().execute(statement + " ORDER BY id", parameters)
        return tuple(self._row(row) for row in cursor)

    def entries(self) -> tuple[Mapping[str, Any], ...]:
        """Every live object as ``object_id``/``sha256``/``size``/``metadata``."""

        return tuple(
            {
                "object_id": row["object_id"],
                "sha256": row["sha256"],
                "size": row["size"],
                "metadata": row["metadata"],
            }
            for row in self.live_rows()
        )

    def live_object_ids(self) -> tuple[str, ...]:
        return tuple(row["object_id"] for row in self.rows() if row["present"])

    def get(self, object_id: str) -> Mapping[str, Any] | None:
        if not isinstance(object_id, str):
            raise ValidationError("object id must be a string")
        row = self._database().execute(
            "SELECT id, sha256, size, meta, present, absent_since, "
            "absence_reason, updated_at FROM object WHERE id = ?",
            (object_id,),
        ).fetchone()
        return None if row is None else self._row(row)

    def read(self, object_id: str) -> bytes:
        """An object's bytes, verified against the size and sha256 recorded."""

        row = self.get(object_id)
        if row is None or not row["present"]:
            raise ManifestError(f"replica state has no object {object_id!r}")
        digest = row["sha256"]
        if not isinstance(digest, str) or _DIGEST.fullmatch(digest) is None:
            raise ManifestError(f"{object_id!r} has no recorded sha256")
        path = self._root / OBJECTS_DIR / digest[:2] / digest
        if path.is_symlink() or not path.is_file():
            raise ManifestError(f"{object_id!r} has no object file")
        try:
            data = path.read_bytes()
        except OSError as exc:
            raise ManifestError(f"{object_id!r} is unreadable") from exc
        if len(data) != row["size"]:
            raise ManifestError(f"{object_id!r} does not match its recorded size")
        if hashlib.sha256(data).hexdigest() != digest:
            raise ManifestError(f"{object_id!r} does not match its recorded sha256")
        return data

    def _require_object(self, row: Mapping[str, Any]) -> None:
        """A live row whose file vanished is damage, not a stale cache.

        A replica restored without ``objects/`` would otherwise keep every row
        live and report a healthy pass until something reads the bytes.
        """

        digest = row["sha256"]
        if not isinstance(digest, str) or _DIGEST.fullmatch(digest) is None:
            raise ManifestError(f"{row['object_id']!r} has no recorded sha256")
        path = self._root / OBJECTS_DIR / digest[:2] / digest
        try:
            stat = path.stat()
        except OSError as exc:
            raise ManifestError(f"{row['object_id']!r} has no object file") from exc
        if path.is_symlink() or stat.st_size != row["size"]:
            raise ManifestError(f"{row['object_id']!r} does not match its recorded size")

    def close(self) -> None:
        if not self._dry_run and (self._puts or self._tombstones):
            self._mark_collection_pending()
        if self._connection is not None:
            self._connection.close()
            self._connection = None
        if self._lock is not None:
            self._lock.close()
            self._lock = None
        self._puts.clear()
        self._seen.clear()
        self._tombstones.clear()
        self._closed = True

    def __enter__(self) -> "ReplicaState":
        return self

    def __exit__(self, *_exc_info: object) -> None:
        self.close()

    # -- internals --------------------------------------------------------

    def _database(self) -> sqlite3.Connection:
        """Open the writer's database on first use.

        A pass that refuses before it commits -- a missing vault, a symlinked
        note -- must not leave a database behind, so opening is deferred past
        the enumeration.
        """

        if self._closed:
            raise PublishError("replica state is closed")
        if self._connection is None:
            if self._dry_run:
                raise PublishError("a dry run has no database")
            self._connection = self._open()
            self._epoch = self._stored_epoch()
        return self._connection

    def _require_writable(self) -> None:
        if self._closed:
            raise PublishError("replica state is closed")
        if self._read_only:
            raise PublishError("replica state is read-only")

    def _open(self) -> sqlite3.Connection:
        if self._read_only:
            return self._open_reader()
        self._root.mkdir(parents=True, exist_ok=True)
        if self.path.is_symlink():
            raise PublishError(f"{self.path} is a symlink; refusing to follow it")
        try:
            connection = sqlite3.connect(self.path, isolation_level=None)
            # WAL needs a writable -shm/-wal beside the database, and the facade
            # mounts the replica read-only.
            connection.execute("PRAGMA journal_mode=DELETE")
            connection.execute("PRAGMA synchronous=FULL")
            connection.executescript(_SCHEMA)
            if connection.execute("SELECT v FROM version").fetchone() is None:
                connection.execute("INSERT INTO version (v) VALUES (0)")
            if (
                connection.execute(
                    "SELECT value FROM meta WHERE key = 'state_id'"
                ).fetchone()
                is None
            ):
                # A replica that is deleted and rebuilt starts its versions over,
                # so anything caching by version (the facade's search index) needs
                # an identity that a rebuild cannot reuse.
                connection.execute(
                    "INSERT INTO meta (key, value) VALUES ('state_id', ?)",
                    (uuid.uuid4().hex,),
                )
            stored = self._source_of(connection)
            if stored and self._source_id and stored != self._source_id:
                raise PublishError(
                    f"{self.path} holds source {stored!r}, not {self._source_id!r}"
                )
            self._source_id = self._source_id or stored
        except sqlite3.DatabaseError as exc:
            raise PublishError(f"replica state {self.path} is unusable") from exc
        except BaseException:
            connection.close()
            raise
        return connection

    def _open_reader(self) -> sqlite3.Connection:
        if self.path.is_symlink():
            raise PublishError(f"{self.path} is a symlink; refusing to follow it")
        if not self.path.is_file():
            raise ManifestError(f"{self._root} has no replica state")
        uri = f"file:{quote(str(self.path.resolve()))}?mode=ro"
        try:
            connection = sqlite3.connect(uri, uri=True)
            connection.execute("PRAGMA query_only=ON")
            self._integrity_check(connection)
            # A file that is a database but not this schema (a truncated first
            # creation) must not escape as a raw sqlite3 error.
            connection.execute("SELECT v FROM version").fetchone()
        except sqlite3.DatabaseError as exc:
            raise PublishError(f"replica state {self.path} is unusable") from exc
        return connection

    def _integrity_check(self, connection: sqlite3.Connection) -> None:
        # The header's change counter moves on every write transaction, which
        # mtime and size do not: SQLite rewrites pages in place.
        try:
            with self.path.open("rb") as handle:
                header = handle.read(28)
        except OSError as exc:
            raise PublishError(f"replica state {self.path} is unreadable") from exc
        if len(header) < 28:
            raise PublishError(f"replica state {self.path} is damaged")
        key = (str(self.path), int.from_bytes(header[24:28], "big"))
        if key in _VERIFIED:
            return
        result = connection.execute("PRAGMA integrity_check").fetchone()
        if result is None or result[0] != "ok":
            raise PublishError(f"replica state {self.path} is damaged")
        _VERIFIED[key] = None

    def _write_object(self, digest: str, data: bytes) -> None:
        objects = self._root / OBJECTS_DIR
        if objects.is_symlink():
            raise PublishError(f"{objects} is a symlink; refusing to follow it")
        bucket = objects / digest[:2]
        if bucket.is_symlink():
            raise PublishError(f"{bucket} is a symlink; refusing to follow it")
        created = not bucket.is_dir()
        try:
            bucket.mkdir(parents=True, exist_ok=True)
        except OSError as exc:
            raise PublishError(f"{bucket} cannot be created") from exc
        destination = bucket / digest
        if destination.is_symlink():
            raise PublishError(f"{destination} is a symlink; refusing to follow it")
        if destination.is_file():
            if destination.stat().st_size != len(data):
                raise ManifestError(f"{destination} is corrupt")
            return
        temporary = bucket / f".{digest}.{os.getpid()}.{time.time_ns()}.tmp"
        try:
            # The row is committed with synchronous=FULL, so the bytes must
            # reach the disk first or a power loss leaves a row with no object.
            with temporary.open("wb") as handle:
                handle.write(data)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, destination)
        except OSError as exc:
            temporary.unlink(missing_ok=True)
            raise PublishError(f"{destination} cannot be written") from exc
        self._sync_directory(bucket)
        if created:
            self._sync_directory(objects)

    @staticmethod
    def _sync_directory(path: Path) -> None:
        try:
            descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
        except OSError:
            return
        try:
            os.fsync(descriptor)
        except OSError:
            pass
        finally:
            os.close(descriptor)

    def _acquire_lock(self) -> None:
        """Refuse a second pass on the same source instead of racing it.

        Two writers would let one commit's GC delete the other's in-flight
        object bytes, leaving a committed row with no file.
        """

        self._root.mkdir(parents=True, exist_ok=True)
        path = self._root / LOCK_NAME
        if path.is_symlink():
            raise PublishError(f"{path} is a symlink; refusing to follow it")
        try:
            handle = path.open("a+")
        except OSError as exc:
            raise PublishError(f"{path} cannot be opened") from exc
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as exc:
            handle.close()
            raise PublishError(f"another pass holds {path}") from exc
        self._lock = handle

    def _mark_collection_pending(self) -> None:
        """Ask the next pass to sweep, without following a planted symlink."""

        try:
            handle = os.open(
                self._root / GC_MARKER,
                os.O_CREAT | os.O_WRONLY | os.O_NOFOLLOW,
                0o600,
            )
        except OSError:
            return
        os.close(handle)

    def _is_new(
        self,
        connection: sqlite3.Connection,
        object_id: str,
        digest: str,
        size: int,
        meta: str,
    ) -> bool:
        row = connection.execute(
            "SELECT sha256, size, meta, present, absent_since FROM object "
            "WHERE id = ?",
            (object_id,),
        ).fetchone()
        if row is None:
            return True
        sha256, stored_size, stored_meta, present, absent_since = row
        if present != 1 or absent_since is not None:
            return True
        if sha256 != digest or stored_size != size:
            return True
        return _identity(stored_meta) != _identity(meta)

    def _next_cursor(self, cursor: int | None) -> int:
        base = self.cursor or 0
        if cursor is None:
            return base + 1
        if isinstance(cursor, bool) or not isinstance(cursor, int) or cursor < 1:
            raise ValidationError("cursor must be a positive integer")
        if cursor <= base:
            raise CursorError(f"cursor {cursor} does not advance {base}")
        return cursor

    def _stored_epoch(self) -> int:
        if self._connection is None:
            return 1
        row = self._connection.execute(
            "SELECT epoch FROM cursor WHERE source_id = ?", (self._source_id,)
        ).fetchone()
        return int(row[0]) if row is not None else 1

    def _stored_source_id(self) -> str:
        if self._connection is None:
            return ""
        return self._source_of(self._connection)

    @staticmethod
    def _source_of(connection: sqlite3.Connection) -> str:
        row = connection.execute(
            "SELECT source_id FROM cursor ORDER BY source_id LIMIT 1"
        ).fetchone()
        return str(row[0]) if row is not None else ""

    def _collect_garbage(self) -> int:
        """Delete object files no row references and no live pass can still need."""

        objects = self._root / OBJECTS_DIR
        if objects.is_symlink() or not objects.is_dir():
            return 0
        referenced = {
            row[0]
            for row in self._database().execute(
                "SELECT DISTINCT sha256 FROM object "
                "WHERE present = 1 AND sha256 IS NOT NULL"
            )
        }
        collected = 0
        for bucket in objects.iterdir():
            if bucket.is_symlink() or not bucket.is_dir():
                continue
            for path in bucket.iterdir():
                if path.is_symlink() or not path.is_file():
                    continue
                if path.name in referenced:
                    continue
                try:
                    if path.stat().st_mtime >= self._pass_started_at:
                        continue
                    path.unlink()
                except OSError:
                    continue
                collected += 1
        try:
            (self._root / GC_MARKER).unlink(missing_ok=True)
        except OSError:
            pass
        return collected

    @staticmethod
    def _row(row: tuple) -> Mapping[str, Any]:
        object_id, sha256, size, meta, present, absent_since, reason, updated = row
        metadata = json.loads(meta) if meta is not None else {}
        if absent_since is not None:
            metadata[ABSENT_SINCE] = absent_since
        if reason is not None:
            metadata[ABSENCE_REASON] = reason
        return {
            "object_id": object_id,
            "sha256": sha256,
            "size": size,
            "metadata": metadata,
            "present": bool(present),
            "absent_since": absent_since,
            "absence_reason": reason,
            "updated_at": updated,
        }
