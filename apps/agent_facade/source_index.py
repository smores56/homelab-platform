"""The derived full-text index over one committed state's projections.

A committed state is immutable until the next pass, so its index is a pure
function of the snapshot: one SQLite file per ``(source, snapshot)``, named
after the snapshot, and a new snapshot is a new file rather than an update. That is
what makes the file disposable instead of a second store -- deleting it costs one
rebuild, and the projections it was built from are still in the state.

Two properties keep it a cache and never an authority:

* The tokenizer is ``trigram``, not the word tokenizer memory uses: the adapter
  it replaces matches substrings, so ``orld`` must find ``Hello world``. A
  trigram cannot index or match anything shorter than three characters, which is
  why a query with a short word is answered by the scan instead (see
  ``replica_sources``), not by a narrower index. Its case folding is SQLite's
  rather than ``str.casefold()``'s: on ordinary text the two agree, and a word
  that reaches a record only through a compatibility character (``ﬁ`` for
  ``fi``) is a hit the scan finds and this file does not. The scan is the
  definition; this is the fast path over it.
* Query text is never handed to the FTS5 parser: the words are quoted and
  AND-joined by ``contracts.search_expression`` and the result travels as a
  bound parameter, so ``OR``, ``-`` or ``NEAR(`` in a query stay literals.

Every failure here -- an unwritable root, a missing file, a foreign schema, a
damaged database -- is a ``SourceIndexUnavailable``: the caller scans instead.
An optimisation that cannot run is never a tool failure.
"""

from __future__ import annotations

import os
import sqlite3
import tempfile
from pathlib import Path
from typing import Mapping, Protocol, Sequence

from data_plane.errors import ValidationError

from . import contracts

#: Bumped when the table layout or the projection feeding it changes; a file
#: carrying another version is rebuilt rather than read.
SCHEMA_VERSION = 2
#: The suffix that identifies one snapshot's file inside a source directory.
SUFFIX = ".sqlite"
#: The shortest word a trigram can match. A shorter one is a scan's job.
MIN_WORD_CHARS = 3

_CREATE_INDEX = (
    "CREATE VIRTUAL TABLE records USING fts5("
    "record_id UNINDEXED, title, body, tokenize='trigram')"
)
_CREATE_META = "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)"
_INSERT_INDEX = "INSERT INTO records (record_id, title, body) VALUES (?, ?, ?)"
_INSERT_META = "INSERT INTO meta (key, value) VALUES (?, ?)"
_MATCH = "SELECT record_id FROM records WHERE records MATCH ? ORDER BY rank, record_id LIMIT ?"
#: A hit is answered from the file: the title and body are the projection that
#: built it, so a search never has to project the state again.
_MATCH_ROWS = (
    "SELECT record_id, title, body FROM records "
    "WHERE records MATCH ? ORDER BY rank, record_id LIMIT ?"
)


class SourceIndexUnavailable(Exception):
    """The derived index cannot answer, so the caller must answer by scanning."""


class RecordView(Protocol):
    """The text one record contributes; a ``sources.SourceRecord`` satisfies it."""

    title: str
    body: str


def _plain(name: str) -> bool:
    """A name that can only ever be one path component."""

    return bool(name) and name not in {".", ".."} and "/" not in name and "\x00" not in name


