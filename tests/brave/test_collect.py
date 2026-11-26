"""The collector over a snapshot: one committed state, one ``brave::db`` object.

This is the half the unit runs, so it is the real CLI (`data_plane.collectors.raw`)
over a real database written by the fixture -- not a function call that skips the
contract the replica state enforces. The refusals are the ones the unit turns into a
failed service: a database still being written, and a database that is not one.
"""

from __future__ import annotations

import io
import json
import sqlite3
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

from apps.brave_ingest import snapshot as snapper
from data_plane.collectors.state import ReplicaState
from data_plane.collectors.raw.cli import EXIT_REFUSED, main

from history_fixture import create_history, url_count


class _View:
    """The committed state read back with the names these cases were written in."""

    def __init__(self, root: Path) -> None:
        self._state = ReplicaState(root, read_only=True)

    def read(self, object_id: str) -> bytes:
        return self._state.read(object_id)

    def metadata(self, object_id: str) -> dict:
        return self._state.get(object_id)["metadata"]

    def object_ids(self) -> tuple[str, ...]:
        return self._state.live_object_ids()


def _replica(root: Path) -> _View:
    return _View(root)


class CollectorTests(unittest.TestCase):
    def setUp(self) -> None:
        self._work = tempfile.TemporaryDirectory()
        self.addCleanup(self._work.cleanup)
        self.root = Path(self._work.name)
        self.quarantine = self.root / "quarantine"
        self.copy = self.quarantine / "History"
        self.replica_root = self.root / "replica" / "brave"

    def collect(self) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = main(
                [
                    "--root",
                    str(self.replica_root),
                    "--captured-at",
                    "2026-11-20T00:00:00+00:00",
                    "brave",
                    "--database",
                    str(self.copy),
                    "--device",
                    "smortress",
                    "--profile",
                    "default",
                ]
            )
        return code, out.getvalue(), err.getvalue()

    def test_one_state_is_committed_with_a_brave_db_object(self) -> None:
        create_history(self.copy, visits=2)

        code, out, _ = self.collect()

        self.assertEqual(code, 0)
        report = json.loads(out)
        self.assertEqual(report["source_id"], "brave.history")
        self.assertEqual(report["deleted"], 0)
        self.assertEqual(report["published"], str(self.replica_root / "state.sqlite"))
        replica = _replica(self.replica_root)
        self.assertEqual(replica.read("brave::db"), self.copy.read_bytes())
        metadata = replica.metadata("brave::db")
        self.assertEqual(metadata["device"], "smortress")
        self.assertEqual(metadata["profile"], "default")
        self.assertIn("brave::table::visits", replica.object_ids())
        self.assertEqual(
            set(report["details"]["tables"]),
            {
                "urls",
                "visits",
                "visit_source",
                "keyword_search_terms",
                "downloads",
                "segments",
            },
        )

    def test_a_snapshot_of_a_live_profile_is_what_gets_published(self) -> None:
        live = self.root / "profile" / "Default" / "History"
        live.parent.mkdir(parents=True)
        create_history(live, visits=3)

        snapper.snapshot_database(live, self.copy)
        code, _, _ = self.collect()

        self.assertEqual(code, 0)
        replica = _replica(self.replica_root)
        self.assertEqual(
            json.loads(replica.read("brave::table::urls"))["rows"][0][1],
            "https://example.com/0",
        )

    def test_a_sidecar_beside_the_copy_is_a_refusal(self) -> None:
        create_history(self.copy)
        Path(str(self.copy) + "-wal").write_bytes(b"")

        code, _, err = self.collect()

        self.assertEqual(code, EXIT_REFUSED)
        self.assertIn("-wal", err)
        self.assertFalse((self.replica_root / "published").exists())

    def test_a_database_with_no_user_tables_is_a_refusal(self) -> None:
        self.quarantine.mkdir(parents=True)
        connection = sqlite3.connect(str(self.copy))
        connection.execute("PRAGMA user_version = 1")
        connection.close()

        code, _, err = self.collect()

        self.assertEqual(code, EXIT_REFUSED)
        self.assertIn("no user tables", err)
        self.assertFalse((self.replica_root / "published").exists())

    def test_the_snapshot_leaves_the_copy_the_collector_accepts(self) -> None:
        live = self.root / "profile" / "Default" / "History"
        live.parent.mkdir(parents=True)
        create_history(live, visits=2)
        snapper.snapshot_database(live, self.copy)

        self.assertEqual(url_count(self.copy), 2)
        for suffix in ("-wal", "-journal", "-shm"):
            self.assertFalse(Path(str(self.copy) + suffix).exists())


if __name__ == "__main__":
    unittest.main()
