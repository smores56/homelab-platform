"""Raw browsing history: one Brave ``History`` copy becomes one generation.

Chromium takes an exclusive lock on ``History`` and keeps most recent writes in
its WAL, so the database that is collected is always a *copy* taken while no
Brave process holds the profile -- at login before launch, and on idle or
shutdown. This module never opens the live file: it refuses a ``-wal`` or
``-journal`` sibling, because their presence means the copy is incomplete, and it
refuses a symlink for the same reason it refuses one anywhere else.

What lands is the whole database, not ``visits JOIN urls``:

* ``brave::db`` is the copy's own bytes, verified by sha256, so the replica is
  what the browser wrote rather than this collector's reading of it.
* One derived object per table holds every column and every row, so a search
  index can be rebuilt without the browser and without guessing at a projection.

``PRAGMA integrity_check`` must answer ``ok`` before anything is written, and a
database naming no user tables publishes nothing. Retention expiry, a user
deleting history and a profile being recreated all look the same from here, so a
table or a URL that stops appearing is carried forward with a reason instead of
being tombstoned.
"""

from __future__ import annotations

import base64
import sqlite3
from pathlib import Path
from typing import Any, Iterable, Mapping
from urllib.parse import quote

from ...errors import PublishError
from ...model import FidelityLimit
from ..staging import StagingGeneration
from .replica import (
    ABSENCE_RETENTION,
    CollectReport,
    canonical_json,
    carry_forward,
    file_sha256,
    previous_replica,
)

SOURCE_ID = "brave.history"

FIDELITY_LIMITS: tuple[FidelityLimit, ...] = (
    FidelityLimit(
        field="deletion",
        reason="retention expiry, user deletion and profile recreation are indistinguishable",
    ),
    FidelityLimit(
        field="device.smoreswork",
        reason="the work Mac is outside agent collection; its history is a declared gap",
    ),
    FidelityLimit(
        field="sync.state",
        reason="the headless Brave Sync profile and its seed are removed, so no sync history exists",
    ),
)

_LIVE_SUFFIXES = ("-wal", "-journal")


def _refuse_live_or_partial(path: Path) -> None:
    if path.is_symlink():
        raise PublishError(f"{path} is a symlink; refusing to follow it")
    if not path.is_file():
        raise PublishError(f"{path} is not a file")
    for suffix in _LIVE_SUFFIXES:
        sibling = path.with_name(path.name + suffix)
        if sibling.exists():
            raise PublishError(
                f"{sibling.name} exists beside the copy; the database is still being written"
            )


def _jsonable(value: Any) -> Any:
    if isinstance(value, bytes):
        return {"b64": base64.b64encode(value).decode("ascii")}
    if isinstance(value, (str, int, float)) or value is None:
        return value
    raise PublishError(f"a column holds an unsupported type {type(value).__name__}")


def _decode_text(value: bytes) -> str | bytes:
    """Hand back TEXT that is not UTF-8 as the bytes it is.

    Chromium stores binary values in TEXT-affinity columns (``meta.value`` for
    several keys), and sqlite3 decodes every TEXT value before the collector can
    look at it, so the default factory aborts the whole dump with ``Could not
    decode to UTF-8``. A value that decodes stays a string; one that does not is
    carried as bytes and base64 in ``_jsonable``.
    """

    try:
        return value.decode("utf-8")
    except UnicodeDecodeError:
        return value


def _tables(connection: sqlite3.Connection) -> list[str]:
    rows = connection.execute(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
    ).fetchall()
    return [str(row[0]) for row in rows]


def _dump_table(connection: sqlite3.Connection, table: str) -> dict[str, Any]:
    escaped = table.replace('"', '""')
    columns = [
        str(row[1])
        for row in connection.execute(f'PRAGMA table_info("{escaped}")').fetchall()
    ]
    rows = connection.execute(f'SELECT * FROM "{escaped}"').fetchall()
    return {
        "table": table,
        "columns": columns,
        "rows": [[_jsonable(value) for value in row] for row in rows],
    }


def collect_brave_db(
    database: str | Path,
    generation: StagingGeneration,
    *,
    device: str,
    profile: str,
    captured_at: str,
) -> CollectReport:
    """Enumerate one Brave history copy into ``generation``; never commit it."""

    path = Path(database)
    _refuse_live_or_partial(path)
    if not device.strip() or not profile.strip():
        raise PublishError("a history generation names its device and profile")

    raw = path.read_bytes()
    digest = file_sha256(path)
    generation.put(
        "brave::db",
        raw,
        {
            "source_id": SOURCE_ID,
            "kind": "database",
            "device": device,
            "profile": profile,
            "sha256": digest,
            "size": len(raw),
            "captured_at": captured_at,
        },
    )

    try:
        connection = sqlite3.connect(f"file:{quote(str(path))}?mode=ro", uri=True)
        connection.text_factory = _decode_text
    except sqlite3.Error as exc:
        raise PublishError(f"{path.name} is not a readable SQLite database") from exc
    try:
        try:
            check = connection.execute("PRAGMA integrity_check").fetchall()
        except sqlite3.Error as exc:
            raise PublishError(f"{path.name} is not a readable SQLite database") from exc
        if [tuple(row) for row in check] != [("ok",)]:
            raise PublishError(f"{path.name} fails integrity_check: {check!r}")
        tables = _tables(connection)
        if not tables:
            raise PublishError(f"{path.name} has no user tables")
        counts: dict[str, int] = {}
        for table in tables:
            dump = _dump_table(connection, table)
            counts[table] = len(dump["rows"])
            generation.put(
                f"brave::table::{table}",
                canonical_json(dump),
                {
                    "source_id": SOURCE_ID,
                    "kind": "table",
                    "device": device,
                    "profile": profile,
                    "table": table,
                    "columns": dump["columns"],
                    "rows": counts[table],
                    "db_sha256": digest,
                    "captured_at": captured_at,
                },
            )
        page_count = connection.execute("PRAGMA page_count").fetchone()
        user_version = connection.execute("PRAGMA user_version").fetchone()
    finally:
        connection.close()

    carried = carry_forward(
        generation,
        previous_replica(generation),
        reason=ABSENCE_RETENTION,
        captured_at=captured_at,
    )
    return CollectReport(
        source_id=SOURCE_ID,
        generation_id=generation.generation_id,
        objects=sum(counts.values()),
        carried=carried,
        deleted=0,
        details={
            "device": device,
            "profile": profile,
            "tables": counts,
            "db_sha256": digest,
            "page_count": page_count[0] if page_count else None,
            "user_version": user_version[0] if user_version else None,
        },
    )


def fidelity_fields() -> Iterable[str]:
    return (
        "database.raw",
        "table.urls",
        "table.visits",
        "table.visit_source",
        "table.downloads",
        "table.keyword_search_terms",
        "table.segments",
    )


def declared_columns(report_details: Mapping[str, Any]) -> Iterable[str]:
    """The tables a generation actually carried, for a fidelity declaration."""

    tables = report_details.get("tables")
    if not isinstance(tables, Mapping):
        return ()
    return (f"table.{name}" for name in sorted(tables))
