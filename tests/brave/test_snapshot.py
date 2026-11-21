"""The snapshot: one consistent file, no sidecar, and what it refuses.

The live case is a database another connection holds open in WAL mode, which is
what the browser is; the fallback is exercised by injecting a backup that fails,
because the failure it exists for (a source SQLite will not back up) is not
something a test can produce on demand. Nothing here needs a browser.
"""

from __future__ import annotations

import io
import os
import shutil
import sqlite3
import stat
import tempfile
import threading
import time
import unittest
from contextlib import redirect_stdout
from pathlib import Path

from apps.brave_ingest import snapshot as snapper

from history_fixture import VISIT_TIME, create_history, live_history, url_count


class SnapshotTests(unittest.TestCase):
    def setUp(self) -> None:
        self._work = tempfile.TemporaryDirectory()
        self.addCleanup(self._work.cleanup)
        self.root = Path(self._work.name)
        self.live = self.root / "profile" / "Default" / "History"
        self.live.parent.mkdir(parents=True)
        self.target = self.root / "quarantine" / "History"

    def test_a_live_database_is_copied_with_its_rows(self) -> None:
        writer, _ = live_history(self.live, rows=2)
        self.addCleanup(writer.close)

        snapper.snapshot_database(self.live, self.target)

        self.assertEqual(url_count(self.target), 2)
        self.assertEqual(sorted(p.name for p in self.target.parent.iterdir()), ["History"])

    def test_the_copy_has_no_sidecar_beside_it(self) -> None:
        writer, _ = live_history(self.live, rows=1)
        self.addCleanup(writer.close)
        self.assertTrue(Path(str(self.live) + "-wal").exists())

        snapper.snapshot_database(self.live, self.target)

        for suffix in snapper.SIDECARS:
            self.assertFalse(
                Path(str(self.target) + suffix).exists(),
                f"{suffix} survived the snapshot",
            )

    def test_the_copy_is_owner_only(self) -> None:
        create_history(self.live)
        snapper.snapshot_database(self.live, self.target)
        self.assertEqual(stat.S_IMODE(os.stat(self.target).st_mode), 0o600)

    def test_no_partial_file_is_left_behind(self) -> None:
        create_history(self.live)
        snapper.snapshot_database(self.live, self.target)
        self.assertFalse(Path(str(self.target) + ".partial").exists())

    def test_a_second_snapshot_replaces_the_first(self) -> None:
        create_history(self.live, visits=1)
        snapper.snapshot_database(self.live, self.target)
        # A browser that kept browsing: the same profile, two more visits.
        connection = sqlite3.connect(str(self.live))
        try:
            for index in (1, 2):
                connection.execute(
                    "INSERT INTO urls (id, url, title, last_visit_time) VALUES (?, ?, ?, ?)",
                    (10 + index, f"https://example.com/{index}", "later", VISIT_TIME),
                )
                connection.execute(
                    "INSERT INTO visits (id, url, visit_time) VALUES (?, ?, ?)",
                    (10 + index, 10 + index, VISIT_TIME + index),
                )
            connection.commit()
        finally:
            connection.close()
        snapper.snapshot_database(self.live, self.target)
        self.assertEqual(url_count(self.target), 3)

    def test_the_fallback_folds_a_log_into_one_file(self) -> None:
        # A database with a hot log beside it, which is the state the fallback
        # exists for: the fixture is a copy of a live WAL database, so its rows are
        # in the log rather than in the main file.
        writer, _ = live_history(self.live, rows=2)
        fixture = self.root / "restored" / "History"
        fixture.parent.mkdir(parents=True)
        shutil.copy2(self.live, fixture)
        for suffix in ("-wal", "-shm"):
            shutil.copy2(str(self.live) + suffix, str(fixture) + suffix)
        writer.close()

        def refuse(_source: Path, _target: Path) -> None:
            raise sqlite3.Error("database is locked")

        snapper.snapshot_database(fixture, self.target, backup=refuse)

        self.assertEqual(url_count(self.target), 2)
        self.assertEqual(sorted(p.name for p in self.target.parent.iterdir()), ["History"])
        self.assertEqual(
            sqlite3.connect(str(self.target)).execute("PRAGMA journal_mode").fetchone()[0],
            "delete",
        )

    def test_a_stalled_backup_falls_back_to_the_copy(self) -> None:
        # `sqlite3.Connection.backup()` retries a locked source forever, sleeping
        # between attempts and ignoring `timeout`; the browser holding ``History``
        # is exactly that case. Unbounded, this is a oneshot that never returns and
        # cannot act on SIGTERM, so the deadline turns it into the fallback below.
        writer, _ = live_history(self.live, rows=2)
        self.addCleanup(writer.close)
        release = threading.Event()
        self.addCleanup(release.set)

        def stall(_source: Path, _target: Path) -> None:
            release.wait()

        started = time.monotonic()
        snapper.snapshot_database(self.live, self.target, backup=stall, deadline=0.2)
        elapsed = time.monotonic() - started

        self.assertLess(elapsed, 5)
        self.assertEqual(url_count(self.target), 2)
        self.assertEqual(sorted(p.name for p in self.target.parent.iterdir()), ["History"])
        self.assertFalse(Path(str(self.target) + ".partial").exists())

    def test_a_finished_backup_is_used_rather_than_the_copy(self) -> None:
        create_history(self.live)
        calls: list[Path] = []

        def quick(source: Path, target: Path) -> None:
            calls.append(source)
            connection = sqlite3.connect(f"file:{source}?mode=ro", uri=True)
            try:
                destination = sqlite3.connect(str(target))
                try:
                    connection.backup(destination)
                finally:
                    destination.close()
            finally:
                connection.close()

        snapper.snapshot_database(self.live, self.target, backup=quick)

        self.assertEqual(calls, [self.live])

    def test_the_copy_is_readable_by_a_reader_that_checks_integrity(self) -> None:
        create_history(self.live, visits=3)
        snapper.snapshot_database(self.live, self.target)
        connection = sqlite3.connect(f"file:{self.target}?mode=ro", uri=True)
        try:
            self.assertEqual(connection.execute("PRAGMA integrity_check").fetchall(), [("ok",)])
            row = connection.execute("SELECT MAX(visit_time) FROM visits").fetchone()
        finally:
            connection.close()
        self.assertEqual(row[0], VISIT_TIME + 2)


