"""Take the one quiesced copy of a live Brave ``History`` that the collector reads.

Chromium holds ``History`` open for the whole life of the browser and keeps its
recent writes in the write-ahead log beside it, so the live file is never a
point-in-time database and the collector refuses a copy that carries a ``-wal``
sibling at all. Both halves of that problem are this module's:

* SQLite's backup API copies a database consistently while another process is
  writing to it, which is exactly the case here -- the browser is running, that
  is the point of the profile.
* When the backup API cannot be used (a locked or busy source, a database that
  another process created without shared-memory support), the fallback copies
  ``History`` and its sidecars into a staging directory, folds the write-ahead log
  into the main file there, and publishes only the folded file. Copying the
  sidecars *and keeping them* would be the one thing the collector rejects, so the
  fallback ends with a single file or no copy at all.

The copy lands at one path (`quarantine/brave/History`), replaced by rename, so a
half-written snapshot is never readable under the name the collector is given.

Which sidecar name the live artifact actually writes is not a guess: the pinned
Brave 1.100.58 was launched against a scratch profile, `PRAGMA journal_mode`
answered `delete`, and the file beside `Default/History` was `History-journal` --
its other databases (`DIPS`, `segmentation_platform/ukm_db`) are WAL, with the
lower-case `-wal` SQLite derives from the name. Both spellings are therefore
treated as sidecars here, and the path unit watches `History`, `History-wal` and
`History-journal`: a later Chromium switching the database to WAL would then be
collected without an edit.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sqlite3
import sys
import tempfile
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable
from urllib.parse import quote

#: A refusal is exit 3, the same code the raw collectors use: nothing is written
#: and the journal names the reason.
EXIT_REFUSED = 3

UNIT = "agent-brave-snapshot"
#: SQLite appends the suffix in lower case, and Chromium keeps ``History`` in
#: rollback-journal mode (``PRAGMA journal_mode`` answers ``delete`` on the pinned
#: Brave 1.100.58, which writes ``History-journal``), while other profile databases
#: such as ``DIPS`` are WAL. Every spelling is treated as a sidecar: the collector
#: refuses ``-wal`` and ``-journal`` alike, and a profile restored from a
#: case-insensitive filesystem can carry the upper-case name.
SIDECARS = ("-wal", "-WAL", "-journal", "-JOURNAL", "-shm", "-SHM")
COPY_MODE = 0o600

#: `sqlite3.Connection.backup()` retries a locked source on its own schedule and
#: never consults `timeout`, so a browser that holds ``History`` can keep it
#: looping for as long as the browser runs. A oneshot that cannot return also
#: cannot act on SIGTERM, which is how this unit sat in `stop-sigterm` after its
#: 600 s start limit. The deadline turns that into the fallback that already
#: exists for a source SQLite will not back up.
BACKUP_DEADLINE = 30.0

Backup = Callable[[Path, Path], None]


class SnapshotError(RuntimeError):
    """A refused source, copy or staging directory."""


class BackupStalled(SnapshotError):
    """The backup API did not finish inside the deadline."""


def log(event: str, **fields: object) -> None:
    record = {
        "ts": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "unit": UNIT,
        "event": event,
    }
    record.update(fields)
    print(json.dumps(record, sort_keys=True), flush=True)


def _refuse_source(source: Path) -> None:
    if source.is_symlink():
        raise SnapshotError(f"{source} is a symlink; refusing to follow it")
    if not source.is_file():
        raise SnapshotError(f"{source} is missing")


def _backup_api(source: Path, target: Path) -> None:
    """Copy a database with SQLite's backup API, which is safe while it is live."""

    # `mode=ro` so this never creates a sidecar beside the live database: the
    # browser owns it, and a second writer is the failure this module exists to
    # avoid.
    connection = sqlite3.connect(f"file:{quote(str(source))}?mode=ro", uri=True, timeout=5)
    try:
        destination = sqlite3.connect(str(target))
        try:
            connection.backup(destination)
        finally:
            destination.close()
    finally:
        connection.close()


def _bounded_backup(
    backup: Backup, source: Path, target: Path, deadline: float
) -> None:
    """Run ``backup`` but give up after ``deadline``; a stalled call is abandoned."""

    failure: list[BaseException] = []

    def attempt() -> None:
        try:
            backup(source, target)
        except BaseException as error:  # noqa: BLE001 - reported to the caller
            failure.append(error)

    worker = threading.Thread(target=attempt, name="brave-snapshot-backup", daemon=True)
    worker.start()
    worker.join(deadline)
    if worker.is_alive():
        raise BackupStalled(f"the live database did not back up within {deadline:g}s")
    if failure:
        raise failure[0]


