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

from apps.data_plane import run  # noqa: E402
from data_plane.effects import NotesAdapter, TasksAdapter  # noqa: E402
from data_plane.errors import ValidationError  # noqa: E402

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

    def test_without_a_root_every_source_is_a_fixture(self) -> None:
        adapters = run.build_adapters(self.sources)
        self.assertIsInstance(adapters["notes.markdown"], run.FixtureAdapter)
        self.assertIsInstance(adapters["tasks.todo"], run.FixtureAdapter)

    def test_a_notes_root_selects_the_real_owner_and_leaves_the_rest_alone(self) -> None:
        adapters = run.build_adapters(self.sources, notes_root=str(self.root))
        self.assertIsInstance(adapters["notes.markdown"], NotesAdapter)
        self.assertIsInstance(adapters["tasks.todo"], run.FixtureAdapter)

    def test_a_tasks_root_selects_the_real_owner_and_leaves_the_rest_alone(self) -> None:
        adapters = run.build_adapters(self.sources, tasks_root=str(self.root))
        self.assertIsInstance(adapters["tasks.todo"], TasksAdapter)
        self.assertIsInstance(adapters["notes.markdown"], run.FixtureAdapter)

    def test_a_root_the_catalog_does_not_declare_is_refused(self) -> None:
        sources = {"books.opds": self.sources["books.opds"]}
        with self.assertRaises(run.ConfigError):
            run.build_adapters(sources, notes_root=str(self.root))

    def test_an_unusable_root_fails_at_startup(self) -> None:
        with self.assertRaises(ValidationError):
            run.build_adapters(self.sources, notes_root=str(self.root / "nowhere"))


if __name__ == "__main__":
    unittest.main()
