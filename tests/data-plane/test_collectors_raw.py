"""Raw collector tests: enumeration, epochs, absence, and the refusals.

Every case is a real on-disk fixture in a temporary directory: a Maildir, a
directory of calendar entities, an AccountSet document, and a SQLite database the
test writes itself. No network, no provider, no credentials.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import sqlite3
import tempfile
import unittest
from unittest import mock
from pathlib import Path

from data_plane.collectors.raw import (
    ABSENCE_NO_TOMBSTONE,
    ABSENCE_PROVIDER_WINDOW,
    ABSENCE_RETENTION,
    ABSENT_SINCE,
    MAX_MEDIA_OBJECTS,
    RawReplica,
    carry_forward,
    collect_brave_db,
    collect_calendar,
    collect_maildir,
    collect_music,
    collect_notes,
    collect_photos,
    collect_simplefin,
    collect_tasks,
    previous_replica,
)
from data_plane.collectors.staging import StagingGeneration
from data_plane.collectors.state import ReplicaState
from data_plane.errors import EpochError, ManifestError, PublishError, ValidationError

CAPTURED = "2026-11-19T00:00:00+00:00"


def _generation(root: Path, name: str = "gen-0001") -> StagingGeneration:
    return StagingGeneration(root, name, source_id="test.source")


def _publish(generation: StagingGeneration) -> Path:
    return generation.commit_next(complete=True)


def _object_files(root: Path) -> list[Path]:
    objects = root / "objects"
    if not objects.is_dir():
        return []
    return sorted(path for path in objects.glob("*/*") if path.is_file())


def _maildir(root: Path, folder: str = "") -> Path:
    base = root / folder if folder else root
    for name in ("cur", "new", "tmp"):
        (base / name).mkdir(parents=True, exist_ok=True)
    return base


def _message(path: Path, key: str, *, flags: str = "", body: str = "hello") -> None:
    name = f"{key}:2,{flags}" if flags else key
    spool = "cur" if flags else "new"
    (path / spool / name).write_bytes(
        (
            f"From: someone@example.com\r\n"
            f"To: me@example.com\r\n"
            f"Subject: {key}\r\n"
            f"Message-ID: <{key}@example.com>\r\n"
            f"Date: Tue, 18 Nov 2026 10:00:00 +0000\r\n"
            f"\r\n{body}\r\n"
        ).encode("utf-8")
    )


class ReplicaTests(unittest.TestCase):
    def test_reads_verified_objects(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            generation = _generation(root)
            generation.put("a", b"one", {"kind": "test"})
            published = _publish(generation)

            replica = RawReplica(root)
            self.assertEqual(replica.generation_id, "gen-0001")
            self.assertEqual(replica.read("a"), b"one")
            self.assertEqual(replica.metadata("a"), {"kind": "test"})
            self.assertEqual(replica.path, published)

    def test_tampered_object_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            generation = _generation(root)
            generation.put("a", b"one", {})
            published = _publish(generation)
            (published / "objects" / "a").write_bytes(b"two")

            with self.assertRaises(ManifestError):
                RawReplica(root).read("a")

    def test_no_generation_is_a_named_failure(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            with self.assertRaises(ManifestError):
                RawReplica(Path(work))

    def test_carry_forward_marks_absence_once(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            first = _generation(root)
            first.put("kept", b"keep", {})
            first.put("gone", b"bye", {})
            _publish(first)

            second = _generation(root, "gen-0002")
            second.put("kept", b"keep", {})
            carried = carry_forward(
                second,
                previous_replica(second),
                reason=ABSENCE_NO_TOMBSTONE,
                captured_at="2026-11-19T00:00:00+00:00",
            )
            self.assertEqual(carried, 1)
            _publish(second)

            third = _generation(root, "gen-0003")
            carry_forward(
                third,
                previous_replica(third),
                reason=ABSENCE_NO_TOMBSTONE,
                captured_at="2026-12-01T00:00:00+00:00",
            )
            _publish(third)

            metadata = RawReplica(root, "gen-0003").metadata("gone")
            self.assertEqual(metadata[ABSENT_SINCE], "2026-11-19T00:00:00+00:00")
            self.assertEqual(metadata["absence_reason"], ABSENCE_NO_TOMBSTONE)

    def test_carry_forward_reads_no_object_bytes(self) -> None:
        """A carried object costs an inode, not a read of the previous replica."""

        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            first = StagingGeneration(root, "gen-1", source_id="tuta.mail")
            first.put("mail::INBOX::1", b"From: a\r\n\r\nbody\r\n", {"folder": "INBOX"})
            first.commit_next(complete=True)

            second = StagingGeneration(root, "gen-2", source_id="tuta.mail")
            def guarded(self, object_id):
                raise AssertionError(f"carry_forward read {object_id}")

            with mock.patch.object(RawReplica, "read", guarded):
                carried = carry_forward(
                    second,
                    previous_replica(second),
                    reason=ABSENCE_NO_TOMBSTONE,
                    captured_at="2026-11-20T00:00:00+00:00",
                )
            self.assertEqual(carried, 1)

            second.commit_next(complete=True)
            replica = RawReplica(root, "gen-2")
            self.assertEqual(
                replica.read("mail::INBOX::1"), b"From: a\r\n\r\nbody\r\n"
            )
            self.assertIn(
                "absent_since", replica.metadata("mail::INBOX::1")
            )

    def test_carry_forward_never_resurrects_a_tombstone(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            first = _generation(root)
            first.put("gone", b"bye", {})
            _publish(first)

            second = _generation(root, "gen-0002")
            second.delete("gone")
            self.assertEqual(
                carry_forward(
                    second,
                    previous_replica(second),
                    reason=ABSENCE_NO_TOMBSTONE,
                    captured_at=CAPTURED,
                ),
                0,
            )
            _publish(second)
            self.assertFalse(RawReplica(root, "gen-0002").object_ids())

    def test_carry_forward_refuses_an_empty_reason(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            generation = _generation(Path(work))
            with self.assertRaises(ValidationError):
                carry_forward(
                    generation, None, reason="  ", captured_at=CAPTURED
                )


class MailTests(unittest.TestCase):
    def test_collects_both_spools_with_flags(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            inbox = _maildir(root / "mail")
            sent = _maildir(root / "mail", ".Sent")
            _message(inbox, "aaa")
            _message(inbox, "bbb", flags="RS")
            _message(sent, "ccc", flags="S")

            generation = _generation(root / "replica")
            report = collect_maildir(
                root / "mail",
                generation,
                uidvalidity={"INBOX": 7, ".Sent": 3},
                captured_at=CAPTURED,
            )
            _publish(generation)

            self.assertEqual(report.objects, 3)
            self.assertEqual(report.details["folders"], {"INBOX": 2, ".Sent": 1})
            replica = RawReplica(root / "replica")
            metadata = replica.metadata("mail::INBOX::bbb")
            self.assertEqual(metadata["flags"], ["R", "S"])
            self.assertEqual(metadata["uidvalidity"], 7)
            self.assertIn(b"Subject: bbb", replica.read("mail::INBOX::bbb"))
            self.assertEqual(
                json.loads(replica.read("mail::_uidvalidity")),
                {"INBOX": 7, ".Sent": 3},
            )

    def test_tmp_is_a_refusal(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            inbox = _maildir(root / "mail")
            (inbox / "tmp" / "in-flight").write_bytes(b"partial")
            with self.assertRaises(PublishError):
                collect_maildir(
                    root / "mail",
                    _generation(root / "replica"),
                    uidvalidity={"INBOX": 1},
                    captured_at=CAPTURED,
                )

    def test_duplicate_key_is_a_refusal(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            inbox = _maildir(root / "mail")
            _message(inbox, "same")
            _message(inbox, "same", flags="S")
            with self.assertRaises(PublishError):
                collect_maildir(
                    root / "mail",
                    _generation(root / "replica"),
                    uidvalidity={"INBOX": 1},
                    captured_at=CAPTURED,
                )

    def test_missing_uidvalidity_is_a_refusal(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            _maildir(root / "mail")
            with self.assertRaises(ValidationError):
                collect_maildir(
                    root / "mail",
                    _generation(root / "replica"),
                    uidvalidity={},
                    captured_at=CAPTURED,
                )

    def test_uidvalidity_change_is_a_new_epoch(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            inbox = _maildir(root / "mail")
            _message(inbox, "aaa")
            first = _generation(root / "replica")
            collect_maildir(
                root / "mail", first, uidvalidity={"INBOX": 7}, captured_at=CAPTURED
            )
            _publish(first)

            second = _generation(root / "replica", "gen-0002")
            with self.assertRaises(EpochError):
                collect_maildir(
                    root / "mail", second, uidvalidity={"INBOX": 8}, captured_at=CAPTURED
                )

    def test_a_vanished_folder_is_a_refusal(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            inbox = _maildir(root / "mail")
            _maildir(root / "mail", ".Sent")
            _message(inbox, "aaa")
            first = _generation(root / "replica")
            collect_maildir(
                root / "mail",
                first,
                uidvalidity={"INBOX": 7, ".Sent": 3},
                captured_at=CAPTURED,
            )
            _publish(first)

            for name in ("cur", "new", "tmp"):
                (root / "mail" / ".Sent" / name).rmdir()
            (root / "mail" / ".Sent").rmdir()
            second = _generation(root / "replica", "gen-0002")
            with self.assertRaises(PublishError):
                collect_maildir(
                    root / "mail",
                    second,
                    uidvalidity={"INBOX": 7},
                    captured_at=CAPTURED,
                )

    def test_expunge_is_tombstoned(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            inbox = _maildir(root / "mail")
            _message(inbox, "aaa")
            _message(inbox, "bbb")
            first = _generation(root / "replica")
            collect_maildir(
                root / "mail", first, uidvalidity={"INBOX": 7}, captured_at=CAPTURED
            )
            _publish(first)

            (inbox / "new" / "bbb").unlink()
            second = _generation(root / "replica", "gen-0002")
            report = collect_maildir(
                root / "mail", second, uidvalidity={"INBOX": 7}, captured_at=CAPTURED
            )
            self.assertEqual(report.deleted, 1)
            _publish(second)
            self.assertNotIn("mail::INBOX::bbb", RawReplica(root / "replica").object_ids())


class CalendarTests(unittest.TestCase):
    def _write(self, directory: Path, name: str, entity: dict) -> None:
        directory.mkdir(parents=True, exist_ok=True)
        (directory / name).write_text(json.dumps(entity), encoding="utf-8")

    def test_keeps_rrule_and_derives_ics(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            entities = root / "entities"
            self._write(
                entities,
                "e1.json",
                {
                    "id": "e1",
                    "uid": "uid-1",
                    "revision": "3",
                    "summary": "Weekly, with a comma",
                    "dtstart": "2026-11-19T10:00:00",
                    "dtend": "2026-11-19T11:00:00",
                    "rrule": "FREQ=WEEKLY;COUNT=5",
                    "attendees": [{"email": "a@example.com", "name": "A"}],
                    "alarms": [{"trigger": "-PT15M"}],
                },
            )
            generation = _generation(root / "replica")
            report = collect_calendar(entities, generation, captured_at=CAPTURED)
            _publish(generation)

            self.assertEqual(report.objects, 1)
            replica = RawReplica(root / "replica")
            raw = json.loads(replica.read("calendar::e1"))
            self.assertEqual(raw["rrule"], "FREQ=WEEKLY;COUNT=5")
            ics = replica.read("calendar::e1::ics").decode("utf-8")
            self.assertIn("RRULE:FREQ=WEEKLY;COUNT=5\r\n", ics)
            self.assertIn("SUMMARY:Weekly\\, with a comma", ics)
            self.assertIn("ATTENDEE;CN=\"A\":mailto:a@example.com", ics)
            self.assertIn("BEGIN:VALARM", ics)
            self.assertNotIn("EXDATE", ics)
            self.assertEqual(ics.count("BEGIN:VEVENT"), 1)

    def test_explicit_deletion_is_tombstoned_and_absence_is_not(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            entities = root / "entities"
            self._write(entities, "e1.json", {"id": "e1", "uid": "uid-1"})
            self._write(entities, "e2.json", {"id": "e2", "uid": "uid-2"})
            first = _generation(root / "replica")
            collect_calendar(entities, first, captured_at=CAPTURED)
            _publish(first)

            # e1 is deleted by the provider; e2 simply stops appearing.
            self._write(entities, "e1.json", {"id": "e1", "uid": "uid-1", "deleted": True})
            (entities / "e2.json").unlink()
            second = _generation(root / "replica", "gen-0002")
            report = collect_calendar(entities, second, captured_at=CAPTURED)
            self.assertEqual(report.deleted, 1)
            _publish(second)

            replica = RawReplica(root / "replica", "gen-0002")
            self.assertEqual(replica.object_ids(), ("calendar::e2", "calendar::e2::ics"))
            metadata = replica.metadata("calendar::e2")
            self.assertEqual(metadata["absence_reason"], ABSENCE_NO_TOMBSTONE)
            self.assertEqual(metadata[ABSENT_SINCE], CAPTURED)

    def test_two_entities_with_one_id_are_refused(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            entities = root / "entities"
            self._write(entities, "a.json", {"id": "same", "uid": "u1"})
            self._write(entities, "b.json", {"id": "same", "uid": "u2"})
            with self.assertRaises(PublishError):
                collect_calendar(entities, _generation(root / "replica"), captured_at=CAPTURED)


class NotesTests(unittest.TestCase):
    def _vault(self, root: Path) -> Path:
        vault = root / "vault"
        (vault / "projects").mkdir(parents=True)
        (vault / "index.md").write_text("# Vault index\n\nBody.\n", encoding="utf-8")
        (vault / "projects" / "alpha.md").write_text(
            "No heading here.\n", encoding="utf-8"
        )
        return vault

    def test_ids_are_the_quoted_paths_and_headings_fall_back_to_the_stem(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            vault = self._vault(root)
            with ReplicaState(root / "replica", source_id="notes.markdown") as state:
                report = collect_notes(vault, state, captured_at=CAPTURED)

                self.assertEqual(report.objects, 2)
                self.assertEqual(report.version, 1)
                self.assertEqual(
                    state.live_object_ids(),
                    ("notes::index.md", "notes::projects%2Falpha.md"),
                )
                index = json.loads(state.read("notes::index.md"))
                self.assertEqual(index["heading"], "Vault index")
                alpha = json.loads(state.read("notes::projects%2Falpha.md"))
                self.assertEqual(alpha["heading"], "alpha")
                self.assertEqual(alpha["path"], "projects/alpha.md")
                self.assertEqual(alpha["tags"], [])
                self.assertEqual(alpha["body"], "No heading here.\n")
                metadata = state.get("notes::projects%2Falpha.md")["metadata"]
                self.assertEqual(metadata["source_id"], "notes.markdown")
                self.assertEqual(metadata["path"], "projects/alpha.md")
                self.assertEqual(metadata["heading"], "alpha")
                self.assertEqual(metadata["tags"], [])
                self.assertEqual(metadata["body_sha256"], alpha["revision"])
                self.assertTrue(metadata["updated_at"].endswith("+00:00"))

    def test_a_second_pass_writes_no_new_object(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            vault = self._vault(root)
            with ReplicaState(root / "replica", source_id="notes.markdown") as state:
                collect_notes(vault, state, captured_at=CAPTURED)
                before = _object_files(root / "replica")
                collect_notes(vault, state, captured_at=CAPTURED)

                self.assertEqual(_object_files(root / "replica"), before)
                self.assertEqual(state.version, 2)
                self.assertEqual(len(state.live_object_ids()), 2)

    def test_a_vanished_file_keeps_its_bytes_with_an_absence_marker(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            vault = self._vault(root)
            with ReplicaState(root / "replica", source_id="notes.markdown") as state:
                collect_notes(vault, state, captured_at=CAPTURED)

                (vault / "projects" / "alpha.md").unlink()
                missing = "2026-11-20T00:00:00+00:00"
                report = collect_notes(vault, state, captured_at=missing)

                self.assertEqual(report.carried, 1)
                self.assertEqual(
                    state.live_object_ids(),
                    ("notes::index.md", "notes::projects%2Falpha.md"),
                )
                row = state.get("notes::projects%2Falpha.md")
                self.assertEqual(row["metadata"]["absence_reason"], ABSENCE_NO_TOMBSTONE)
                self.assertEqual(row["metadata"][ABSENT_SINCE], missing)
                self.assertEqual(
                    json.loads(state.read("notes::projects%2Falpha.md"))["body"],
                    "No heading here.\n",
                )

    def test_a_changed_note_writes_a_new_object_and_collects_the_old_one(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            vault = self._vault(root)
            with ReplicaState(root / "replica", source_id="notes.markdown") as state:
                collect_notes(vault, state, captured_at=CAPTURED)
                self.assertEqual(len(_object_files(root / "replica")), 2)

                (vault / "index.md").write_text("# Renamed\n", encoding="utf-8")
                collect_notes(vault, state, captured_at=CAPTURED)

                self.assertEqual(len(_object_files(root / "replica")), 2)
                self.assertEqual(
                    json.loads(state.read("notes::index.md"))["heading"], "Renamed"
                )

    def test_a_symlinked_file_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            vault = self._vault(root)
            target = root / "outside.md"
            target.write_text("# Elsewhere\n", encoding="utf-8")
            (vault / "linked.md").symlink_to(target)
            with ReplicaState(root / "replica", source_id="notes.markdown") as state:
                with self.assertRaises(PublishError) as caught:
                    collect_notes(vault, state, captured_at=CAPTURED)
                self.assertIn("symlink", str(caught.exception))

    def test_a_symlinked_non_note_is_skipped(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            vault = self._vault(root)
            target = root / "outside.png"
            target.write_bytes(b"\x89PNG")
            (vault / "linked.png").symlink_to(target)
            with ReplicaState(root / "replica", source_id="notes.markdown") as state:
                report = collect_notes(vault, state, captured_at=CAPTURED)
                self.assertEqual(report.objects, 2)

    def test_a_symlinked_directory_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            vault = self._vault(root)
            elsewhere = root / "elsewhere"
            elsewhere.mkdir()
            (elsewhere / "note.md").write_text("# Elsewhere\n", encoding="utf-8")
            (vault / "linked").symlink_to(elsewhere)
            with ReplicaState(root / "replica", source_id="notes.markdown") as state:
                with self.assertRaises(PublishError) as caught:
                    collect_notes(vault, state, captured_at=CAPTURED)
                self.assertIn("symlink", str(caught.exception))

    def test_a_symlinked_vault_root_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            vault = self._vault(root)
            linked = root / "linked-vault"
            linked.symlink_to(vault)
            with ReplicaState(root / "replica", source_id="notes.markdown") as state:
                with self.assertRaises(PublishError) as caught:
                    collect_notes(linked, state, captured_at=CAPTURED)
                self.assertIn("symlink", str(caught.exception))

    def test_a_file_that_is_not_utf8_is_refused_by_path(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            vault = self._vault(root)
            broken = vault / "projects" / "broken.md"
            broken.write_bytes(b"# Broken\n\xff\xfe\n")
            with ReplicaState(root / "replica", source_id="notes.markdown") as state:
                with self.assertRaises(PublishError) as caught:
                    collect_notes(vault, state, captured_at=CAPTURED)
                self.assertIn(str(broken), str(caught.exception))


class TasksTests(unittest.TestCase):
    def _directory(self, root: Path) -> Path:
        directory = root / "todo"
        directory.mkdir(parents=True)
        return directory

    def _object_id(self, line: str) -> str:
        digest = hashlib.sha256(line.encode("utf-8")).hexdigest()[:16]
        return f"tasks::{digest}"

    def test_line_fields_are_parsed_and_the_text_stays_verbatim(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            directory = self._directory(root)
            open_line = (
                "(A) 2026-11-08 Verify #427 on smoreswork after access returns - "
                "home-manager switch +nix-config @smoreswork due:2026-11-10"
            )
            done_line = "x 2026-11-01 call the clinic"
            (directory / "todo.txt").write_text(open_line + "\n", encoding="utf-8")
            (directory / "done.txt").write_text(done_line + "\n", encoding="utf-8")
            with ReplicaState(root / "replica", source_id="tasks.todo") as state:
                report = collect_tasks(directory, state, captured_at=CAPTURED)
                self.assertEqual(report.objects, 2)

                open_id = self._object_id(open_line)
                done_id = self._object_id(done_line)
                self.assertEqual(
                    sorted(state.live_object_ids()), sorted((open_id, done_id))
                )

                task = json.loads(state.read(open_id))
                self.assertEqual(task["task_id"], open_id)
                self.assertEqual(task["text"], open_line)
                self.assertFalse(task["done"])
                self.assertEqual(task["priority"], "A")
                self.assertEqual(task["projects"], ["nix-config"])
                self.assertEqual(task["contexts"], ["smoreswork"])
                self.assertEqual(task["dates"], {"due": "2026-11-10"})
                self.assertEqual(task["created"], "2026-11-08")
                self.assertEqual(task["file"], "todo.txt")

                finished = json.loads(state.read(done_id))
                self.assertTrue(finished["done"])
                self.assertEqual(finished["text"], done_line)
                self.assertEqual(finished["created"], "2026-11-01")
                self.assertEqual(finished["file"], "done.txt")

                metadata = state.get(open_id)["metadata"]
                self.assertEqual(metadata["source_id"], "tasks.todo")
                self.assertEqual(metadata["captured_at"], CAPTURED)
                self.assertEqual(metadata["file"], "todo.txt")
                self.assertEqual(metadata["priority"], "A")
                self.assertEqual(metadata["projects"], ["nix-config"])
                self.assertEqual(metadata["contexts"], ["smoreswork"])
                self.assertEqual(metadata["dates"], {"due": "2026-11-10"})
                self.assertEqual(metadata["created"], "2026-11-08")

    def test_a_second_pass_writes_no_new_object(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            directory = self._directory(root)
            (directory / "todo.txt").write_text(
                "(B) come up with vocal therapy schedule\n"
                "2026-11-09 book the room +home t:2026-11-09\n",
                encoding="utf-8",
            )
            with ReplicaState(root / "replica", source_id="tasks.todo") as state:
                collect_tasks(directory, state, captured_at=CAPTURED)
                before = _object_files(root / "replica")
                collect_tasks(directory, state, captured_at=CAPTURED)

                self.assertEqual(_object_files(root / "replica"), before)
                self.assertEqual(state.version, 2)

    def test_an_edited_line_is_a_new_task_and_the_old_one_keeps_an_absence_marker(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            directory = self._directory(root)
            before = "(C) renew the passport due:2026-12-01"
            after = "(C) renew the passport due:2026-12-08"
            (directory / "todo.txt").write_text(before + "\n", encoding="utf-8")
            with ReplicaState(root / "replica", source_id="tasks.todo") as state:
                collect_tasks(directory, state, captured_at=CAPTURED)

                (directory / "todo.txt").write_text(after + "\n", encoding="utf-8")
                report = collect_tasks(directory, state, captured_at=CAPTURED)
                self.assertEqual(report.objects, 1)
                self.assertEqual(report.carried, 1)

                old_id = self._object_id(before)
                new_id = self._object_id(after)
                self.assertIn(new_id, state.live_object_ids())
                self.assertIn(old_id, state.live_object_ids())
                row = state.get(old_id)
                self.assertEqual(row["metadata"]["absence_reason"], ABSENCE_NO_TOMBSTONE)
                self.assertEqual(row["metadata"][ABSENT_SINCE], CAPTURED)
                self.assertEqual(json.loads(state.read(old_id))["text"], before)

    def test_a_duplicate_line_collapses_and_is_counted(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            directory = self._directory(root)
            line = "(B) come up with vocal therapy schedule"
            (directory / "todo.txt").write_text(
                f"{line}\n(D) water the plants\n{line}\n", encoding="utf-8"
            )
            with ReplicaState(root / "replica", source_id="tasks.todo") as state:
                report = collect_tasks(directory, state, captured_at=CAPTURED)
                self.assertEqual(report.objects, 2)
                self.assertEqual(report.details["duplicates"], 1)

    def test_no_task_file_at_all_is_refused_by_directory(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            directory = self._directory(root)
            with ReplicaState(root / "replica", source_id="tasks.todo") as state:
                with self.assertRaises(PublishError) as caught:
                    collect_tasks(directory, state, captured_at=CAPTURED)
                self.assertIn(str(directory), str(caught.exception))

    def test_an_empty_todo_file_publishes_nothing_and_does_not_fail(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            directory = self._directory(root)
            (directory / "todo.txt").write_text("", encoding="utf-8")
            with ReplicaState(root / "replica", source_id="tasks.todo") as state:
                report = collect_tasks(directory, state, captured_at=CAPTURED)
                self.assertEqual(report.objects, 0)
                self.assertEqual(state.live_object_ids(), ())


class FinanceTests(unittest.TestCase):
    def _accountset(self) -> dict:
        return {
            "connections": [{"conn_id": "conn-1", "name": "Schwab"}],
            "accounts": [
                {
                    "id": "acct-1",
                    "name": "Checking",
                    "currency": "USD",
                    "balance": "100.00",
                    "extra": {"provider": "schwab"},
                    "transactions": [
                        {
                            "id": "txn-1",
                            "amount": "-12.34",
                            "description": "Coffee",
                            "posted": 1763500000,
                        },
                        {
                            "id": "txn-2",
                            "amount": "-1.00",
                            "description": "Pending thing",
                            "pending": True,
                            "posted": 0,
                        },
                    ],
                }
            ],
        }

    def test_an_accountset_without_connections_keys_by_institution(self) -> None:
        # The beta bridge sends no `connections` array at all; each account
        # carries `org` instead. Refusing there would fail every real read.
        accountset = self._accountset()
        del accountset["connections"]
        accountset["accounts"][0]["org"] = {"domain": "schwab.com", "name": "Schwab"}
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            generation = _generation(root / "replica")
            collect_simplefin(
                accountset,
                generation,
                accountset_url="https://sfin.example/access",
                captured_at=CAPTURED,
                include_pending=True,
                now=1763500000,
            )
            _publish(generation)
            metadata = RawReplica(root / "replica").metadata(
                "finance::txn::acct-1::txn-1"
            )
            self.assertEqual(metadata["conn_id"], "schwab.com")

    def test_stores_raw_records_keyed_and_hashed(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            generation = _generation(root / "replica")
            report = collect_simplefin(
                self._accountset(),
                generation,
                accountset_url="https://sfin.example/access",
                captured_at=CAPTURED,
                include_pending=True,
                now=1763500000,
            )
            _publish(generation)

            self.assertEqual(report.details["transactions"], 2)
            self.assertEqual(report.details["pending"], 1)
            replica = RawReplica(root / "replica")
            metadata = replica.metadata("finance::txn::acct-1::txn-1")
            self.assertEqual(metadata["conn_id"], "conn-1")
            self.assertEqual(metadata["accountset_url"], "https://sfin.example/access")
            self.assertFalse(metadata["pending"])
            self.assertEqual(len(metadata["record_sha256"]), 64)
            self.assertIn(b"provider", replica.read("finance::account::acct-1"))
            self.assertIn(b"Pending thing", replica.read("finance::accountset"))

    def test_errors_block_publication(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            accountset = self._accountset()
            accountset["errlist"] = ["login required"]
            with self.assertRaises(PublishError):
                collect_simplefin(
                    accountset,
                    _generation(root / "replica"),
                    accountset_url="https://sfin.example/access",
                    captured_at=CAPTURED,
                    include_pending=True,
                )

    def test_missing_data_blocks_publication(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            accountset = self._accountset()
            accountset["accounts"][0]["act"] = {"missingdata": ["balance"]}
            with self.assertRaises(PublishError):
                collect_simplefin(
                    accountset,
                    _generation(root / "replica"),
                    accountset_url="https://sfin.example/access",
                    captured_at=CAPTURED,
                    include_pending=True,
                )

    def test_pending_must_be_requested(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            with self.assertRaises(ValidationError):
                collect_simplefin(
                    self._accountset(),
                    _generation(root / "replica"),
                    accountset_url="https://sfin.example/access",
                    captured_at=CAPTURED,
                )

    def test_window_absence_is_carried_forward(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            now = 1763500000
            first = _generation(root / "replica")
            collect_simplefin(
                self._accountset(),
                first,
                accountset_url="https://sfin.example/access",
                captured_at=CAPTURED,
                include_pending=True,
                now=now,
            )
            _publish(first)

            old = self._accountset()
            old["accounts"][0]["transactions"] = [
                {
                    "id": "txn-old",
                    "amount": "-5.00",
                    "description": "Ancient",
                    "posted": now - 200 * 86400,
                }
            ]
            second = _generation(root / "replica", "gen-0002")
            report = collect_simplefin(
                old,
                second,
                accountset_url="https://sfin.example/access",
                captured_at="2026-11-20T00:00:00+00:00",
                include_pending=True,
                now=now,
            )
            self.assertEqual(report.deleted, 0)
            _publish(second)

            replica = RawReplica(root / "replica", "gen-0002")
            metadata = replica.metadata("finance::txn::acct-1::txn-1")
            self.assertEqual(metadata["absence_reason"], ABSENCE_PROVIDER_WINDOW)
            self.assertNotIn("finance::txn::acct-1::txn-old", replica.object_ids())


class BraveTests(unittest.TestCase):
    def _database(self, path: Path) -> None:
        connection = sqlite3.connect(path)
        try:
            connection.execute("CREATE TABLE urls (id INTEGER PRIMARY KEY, url TEXT, title TEXT)")
            connection.execute("CREATE TABLE visits (id INTEGER PRIMARY KEY, url INTEGER, visit_time INTEGER)")
            connection.execute("CREATE TABLE visit_source (id INTEGER PRIMARY KEY, source INTEGER)")
            connection.execute(
                "INSERT INTO urls (url, title) VALUES ('https://example.com', 'Example')"
            )
            connection.execute("INSERT INTO visits (url, visit_time) VALUES (1, 1234)")
            connection.execute("INSERT INTO visit_source (source) VALUES (0)")
            connection.commit()
        finally:
            connection.close()

    def test_stores_the_database_and_every_table(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            database = root / "History"
            self._database(database)

            generation = _generation(root / "replica")
            report = collect_brave_db(
                database,
                generation,
                device="smorespro",
                profile="Default",
                captured_at=CAPTURED,
            )
            _publish(generation)

            self.assertEqual(report.details["tables"]["urls"], 1)
            replica = RawReplica(root / "replica")
            self.assertEqual(replica.read("brave::db"), database.read_bytes())
            dump = json.loads(replica.read("brave::table::urls"))
            self.assertEqual(dump["columns"], ["id", "url", "title"])
            self.assertEqual(dump["rows"], [[1, "https://example.com", "Example"]])
            self.assertEqual(
                replica.metadata("brave::table::visits")["rows"], 1
            )

    def test_a_text_column_with_invalid_utf8_is_carried_as_bytes(self) -> None:
        # Brave's own tables hold binary values in TEXT-affinity columns: `meta`
        # has one for several keys. sqlite3 decodes TEXT to str before this module
        # sees the value, so a column like that aborts the whole dump with
        # `Could not decode to UTF-8` unless the connection hands it back raw.
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            database = root / "History"
            self._database(database)
            connection = sqlite3.connect(database)
            try:
                connection.execute("CREATE TABLE meta (key TEXT, value TEXT)")
                connection.execute(
                    "INSERT INTO meta VALUES ('binary', CAST(X'FFFE68' AS TEXT))"
                )
                connection.commit()
            finally:
                connection.close()

            generation = _generation(root / "replica")
            collect_brave_db(
                database,
                generation,
                device="smortress",
                profile="Default",
                captured_at=CAPTURED,
            )
            _publish(generation)

            dump = json.loads(RawReplica(root / "replica").read("brave::table::meta"))
            self.assertEqual(dump["rows"], [["binary", {"b64": "//5o"}]])

    def test_a_wal_sibling_is_a_refusal(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            database = root / "History"
            self._database(database)
            Path(str(database) + "-wal").write_bytes(b"")
            with self.assertRaises(PublishError):
                collect_brave_db(
                    database,
                    _generation(root / "replica"),
                    device="smorespro",
                    profile="Default",
                    captured_at=CAPTURED,
                )

    def test_not_a_database_is_a_named_failure(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            database = root / "History"
            database.write_bytes(b"not sqlite at all")
            with self.assertRaises(PublishError):
                collect_brave_db(
                    database,
                    _generation(root / "replica"),
                    device="smorespro",
                    profile="Default",
                    captured_at=CAPTURED,
                )

    def test_absence_is_carried_forward_as_retention(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            database = root / "History"
            self._database(database)
            first = _generation(root / "replica")
            collect_brave_db(
                database, first, device="smorespro", profile="Default", captured_at=CAPTURED
            )
            _publish(first)

            # A second copy without the urls table: retention cannot be told
            # apart from a user deletion, so the old table stays, marked absent.
            second_db = root / "History2"
            connection = sqlite3.connect(second_db)
            try:
                connection.execute("CREATE TABLE visits (id INTEGER PRIMARY KEY)")
                connection.commit()
            finally:
                connection.close()
            second = _generation(root / "replica", "gen-0002")
            collect_brave_db(
                second_db, second, device="smorespro", profile="Default", captured_at=CAPTURED
            )
            _publish(second)

            replica = RawReplica(root / "replica", "gen-0002")
            metadata = replica.metadata("brave::table::urls")
            self.assertEqual(metadata["absence_reason"], ABSENCE_RETENTION)
            self.assertIn("brave::table::visits", replica.object_ids())


class PhotosTests(unittest.TestCase):
    """A photo library is metadata only: the bytes stay on the media dataset."""

    def _library(self, root: Path) -> Path:
        library = root / "photos"
        (library / "2026" / "11").mkdir(parents=True)
        (library / "2026" / "11" / "harbour-sunset.jpg").write_bytes(b"\xff\xd8jpegbytes")
        (library / "2026" / "11" / "ridge.heic").write_bytes(b"\x00\x00heicbytes")
        (library / "2026" / "11" / "README.txt").write_text(
            "not media\n", encoding="utf-8"
        )
        return library

    def test_each_media_file_becomes_one_metadata_object(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            library = self._library(root)
            generation = _generation(root / "replica")
            report = collect_photos(library, generation, captured_at=CAPTURED)
            self.assertEqual(report.objects, 2)
            _publish(generation)

            replica = RawReplica(root / "replica")
            photo_id = "photos::2026%2F11%2Fharbour-sunset.jpg"
            self.assertEqual(
                replica.object_ids(),
                (photo_id, "photos::2026%2F11%2Fridge.heic"),
            )

            photo = json.loads(replica.read(photo_id))
            self.assertEqual(photo["photo_id"], photo_id)
            self.assertEqual(photo["path"], "2026/11/harbour-sunset.jpg")
            self.assertEqual(photo["title"], "harbour-sunset")
            self.assertEqual(photo["format"], "jpg")
            self.assertEqual(photo["size"], len(b"\xff\xd8jpegbytes"))
            self.assertTrue(photo["updated_at"].endswith("+00:00"))
            # The generation carries the metadata, never the media bytes.
            self.assertNotIn(b"jpegbytes", replica.read(photo_id))

            metadata = replica.metadata(photo_id)
            self.assertEqual(metadata["source_id"], "photos.library")
            self.assertEqual(metadata["captured_at"], CAPTURED)
            self.assertEqual(metadata["path"], "2026/11/harbour-sunset.jpg")
            self.assertEqual(metadata["revision"], photo["revision"])

    def test_an_unchanged_library_republishes_identical_objects(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            library = self._library(root)
            first = _generation(root / "replica", "gen-0001")
            collect_photos(library, first, captured_at=CAPTURED)
            _publish(first)
            second = _generation(root / "replica", "gen-0002")
            collect_photos(library, second, captured_at=CAPTURED)
            _publish(second)

            earlier = RawReplica(root / "replica", "gen-0001")
            later = RawReplica(root / "replica", "gen-0002")
            self.assertEqual(earlier.object_ids(), later.object_ids())
            for object_id in earlier.object_ids():
                self.assertEqual(earlier.read(object_id), later.read(object_id))

    def test_a_deleted_photo_is_carried_forward(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            library = self._library(root)
            first = _generation(root / "replica", "gen-0001")
            collect_photos(library, first, captured_at=CAPTURED)
            _publish(first)

            (library / "2026" / "11" / "ridge.heic").unlink()
            second = _generation(root / "replica", "gen-0002")
            report = collect_photos(library, second, captured_at=CAPTURED)
            self.assertEqual(report.carried, 1)
            _publish(second)

            replica = RawReplica(root / "replica")
            self.assertIn("photos::2026%2F11%2Fridge.heic", replica.object_ids())
            metadata = replica.metadata("photos::2026%2F11%2Fridge.heic")
            self.assertEqual(metadata["absence_reason"], ABSENCE_NO_TOMBSTONE)

    def test_a_symlinked_directory_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            library = self._library(root)
            (root / "elsewhere").mkdir()
            (root / "elsewhere" / "foreign.jpg").write_bytes(b"\xff\xd8")
            (library / "linked").symlink_to(root / "elsewhere")
            generation = _generation(root / "replica")
            with self.assertRaises(PublishError):
                collect_photos(library, generation, captured_at=CAPTURED)

    def test_a_library_over_the_limit_is_refused_not_truncated(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            library = self._library(root)
            generation = _generation(root / "replica")
            with mock.patch("data_plane.collectors.raw.media.MAX_MEDIA_OBJECTS", 1):
                with self.assertRaises(PublishError) as raised:
                    collect_photos(library, generation, captured_at=CAPTURED)
            self.assertIn(str(1), str(raised.exception))
            self.assertFalse(any((root / "replica").glob("published/*")))
            self.assertGreater(MAX_MEDIA_OBJECTS, 1)

    def test_an_empty_library_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            library = root / "photos"
            library.mkdir()
            (library / "README.txt").write_text("no media\n", encoding="utf-8")
            generation = _generation(root / "replica")
            with self.assertRaises(PublishError):
                collect_photos(library, generation, captured_at=CAPTURED)

    def test_immich_derived_trees_are_not_walked(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            location = self._library(root)
            thumbs = location / "thumbs" / "2026" / "11"
            thumbs.mkdir(parents=True)
            (thumbs / "harbour-sunset.webp").write_bytes(b"RIFFthumb")
            originals = location / "library" / "2026" / "11"
            originals.mkdir(parents=True)
            (originals / "harbour-sunset.jpg").write_bytes(b"\xff\xd8jpegbytes")
            generation = _generation(root / "replica")
            report = collect_photos(location, generation, captured_at=CAPTURED)
            self.assertEqual(report.objects, 1)
            _publish(generation)

            replica = RawReplica(root / "replica")
            self.assertEqual(
                replica.object_ids(), ("photos::2026%2F11%2Fharbour-sunset.jpg",)
            )

    def test_an_unreadable_directory_is_refused_not_skipped(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            library = self._library(root)
            hidden = library / "2026" / "11"
            generation = _generation(root / "replica")
            mode = hidden.stat().st_mode
            hidden.chmod(0o000)
            try:
                with self.assertRaises(PublishError):
                    collect_photos(library, generation, captured_at=CAPTURED)
            finally:
                hidden.chmod(mode)
            self.assertFalse(any((root / "replica").glob("published/*")))

    def test_a_name_the_replica_cannot_store_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            library = self._library(root)
            name = os.path.join(os.fsencode(library), b"bad\xffname.jpg")
            os.close(os.open(name, os.O_CREAT | os.O_WRONLY))
            generation = _generation(root / "replica")
            with self.assertRaises(PublishError):
                collect_photos(library, generation, captured_at=CAPTURED)
            self.assertFalse(any((root / "replica").glob("published/*")))

    def test_an_unrepresentable_mtime_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            library = self._library(root)
            future = library / "2026" / "11" / "harbour-sunset.jpg"
            # The filesystem is not the subject here: ext4 clamps a year-10000
            # utime back into range, so a real mtime only reproduces on hosts
            # whose fs accepts it. Present the unrepresentable value directly.
            real_stat = Path.stat
            future_stat = mock.Mock(wraps=real_stat(future), st_mtime=253_402_300_800.0)

            def stat(path: Path, **kwargs: object) -> os.stat_result:
                if path == future:
                    return future_stat
                return real_stat(path, **kwargs)

            generation = _generation(root / "replica")
            with mock.patch.object(Path, "stat", stat):
                with self.assertRaises(PublishError):
                    collect_photos(library, generation, captured_at=CAPTURED)
            self.assertFalse(any((root / "replica").glob("published/*")))

    def test_a_name_longer_than_a_filename_is_still_stored(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            library = self._library(root)
            long_name = "immich-branded-" + "x" * 220 + ".jpg"
            (library / "2026" / "11" / long_name).write_bytes(b"\xff\xd8jpegbytes")
            generation = _generation(root / "replica")
            report = collect_photos(library, generation, captured_at=CAPTURED)
            self.assertEqual(report.objects, 3)
            _publish(generation)

            replica = RawReplica(root / "replica")
            object_id = f"photos::2026%2F11%2F{long_name}"
            self.assertIn(object_id, replica.object_ids())
            self.assertEqual(json.loads(replica.read(object_id))["title"],
                             "immich-branded-" + "x" * 220)

    def test_a_branded_base64_name_is_read_as_the_name_it_encodes(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            library = self._library(root)
            payload = {
                "bucket": "smp-prod",
                "key": "events/1c3f/photos/branded/1793739847399-26-11-03 Blitzy Headshots-0870.jpg",
            }
            encoded = base64.urlsafe_b64encode(json.dumps(payload).encode()).decode()
            (library / "2026" / "11" / f"{encoded}.jpg").write_bytes(b"\xff\xd8jpegbytes")
            generation = _generation(root / "replica")
            collect_photos(library, generation, captured_at=CAPTURED)
            _publish(generation)

            replica = RawReplica(root / "replica")
            object_id = f"photos::2026%2F11%2F{encoded}.jpg"
            self.assertEqual(
                json.loads(replica.read(object_id))["title"],
                "1793739847399-26-11-03 Blitzy Headshots-0870",
            )

    def test_the_report_counts_the_files_it_skipped(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            library = self._library(root)
            generation = _generation(root / "replica")
            report = collect_photos(library, generation, captured_at=CAPTURED)
            self.assertEqual(report.details["skipped"], 1)


class MusicTests(unittest.TestCase):
    """A music library is metadata only: the audio stays on the music dataset."""

    def _library(self, root: Path) -> Path:
        library = root / "music"
        album = library / "Tori Amos" / "Little Earthquakes"
        album.mkdir(parents=True)
        (album / "01 - Crucify.flac").write_bytes(b"fLaCaudio")
        (album / "02 Crucify (live).mp3").write_bytes(b"ID3audio")
        (library / "singles").mkdir()
        (library / "singles" / "Aurora.opus").write_bytes(b"OggSaudio")
        (library / "cover.jpg").write_bytes(b"\xff\xd8artwork")
        return library

    def test_artist_and_album_come_from_the_path_and_the_track_is_stripped(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            library = self._library(root)
            generation = _generation(root / "replica")
            report = collect_music(library, generation, captured_at=CAPTURED)
            self.assertEqual(report.objects, 3)
            _publish(generation)

            replica = RawReplica(root / "replica")
            track_id = "music::Tori%20Amos%2FLittle%20Earthquakes%2F01%20-%20Crucify.flac"
            self.assertIn(track_id, replica.object_ids())
            self.assertNotIn("music::cover.jpg", replica.object_ids())

            track = json.loads(replica.read(track_id))
            self.assertEqual(track["track_id"], track_id)
            self.assertEqual(track["title"], "Crucify")
            self.assertEqual(track["track"], 1)
            self.assertEqual(track["artist"], "Tori Amos")
            self.assertEqual(track["album"], "Little Earthquakes")
            self.assertEqual(track["format"], "flac")
            self.assertEqual(track["size"], len(b"fLaCaudio"))
            self.assertNotIn(b"fLaCaudio", replica.read(track_id))

            # A space is a separator too, and the suffix stays part of the title.
            live = json.loads(
                replica.read(
                    "music::Tori%20Amos%2FLittle%20Earthquakes%2F02%20Crucify%20%28live%29.mp3"
                )
            )
            self.assertEqual(live["title"], "Crucify (live)")
            self.assertEqual(live["track"], 2)

            # One directory is not enough to claim an artist or an album.
            single = json.loads(replica.read("music::singles%2FAurora.opus"))
            self.assertEqual(single["title"], "Aurora")
            self.assertEqual(single["artist"], "")
            self.assertEqual(single["album"], "")
            self.assertIsNone(single["track"])

            metadata = replica.metadata(track_id)
            self.assertEqual(metadata["source_id"], "music.library")
            self.assertEqual(metadata["captured_at"], CAPTURED)
            self.assertEqual(metadata["artist"], "Tori Amos")
            self.assertEqual(metadata["album"], "Little Earthquakes")

    def test_an_unchanged_library_republishes_identical_objects(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            library = self._library(root)
            first = _generation(root / "replica", "gen-0001")
            collect_music(library, first, captured_at=CAPTURED)
            _publish(first)
            second = _generation(root / "replica", "gen-0002")
            collect_music(library, second, captured_at=CAPTURED)
            _publish(second)

            earlier = RawReplica(root / "replica", "gen-0001")
            later = RawReplica(root / "replica", "gen-0002")
            self.assertEqual(earlier.object_ids(), later.object_ids())
            for object_id in earlier.object_ids():
                self.assertEqual(earlier.read(object_id), later.read(object_id))

    def test_an_empty_library_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            library = root / "music"
            (library / "Artwork").mkdir(parents=True)
            (library / "Artwork" / "cover.jpg").write_bytes(b"\xff\xd8artwork")
            generation = _generation(root / "replica")
            with self.assertRaises(PublishError):
                collect_music(library, generation, captured_at=CAPTURED)

    def test_a_symlinked_directory_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            library = self._library(root)
            (root / "elsewhere").mkdir()
            (root / "elsewhere" / "foreign.flac").write_bytes(b"fLaC")
            (library / "linked").symlink_to(root / "elsewhere")
            generation = _generation(root / "replica")
            with self.assertRaises(PublishError):
                collect_music(library, generation, captured_at=CAPTURED)

    def test_a_library_over_the_limit_is_refused_not_truncated(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            library = self._library(root)
            generation = _generation(root / "replica")
            with mock.patch("data_plane.collectors.raw.media.MAX_MEDIA_OBJECTS", 1):
                with self.assertRaises(PublishError):
                    collect_music(library, generation, captured_at=CAPTURED)
            self.assertFalse(any((root / "replica").glob("published/*")))


if __name__ == "__main__":
    unittest.main()
