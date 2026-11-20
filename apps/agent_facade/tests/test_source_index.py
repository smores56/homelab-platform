"""Derived source index tests: parity with the scan, one file per generation.

Each case publishes real generations and asks an adapter with an index root the
same questions as one without: the index is an optimisation, so the two answers
have to agree, and a generation that publishes something else has to replace the
file rather than append to it.
"""

from __future__ import annotations

import os
import sqlite3
import tempfile
import unittest
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping

from agent_facade import replica_sources, source_index, sources
from data_plane.collectors.raw import collect_maildir
from data_plane.collectors.staging import StagingGeneration

CAPTURED = "2026-11-19T00:00:00+00:00"

#: ``new/<name>`` -> (subject, body): the name is the record id's last component.
Message = tuple[str, str]

MESSAGES: Mapping[str, Message] = {
    "aaa": (
        "Boiler inspection",
        "The boiler inspection is booked for the twelfth.",
    ),
    "bbb": ("Hello world", "A quiet greeting about the boiler."),
    "ccc": ("Unrelated", "Nothing to see here."),
}


def _publish(root: Path, generation_id: str, messages: Mapping[str, Message]) -> Path:
    """Publish one mail generation under ``root`` and return the replica root."""

    maildir = root / f"maildir-{generation_id}"
    for spool in ("cur", "new", "tmp"):
        (maildir / spool).mkdir(parents=True, exist_ok=True)
    for name, (subject, body) in messages.items():
        (maildir / "new" / name).write_bytes(
            (
                "From: someone@example.com\r\n"
                f"Subject: {subject}\r\n"
                f"Message-ID: <{name}@example.com>\r\n"
                "Date: Tue, 18 Nov 2026 10:00:00 +0000\r\n"
                "\r\n"
                f"{body}\r\n"
            ).encode("utf-8")
        )
    generation = StagingGeneration(root / "replica", generation_id, source_id="tuta.mail")
    collect_maildir(maildir, generation, uidvalidity={"INBOX": 7}, captured_at=CAPTURED)
    generation.commit_next(complete=True)
    return root / "replica"


def _adapter(replica: Path, index_root: Path | None):
    return replica_sources.adapters_for(
        sources.Visibility.PERSONAL, {"mail": replica}, index_root
    )["mail"]


def _ids(hits) -> set[str]:
    return {hit.id for hit in hits}


def _file(index_root: Path, generation_id: str) -> Path:
    return index_root / "mail" / f"{generation_id}.sqlite"


@dataclass(frozen=True)
class _View:
    """The two fields ``SourceIndex.build`` reads; a ``SourceRecord`` has them too."""

    title: str
    body: str


