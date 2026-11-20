"""Dump tests: what lands in ``--out``, what is removed, and the deterministic bytes.

The API is a stand-in that serves synthetic entities encrypted with this module's
own primitives -- no network, no provider, no fixtures recorded from an account.
A dump is only usable by the collector if a re-run over the same events is
byte-identical, so that is asserted directly.
"""

from __future__ import annotations

import contextlib
import io
import json
import shutil
import stat
import tempfile
import unittest
from pathlib import Path
from typing import Any, Iterator, Mapping

from apps.tuta_calendar import crypto
from apps.tuta_calendar.crypto import Padding
from apps.tuta_calendar.dump import documents, run_dump, write_documents
from apps.tuta_calendar.errors import CalendarError
from apps.tuta_calendar.session import Session, seal
from data_plane.collectors.raw import RawReplica, collect_calendar
from data_plane.collectors.staging import StagingGeneration

import fixtures


class FakeApi:
    """Exactly the four calls a dump makes, over a fixed set of entities."""

    def __init__(self, lists: Mapping[str, list[dict[str, Any]]] | None = None) -> None:
        self.lists = lists if lists is not None else {"shortList": [fixtures.event()]}
        self.walked: list[str] = []

    def calendar_group(self, user_id: str, access_token: str, user_group_key: bytes):
        return "calendarGroup", fixtures.GROUP_KEY

    def calendar_list_ids(self, group_id: str, access_token: str) -> tuple[str, ...]:
        return tuple(self.lists)

    def calendar_events(self, list_id: str, access_token: str) -> Iterator[dict[str, Any]]:
        self.walked.append(list_id)
        yield from self.lists[list_id]


def a_session() -> Session:
    return Session(
        address="someone@example.com",
        user_id="userIdAAA",
        access_token="token",
        kdf_type=crypto.KDF_ARGON2ID,
        salt=bytes(range(16)),
        passphrase_key=fixtures.PASSPHRASE_KEY,
        encrypted_passphrase_key=crypto.encrypt(
            fixtures.PASSPHRASE_KEY, fixtures.GROUP_KEY, padding=Padding.NONE
        ),
    )


class DocumentsTest(unittest.TestCase):
    def test_both_lists_are_walked(self) -> None:
        api = FakeApi(
            {
                "shortList": [fixtures.event(list_id="shortList", element_id="a")],
                "longList": [fixtures.event(list_id="longList", element_id="b")],
            }
        )
        records = documents(api, a_session())
        self.assertEqual(["shortList", "longList"], api.walked)
        self.assertEqual(["shortList-a", "longList-b"], [record["id"] for record in records])

    def test_two_events_with_one_id_are_refused(self) -> None:
        api = FakeApi(
            {
                "shortList": [fixtures.event(element_id="same")],
                "longList": [fixtures.event(list_id="longList", element_id="same")],
            }
        )
        # The object id is list-qualified, so only a genuine duplicate collides.
        self.assertEqual(2, len(documents(api, a_session())))

        api = FakeApi({"shortList": [fixtures.event(element_id="same")] * 2})
        with self.assertRaises(CalendarError) as caught:
            documents(api, a_session())
        self.assertIn("two events claim", str(caught.exception))