class SourceIndex:
    """One source's index of one committed state."""

    def __init__(self, root: str | os.PathLike[str], source_id: str, snapshot: str) -> None:
        if not _plain(source_id) or not _plain(snapshot):
            raise SourceIndexUnavailable(
                f"no index path for source {source_id!r} state {snapshot!r}"
            )
        self.root = Path(root).expanduser().resolve()
        self.source_id = source_id
        self.snapshot = snapshot
        self.directory = self.root / source_id
        self.path = self.directory / f"{snapshot}{SUFFIX}"
        self._connection: sqlite3.Connection | None = None

    def build(self, records: Mapping[str, RecordView]) -> None:
        """Write this snapshot's file, or keep the one already published.

        The file is named after a snapshot and records what it was
        built from, so an existing file with this schema version is the answer
        already: rewriting it on every process start would cost a full rebuild to
        produce the same bytes.
        """

        # A rebuild replaces the file, so a handle opened on the old one is stale.
        self.close()
        if self._published():
            self._prune()
            return
        temporary: str | None = None
        try:
            self.directory.mkdir(parents=True, exist_ok=True)
            descriptor, temporary = tempfile.mkstemp(
                dir=self.directory, prefix=f".{self.snapshot}.", suffix=".tmp"
            )
            os.close(descriptor)
            connection = sqlite3.connect(temporary)
            try:
                connection.execute(_CREATE_INDEX)
                connection.execute(_CREATE_META)
                connection.executemany(
                    _INSERT_META,
                    [
                        ("schema_version", str(SCHEMA_VERSION)),
                        ("source_id", self.source_id),
                        ("snapshot", self.snapshot),
                    ],
                )
                connection.executemany(
                    _INSERT_INDEX,
                    [(record_id, view.title, view.body) for record_id, view in records.items()],
                )
                connection.commit()
            finally:
                connection.close()
            os.chmod(temporary, 0o600)
            os.replace(temporary, self.path)
        except (OSError, sqlite3.Error) as error:
            if temporary is not None:
                Path(temporary).unlink(missing_ok=True)
            raise SourceIndexUnavailable(
                f"source index for {self.source_id!r} state "
                f"{self.snapshot!r} could not be built: {error}"
            ) from error
        self._prune()

    def search(self, words: Sequence[str], limit: int) -> tuple[str, ...]:
        """Record ids matching every word, best first, or why the index cannot say.

        ``limit`` is the caller's, not a candidate window: the files hold one
        snapshot, so the rows are already the answer set.
        """

        return tuple(row[0] for row in self.rows(words, limit))

    def rows(self, words: Sequence[str], limit: int) -> tuple[tuple[str, str, str], ...]:
        """``(record_id, title, body)`` for the matching records, best first.

        The row carries the projection the file was built from, so a caller can
        answer a hit without projecting the state: that pass is the cost this
        file exists to avoid.
        """

        if limit < 1:
            raise ValidationError("limit must be at least 1")
        if not words:
            raise ValidationError("query must contain at least one word")
        if any(len(word) < MIN_WORD_CHARS for word in words):
            raise SourceIndexUnavailable("a trigram index cannot match a word that short")
        expression = contracts.search_expression(" ".join(words))
        connection = self._connect()
        try:
            rows = connection.execute(_MATCH_ROWS, (expression, limit)).fetchall()
        except sqlite3.Error as error:
            raise SourceIndexUnavailable(
                f"source index for {self.source_id!r} could not be queried: {error}"
            ) from error
        return tuple((str(row[0]), str(row[1]), str(row[2])) for row in rows)

    def published(self) -> bool:
        """Whether this snapshot's file is already here at this schema version.

        A caller that only needs to search asks this first: ``build`` rewrites the
        file from a projection, and a file that is already the answer makes that
        pass pure cost.
        """

        return self._published()

    def close(self) -> None:
        if self._connection is not None:
            self._connection.close()
            self._connection = None

    def _connect(self) -> sqlite3.Connection:
        """The read-only handle, opened once; a search never repairs the file."""

        if self._connection is not None:
            return self._connection
        if not self.path.is_file():
            raise SourceIndexUnavailable(
                f"no source index for {self.source_id!r} state {self.snapshot!r}"
            )
        try:
            connection = sqlite3.connect(f"{self.path.as_uri()}?mode=ro", uri=True)
        except sqlite3.Error as error:
            raise SourceIndexUnavailable(f"source index could not be opened: {error}") from error
        if not self._is_current(connection):
            connection.close()
            raise SourceIndexUnavailable(
                f"source index for {self.source_id!r} state "
                f"{self.snapshot!r} is not this schema version"
            )
        self._connection = connection
        return connection

    def _published(self) -> bool:
        """Whether the file already is this snapshot's index at this version."""

        if not self.path.is_file():
            return False
        try:
            connection = sqlite3.connect(f"{self.path.as_uri()}?mode=ro", uri=True)
            try:
                return self._is_current(connection)
            finally:
                connection.close()
        except sqlite3.Error:
            return False

    def _is_current(self, connection: sqlite3.Connection) -> bool:
        try:
            rows = connection.execute("SELECT key, value FROM meta").fetchall()
        except sqlite3.Error:
            return False
        meta = {str(key): str(value) for key, value in rows}
        return meta == {
            "schema_version": str(SCHEMA_VERSION),
            "source_id": self.source_id,
            "snapshot": self.snapshot,
        }

    def _prune(self) -> None:
        """Delete this source's other files: one index, one snapshot.

        A failed unlink is left alone on purpose: the next build that publishes a
        newer snapshot tries again, and a file that could not be removed costs
        disk, not correctness.
        """

        try:
            stale = [
                entry
                for entry in self.directory.iterdir()
                if entry.name != self.path.name
                and entry.name.endswith(SUFFIX)
                and not entry.is_dir()
            ]
        except OSError:
            return
        for entry in stale:
            try:
                entry.unlink()
            except OSError:
                continue
