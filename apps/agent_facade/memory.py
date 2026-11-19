"""Per-deployment memory over ``FileMemory``, plus a disposable FTS5 index.

The safety rule this module exists for: memory is one profile per deployment and
the full-text index is derived, never authoritative. A hit is only returned after
its record has been read back from disk and found alive, so a record deleted on
disk disappears from search even if the index still lists it; the index is
rebuilt from the record files when it is missing, stale, or asked to be, and
deleting it changes nothing but the cost of the next search. ``FileMemory`` owns
the record format, the provenance rules and the revision/supersedes rule; this
module adds a profile mapping, a monotonic revision per key, and an index.

The profile mapping is what keeps the two deployments' memories apart: personal
memory lives in the ``local`` profile, general memory in ``external``, and a
``MemoryIndex`` can only ever open the one that matches its deployment.
"""

from __future__ import annotations

import os
import sqlite3
import tempfile
import threading
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import MappingProxyType
from typing import Mapping, Sequence

from data_plane.errors import ContractError, ValidationError
from data_plane.identity import EXTERNAL_PROFILE, LOCAL_PROFILE
from data_plane.memory import FileMemory, MemoryRecord
from data_plane.model import Visibility

from . import contracts

#: Personal memory is the local profile, general memory the external one: the
#: same split the identity library signs, so no second vocabulary appears.
PROFILE_BY_DEPLOYMENT: Mapping[Visibility, str] = MappingProxyType(
    {
        Visibility.PERSONAL: LOCAL_PROFILE,
        Visibility.GENERAL: EXTERNAL_PROFILE,
    }
)

#: The record the facade writes is attributed to the facade; the upstream
#: citation travels in provenance, which a memory record requires anyway.
MEMORY_SOURCE = "agent-memory"
INDEX_DIRECTORY = "cache"
INDEX_NAME = "index.sqlite"
SCHEMA_VERSION = 1
#: Bounded candidate window: a stale index entry costs a read, not a scan.
CANDIDATE_LIMIT = 512

_CREATE_INDEX = (
    "CREATE VIRTUAL TABLE records USING fts5("
    "key UNINDEXED, body, tags, revision UNINDEXED, digest UNINDEXED)"
)
_CREATE_STATE = (
    "CREATE TABLE indexed (key TEXT PRIMARY KEY, sha256 TEXT NOT NULL, "
    "updated_at TEXT NOT NULL)"
)
_INSERT_INDEX = (
    "INSERT INTO records (key, body, tags, revision, digest) VALUES (?, ?, ?, ?, ?)"
)
_INSERT_STATE = "INSERT INTO indexed (key, sha256, updated_at) VALUES (?, ?, ?)"


class MemoryNotFound(ValidationError):
    """The key is not set in this deployment's memory."""


@dataclass(frozen=True)
class MemoryHit:
    """One derived-index hit: the key, an excerpt, and the revision it was built from."""

    key: str
    snippet: str
    revision: str

    def as_dict(self) -> dict[str, str]:
        return {"key": self.key, "snippet": self.snippet, "revision": self.revision}


def _now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def _parse(value: str) -> datetime:
    parsed = datetime.fromisoformat(value)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed


def next_revision(existing: str | None) -> str:
    """The next record timestamp: strictly after the current one.

    ``FileMemory`` supersedes by ``updated_at`` compared as a string, so two
    writes inside one clock second would tie and the second would not win. The
    revision therefore never repeats for a key.
    """

    now = datetime.now(timezone.utc).replace(microsecond=0)
    if existing is None:
        return now.isoformat()
    candidate = max(now, _parse(existing) + timedelta(seconds=1))
    return candidate.isoformat()


