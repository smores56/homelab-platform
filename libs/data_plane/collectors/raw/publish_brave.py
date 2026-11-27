"""A plain-file view of the Brave snapshot: the visits an agent can read anywhere.

The replica is the fidelity anchor, and it is a directory of table dumps plus the
database's own bytes -- readable only through code that knows both. The agent's
runtime has a shell on the state dataset and nothing else guaranteed, so the same
inputs get a second, smaller rendering beside them: one JSON object per visit and
one document describing the pass. Both are written with ``cat``, ``rg`` or ``jq``;
neither needs SQLite, and neither is a substitute for the replica.

Everything here is *current state*, never history: the file holds the last pass's
window, replaced whole. A client that wants to know whether the view is advancing
reads ``last_run`` from ``state.json`` and compares it with its own clock -- there
is no ledger to reconcile and no append to replay.

The input is the consistent copy ``apps/brave_ingest/snapshot.py`` published
(``quarantine/brave/History``), never the live profile, so this pass only reads.
It opens that file ``mode=ro`` and adds ``immutable=1`` only when the file cannot
be written anyway -- immutable skips every lock, which is a lie about a file
another process may be writing. The copy published beside the view is a copy, so
the quarantine file the replica collector also reads stays where it is.

A missing History, a database that fails ``quick_check``, or a view that cannot be
written is exit 3 and publishes nothing: the previous pass's files are left as
they were, and the unadvanced ``last_run`` is what says so.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sqlite3
import sys
import tempfile
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any
from urllib.parse import quote, urlsplit

#: A refusal is exit 3, the code the snapshot and the raw collectors use.
EXIT_REFUSED = 3

SOURCE = "brave"
#: The view is bounded rather than complete: the whole database is already the
#: replica's, and a client reading a file wants a size it can hold in a context.
MAX_VISITS = 2000
DEFAULT_WINDOW_DAYS = 90

HISTORY = "History"
VISITS = "visits.jsonl"
STATE = "state.json"
#: Browsing history in a readable directory: the mode the snapshot already uses.
VIEW_MODE = 0o600

#: Chromium stores a visit time as microseconds since 1601-01-01 UTC, and the
#: difference to the Unix epoch is a constant no timezone can affect.
CHROMIUM_OFFSET = 11_644_473_600
MICROS = 1_000_000


class PublishRefused(RuntimeError):
    """A source or destination the view cannot be built from."""


def log(event: str, **fields: object) -> None:
    record = {
        "ts": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "unit": "agent-brave-publish",
        "event": event,
    }
    record.update(fields)
    print(json.dumps(record, sort_keys=True), flush=True)


def iso(moment: datetime) -> str:
    """One timestamp spelling everywhere: UTC, seconds, ``Z`` suffix."""

    return (
        moment.astimezone(timezone.utc)
        .isoformat(timespec="seconds")
        .replace("+00:00", "Z")
    )


def visit_moment(micros: int) -> datetime:
    """The instant a ``visits.visit_time`` value names."""

    seconds, remainder = divmod(int(micros), MICROS)
    return datetime.fromtimestamp(seconds - CHROMIUM_OFFSET, timezone.utc) + timedelta(
        microseconds=remainder
    )


def window_floor(now: int, days: int) -> int:
    """The window's lower bound, in the units the column stores."""

    return (now - days * 86_400 + CHROMIUM_OFFSET) * MICROS


def host_of(url: str) -> str:
    """The host a client groups by, or empty for an opaque scheme.

    ``urlsplit`` lowercases the host and drops the port, which is what a grouping
    wants; a ``file:`` or ``about:`` visit has none and gets an empty string
    rather than a token that would collide with a real host.
    """

    try:
        return urlsplit(url).hostname or ""
    except ValueError:
        # A malformed authority (`https://[::1` and friends) is not a reason to
        # lose the visit: the URL stays verbatim and the host stays unknown.
        return ""


def _text(raw: bytes) -> str:
    """Decode a TEXT column without losing the row.

    Chromium writes non-UTF-8 bytes into TEXT-affinity columns, and one such
    title must not abort the whole view.
    """

    return raw.decode("utf-8", "replace")


def _open(path: Path) -> sqlite3.Connection:
    query = "mode=ro"
    if not os.access(path, os.W_OK):
        # The file is read-only to us anyway, so SQLite's locks could never be
        # taken and its promise that the file cannot change is true. On a
        # writable file this stays off: immutable also tells SQLite to skip the
        # rollback journal check it exists for.
        query += "&immutable=1"
    connection = sqlite3.connect(
        f"file:{quote(str(path))}?{query}", uri=True, timeout=5
    )
    connection.text_factory = _text
    return connection


def _quick_check(connection: sqlite3.Connection, path: Path) -> None:
    try:
        check = connection.execute("PRAGMA quick_check").fetchall()
    except sqlite3.Error as exc:
        raise PublishRefused(f"{path.name} is not a readable SQLite database") from exc
    if [tuple(row) for row in check] != [("ok",)]:
        raise PublishRefused(f"{path.name} fails quick_check: {check!r}")


