"""Memory is per profile, and the full-text index is derived and disposable.

The assertions that matter: a write round-trips through ``FileMemory`` with
provenance and a revision that advances; the index can be deleted and rebuilt to
the same results; and a record that the index still lists but the disk no longer
holds is never returned.
"""

from __future__ import annotations

import hashlib
import sqlite3
import unittest
from datetime import datetime

from data_plane.errors import ContractError
from data_plane.memory import FileMemory, MemoryRecord
from data_plane.model import Visibility

from apps.agent_facade import memory
from apps.agent_facade.tests import support


class MemoryRoundTripTestCase(support.FacadeCase):
    def test_write_then_read_round_trips(self) -> None:
        written = self.write("preference-tea", "green tea in the morning")
        self.assertEqual(written["key"], "preference-tea")
        self.assertEqual(
            written["digest"], hashlib.sha256(b"green tea in the morning").hexdigest()
        )

        read = self.call("memory.read", {"key": "preference-tea"})
        self.assertEqual(read["key"], "preference-tea")
        self.assertEqual(read["value"], "green tea in the morning")
        self.assertEqual(read["tags"], ["preference"])
        self.assertEqual(dict(read["provenance"]), self.provenance)
        self.assertEqual(read["revision"], written["revision"])
        self.assertEqual(read["digest"], written["digest"])

    def test_the_record_on_disk_is_a_file_memory_record(self) -> None:
        self.write("preference-tea", "green tea")
        record = FileMemory(self.root, "local").get("preference-tea")
        self.assertIsInstance(record, MemoryRecord)
        assert record is not None
        self.assertEqual(record.content, "green tea")
        self.assertEqual(record.provenance, self.provenance)
        self.assertEqual(record.source, memory.MEMORY_SOURCE)

    def test_unknown_key_is_refused(self) -> None:
        error = self.refusal("memory.read", {"key": "no-such-key"})
        self.assertEqual(error["code"], "not_found")

    def test_write_requires_provenance_through_the_tool(self) -> None:
        error = self.refusal("memory.write", {"key": "note", "value": "v"})
        self.assertEqual(error["code"], "validation")

    def test_value_over_the_cap_is_refused_without_a_write(self) -> None:
        error = self.refusal(
            "memory.write",
            {
                "key": "huge",
                "value": "a" * (support.MAX_BYTES + 1),
                "provenance": self.provenance,
            },
        )
        self.assertEqual(error["code"], "validation")
        self.assertFalse((self.root / "local" / "huge.json").exists())


class RevisionTestCase(support.FacadeCase):
    def test_second_write_supersedes_and_advances_the_revision(self) -> None:
        first = self.write("preference-tea", "green tea")
        second = self.call(
            "memory.write",
            {"key": "preference-tea", "value": "green tea and toast", "provenance": self.provenance},
        )
        self.assertGreater(second["revision"], first["revision"])
        self.assertEqual(
            self.call("memory.read", {"key": "preference-tea"})["value"],
            "green tea and toast",
        )
        stored = FileMemory(self.root, "local").get("preference-tea")
        assert stored is not None
        self.assertEqual(stored.content, "green tea and toast")

        # The library's own supersedes rule agrees that the revision advanced:
        # an older revision imported over the newer one is not applied.
        replica = FileMemory(self.root / "replica", "local")
        older = MemoryRecord(
            id=stored.id,
            profile=stored.profile,
            source=stored.source,
            content="green tea",
            provenance=stored.provenance,
            created_at=stored.created_at,
            updated_at=first["revision"],
        )
        self.assertEqual(replica.import_records([stored.as_dict()]), (stored,))
        self.assertEqual(replica.import_records([older.as_dict()]), ())
        self.assertEqual(replica.get("preference-tea"), stored)

    def test_revision_advances_at_least_one_second(self) -> None:
        current = "2026-11-19T12:00:00+00:00"
        following = memory.next_revision(current)
        self.assertGreater(following, current)
        gap = datetime.fromisoformat(following) - datetime.fromisoformat(current)
        self.assertGreaterEqual(gap.total_seconds(), 1)
        # A revision already ahead of the clock moves forward, not backward.
        future = "2999-01-01T00:00:00+00:00"
        self.assertGreater(memory.next_revision(future), future)

    def test_created_at_survives_a_rewrite(self) -> None:
        self.write("preference-tea", "green tea")
        created = self.store.get("preference-tea").created_at
        self.write("preference-tea", "green tea and toast")
        self.assertEqual(self.store.get("preference-tea").created_at, created)


