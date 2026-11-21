"""A Brave ``History`` database small enough to read in a test.

The schema is the shape the pinned browser writes: the tables the collector's
fidelity list names, with the columns a real profile has. Two visits over two URLs
are enough to tell a copy from an empty file, and one visit_source row is enough to
prove a second table survives a snapshot.
"""

from __future__ import annotations

import sqlite3
from pathlib import Path

SCHEMA = (
    "CREATE TABLE urls (id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR,"
    " visit_count INTEGER DEFAULT 0, typed_count INTEGER DEFAULT 0,"
    " last_visit_time INTEGER NOT NULL, hidden INTEGER DEFAULT 0)",
    "CREATE TABLE visits (id INTEGER PRIMARY KEY, url INTEGER NOT NULL,"
    " visit_time INTEGER NOT NULL, from_visit INTEGER, transition INTEGER DEFAULT 0,"
    " segment_id INTEGER, visit_duration INTEGER DEFAULT 0)",
    "CREATE TABLE visit_source (id INTEGER PRIMARY KEY, source INTEGER NOT NULL)",
    "CREATE TABLE keyword_search_terms (keyword_id INTEGER NOT NULL, url_id INTEGER NOT NULL,"
    " term LONGVARCHAR NOT NULL, normalized_term LONGVARCHAR NOT NULL)",
    "CREATE TABLE downloads (id INTEGER PRIMARY KEY, current_path LONGVARCHAR NOT NULL,"
    " target_path LONGVARCHAR NOT NULL, start_time INTEGER NOT NULL)",
    "CREATE TABLE segments (id INTEGER PRIMARY KEY, name LONGVARCHAR, url_id INTEGER NOT NULL)",
    "CREATE INDEX urls_url_index ON urls (url)",
    "CREATE INDEX visits_url_index ON visits (url)",
)

#: 2026-11-20T00:00:00Z in Chromium's microseconds-since-1601.
VISIT_TIME = 133_000_000_000_000


def create_history(path: Path, *, visits: int = 2) -> Path:
    """Write a History database at ``path`` and return it."""

    path.parent.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(str(path))
    try:
        for statement in SCHEMA:
            connection.execute(statement)
        for index in range(visits):
            connection.execute(
                "INSERT INTO urls (id, url, title, visit_count, last_visit_time)"
                " VALUES (?, ?, ?, 1, ?)",
                (index + 1, f"https://example.com/{index}", f"Example {index}", VISIT_TIME),
            )
            connection.execute(
                "INSERT INTO visits (id, url, visit_time, transition) VALUES (?, ?, ?, 805306368)",
                (index + 1, index + 1, VISIT_TIME + index),
            )
            connection.execute(
                "INSERT INTO visit_source (id, source) VALUES (?, 0)", (index + 1,)
            )
            connection.execute(
                "INSERT INTO segments (name, url_id) VALUES (?, ?)",
                (f"segment {index}", index + 1),
            )
        connection.execute("PRAGMA user_version = 70")
        connection.commit()
    finally:
        connection.close()
    return path


def live_history(path: Path, *, rows: int = 1) -> tuple[sqlite3.Connection, Path]:
    """Write a WAL-mode History and keep the writer open, as the browser does.

    The returned connection is the live writer: closing it checkpoints the log, so
    a test that wants a database *with* a log most hold it until it has copied.
    """

    path.parent.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(str(path))
    connection.execute("PRAGMA journal_mode = WAL")
    for statement in SCHEMA:
        connection.execute(statement)
    for index in range(rows):
        connection.execute(
            "INSERT INTO urls (id, url, title, last_visit_time) VALUES (?, ?, ?, ?)",
            (index + 1, f"https://example.com/{index}", f"Example {index}", VISIT_TIME),
        )
        connection.execute(
            "INSERT INTO visits (id, url, visit_time) VALUES (?, ?, ?)",
            (index + 1, index + 1, VISIT_TIME + index),
        )
    connection.commit()
    return connection, path


def url_count(path: Path) -> int:
    connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        row = connection.execute("SELECT COUNT(*) FROM urls").fetchone()
    finally:
        connection.close()
    return int(row[0]) if row else 0