class ParityTests(unittest.TestCase):
    def test_index_and_scan_answer_the_same_queries(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            replica = _publish(root, "gen-0001", MESSAGES)
            indexed = _adapter(replica, root / "index")
            scanned = _adapter(replica, None)

            for query in ("boiler", "boiler twelfth", "INSPECTION", "hello world",
                          "quiet greeting", "kettle"):
                with self.subTest(query=query):
                    from_index = indexed.search(query, 10)
                    from_scan = scanned.search(query, 10)
                    self.assertEqual(_ids(from_index), _ids(from_scan))
                    self.assertEqual(
                        sorted(from_index, key=lambda hit: hit.id),
                        sorted(from_scan, key=lambda hit: hit.id),
                    )

            # A limit the answer exceeds binds both paths to the same size, and
            # whatever the index ranks first is still a hit the scan agrees with.
            limited = indexed.search("boiler", 1)
            self.assertEqual(len(limited), 1)
            self.assertLessEqual(_ids(limited), _ids(scanned.search("boiler", 10)))

    def test_a_short_word_scans_instead(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            replica = _publish(root, "gen-0001", MESSAGES)
            indexed = _adapter(replica, root / "index")

            hits = indexed.search("boiler tw", 10)
            self.assertEqual(_ids(hits), {"mail::INBOX::aaa"})
            self.assertEqual(hits, _adapter(replica, None).search("boiler tw", 10))
            # Nothing was built for a query a trigram could not have answered.
            self.assertFalse((root / "index").exists())

            # The same adapter still indexes the next, longer query: the fallback
            # is per query, not a switch that disables the adapter's index.
            indexed.search("boiler", 10)
            self.assertTrue(_file(root / "index", "gen-0001").is_file())

    def test_the_match_is_substring_shaped(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            replica = _publish(root, "gen-0001", {"aaa": ("Hello world", "Body text.")})
            indexed = _adapter(replica, root / "index")

            self.assertEqual(_ids(indexed.search("orld", 5)), {"mail::INBOX::aaa"})
            self.assertTrue(_file(root / "index", "gen-0001").is_file())


class GenerationTests(unittest.TestCase):
    def test_a_new_generation_is_a_new_file_and_the_old_one_is_gone(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            replica = _publish(root, "gen-0001", {"aaa": MESSAGES["aaa"]})
            _adapter(replica, root / "index").search("boiler", 5)
            self.assertTrue(_file(root / "index", "gen-0001").is_file())

            replica = _publish(root, "gen-0002", {"ddd": ("Fresh subject", "New content.")})
            second = _adapter(replica, root / "index")
            self.assertEqual(second.replica.generation_id, "gen-0002")
            self.assertEqual(_ids(second.search("fresh", 5)), {"mail::INBOX::ddd"})

            self.assertTrue(_file(root / "index", "gen-0002").is_file())
            self.assertFalse(_file(root / "index", "gen-0001").is_file())

    def test_the_index_is_rebuilt_not_appended(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            replica = _publish(root, "gen-0001", MESSAGES)
            self.assertEqual(
                _ids(_adapter(replica, root / "index").search("boiler", 5)),
                {"mail::INBOX::aaa", "mail::INBOX::bbb"},
            )

            replica = _publish(
                root,
                "gen-0002",
                {"bbb": MESSAGES["bbb"], "ddd": ("Boiler replaced", "A new boiler.")},
            )
            second = _adapter(replica, root / "index")
            self.assertEqual(
                _ids(second.search("boiler", 5)),
                {"mail::INBOX::bbb", "mail::INBOX::ddd"},
            )
            self.assertEqual(second.search("nothing", 5), ())


class FallbackTests(unittest.TestCase):
    def test_an_unwritable_index_root_still_answers(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            replica = _publish(root, "gen-0001", MESSAGES)
            index_root = root / "index"
            index_root.mkdir()
            os.chmod(index_root, 0o500)
            try:
                with self.assertNoLogs(level="WARNING"):
                    hits = _adapter(replica, index_root).search("boiler", 5)
                self.assertEqual(_ids(hits), {"mail::INBOX::aaa", "mail::INBOX::bbb"})
                self.assertFalse((index_root / "mail").exists())
            finally:
                os.chmod(index_root, 0o700)


class IndexFileTests(unittest.TestCase):
    def test_a_file_of_another_schema_version_is_rebuilt(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            records = {"r1": _View(title="Hello world", body="Body text.")}
            source_index.SourceIndex(root, "mail", "gen-0001").build(records)
            path = _file(root, "gen-0001")

            connection = sqlite3.connect(path)
            try:
                connection.execute("UPDATE meta SET value = '0' WHERE key = 'schema_version'")
                connection.commit()
            finally:
                connection.close()

            stale = source_index.SourceIndex(root, "mail", "gen-0001")
            try:
                with self.assertRaises(source_index.SourceIndexUnavailable):
                    stale.search(["world"], 10)
            finally:
                stale.close()

            rebuilt = source_index.SourceIndex(root, "mail", "gen-0001")
            try:
                rebuilt.build(records)
                self.assertEqual(rebuilt.search(["world"], 10), ("r1",))
            finally:
                rebuilt.close()

    def test_query_text_is_never_parsed(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            index = source_index.SourceIndex(root, "mail", "gen-0001")
            try:
                index.build({"r1": _View(title="Hello world", body="Body text.")})
                # Words travel as one bound parameter, quoted: FTS5 syntax in a
                # word is a word that matches nothing, never a query.
                self.assertEqual(index.search(["NEAR(", "world"], 10), ())
            finally:
                index.close()


if __name__ == "__main__":
    unittest.main()
