"""The file effect owner: confinement, revisions, tombstones, and the broker.

Every test runs against a real temporary tree. Nothing here touches the network,
a provider, or live data; the vault is a ``tempfile.mkdtemp()`` and the broker
uses its production SQLite journal.
"""

from __future__ import annotations

import hashlib
import os
import stat
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from data_plane.broker import MAX_FIELD_BYTES, Broker, WriteRequest
from data_plane.broker_journal import BrokerJournal
from data_plane.confirmation import ConfirmationGate, FieldChange
from data_plane.effects import tombstones
from data_plane.effects.confine import ConfinedRoot
from data_plane.effects.notes import NotesAdapter
from data_plane.effects.tasks import TasksAdapter
from data_plane.effects.tombstones import TombstoneLog
from data_plane.errors import (
    ConfirmationError,
    ConfirmationRequired,
    StaleError,
    ValidationError,
)
from data_plane.identity import LOCAL_PROFILE, IdentityIssuer
from data_plane.intents import IntentStore
from data_plane.model import (
    Authority,
    Capability,
    EffectClass,
    FieldAuthority,
    IntentState,
    SourceContract,
    Visibility,
)

KEY = b"file-effects-test-key"
NOW = 1_000_000
SOURCE_ID = "notes.markdown"


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def notes_contract() -> SourceContract:
    return SourceContract(
        source_id=SOURCE_ID,
        visibility=Visibility.PERSONAL,
        version=1,
        recovery_group="notes",
        stable_id_fields=("note_id",),
        revision_field="revision",
        tombstone_field="tombstone",
        capabilities=(
            Capability(name="read", effect=EffectClass.READ),
            Capability(name="search", effect=EffectClass.SEARCH),
            Capability(name="create", effect=EffectClass.CREATE, reversible=True),
            Capability(name="update", effect=EffectClass.UPDATE, reversible=True),
            Capability(
                name="delete",
                effect=EffectClass.DELETE,
                reversible=False,
                requires_confirmation=True,
            ),
        ),
        authority=(
            FieldAuthority(field="body", authority=Authority.PORTABLE_FILE),
        ),
    )


def tasks_contract() -> SourceContract:
    return SourceContract(
        source_id="tasks.todo",
        visibility=Visibility.PERSONAL,
        version=1,
        recovery_group="notes",
        stable_id_fields=("task_id",),
        revision_field="revision",
        tombstone_field="tombstone",
        capabilities=(
            Capability(name="read", effect=EffectClass.READ),
            Capability(name="search", effect=EffectClass.SEARCH),
            Capability(name="create", effect=EffectClass.CREATE, reversible=True),
            Capability(
                name="delete",
                effect=EffectClass.DELETE,
                reversible=False,
                requires_confirmation=True,
            ),
        ),
        authority=(
            FieldAuthority(field="text", authority=Authority.PORTABLE_FILE),
        ),
    )