def _visits(
    connection: sqlite3.Connection, floor: int
) -> tuple[list[dict[str, Any]], bool]:
    """The windowed visits, newest first, and whether the size bound dropped any."""

    try:
        rows = connection.execute(
            "SELECT v.visit_time, u.url, u.title, u.visit_count"
            " FROM visits AS v JOIN urls AS u ON u.id = v.url"
            " WHERE v.visit_time >= ?"
            " ORDER BY v.visit_time DESC, v.id DESC"
            " LIMIT ?",
            (floor, MAX_VISITS + 1),
        ).fetchall()
        truncated = len(rows) > MAX_VISITS
        visits = [
            {
                "ts": iso(visit_moment(row[0])),
                "url": str(row[1] or ""),
                "title": str(row[2] or ""),
                "host": host_of(str(row[1] or "")),
                "visit_count": int(row[3] or 0),
            }
            for row in rows[:MAX_VISITS]
        ]
    except (sqlite3.Error, TypeError, ValueError) as exc:
        # A column of the wrong type is a copy this reader does not understand,
        # which is a refusal rather than a traceback in the journal.
        raise PublishRefused(f"visits could not be read: {exc}") from exc
    return visits, truncated


def _atomic_copy(source: Path, directory: Path) -> Path:
    """Keep a copy of ``source`` in ``directory``; the source is never touched."""

    handle, temporary = tempfile.mkstemp(dir=str(directory), prefix=f".{HISTORY}.")
    os.close(handle)
    staged = Path(temporary)
    target = directory / HISTORY
    try:
        shutil.copyfile(source, staged)
        os.chmod(staged, VIEW_MODE)
        os.replace(staged, target)
    except BaseException:
        staged.unlink(missing_ok=True)
        raise
    return target


def _atomic_text(directory: Path, name: str, body: str) -> Path:
    handle, temporary = tempfile.mkstemp(dir=str(directory), prefix=f".{name}.")
    staged = Path(temporary)
    target = directory / name
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            stream.write(body)
        os.chmod(staged, VIEW_MODE)
        os.replace(staged, target)
    except BaseException:
        staged.unlink(missing_ok=True)
        raise
    return target


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def publish(
    history: str | Path, out: str | Path, *, now: int, days: int
) -> dict[str, Any]:
    """Build the view under ``out`` and return the state document it published."""

    source = Path(history)
    directory = Path(out)
    if source.is_symlink():
        raise PublishRefused(f"{source} is a symlink; refusing to follow it")
    if not source.is_file():
        raise PublishRefused(f"{source} is missing")

    connection = _open(source)
    try:
        _quick_check(connection, source)
        visits, truncated = _visits(connection, window_floor(now, days))
    finally:
        connection.close()

    directory.mkdir(parents=True, exist_ok=True)
    copy = _atomic_copy(source, directory)
    # `state.json` is written last: it is the document that says the pass landed,
    # so a view that failed halfway leaves the previous `last_run` standing.
    _atomic_text(
        directory,
        VISITS,
        "".join(json.dumps(visit, sort_keys=True) + "\n" for visit in visits),
    )
    state: dict[str, Any] = {
        "source": SOURCE,
        "last_run": iso(datetime.fromtimestamp(now, timezone.utc)),
        "ok": True,
        "visits": len(visits),
        "window_days": days,
        "truncated": truncated,
        "history_sha256": _sha256(copy),
    }
    _atomic_text(directory, STATE, json.dumps(state, sort_keys=True) + "\n")
    return state


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="publish-brave",
        description="Publish a plain-file Brave visit view beside the snapshot.",
    )
    parser.add_argument(
        "--history",
        default=f"/quarantine/{HISTORY}",
        help=f"the consistent History copy to read (default: /quarantine/{HISTORY})",
    )
    parser.add_argument(
        "--out",
        default="/out",
        help="the directory the view is published in (default: /out)",
    )
    parser.add_argument(
        "--now",
        type=int,
        default=None,
        help="the pass's clock, in epoch seconds (default: the current time)",
    )
    parser.add_argument(
        "--days",
        type=int,
        default=DEFAULT_WINDOW_DAYS,
        help=f"the window the visits are drawn from (default: {DEFAULT_WINDOW_DAYS})",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = _parser()
    args = parser.parse_args(list(sys.argv[1:] if argv is None else argv))
    if args.days < 1:
        parser.error("--days must be at least 1")
    now = int(time.time()) if args.now is None else args.now
    try:
        state = publish(args.history, args.out, now=now, days=args.days)
    except (PublishRefused, OSError, sqlite3.Error) as error:
        log("refused", source=args.history, reason=str(error))
        return EXIT_REFUSED
    log(
        "publish",
        source=args.history,
        out=args.out,
        visits=state["visits"],
        truncated=state["truncated"],
        sha256=state["history_sha256"],
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