class IndexTestCase(support.FacadeCase):
    def setUp(self) -> None:
        super().setUp()
        self.write("preference-tea", "green tea in the morning")
        self.write("preference-bike", "replace the rear brake pads")

    def test_search_finds_a_written_record(self) -> None:
        hits = self.call("memory.search", {"query": "brake"})
        self.assertEqual([hit["key"] for hit in hits["hits"]], ["preference-bike"])
        self.assertEqual(set(hits["hits"][0]), {"key", "snippet", "revision"})

    def test_search_is_bounded_by_the_limit(self) -> None:
        hits = self.call("memory.search", {"query": "the", "limit": 1})
        self.assertEqual(len(hits["hits"]), 1)

    def test_index_lives_beside_the_records_in_a_cache_directory(self) -> None:
        self.assertEqual(
            self.store.path, self.root / "local" / memory.INDEX_DIRECTORY / memory.INDEX_NAME
        )
        self.call("memory.search", {"query": "tea"})
        self.assertTrue(self.store.path.is_file())

    def test_deleting_the_index_and_rebuilding_returns_identical_results(self) -> None:
        before = self.store.search("the", 20)
        self.assertTrue(before)
        self.store.path.unlink()
        self.assertFalse(self.store.path.exists())
        after = self.store.search("the", 20)
        self.assertEqual(before, after)
        self.assertTrue(self.store.path.is_file())

    def test_rebuild_is_explicit_and_counts_the_records(self) -> None:
        self.assertEqual(self.call("memory.rebuild")["indexed"], 2)
        self.store.path.unlink()
        self.assertEqual(self.store.rebuild(), 2)

    def test_a_record_deleted_from_disk_disappears_from_search(self) -> None:
        (self.root / "local" / "preference-bike.json").unlink()
        self.assertEqual(self.store.search("brake", 20), ())

    def test_a_record_deleted_from_disk_disappears_after_rebuild(self) -> None:
        record_path = self.root / "local" / "preference-bike.json"
        self.assertEqual([hit.key for hit in self.store.search("brake", 20)], ["preference-bike"])
        record_path.unlink()
        self.assertEqual(self.store.rebuild(), 1)
        self.assertEqual(self.store.search("brake", 20), ())

    def test_the_index_is_not_authoritative(self) -> None:
        # A row the index lists but the record files do not hold: the search
        # reads the record back from disk, so the ghost is never returned.
        self.store.search("tea", 20)
        connection = sqlite3.connect(self.store.path)
        try:
            connection.execute(
                "INSERT INTO records (key, body, tags, revision, digest) "
                "VALUES ('ghost-key', 'green tea ghost', '', '2026-11-01', 'x')"
            )
            connection.commit()
        finally:
            connection.close()
        self.assertEqual(self.store.search("ghost", 20), ())

    def test_a_tombstoned_record_disappears(self) -> None:
        FileMemory(self.root, "local").delete("preference-tea")
        self.assertEqual(self.store.search("tea", 20), ())
        self.assertEqual(self.refusal("memory.read", {"key": "preference-tea"})["code"], "not_found")

    def test_query_syntax_is_never_parsed_by_the_index(self) -> None:
        for query in ('green OR "brake"', "brake*", "-brake", "NEAR(tea brake)"):
            with self.subTest(query=query):
                hits = self.store.search(query, 20)
                self.assertIsInstance(hits, tuple)

    def test_index_file_is_private_to_the_owner(self) -> None:
        self.call("memory.search", {"query": "tea"})
        self.assertEqual(self.store.path.stat().st_mode & 0o777, 0o600)


class ProfileSplitTestCase(support.FacadeCase):
    def test_the_two_deployments_have_separate_profiles(self) -> None:
        self.assertEqual(memory.PROFILE_BY_DEPLOYMENT[Visibility.PERSONAL], "local")
        self.assertEqual(memory.PROFILE_BY_DEPLOYMENT[Visibility.GENERAL], "external")

        self.write("preference-tea", "green tea")
        general = memory.MemoryIndex(self.root, Visibility.GENERAL)
        with self.assertRaises(memory.MemoryNotFound):
            general.get("preference-tea")
        self.assertEqual(general.search("tea", 20), ())

        general.write(
            "preference-tea",
            "hosted summary",
            ("preference",),
            support.PROVENANCE,
        )
        self.assertEqual(self.store.get("preference-tea").content, "green tea")
        self.assertTrue((self.root / "external" / "preference-tea.json").is_file())

    def test_memory_index_refuses_a_non_deployment(self) -> None:
        with self.assertRaises(ContractError):
            memory.MemoryIndex(self.root, Visibility.INFRASTRUCTURE)


if __name__ == "__main__":
    unittest.main()