class TreeTest(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        (self.root / "sub").mkdir()

    def tearDown(self) -> None:
        self.directory.cleanup()

    def write(self, relative: str, text: str) -> Path:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path


class ConfinedRootTests(TreeTest):
    def setUp(self) -> None:
        super().setUp()
        self.confined = ConfinedRoot(self.root, label="vault", suffix=".md")

    def refused(self, relative: object) -> None:
        with self.assertRaises(ValidationError):
            self.confined.read_optional(relative)  # type: ignore[arg-type]

    def test_it_reads_a_regular_note(self) -> None:
        self.write("a.md", "hello")
        snapshot = self.confined.read_optional("a.md")
        assert snapshot is not None
        self.assertEqual(snapshot.data, b"hello")

    def test_an_absent_file_is_none(self) -> None:
        self.assertIsNone(self.confined.read_optional("a.md"))

    def test_it_refuses_traversal_and_non_canonical_paths(self) -> None:
        for relative in (
            "",
            "..",
            "a/../b.md",
            "/etc/passwd",
            "a//b.md",
            "./a.md",
            "a/",
            "sub/../a.md",
            "a.md\x00",
            "a\nb.md",
            "notes/evil.txt",
        ):
            with self.subTest(relative=relative):
                self.refused(relative)

    def test_it_refuses_a_non_string(self) -> None:
        self.refused(None)
        self.refused(7)

    def test_it_refuses_a_vcs_control_path_at_any_depth(self) -> None:
        for relative in (".git/config.md", "sub/.git/config.md", ".hg/a.md", ".svn/a.md"):
            with self.subTest(relative=relative):
                self.refused(relative)

    def test_it_refuses_its_own_control_directory(self) -> None:
        self.refused(".data-plane/tombstones.jsonl")

    def test_it_refuses_a_symlinked_leaf(self) -> None:
        outside = Path(tempfile.mkdtemp())
        try:
            target = outside / "secret.md"
            target.write_text("outside", encoding="utf-8")
            (self.root / "a.md").symlink_to(target)
            with self.assertRaises(ValidationError):
                self.confined.read_optional("a.md")
        finally:
            for child in outside.iterdir():
                child.unlink()
            outside.rmdir()

    def test_it_refuses_a_symlinked_parent(self) -> None:
        outside = Path(tempfile.mkdtemp())
        try:
            (outside / "a.md").write_text("outside", encoding="utf-8")
            (self.root / "linked").symlink_to(outside, target_is_directory=True)
            with self.assertRaises(ValidationError):
                self.confined.read_optional("linked/a.md")
        finally:
            for child in outside.iterdir():
                child.unlink()
            outside.rmdir()

    def test_it_refuses_a_fifo(self) -> None:
        os.mkfifo(self.root / "pipe.md")
        with self.assertRaises(ValidationError):
            self.confined.write("pipe.md", b"x", base_revision=None)

    def test_it_refuses_a_root_that_is_a_symlink(self) -> None:
        real = self.root / "real"
        real.mkdir()
        (real / "a.md").write_text("x", encoding="utf-8")
        link = self.root / "link"
        link.symlink_to(real, target_is_directory=True)
        confined = ConfinedRoot(link, label="vault", suffix=".md")
        with self.assertRaises(ValidationError):
            confined.read_optional("a.md")

    def test_it_refuses_a_missing_root(self) -> None:
        confined = ConfinedRoot(self.root / "nowhere", label="vault", suffix=".md")
        with self.assertRaises(ValidationError):
            confined.read_optional("a.md")

    def test_a_write_is_refused_when_the_base_revision_moved(self) -> None:
        self.write("a.md", "first")
        with self.assertRaises(StaleError):
            self.confined.write("a.md", b"second", base_revision=None)

    def test_a_write_replaces_atomically_and_leaves_no_temporary(self) -> None:
        self.write("a.md", "first")
        revision = self.confined.write(
            "a.md", b"second", base_revision=digest(b"first")
        )
        self.assertEqual(revision, digest(b"second"))
        self.assertEqual((self.root / "a.md").read_bytes(), b"second")
        self.assertEqual(
            [item.name for item in self.root.iterdir() if item.name.startswith(".")],
            [],
        )

    def test_a_file_over_the_cap_is_refused_rather_than_truncated(self) -> None:
        self.write("big.md", "x" * (MAX_FIELD_BYTES + 1))
        with self.assertRaises(ValidationError):
            self.confined.read_optional("big.md")


class TombstoneLogTests(TreeTest):
    def test_the_newest_entry_wins(self) -> None:
        log = TombstoneLog(self.root, source_id=SOURCE_ID)
        log.declare(
            target="notes::a.md", revision="r1", pre_image_sha256="a", deleted_at="t1"
        )
        log.declare(
            target="notes::a.md", revision="r2", pre_image_sha256="b", deleted_at="t2"
        )
        entry = log.lookup("notes::a.md")
        assert entry is not None
        self.assertEqual(entry["revision"], "r2")
        self.assertEqual(log.lookup("notes::b.md"), None)

    def test_a_malformed_line_does_not_hide_a_good_one(self) -> None:
        log = TombstoneLog(self.root, source_id=SOURCE_ID)
        log.declare(
            target="notes::a.md", revision="r1", pre_image_sha256="a", deleted_at="t1"
        )
        ledger = self.root / ".data-plane" / "tombstones.jsonl"
        with ledger.open("a", encoding="utf-8") as handle:
            handle.write("{not json}\n")
        entry = log.lookup("notes::a.md")
        assert entry is not None
        self.assertEqual(entry["revision"], "r1")



    def test_a_ledger_window_on_a_line_boundary_keeps_its_first_line(self) -> None:
        log = TombstoneLog(self.root, source_id=SOURCE_ID)
        log.declare(
            target="notes::boundary.md",
            revision="rB",
            pre_image_sha256="0" * 64,
            deleted_at="tB",
        )
        ledger = self.root / ".data-plane" / "tombstones.jsonl"
        entry = ledger.read_bytes()
        filler = b'{"a":1}\n'
        with mock.patch.object(tombstones, "MAX_LEDGER_BYTES", len(entry)):
            ledger.write_bytes(filler * 4 + entry)
            found = log.lookup("notes::boundary.md")
        assert found is not None
        self.assertEqual(found["revision"], "rB")

    def test_an_old_ledger_stays_readable_past_the_bound(self) -> None:
        log = TombstoneLog(self.root, source_id=SOURCE_ID)
        log.declare(
            target="notes::old.md", revision="r1", pre_image_sha256="a", deleted_at="t1"
        )
        ledger = self.root / ".data-plane" / "tombstones.jsonl"
        filler = b'{"target":"notes::filler.md","revision":"r"}\n'
        with ledger.open("ab") as handle:
            handle.write(filler * (tombstones.MAX_LEDGER_BYTES // len(filler) + 1))
        log.declare(
            target="notes::new.md", revision="r2", pre_image_sha256="b", deleted_at="t2"
        )
        entry = log.lookup("notes::new.md")
        assert entry is not None
        self.assertEqual(entry["revision"], "r2")

class NotesAdapterTests(TreeTest):
    def setUp(self) -> None:
        super().setUp()
        self.adapter = NotesAdapter(self.root)
        self.target = "notes::index.md"

    def apply(self, capability: str, **values: object) -> dict:
        from data_plane.confirmation import NormalizedOperation

        target = str(values.pop("target", self.target))
        operation = NormalizedOperation(
            intent_id="intent-1",
            source_id=SOURCE_ID,
            capability=capability,
            targets=(target,),
            base_revision=values.get("base_revision"),  # type: ignore[arg-type]
            field_diff=tuple(
                FieldChange(field=name, before=None, after=value)
                for name, value in values.items()
                if name != "base_revision"
            ),
            affected_count=1,
            epoch=1,
        )
        return self.adapter.apply(operation, "key-1")

    def test_create_then_read_round_trips(self) -> None:
        self.apply("create", body="# Title\n\nbody text\n")
        record = self.adapter.read(self.target)
        self.assertEqual(record["note_id"], self.target)
        self.assertEqual(record["path"], "index.md")
        self.assertEqual(record["heading"], "Title")
        self.assertEqual(record["tags"], [])
        self.assertEqual(record["revision"], digest((self.root / "index.md").read_bytes()))
        self.assertEqual(record["body"], "# Title\n\nbody text\n")

    def test_create_refuses_an_existing_note_with_other_content(self) -> None:
        self.write("index.md", "already here")
        with self.assertRaises(ValidationError):
            self.apply("create", body="different")

    def test_create_is_harmless_when_the_same_bytes_already_landed(self) -> None:
        self.write("index.md", "same")
        self.apply("create", body="same")
        self.assertEqual(self.adapter.revision(self.target), digest(b"same"))

    def test_update_requires_the_base_revision(self) -> None:
        self.apply("create", body="first")
        base = self.adapter.revision(self.target)
        self.apply("update", body="second", base_revision=base)
        self.assertEqual((self.root / "index.md").read_text(), "second")
        with self.assertRaises(StaleError):
            self.apply("update", body="third", base_revision=base)

    def test_update_of_an_absent_note_is_stale(self) -> None:
        with self.assertRaises(StaleError):
            self.apply("update", body="x", base_revision=None)

    def test_delete_leaves_a_tombstone_that_read_reports(self) -> None:
        self.apply("create", body="bye")
        revision = self.adapter.revision(self.target)
        self.apply("delete", base_revision=revision)
        self.assertFalse((self.root / "index.md").exists())
        record = self.adapter.read(self.target)
        self.assertTrue(record["tombstone"])
        self.assertEqual(record["revision"], revision)
        entry = TombstoneLog(self.root, source_id=SOURCE_ID).lookup(self.target)
        assert entry is not None
        self.assertEqual(entry["deleted_at"], record["deleted_at"])
        self.assertEqual(len(entry["pre_image_sha256"]), 64)

    def test_a_second_delete_is_a_no_op(self) -> None:
        self.apply("create", body="bye")
        self.apply("delete", base_revision=self.adapter.revision(self.target))
        self.apply("delete", base_revision=None)
        self.assertTrue(self.adapter.read(self.target)["tombstone"])

    def test_delete_of_a_never_existent_target_is_a_no_op(self) -> None:
        self.apply("delete", base_revision=None)
        self.assertEqual(self.adapter.read(self.target), {})

    def test_a_control_character_in_the_body_is_refused(self) -> None:
        with self.assertRaises(ValidationError):
            self.apply("create", body="a\x00b")

    def test_a_body_over_the_cap_is_refused(self) -> None:
        with self.assertRaises(ValidationError):
            self.apply("create", body="x" * (MAX_FIELD_BYTES + 1))

    def test_a_target_outside_the_prefix_is_refused(self) -> None:
        with self.assertRaises(ValidationError):
            self.adapter.read("index.md")

    def test_a_traversal_target_is_refused(self) -> None:
        with self.assertRaises(ValidationError):
            self.adapter.read("notes::%2E%2E%2Fsecret.md")


    def test_an_update_keeps_the_mode_of_the_file(self) -> None:
        self.write("index.md", "first")
        os.chmod(self.root / "index.md", 0o664)
        self.apply("update", body="second", base_revision=digest(b"first"))
        self.assertEqual(
            stat.S_IMODE((self.root / "index.md").stat().st_mode), 0o664
        )

    def test_a_long_but_legal_name_can_be_updated(self) -> None:
        name = "n" * 240 + ".md"
        self.write(name, "first")
        target = f"notes::{name}"
        self.apply("update", body="second", base_revision=digest(b"first"), target=target)
        self.assertEqual((self.root / name).read_text(), "second")

    def test_a_delete_refuses_a_version_that_arrived_after_the_read(self) -> None:
        self.apply("create", body="v1")
        revision = self.adapter.revision(self.target)
        path = self.root / "index.md"
        declare = self.adapter._tombstones.declare

        def arrive(**values: object) -> dict:
            path.write_text("v2 worth keeping", encoding="utf-8")
            return declare(**values)  # type: ignore[arg-type]

        self.adapter._tombstones.declare = arrive  # type: ignore[method-assign]
        with self.assertRaises(StaleError):
            self.apply("delete", base_revision=revision)
        self.assertEqual(path.read_text(), "v2 worth keeping")

    def test_a_note_named_like_the_control_directory_is_ordinary(self) -> None:
        self.write(".data-plane.md", "not the ledger")
        record = self.adapter.read("notes::.data-plane.md")
        self.assertEqual(record["body"], "not the ledger")
        self.assertEqual(
            [hit["path"] for hit in self.adapter.search("ledger")], [".data-plane.md"]
        )

    def test_search_finds_body_and_heading_and_skips_the_ledger(self) -> None:
        self.apply("create", body="# Espresso\n\nwater and beans\n")
        self.write("sub/other.md", "nothing here")
        TombstoneLog(self.root, source_id=SOURCE_ID).declare(
            target="notes::gone.md",
            revision="r",
            pre_image_sha256="0" * 64,
            deleted_at="2026-01-01T00:00:00+00:00",
        )
        found = self.adapter.search("espresso")
        self.assertEqual([record["note_id"] for record in found], [self.target])
        self.assertEqual(self.adapter.search("nothing")[0]["path"], "sub/other.md")


class BrokerFileEffectTests(TreeTest):
    def setUp(self) -> None:
        super().setUp()
        self.contract = notes_contract()
        self.sources = {SOURCE_ID: self.contract}
        self.adapter = NotesAdapter(self.root)
        self.issuer = IdentityIssuer(self.sources, KEY, clock=lambda: NOW)
        self.gate = ConfirmationGate(ttl_seconds=60, clock=lambda: NOW)
        self.journal_path = self.root / ".journal.db"
        self.store = IntentStore(self.journal_path, clock=lambda: NOW)
        self.events: list[dict] = []
        self.broker = Broker(
            self.sources,
            {SOURCE_ID: self.adapter},
            self.issuer,
            self.gate,
            BrokerJournal(self.store),
            _Recorder(self.events),
            clock=lambda: NOW,
        )
        self.write("index.md", "# First\n")

    def tearDown(self) -> None:
        self.store.close()
        super().tearDown()

    def claims(self, *capabilities: str):
        return self.issuer.verify(
            self.issuer.issue(
                LOCAL_PROFILE,
                "agent",
                tuple((SOURCE_ID, capability) for capability in capabilities),
            )
        )

    def update(self, **overrides) -> WriteRequest:
        values = dict(
            source_id=SOURCE_ID,
            capability="update",
            targets=("notes::index.md",),
            idempotency_key="key-1",
            field_diff=(FieldChange(field="body", before="# First\n", after="# Second\n"),),
            base_revision=digest(b"# First\n"),
            run_id="run-1",
        )
        values.update(overrides)
        return WriteRequest(**values)

    def test_a_routine_update_applies_and_read_back_proves_it(self) -> None:
        claims = self.claims("update")
        write = self.update()
        self.broker.propose(claims, write)
        effect = self.broker.apply(claims, write)
        self.assertEqual(effect["results"][0]["target"], "notes::index.md")
        self.assertEqual((self.root / "index.md").read_text(), "# Second\n")
        self.assertEqual(self.events[0]["capability"], "update")

    def test_a_stale_base_revision_is_refused_and_changes_nothing(self) -> None:
        claims = self.claims("update")
        write = self.update()
        self.broker.propose(claims, write)
        self.write("index.md", "# Edited by hand\n")
        with self.assertRaises(StaleError):
            self.broker.apply(claims, write)
        self.assertEqual((self.root / "index.md").read_text(), "# Edited by hand\n")

    def test_a_delete_parks_for_confirmation_then_applies(self) -> None:
        claims = self.claims("delete")
        write = self.update(
            capability="delete",
            idempotency_key="key-del",
            field_diff=(),
            base_revision=digest(b"# First\n"),
        )
        intent, operation = self.broker.propose(claims, write)
        self.assertEqual(intent.state, IntentState.AWAITING_CONFIRMATION)
        with self.assertRaises(ConfirmationRequired):
            self.broker.apply(claims, write)
        self.assertTrue((self.root / "index.md").exists())

        _, token = self.gate.issue(operation, "smores")
        self.broker.confirm(claims, write, token)
        self.broker.apply(claims, write)
        self.assertFalse((self.root / "index.md").exists())
        self.assertTrue(self.adapter.read("notes::index.md")["tombstone"])

    def test_a_rejected_intent_leaves_the_note_intact(self) -> None:
        claims = self.claims("delete")
        write = self.update(
            capability="delete",
            idempotency_key="key-reject",
            field_diff=(),
            base_revision=digest(b"# First\n"),
        )
        intent, _ = self.broker.propose(claims, write)
        self.store.transition(intent.intent_id, IntentState.REJECTED, error="no")
        with self.assertRaises(ConfirmationError):
            self.broker.apply(claims, write)
        self.assertEqual((self.root / "index.md").read_text(), "# First\n")

    def test_replaying_an_applied_intent_writes_nothing(self) -> None:
        claims = self.claims("update")
        write = self.update()
        self.broker.propose(claims, write)
        first = self.broker.apply(claims, write)
        before = (self.root / "index.md").stat().st_mtime_ns
        self.write("index.md", "# Second\n")
        os.utime(self.root / "index.md", ns=(before, before))
        second = self.broker.apply(claims, write)
        self.assertEqual(first, second)
        self.assertEqual((self.root / "index.md").stat().st_mtime_ns, before)
        self.assertEqual(len(self.events), 1)

    def test_a_field_over_the_cap_is_refused_at_propose(self) -> None:
        claims = self.claims("update")
        write = self.update(
            field_diff=(
                FieldChange(field="body", before=None, after="x" * (MAX_FIELD_BYTES + 1)),
            )
        )
        with self.assertRaises(ValidationError):
            self.broker.propose(claims, write)


class TasksAdapterTests(TreeTest):
    def setUp(self) -> None:
        super().setUp()
        self.adapter = TasksAdapter(self.root)
        self.line = "buy milk +groceries @home"
        self.target = f"tasks::{digest(self.line.encode())[:16]}"

    def apply(self, capability: str, **values: object) -> dict:
        from data_plane.confirmation import NormalizedOperation

        target = str(values.pop("target", self.target))
        operation = NormalizedOperation(
            intent_id="intent-1",
            source_id="tasks.todo",
            capability=capability,
            targets=(target,),
            base_revision=values.get("base_revision"),  # type: ignore[arg-type]
            field_diff=tuple(
                FieldChange(field=name, before=None, after=value)
                for name, value in values.items()
                if name != "base_revision"
            ),
            affected_count=1,
            epoch=1,
        )
        return self.adapter.apply(operation, "key-1")

    def test_read_reports_the_line_and_its_parsed_fields(self) -> None:
        self.write("todo.txt", self.line + "\n")
        record = self.adapter.read(self.target)
        self.assertEqual(record["text"], self.line)
        self.assertEqual(record["file"], "todo.txt")
        self.assertEqual(record["projects"], ["groceries"])
        self.assertEqual(record["contexts"], ["home"])
        self.assertFalse(record["done"])
        self.assertEqual(record["revision"], digest(self.line.encode()))
        self.assertEqual(self.adapter.revision(self.target), digest(self.line.encode()))

    def test_create_appends_to_todo_and_creates_it_when_missing(self) -> None:
        self.apply("create", text=self.line)
        self.assertEqual((self.root / "todo.txt").read_text(), self.line + "\n")
        self.assertEqual(self.adapter.read(self.target)["text"], self.line)

    def test_create_keeps_the_existing_lines_and_their_blank_lines(self) -> None:
        self.write("todo.txt", "first\n\nsecond")
        self.apply("create", text=self.line)
        self.assertEqual(
            (self.root / "todo.txt").read_text(),
            "first\n\nsecond\n" + self.line + "\n",
        )

    def test_create_of_a_line_that_already_exists_is_refused(self) -> None:
        self.write("done.txt", self.line + "\n")
        with self.assertRaises(ValidationError):
            self.apply("create", text=self.line)

    def test_delete_removes_every_occurrence_in_both_files(self) -> None:
        self.write("todo.txt", self.line + "\nkeep me\n" + self.line + "\n")
        self.write("done.txt", self.line + "\n")
        effect = self.apply("delete", base_revision=digest(self.line.encode()))
        self.assertEqual(effect["results"][0]["removed"], 3)
        self.assertEqual((self.root / "todo.txt").read_text(), "keep me\n")
        self.assertEqual((self.root / "done.txt").read_text(), "")
        self.assertTrue(self.adapter.read(self.target)["tombstone"])

    def test_a_second_delete_is_a_no_op(self) -> None:
        self.apply("create", text=self.line)
        self.apply("delete", base_revision=digest(self.line.encode()))
        self.apply("delete", base_revision=None)
        self.assertTrue(self.adapter.read(self.target)["tombstone"])

    def test_delete_of_an_absent_task_is_a_no_op(self) -> None:
        self.apply("delete", base_revision=None)
        self.assertEqual(self.adapter.read(self.target), {})

    def test_update_is_not_a_capability_of_a_line_identified_task(self) -> None:
        self.apply("create", text=self.line)
        with self.assertRaises(ValidationError):
            self.apply("update", text="buy oat milk")

    def test_a_unicode_line_separator_is_refused(self) -> None:
        with self.assertRaises(ValidationError):
            self.apply("create", text="milk\u2028eggs")

    def test_a_multi_line_text_is_refused(self) -> None:
        with self.assertRaises(ValidationError):
            self.apply("create", text="first\nsecond")

    def test_a_target_that_is_not_a_digest_is_refused(self) -> None:
        for target in ("tasks::zz", "tasks::" + "0" * 15, "done::" + "0" * 16):
            with self.subTest(target=target), self.assertRaises(ValidationError):
                self.adapter.read(target)


    def test_a_line_terminated_by_a_form_feed_is_still_removed(self) -> None:
        (self.root / "todo.txt").write_bytes(b"foo\x0b\nkeep\n")
        target = f"tasks::{digest(b'foo')[:16]}"
        effect = self.apply("delete", base_revision=digest(b"foo"), target=target)
        self.assertEqual(effect["results"][0]["removed"], 1)
        self.assertNotIn(b"foo", (self.root / "todo.txt").read_bytes())
        self.assertIn(b"keep", (self.root / "todo.txt").read_bytes())

    def test_a_failed_second_write_restores_the_first_file(self) -> None:
        self.write("todo.txt", self.line + "\n")
        self.write("done.txt", self.line + "\n")
        root = self.adapter._root
        real = root.write
        failures = {"done.txt": 1}

        def flaky(name, data, *, base_revision, must_exist=False):
            if failures.get(name):
                failures[name] = 0
                raise StaleError("simulated loss between the two writes")
            return real(name, data, base_revision=base_revision, must_exist=must_exist)

        root.write = flaky  # type: ignore[method-assign]
        with self.assertRaises(StaleError):
            self.apply("delete", base_revision=digest(self.line.encode()))
        self.assertEqual((self.root / "todo.txt").read_text(), self.line + "\n")
        self.assertEqual((self.root / "done.txt").read_text(), self.line + "\n")

    def test_search_finds_and_dedupes_across_both_files(self) -> None:
        self.write("todo.txt", self.line + "\n")
        self.write("done.txt", self.line + "\nx  old thing\n")
        found = self.adapter.search("milk")
        self.assertEqual([record["task_id"] for record in found], [self.target])
        self.assertEqual(len(self.adapter.search("thing")), 1)


class BrokerTasksEffectTests(TreeTest):
    """The tasks adapter through the real broker, not just at its own seam."""

    def setUp(self) -> None:
        super().setUp()
        self.journal = tempfile.TemporaryDirectory()
        self.contract = tasks_contract()
        self.sources = {"tasks.todo": self.contract}
        self.adapter = TasksAdapter(self.root)
        self.issuer = IdentityIssuer(self.sources, KEY, clock=lambda: NOW)
        self.gate = ConfirmationGate(ttl_seconds=60, clock=lambda: NOW)
        self.store = IntentStore(Path(self.journal.name) / "intents.db", clock=lambda: NOW)
        self.broker = Broker(
            self.sources,
            {"tasks.todo": self.adapter},
            self.issuer,
            self.gate,
            BrokerJournal(self.store),
            _Recorder([]),
            clock=lambda: NOW,
        )
        self.line = "buy milk"
        self.target = f"tasks::{digest(self.line.encode())[:16]}"

    def tearDown(self) -> None:
        self.store.close()
        self.journal.cleanup()
        super().tearDown()

    def claims(self, capability: str):
        return self.issuer.verify(
            self.issuer.issue(LOCAL_PROFILE, "agent", (("tasks.todo", capability),))
        )

    def test_a_routine_create_appends_and_read_back_proves_it(self) -> None:
        claims = self.claims("create")
        write = WriteRequest(
            source_id="tasks.todo",
            capability="create",
            targets=(self.target,),
            idempotency_key="task-create-1",
            field_diff=(FieldChange(field="text", before=None, after=self.line),),
            base_revision=None,
            run_id="run-1",
        )
        self.broker.propose(claims, write)
        self.broker.apply(claims, write)
        self.assertEqual((self.root / "todo.txt").read_text(), self.line + "\n")

    def test_a_delete_parks_for_confirmation_then_leaves_a_tombstone(self) -> None:
        (self.root / "todo.txt").write_text(self.line + "\n", encoding="utf-8")
        claims = self.claims("delete")
        write = WriteRequest(
            source_id="tasks.todo",
            capability="delete",
            targets=(self.target,),
            idempotency_key="task-delete-1",
            field_diff=(),
            base_revision=digest(self.line.encode()),
            run_id="run-2",
        )
        intent, operation = self.broker.propose(claims, write)
        self.assertEqual(intent.state, IntentState.AWAITING_CONFIRMATION)
        with self.assertRaises(ConfirmationRequired):
            self.broker.apply(claims, write)
        _, token = self.gate.issue(operation, "smores")
        self.broker.confirm(claims, write, token)
        self.broker.apply(claims, write)
        self.assertEqual((self.root / "todo.txt").read_text(), "")
        self.assertTrue(self.adapter.read(self.target)["tombstone"])


class _Recorder:
    def __init__(self, events: list[dict]) -> None:
        self.events = events

    def record(self, event: dict) -> None:
        if any(item.get("intent_id") == event.get("intent_id") for item in self.events):
            return
        self.events.append(dict(event))


if __name__ == "__main__":
    unittest.main()