class SnapshotRefusalTests(unittest.TestCase):
    def setUp(self) -> None:
        self._work = tempfile.TemporaryDirectory()
        self.addCleanup(self._work.cleanup)
        self.root = Path(self._work.name)
        self.target = self.root / "quarantine" / "History"

    def run_main(self, database: Path) -> tuple[int, str]:
        output = io.StringIO()
        with redirect_stdout(output):
            code = snapper.main(["--database", str(database), "--out", str(self.target)])
        return code, output.getvalue()

    def test_a_missing_database_is_refused(self) -> None:
        code, output = self.run_main(self.root / "History")
        self.assertEqual(code, snapper.EXIT_REFUSED)
        self.assertIn("missing", output)
        self.assertFalse(self.target.exists())

    def test_a_symlinked_database_is_refused(self) -> None:
        real = self.root / "History"
        create_history(real)
        link = self.root / "link"
        link.symlink_to(real)
        code, output = self.run_main(link)
        self.assertEqual(code, snapper.EXIT_REFUSED)
        self.assertIn("symlink", output)
        self.assertFalse(self.target.exists())

    def test_a_successful_snapshot_logs_counts_and_no_url(self) -> None:
        real = self.root / "History"
        create_history(real, visits=2)
        code, output = self.run_main(real)
        self.assertEqual(code, 0)
        self.assertIn('"urls": 2', output)
        self.assertNotIn("example.com", output)


if __name__ == "__main__":
    unittest.main()
