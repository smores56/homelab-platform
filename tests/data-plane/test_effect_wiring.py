"""The catalog and ``run.py`` select the real effect owner only when told to.

The point of these tests is the failure that must not happen: a broker that
answers a write from a fixture while the file it claims to change is untouched.
A configured root therefore either builds the real adapter or stops the process.
"""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
for candidate in (str(ROOT), str(ROOT / "libs")):
    if candidate not in sys.path:
        sys.path.insert(0, candidate)

from data_plane.effects import NotesAdapter, TasksAdapter
from data_plane.errors import ValidationError

from apps.data_plane import run

CATALOG = ROOT / "deploy" / "data-plane" / "config" / "source-catalog.json"


class CatalogTests(unittest.TestCase):
    def setUp(self) -> None:
        self.sources = run._load_catalog(str(CATALOG))

    def test_the_shipped_catalog_declares_the_notes_owner(self) -> None:
        notes = self.sources["notes.markdown"]
        self.assertEqual(notes.revision_field, "revision")
        self.assertEqual(notes.tombstone_field, "tombstone")
        self.assertTrue(notes.capability("delete").requires_confirmation)
        self.assertTrue(notes.capability("update").reversible)
        # Only the body is writable, so a request that changes any other field is
        # refused at propose instead of reaching the adapter and being recorded
        # as an effect of unknown outcome.
        self.assertEqual([item.field for item in notes.authority], ["body"])

    def test_the_shipped_catalog_declares_the_tasks_owner(self) -> None:
        tasks = self.sources["tasks.todo"]
        self.assertEqual(tasks.capability("create").effect.value, "create")
        self.assertTrue(tasks.capability("delete").requires_confirmation)
        self.assertNotIn("update", [item.name for item in tasks.capabilities])


class AdapterSelectionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.sources = run._load_catalog(str(CATALOG))

    def tearDown(self) -> None:
        self.directory.cleanup()

    def test_a_writable_source_without_a_root_is_refused(self) -> None:
        # The shipped catalog makes notes and tasks writable, so a fixture
        # answering them is the failure this seam exists to remove.
        with self.assertRaises(run.ConfigError):
            run.build_adapters(self.sources)

    def test_a_half_configured_pair_is_refused(self) -> None:
        with self.assertRaises(run.ConfigError):
            run.build_adapters(self.sources, notes_root=str(self.root))

    def test_both_roots_select_the_real_owners_and_leave_the_rest_alone(self) -> None:
        adapters = run.build_adapters(
            self.sources, notes_root=str(self.root), tasks_root=str(self.root)
        )
        self.assertIsInstance(adapters["notes.markdown"], NotesAdapter)
        self.assertIsInstance(adapters["tasks.todo"], TasksAdapter)
        self.assertIsInstance(adapters["brave.history"], run.FixtureAdapter)

    def test_a_read_only_catalog_still_answers_from_fixtures(self) -> None:
        sources = {
            source_id: contract
            for source_id, contract in self.sources.items()
            if not contract.writable
        }
        adapters = run.build_adapters(sources)
        self.assertTrue(
            all(isinstance(adapter, run.FixtureAdapter) for adapter in adapters.values())
        )

    def test_a_root_the_catalog_does_not_declare_is_refused(self) -> None:
        sources = {"books.opds": self.sources["books.opds"]}
        with self.assertRaises(run.ConfigError):
            run.build_adapters(sources, notes_root=str(self.root))

    def test_an_unusable_root_fails_at_startup(self) -> None:
        with self.assertRaises(ValidationError):
            run.build_adapters(self.sources, notes_root=str(self.root / "nowhere"))


if __name__ == "__main__":
    unittest.main()