class MemoryIndex:
    """One deployment's memory profile and the FTS5 index derived from it."""

    def __init__(self, root: str | os.PathLike[str], deployment: Visibility) -> None:
        profile = PROFILE_BY_DEPLOYMENT.get(deployment)
        if profile is None:
            raise ContractError(
                f"deployment must be one of "
                f"{', '.join(item.value for item in PROFILE_BY_DEPLOYMENT)}, "
                f"got {deployment!r}"
            )
        self.deployment = deployment
        self.profile = profile
        self.root = Path(root).expanduser().resolve()
        self.memory = FileMemory(self.root, profile)
        self.directory = self.root / profile / INDEX_DIRECTORY
        self.path = self.directory / INDEX_NAME
        self._lock = threading.Lock()

    def get(self, key: str) -> MemoryRecord:
        record = self.memory.get(key)
        if record is None or record.deleted:
            raise MemoryNotFound(f"memory key {key!r} is not set")
        return record

    def write(
        self,
        key: str,
        value: str,
        tags: Sequence[str] = (),
        provenance: Mapping[str, str] | None = None,
    ) -> MemoryRecord:
        with self._lock:
            existing = self.memory.get(key)
            live = existing if existing is not None and not existing.deleted else None
            updated_at = next_revision(None if live is None else live.updated_at)
            record = MemoryRecord(
                id=key,
                profile=self.profile,
                source=MEMORY_SOURCE,
                content=value,
                tags=tuple(tags),
                provenance=dict(provenance or {}),
                created_at=live.created_at if live is not None else updated_at,
                updated_at=updated_at,
            )
            self.memory.put(record)
            return record

    def search(self, query: str, limit: int) -> tuple[MemoryHit, ...]:
        expression = contracts.search_expression(query)
        words = contracts.query_words(query)
        if limit < 1:
            raise ValidationError("limit must be at least 1")

        with self._lock:
            self._ensure_fresh()
            hits: list[MemoryHit] = []
            for key in self._match(expression):
                # The index is a candidate list, not the answer: a record that
                # is missing, tombstoned, or changed on disk is dropped here.
                record = self.memory.get(key)
                if record is None or record.deleted:
                    continue
                hits.append(
                    MemoryHit(
                        key=record.id,
                        snippet=contracts.snippet(record.content, words[0]),
                        revision=record.updated_at,
                    )
                )
                if len(hits) == limit:
                    break
            return tuple(hits)

    def rebuild(self) -> int:
        """Rebuild the index from the record files; returns the indexed count."""

        with self._lock:
            return self._rebuild()

    def _ensure_fresh(self) -> None:
        """Rebuild when the index is missing, unreadable, or out of date."""

        if self._signature() != self._stored_signature():
            self._rebuild()

    def _signature(self) -> tuple[tuple[str, str, str], ...]:
        """What the index should contain: live records as they are on disk now."""

        return tuple(
            sorted(
                (record.id, record.sha256, record.updated_at)
                for record in self.memory.search("")
            )
        )

    def _stored_signature(self) -> tuple[tuple[str, str, str], ...] | None:
        """What the index says it contains, or None when it cannot be trusted."""

        if not self.path.is_file():
            return None
        try:
            connection = self._connect()
            try:
                version = connection.execute("PRAGMA user_version").fetchone()[0]
                if version != SCHEMA_VERSION:
                    return None
                rows = connection.execute(
                    "SELECT key, sha256, updated_at FROM indexed ORDER BY key"
                ).fetchall()
            finally:
                connection.close()
        except sqlite3.Error:
            return None
        return tuple((str(key), str(sha256), str(updated_at)) for key, sha256, updated_at in rows)

    def _connect(self) -> sqlite3.Connection:
        # Read-only: a search must never be able to create or repair the index.
        return sqlite3.connect(f"{self.path.as_uri()}?mode=ro", uri=True)

    def _match(self, expression: str) -> tuple[str, ...]:
        connection = self._connect()
        try:
            rows = connection.execute(
                "SELECT key FROM records WHERE records MATCH ? ORDER BY rank, key LIMIT ?",
                (expression, CANDIDATE_LIMIT),
            ).fetchall()
        except sqlite3.Error as error:
            raise ValidationError(f"memory index could not be queried: {error}") from error
        finally:
            connection.close()
        return tuple(str(row[0]) for row in rows)

    def _rebuild(self) -> int:
        records = tuple(self.memory.search(""))
        self.directory.mkdir(parents=True, exist_ok=True)
        descriptor, temporary = tempfile.mkstemp(
            dir=self.directory, prefix=".index.", suffix=".tmp"
        )
        os.close(descriptor)
        try:
            connection = sqlite3.connect(temporary)
            try:
                # One transaction, then an atomic replace: a search either sees
                # the old index or the new one, never half of either.
                connection.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")
                connection.execute(_CREATE_INDEX)
                connection.execute(_CREATE_STATE)
                connection.executemany(
                    _INSERT_INDEX,
                    [
                        (
                            record.id,
                            record.content,
                            " ".join(record.tags),
                            record.updated_at,
                            record.sha256,
                        )
                        for record in records
                    ],
                )
                connection.executemany(
                    _INSERT_STATE,
                    [(record.id, record.sha256, record.updated_at) for record in records],
                )
                connection.commit()
            finally:
                connection.close()
            os.chmod(temporary, 0o600)
            os.replace(temporary, self.path)
        except sqlite3.Error as error:
            # An index failure is a refusal the caller can read, not a traceback
            # on the wire; the record files are untouched either way.
            Path(temporary).unlink(missing_ok=True)
            raise ValidationError(f"memory index could not be rebuilt: {error}") from error
        except BaseException:
            Path(temporary).unlink(missing_ok=True)
            raise
        return len(records)