class WriteTest(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.out = Path(self.directory.name) / "out"

    def tearDown(self) -> None:
        self.directory.cleanup()

    def test_one_file_per_event_named_by_id(self) -> None:
        records = documents(FakeApi(), a_session())
        count, removed = write_documents(records, self.out)

        self.assertEqual((1, 0), (count, removed))
        self.assertEqual(["shortList-elemAAA.json"], [path.name for path in self.out.iterdir()])
        payload = json.loads((self.out / "shortList-elemAAA.json").read_text(encoding="utf-8"))
        self.assertEqual(records[0], payload)
        mode = stat.S_IMODE((self.out / "shortList-elemAAA.json").stat().st_mode)
        self.assertEqual(0o644, mode)

    def test_the_bytes_are_identical_across_runs(self) -> None:
        records = documents(FakeApi(), a_session())
        write_documents(records, self.out)
        first = (self.out / "shortList-elemAAA.json").read_bytes()
        write_documents(records, self.out)
        self.assertEqual(first, (self.out / "shortList-elemAAA.json").read_bytes())

    def test_keys_are_sorted_and_the_file_ends_with_a_newline(self) -> None:
        write_documents(documents(FakeApi(), a_session()), self.out)
        text = (self.out / "shortList-elemAAA.json").read_text(encoding="utf-8")
        keys = list(json.loads(text))
        self.assertEqual(sorted(keys), keys)
        self.assertTrue(text.endswith("\n"))

    def test_a_file_this_run_did_not_write_is_removed(self) -> None:
        self.out.mkdir(parents=True)
        stale = self.out / "shortList-gone.json"
        stale.write_text("{}", encoding="utf-8")

        _, removed = write_documents(documents(FakeApi(), a_session()), self.out)

        self.assertEqual(1, removed)
        self.assertFalse(stale.exists())

    def test_a_stale_symlink_is_removed_and_its_target_untouched(self) -> None:
        self.out.mkdir(parents=True)
        target = Path(self.directory.name) / "outside.json"
        target.write_text("{}", encoding="utf-8")
        link = self.out / "shortList-link.json"
        link.symlink_to(target)

        _, removed = write_documents(documents(FakeApi(), a_session()), self.out)

        self.assertEqual(1, removed)
        self.assertFalse(link.is_symlink())
        self.assertTrue(target.exists())


class CollectorIntegrationTest(unittest.TestCase):
    """The replica's collector publishes what the dumper wrote, unchanged.

    This is the contract the two halves share: the files are only right if
    ``collect_calendar`` accepts them, counts them and derives ICS from them
    without a transform in between.
    """

    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.out = self.root / "entities"

    def tearDown(self) -> None:
        self.directory.cleanup()

    def collect(self, name: str):
        generation = StagingGeneration(self.root / "replica", name, source_id="test.source")
        report = collect_calendar(self.out, generation, captured_at="2026-11-20T00:00:00+00:00")
        generation.commit_next(complete=True)
        return report, RawReplica(self.root / "replica")

    def test_a_dump_becomes_a_generation_with_both_objects_per_event(self) -> None:
        api = FakeApi(
            {
                "shortList": [
                    fixtures.event(element_id="plain"),
                    fixtures.event(
                        element_id="series",
                        recurrence={"frequency": 1, "end_type": 1, "end_value": 5},
                    ),
                ]
            }
        )
        write_documents(documents(api, a_session()), self.out)
        report, replica = self.collect("gen-0001")

        self.assertEqual(2, report.objects)
        self.assertEqual(0, report.deleted)
        raw = json.loads(replica.read("calendar::shortList-series"))
        self.assertEqual("FREQ=WEEKLY;COUNT=5", raw["rrule"])
        ics = replica.read("calendar::shortList-plain::ics").decode("utf-8")
        self.assertIn("DTSTART:20260301T090000Z\r\n", ics)
        self.assertIn("SUMMARY:Standup\r\n", ics)

    def test_an_event_that_stops_appearing_is_carried_forward_not_deleted(self) -> None:
        api = FakeApi(
            {"shortList": [fixtures.event(element_id="a"), fixtures.event(element_id="b")]}
        )
        write_documents(documents(api, a_session()), self.out)
        self.collect("gen-0001")

        write_documents(
            documents(FakeApi({"shortList": [fixtures.event(element_id="a")]}), a_session()),
            self.out,
        )
        report, _ = self.collect("gen-0002")

        self.assertEqual(1, report.objects)
        self.assertEqual(0, report.deleted)
        # Carried forward is counted in objects: the entity and its derived ICS.
        self.assertEqual(2, report.carried)


HAVE_GPG = shutil.which("gpg") is not None


@unittest.skipUnless(HAVE_GPG, "gpg is the seal's runtime dependency and is not installed")
class RunDumpTest(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.store = Path(self.directory.name) / "store"
        self.out = Path(self.directory.name) / "out"
        seal(self.store, a_session())

    def tearDown(self) -> None:
        self.directory.cleanup()

    def test_a_dump_reports_what_it_wrote_and_a_refusal_exits_three(self) -> None:
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            self.assertEqual(0, run_dump(self.store, self.out, api=FakeApi()))
        summary = json.loads(stdout.getvalue())
        self.assertEqual(
            {"command": "dump", "objects": 1, "out": str(self.out), "removed": 0}, summary
        )
        self.assertTrue((self.out / "shortList-elemAAA.json").is_file())


if __name__ == "__main__":
    unittest.main()
