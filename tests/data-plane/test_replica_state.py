"""The live replica state: object bytes, rows, tombstones, cursor and version.

Every case is a real SQLite file and a real object tree under a temporary
directory. Nothing here reaches a provider.
"""

from __future__ import annotations

import hashlib
import json
import os
import tempfile
import time
import unittest
from pathlib import Path

from data_plane.collectors.raw import ABSENCE_NO_TOMBSTONE
from data_plane.collectors.state import (
    ABSENCE_REASON,
    ABSENT_SINCE,
    ReplicaState,
)
from data_plane.errors import (
    CursorError,
    EpochError,
    ManifestError,
    PublishError,
    ValidationError,
)

CAPTURED = "2026-11-19T00:00:00+00:00"


def _object_files(root: Path) -> list[Path]:
    objects = root / "objects"
    if not objects.is_dir():
        return []
    return sorted(path for path in objects.glob("*/*") if path.is_file())


class ReplicaStateTests(unittest.TestCase):
    def setUp(self) -> None:
        self._work = tempfile.TemporaryDirectory()
        self.root = Path(self._work.name)
        self.addCleanup(self._work.cleanup)
        self.addCleanup(self._close)

    def _close(self) -> None:
        state = getattr(self, "state", None)
        if state is not None:
            state.close()

    def _state(self, **kwargs) -> ReplicaState:
        self.state = ReplicaState(self.root, source_id="test.source", **kwargs)
        return self.state

    def test_put_then_commit_publishes_a_verified_object(self) -> None:
        state = self._state()
        state.put("a", b"hello", {"source_id": "test.source"})
        stats = state.commit(complete=True, captured_at=CAPTURED)

        self.assertEqual(stats.version, 1)
        self.assertEqual(stats.written, 1)
        self.assertEqual(state.version, 1)
        self.assertEqual(state.cursor, 1)
        self.assertEqual(state.read("a"), b"hello")
        row = state.get("a")
        self.assertTrue(row["present"])
        self.assertEqual(
            row["sha256"], hashlib.sha256(b"hello").hexdigest()
        )
        self.assertEqual(row["metadata"]["source_id"], "test.source")

    def test_ids_with_equal_bytes_share_one_file(self) -> None:
        state = self._state()
        state.put("a", b"same", {})
        state.put("b", b"same", {})
        state.commit(complete=True, captured_at=CAPTURED)

        self.assertEqual(len(_object_files(self.root)), 1)
        self.assertEqual(state.read("a"), state.read("b"))

    def test_an_unchanged_object_writes_no_second_file(self) -> None:
        state = self._state()
        state.put("a", b"same", {})
        state.commit(complete=True, captured_at=CAPTURED)
        before = _object_files(self.root)

        state.put("a", b"same", {})
        stats = state.commit(complete=True, captured_at=CAPTURED)

        self.assertEqual(_object_files(self.root), before)
        self.assertEqual(stats.written, 0)
        self.assertEqual(stats.version, 2)

    def test_changed_bytes_are_a_new_object_and_the_old_one_is_collected(self) -> None:
        state = self._state()
        state.put("a", b"before", {})
        state.commit(complete=True, captured_at=CAPTURED)
        old = self.root / "objects" / hashlib.sha256(b"before").hexdigest()[:2]
        old = old / hashlib.sha256(b"before").hexdigest()
        self.assertTrue(old.is_file())
        time.sleep(0.01)

        state.put("a", b"after", {})
        stats = state.commit(complete=True, captured_at=CAPTURED)

        self.assertFalse(old.exists())
        self.assertEqual(stats.collected, 1)
        self.assertEqual(len(_object_files(self.root)), 1)
        self.assertEqual(state.read("a"), b"after")

    def test_an_unreferenced_object_newer_than_the_pass_is_kept(self) -> None:
        # A concurrent pass may have written bytes it has not committed yet.
        state = self._state()
        bucket = self.root / "objects" / "ff"
        bucket.mkdir(parents=True)
        (bucket / ("f" * 64)).write_bytes(b"in flight")

        stats = state.commit(complete=True, captured_at=CAPTURED)

        self.assertEqual(stats.collected, 0)
        self.assertTrue((bucket / ("f" * 64)).is_file())

    def test_read_refuses_bytes_that_do_not_match_the_recorded_digest(self) -> None:
        state = self._state()
        state.put("a", b"hello", {})
        state.commit(complete=True, captured_at=CAPTURED)
        digest = hashlib.sha256(b"hello").hexdigest()
        path = self.root / "objects" / digest[:2] / digest
        path.write_bytes(b"tampered")
        with self.assertRaises(ManifestError):
            state.read("a")

    def test_read_refuses_an_unknown_id(self) -> None:
        state = self._state()
        state.commit(complete=True, captured_at=CAPTURED)
        with self.assertRaises(ManifestError):
            state.read("missing")

    def test_a_tombstone_drops_the_bytes_and_is_not_readable(self) -> None:
        state = self._state()
        state.put("a", b"hello", {})
        state.commit(complete=True, captured_at=CAPTURED)

        state.tombstone("a", "provider expunge")
        stats = state.commit(complete=True, captured_at=CAPTURED)

        self.assertEqual(stats.tombstoned, 1)
        self.assertEqual(stats.collected, 1)
        row = state.get("a")
        self.assertFalse(row["present"])
        self.assertIsNone(row["sha256"])
        self.assertEqual(state.live_object_ids(), ())
        with self.assertRaises(ManifestError):
            state.read("a")
        self.assertEqual(_object_files(self.root), [])

    def test_a_complete_pass_refuses_unaccounted_rows_without_a_reason(self) -> None:
        state = self._state()
        state.put("a", b"hello", {})
        state.commit(complete=True, captured_at=CAPTURED)

        with self.assertRaises(PublishError):
            state.commit(complete=True, captured_at=CAPTURED)

        self.assertEqual(state.version, 1)
        self.assertTrue(state.get("a")["present"])

    def test_a_complete_pass_marks_unseen_rows_absent_without_moving_the_marker(
        self,
    ) -> None:
        state = self._state()
        state.put("a", b"hello", {})
        state.commit(complete=True, captured_at=CAPTURED)

        missing = "2026-11-20T00:00:00+00:00"
        stats = state.commit(
            complete=True,
            absence_reason=ABSENCE_NO_TOMBSTONE,
            captured_at=missing,
        )

        self.assertEqual(stats.absent, 1)
        row = state.get("a")
        self.assertTrue(row["present"])
        # The marker is the first pass that saw it missing, not the last one.
        self.assertEqual(row["absent_since"], missing)
        self.assertEqual(row["metadata"][ABSENT_SINCE], missing)
        self.assertEqual(row["metadata"][ABSENCE_REASON], ABSENCE_NO_TOMBSTONE)
        self.assertEqual(state.read("a"), b"hello")

        stats = state.commit(
            complete=True,
            absence_reason=ABSENCE_NO_TOMBSTONE,
            captured_at="2026-11-21T00:00:00+00:00",
        )
        # It is still absent, so the pass still reports it.
        self.assertEqual(stats.absent, 1)
        self.assertEqual(state.get("a")["absent_since"], missing)

    def test_a_delta_pass_never_infers_absence(self) -> None:
        state = self._state()
        state.put("a", b"hello", {})
        state.commit(complete=True, captured_at=CAPTURED)

        state.put("b", b"other", {})
        stats = state.commit(complete=False, captured_at=CAPTURED)

        self.assertEqual(stats.written, 1)
        row = state.get("a")
        self.assertTrue(row["present"])
        self.assertIsNone(row["absent_since"])

    def test_a_returning_object_clears_its_absence(self) -> None:
        state = self._state()
        state.put("a", b"hello", {})
        state.commit(complete=True, captured_at=CAPTURED)
        state.commit(
            complete=True,
            absence_reason=ABSENCE_NO_TOMBSTONE,
            captured_at=CAPTURED,
        )
        self.assertEqual(state.get("a")["absent_since"], CAPTURED)

        state.put("a", b"hello", {})
        state.commit(complete=True, captured_at=CAPTURED)

        row = state.get("a")
        self.assertIsNone(row["absent_since"])
        self.assertIsNone(row["absence_reason"])
        self.assertNotIn(ABSENT_SINCE, row["metadata"])

    def test_cursors_only_move_forward(self) -> None:
        state = self._state()
        state.commit(complete=True, captured_at=CAPTURED)
        # A file-backed source has no provider cursor: the store supplies one.
        self.assertEqual(state.cursor, 1)

        state.commit(complete=True, captured_at=CAPTURED, cursor=5)
        self.assertEqual(state.cursor, 5)
        with self.assertRaises(CursorError):
            state.commit(complete=True, captured_at=CAPTURED, cursor=5)
        with self.assertRaises(CursorError):
            state.commit(complete=True, captured_at=CAPTURED, cursor=3)
        with self.assertRaises(ValidationError):
            state.commit(complete=True, captured_at=CAPTURED, cursor=0)
        self.assertEqual(state.cursor, 5)
        self.assertEqual(state.version, 2)

    def test_a_failed_commit_leaves_the_state_untouched(self) -> None:
        state = self._state()
        state.put("a", b"hello", {})
        state.commit(complete=True, captured_at=CAPTURED)

        state.put("b", b"other", {})
        with self.assertRaises(PublishError):
            state.commit(complete=True, captured_at=CAPTURED)

        self.assertEqual(state.version, 1)
        self.assertEqual(state.cursor, 1)
        self.assertIsNone(state.get("b"))

    def test_rebuild_starts_a_new_epoch_with_no_cursor_and_bumps_the_version(
        self,
    ) -> None:
        state = self._state()
        state.commit(complete=True, captured_at=CAPTURED)
        self.assertEqual(state.version, 1)
        self.assertEqual(state.epoch, 1)
        self.assertEqual(state.cursor, 1)

        self.assertEqual(state.rebuild(), 2)

        self.assertEqual(state.epoch, 2)
        self.assertIsNone(state.cursor)
        self.assertEqual(state.version, 2)
        state.commit(complete=True, captured_at=CAPTURED)
        self.assertEqual(state.cursor, 1)

    def test_a_new_epoch_refuses_a_pass_that_started_in_the_old_one(self) -> None:
        state = self._state()
        state.commit(complete=True, captured_at=CAPTURED)

        # An operator tool that does not take the pass lock can rebuild under a
        # running pass; the commit must notice instead of tombstoning everything.
        import sqlite3

        connection = sqlite3.connect(self.root / "state.sqlite")
        connection.execute("UPDATE cursor SET epoch = 2")
        connection.commit()
        connection.close()

        with self.assertRaises(EpochError):
            state.commit(complete=True, captured_at=CAPTURED)

    def test_a_second_writer_is_refused_while_a_pass_is_open(self) -> None:
        with ReplicaState(self.root, source_id="test.source"):
            with self.assertRaises(PublishError):
                ReplicaState(self.root, source_id="test.source")

    def test_a_state_belongs_to_one_source(self) -> None:
        with ReplicaState(self.root, source_id="notes.markdown") as notes:
            notes.commit(complete=True, captured_at=CAPTURED)

        with self.assertRaises(PublishError):
            ReplicaState(self.root, source_id="tasks.todo")
        # The same source is fine, and so is a reader that names none.
        with ReplicaState(self.root, source_id="notes.markdown"):
            pass
        with ReplicaState(self.root, read_only=True) as reader:
            self.assertEqual(reader.source_id, "notes.markdown")

    def test_unchanged_bytes_keep_the_first_captured_at(self) -> None:
        state = self._state()
        state.put("a", b"hello", {"captured_at": "2026-11-19T00:00:00+00:00"})
        state.commit(complete=True, captured_at=CAPTURED)

        state.put("a", b"hello", {"captured_at": "2026-11-20T00:00:00+00:00"})
        stats = state.commit(complete=True, captured_at=CAPTURED)

        self.assertEqual(stats.written, 0)
        row = state.get("a")
        self.assertEqual(row["metadata"]["captured_at"], "2026-11-19T00:00:00+00:00")

    def test_a_tombstone_keeps_the_first_absent_marker(self) -> None:
        state = self._state()
        state.put("a", b"hello", {"captured_at": CAPTURED})
        state.commit(complete=True, captured_at=CAPTURED)
        missing = "2026-11-20T00:00:00+00:00"
        state.commit(
            complete=True, absence_reason=ABSENCE_NO_TOMBSTONE, captured_at=missing
        )

        state.tombstone("a", "provider expunge")
        state.commit(complete=True, captured_at=CAPTURED)

        row = state.get("a")
        self.assertFalse(row["present"])
        self.assertIsNone(row["sha256"])
        self.assertEqual(row["absent_since"], missing)

    def test_a_dry_run_writes_no_object_and_refuses_to_commit(self) -> None:
        state = self._state(dry_run=True)
        state.put("a", b"hello", {})
        self.assertEqual(_object_files(self.root), [])
        with self.assertRaises(PublishError):
            state.commit(complete=True, captured_at=CAPTURED)
        self.assertFalse((self.root / "state.sqlite").exists())

    def test_a_reader_is_read_only_and_sees_the_committed_state(self) -> None:
        writer = self._state()
        writer.put("a", b"hello", {"source_id": "test.source"})
        writer.put("gone", b"bye", {})
        writer.tombstone("gone", "provider expunge")
        writer.commit(complete=True, captured_at=CAPTURED)
        writer.close()

        reader = self._state(read_only=True)
        self.assertEqual(reader.version, 1)
        self.assertEqual(reader.read("a"), b"hello")
        self.assertEqual(reader.live_object_ids(), ("a",))
        self.assertEqual(reader.source_id, "test.source")
        with self.assertRaises(PublishError):
            reader.put("b", b"x", {})

    def test_a_state_file_that_is_not_a_database_is_refused(self) -> None:
        writer = self._state()
        writer.put("a", b"hello", {})
        writer.commit(complete=True, captured_at=CAPTURED)
        writer.close()

        database = self.root / "state.sqlite"
        database.write_bytes(b"not a database" * 100)

        with self.assertRaises(PublishError):
            self._state(read_only=True)

    def test_an_unsafe_object_id_is_refused(self) -> None:
        state = self._state()
        for object_id in ("", " ", ".", "..", "a/b", "a\x00b"):
            with self.assertRaises(ValidationError):
                state.put(object_id, b"x", {})
        with self.assertRaises(ValidationError):
            state.put("a", "not bytes", {})  # type: ignore[arg-type]
        with self.assertRaises(ValidationError):
            state.put("a", b"x", {"when": object()})

    def test_rows_are_ordered_and_complete(self) -> None:
        state = self._state()
        state.put("b", b"two", {})
        state.put("a", b"one", {})
        state.commit(complete=True, captured_at=CAPTURED)

        self.assertEqual([row["object_id"] for row in state.rows()], ["a", "b"])
        self.assertEqual(state.live_object_ids(), ("a", "b"))
        self.assertEqual(json.loads(json.dumps(state.rows())), list(state.rows()))