def _sidecars(database: Path) -> list[Path]:
    return [
        database.with_name(database.name + suffix)
        for suffix in SIDECARS
        if database.with_name(database.name + suffix).exists()
    ]


def _fold_wal(database: Path) -> None:
    """Fold a staged copy's write-ahead log into the copy itself, then remove it."""

    connection = sqlite3.connect(str(database), timeout=10)
    try:
        checkpoint = connection.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()
        # (busy, log, checkpointed): a non-zero busy means another connection held
        # the log, and a staged copy nobody else may open cannot have one.
        if checkpoint is not None and int(checkpoint[0]):
            raise SnapshotError(
                "the staged copy's write-ahead log could not be checkpointed"
            )
        connection.execute("PRAGMA journal_mode=DELETE").fetchone()
    finally:
        connection.close()


def _normalize(database: Path) -> None:
    """Publish a rollback-journal copy, so no reader ever creates a ``-wal``.

    The source header says WAL -- Chromium writes the database that way -- and the
    backup API copies page 1 verbatim, so a copy would keep the flag. The
    collector opens its input read-only and would not create the log itself, but a
    later copy of a copy is exactly how a sidecar appears beside the file it
    refuses. Folding it here makes the published copy self-contained.
    """

    _fold_wal(database)
    for leftover in _sidecars(database):
        leftover.unlink()


def _copy_with_sidecars(source: Path, target: Path) -> None:
    """Copy ``History`` and its sidecars beside it, then fold the log in."""

    # The staging directory is beside the target, so the final move is a rename on
    # one filesystem and the collector can never read a partial file.
    staging = Path(tempfile.mkdtemp(dir=str(target.parent), prefix=".snapshot-"))
    try:
        copied = staging / target.name
        shutil.copy2(source, copied)
        for sidecar in _sidecars(source):
            shutil.copy2(
                sidecar, staging / (target.name + sidecar.name[len(source.name) :])
            )
        _normalize(copied)
        os.chmod(copied, COPY_MODE)
        os.replace(copied, target)
    finally:
        shutil.rmtree(staging, ignore_errors=True)


def snapshot_database(
    source: str | Path,
    target: str | Path,
    *,
    backup: Backup = _backup_api,
    deadline: float = BACKUP_DEADLINE,
) -> Path:
    """Publish one consistent copy of ``source`` at ``target``; return the path."""

    origin = Path(source)
    destination = Path(target)
    _refuse_source(origin)
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o750)
    staging = destination.with_name(destination.name + ".partial")
    if staging.exists():
        staging.unlink()
    try:
        _bounded_backup(backup, origin, staging, deadline)
        _normalize(staging)
        os.chmod(staging, COPY_MODE)
        os.replace(staging, destination)
    except (sqlite3.Error, BackupStalled):
        # The fallback is the live-artifact case: the browser holds the database
        # and the read-only connection could not start or finish a backup.
        if staging.exists():
            staging.unlink()
        _copy_with_sidecars(origin, destination)
    except BaseException:
        if staging.exists():
            staging.unlink()
        raise
    # A sidecar beside the target is the collector's refusal, and a previous copy
    # of a live database could have left one.
    for sidecar in _sidecars(destination):
        sidecar.unlink()
    return destination


def _counts(database: Path) -> dict[str, int]:
    """Row counts the journal can show without printing a URL."""

    counts: dict[str, int] = {}
    connection = sqlite3.connect(f"file:{quote(str(database))}?mode=ro", uri=True)
    try:
        for table in ("urls", "visits"):
            try:
                row = connection.execute(f"SELECT COUNT(*) FROM {table}").fetchone()
            except sqlite3.Error:
                continue
            counts[table] = int(row[0]) if row else 0
    finally:
        connection.close()
    return counts


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="brave-snapshot",
        description="Copy a live Brave History into the path the collector reads.",
    )
    parser.add_argument(
        "--database",
        default="/data/Default/History",
        help="the live History database (default: /data/Default/History)",
    )
    parser.add_argument(
        "--out",
        default="/quarantine/History",
        help="where the copy is published (default: /quarantine/History)",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(list(sys.argv[1:] if argv is None else argv))
    try:
        copy = snapshot_database(args.database, args.out)
        counts = _counts(copy)
    except (SnapshotError, OSError, sqlite3.Error) as error:
        log("refused", source=args.database, reason=str(error))
        return EXIT_REFUSED
    log(
        "snapshot",
        source=args.database,
        out=str(copy),
        size=copy.stat().st_size,
        **counts,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
