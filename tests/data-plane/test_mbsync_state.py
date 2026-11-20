"""The epoch map comes from the sync tool's state, not from an operator's guess.

mbsync records the far-side UIDVALIDITY in a state file beside each Maildir box,
so the collector can read the provider's own epoch instead of being told one.
These fixtures are the exact header a real state file carries; the parser is
strict because a wrong epoch turns a renumbering into silent deletion evidence.
"""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from data_plane.errors import ValidationError
from data_plane.collectors.raw.mbsync import STATE_FILE, read_uidvalidity

STATE = (
    "FarUidValidity {far}\n"
    "NearUidValidity 1699999999\n"
    "MaxPulledUid 42\n"
    "MaxPushedUid 0\n"
    "\n"
    "42 1 S\n"
    "41 2 ST\n"
)


def _box(root: Path, folder: str = "") -> Path:
    path = root / folder if folder else root
    for spool in ("cur", "new", "tmp"):
        (path / spool).mkdir(parents=True, exist_ok=True)
    return path


def _state(box: Path, far: int = 1) -> Path:
    state = box / STATE_FILE
    state.write_text(STATE.format(far=far), encoding="utf-8")
    return state


class ReadUidvalidityTests(unittest.TestCase):
    def test_reads_every_folder_from_its_own_state_file(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            _state(_box(root), far=1)
            _state(_box(root, ".Sent"), far=7)
            self.assertEqual(
                read_uidvalidity(root), {"INBOX": 1, ".Sent": 7}
            )

    def test_ignores_the_message_records(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            # A record line is `<far> <near> [<>] [^~] <flags>`; one that happens
            # to start with digits must never be read as a header value.
            _state(_box(root), far=1)
            self.assertEqual(read_uidvalidity(root)["INBOX"], 1)

    def test_a_folder_without_state_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            _state(_box(root))
            _box(root, ".Drafts")
            with self.assertRaises(ValidationError) as caught:
                read_uidvalidity(root)
            self.assertIn(".Drafts", str(caught.exception))

    def test_a_live_journal_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            box = _box(root)
            state = _state(box)
            state.with_name(state.name + ".journal").write_text("5\n", encoding="utf-8")
            with self.assertRaises(ValidationError) as caught:
                read_uidvalidity(root)
            self.assertIn("journal", str(caught.exception))

    def test_a_half_written_state_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            box = _box(root)
            _state(box)
            (box / (STATE_FILE + ".new")).write_text(
                STATE.format(far=1), encoding="utf-8"
            )
            with self.assertRaises(ValidationError) as caught:
                read_uidvalidity(root)
            self.assertIn(".new", str(caught.exception))

    def test_a_state_without_far_uidvalidity_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            box = _box(root)
            (box / STATE_FILE).write_text(
                "NearUidValidity 2\nMaxPulledUid 0\nMaxPushedUid 0\n\n",
                encoding="utf-8",
            )
            with self.assertRaises(ValidationError) as caught:
                read_uidvalidity(root)
            self.assertIn("FarUidValidity", str(caught.exception))

    def test_an_unknown_header_key_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            box = _box(root)
            (box / STATE_FILE).write_text(
                "FarUidValidity 1\nUnexpected 3\n\n", encoding="utf-8"
            )
            with self.assertRaises(ValidationError) as caught:
                read_uidvalidity(root)
            self.assertIn("Unexpected", str(caught.exception))

    def test_a_non_numeric_epoch_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            box = _box(root)
            (box / STATE_FILE).write_text("FarUidValidity one\n\n", encoding="utf-8")
            with self.assertRaises(ValidationError):
                read_uidvalidity(root)

    def test_a_zero_epoch_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            _state(_box(root), far=0)
            with self.assertRaises(ValidationError) as caught:
                read_uidvalidity(root)
            self.assertIn("positive", str(caught.exception))

    def test_a_duplicate_key_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            box = _box(root)
            (box / STATE_FILE).write_text(
                "FarUidValidity 1\nFarUidValidity 2\n\n", encoding="utf-8"
            )
            with self.assertRaises(ValidationError):
                read_uidvalidity(root)

    def test_the_expire_key_is_accepted_on_either_side(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            box = _box(root)
            # 1.5 writes MaxExpiredNearUid by default and 1.4 writes
            # MaxExpiredFarUid; both are the same field for a reader.
            (box / STATE_FILE).write_text(
                "FarUidValidity 4\nNearUidValidity 9\nMaxPulledUid 0\n"
                "MaxPushedUid 0\nMaxExpiredNearUid 0\n\n",
                encoding="utf-8",
            )
            self.assertEqual(read_uidvalidity(root), {"INBOX": 4})

    def test_a_maildir_with_no_folder_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            root.mkdir(exist_ok=True)
            with self.assertRaises(ValidationError):
                read_uidvalidity(root)


if __name__ == "__main__":
    unittest.main()
