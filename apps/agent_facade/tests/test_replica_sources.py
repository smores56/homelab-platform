"""Replica-backed source tests: projection, provenance and the structural split.

Each case publishes a real generation with the raw collectors and then asks the
adapter the same questions the facade tool surface asks: read one record, search
for words, and describe what the record can cite as provenance.
"""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from agent_facade import replica_sources, sources
from data_plane.collectors.raw import (
    collect_calendar,
    collect_maildir,
    collect_simplefin,
)
from data_plane.collectors.staging import StagingGeneration
from data_plane.errors import ContractError, ValidationError

CAPTURED = "2026-11-19T00:00:00+00:00"


def _mail_generation(
    root: Path,
    generation_id: str = "gen-0001",
    subject: str = "Boiler inspection",
    body: str = "The boiler inspection is booked for the twelfth.",
) -> None:
    maildir = root / "mail"
    for spool in ("cur", "new", "tmp"):
        (maildir / spool).mkdir(parents=True, exist_ok=True)
    (maildir / "new" / "aaa").write_bytes(
        (
            "From: someone@example.com\r\n"
            f"Subject: {subject}\r\n"
            "Message-ID: <aaa@example.com>\r\n"
            "Date: Tue, 18 Nov 2026 10:00:00 +0000\r\n"
            "\r\n"
            f"{body}\r\n"
        ).encode("utf-8")
    )
    generation = StagingGeneration(root / "replica", generation_id, source_id="tuta.mail")
    collect_maildir(
        maildir, generation, uidvalidity={"INBOX": 7}, captured_at=CAPTURED
    )
    generation.commit_next(complete=True)


def _calendar_generation(root: Path) -> None:
    entities = root / "entities"
    entities.mkdir()
    (entities / "e1.json").write_text(
        json.dumps(
            {
                "id": "e1",
                "uid": "uid-1",
                "summary": "Dentist",
                "dtstart": "2026-11-20T09:30:00",
                "rrule": "FREQ=MONTHLY",
                "description": "Check-up",
            }
        ),
        encoding="utf-8",
    )
    generation = StagingGeneration(
        root / "replica-calendar", "gen-0001", source_id="tuta.calendar"
    )
    collect_calendar(entities, generation, captured_at=CAPTURED)
    generation.commit_next(complete=True)


def _finance_generation(root: Path) -> None:
    accountset = {
        "connections": [{"conn_id": "conn-1", "name": "Schwab"}],
        "accounts": [
            {
                "id": "acct-1",
                "name": "Checking",
                "transactions": [
                    {
                        "id": "txn-1",
                        "amount": "-23.40",
                        "description": "Corner shop",
                        "posted": 1763500000,
                    }
                ],
            }
        ],
    }
    generation = StagingGeneration(
        root / "replica-finance", "gen-0001", source_id="finance.ledger"
    )
    collect_simplefin(
        accountset,
        generation,
        accountset_url="https://sfin.example/access",
        captured_at=CAPTURED,
        include_pending=True,
        now=1763500000,
    )
    generation.commit_next(complete=True)


class MailReplicaTests(unittest.TestCase):
    def test_reads_and_searches_the_projection(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            _mail_generation(root)
            adapters = replica_sources.adapters_for(
                sources.Visibility.PERSONAL, {"mail": root / "replica"}
            )
            mail = adapters["mail"]

            record = mail.read("mail::INBOX::aaa")
            self.assertEqual(record.title, "Boiler inspection")
            self.assertIn("booked for the twelfth", record.body)
            self.assertEqual(set(record.provenance), {"source_id", "revision", "captured_at"})
            self.assertEqual(record.provenance["source_id"], "mail/mail::INBOX::aaa")
            self.assertEqual(record.provenance["captured_at"], CAPTURED)
            self.assertEqual(record.revision, record.provenance["revision"])

            hits = mail.search("boiler twelfth", 5)
            self.assertEqual([hit.id for hit in hits], ["mail::INBOX::aaa"])
            self.assertEqual(mail.search("kettle", 5), ())

    def test_derived_objects_are_not_records(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            _mail_generation(root)
            mail = replica_sources.adapters_for(
                sources.Visibility.PERSONAL, {"mail": root / "replica"}
            )["mail"]
            with self.assertRaises(sources.SourceNotFound):
                mail.read("mail::_uidvalidity")

    def test_the_contract_is_the_deployment_table_s(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            _mail_generation(root)
            adapter = replica_sources.adapters_for(
                sources.Visibility.PERSONAL, {"mail": root / "replica"}
            )["mail"]
            table = sources.SOURCES_BY_DEPLOYMENT[sources.Visibility.PERSONAL]["mail"]
            self.assertEqual(adapter.contract, table.contract)


class CalendarAndFinanceTests(unittest.TestCase):
    def test_calendar_projects_the_entity_not_the_ics(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            _calendar_generation(root)
            calendar = replica_sources.adapters_for(
                sources.Visibility.PERSONAL, {"calendar": root / "replica-calendar"}
            )["calendar"]

            record = calendar.read("calendar::e1")
            self.assertEqual(record.title, "Dentist")
            self.assertIn("repeats FREQ=MONTHLY", record.body)
            with self.assertRaises(sources.SourceNotFound):
                calendar.read("calendar::e1::ics")

    def test_finance_projects_the_transaction_only(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            _finance_generation(root)
            finance = replica_sources.adapters_for(
                sources.Visibility.PERSONAL, {"finance": root / "replica-finance"}
            )["finance"]

            record = finance.read("finance::txn::acct-1::txn-1")
            self.assertEqual(record.title, "Corner shop")
            self.assertIn("amount -23.40", record.body)
            for derived in ("finance::accountset", "finance::account::acct-1"):
                with self.assertRaises(sources.SourceNotFound):
                    finance.read(derived)
            self.assertEqual([hit.id for hit in finance.search("corner", 5)],
                             ["finance::txn::acct-1::txn-1"])


class BraveReplicaTests(unittest.TestCase):
    def test_urls_become_searchable_records(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            replica = root / "replica-brave" / "published" / "gen-0001"
            (replica / "objects").mkdir(parents=True)
            dump = {
                "table": "urls",
                "columns": ["id", "url", "title"],
                "rows": [[7, "https://example.com/cycling", "Quiet bike routes"]],
            }
            object_id = "brave::table::urls"
            data = (json.dumps(dump) + "\n").encode("utf-8")
            import hashlib

            (replica / "objects" / object_id).write_bytes(data)
            (replica / "manifest.json").write_text(
                json.dumps(
                    {
                        "generation_id": "gen-0001",
                        "source_id": "brave.history",
                        "epoch": None,
                        "cursor": 1,
                        "objects": [
                            {
                                "object_id": object_id,
                                "filename": object_id,
                                "size": len(data),
                                "sha256": hashlib.sha256(data).hexdigest(),
                                "metadata": {
                                    "kind": "table",
                                    "table": "urls",
                                    "captured_at": CAPTURED,
                                },
                            }
                        ],
                        "tombstones": [],
                    }
                ),
                encoding="utf-8",
            )
            brave = replica_sources.adapters_for(
                sources.Visibility.PERSONAL, {"brave": root / "replica-brave"}
            )["brave"]
            hits = brave.search("cycling", 5)
            self.assertEqual([hit.id for hit in hits], ["urls::7"])
            self.assertEqual(brave.read("urls::7").title, "Quiet bike routes")


class LiveRefreshTests(unittest.TestCase):
    def test_a_new_generation_is_visible_without_rebuilding_the_adapter(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            _mail_generation(root)
            mail = replica_sources.adapters_for(
                sources.Visibility.PERSONAL,
                {"mail": root / "replica"},
                refresh_seconds=0,
            )["mail"]
            self.assertEqual(mail.read("mail::INBOX::aaa").title, "Boiler inspection")

            _mail_generation(
                root,
                "gen-0002",
                subject="Boiler inspection updated",
                body="Rescheduled to the nineteenth.",
            )

            record = mail.read("mail::INBOX::aaa")
            self.assertEqual(record.title, "Boiler inspection updated")
            self.assertIn("Rescheduled", record.body)
            self.assertEqual(
                [hit.id for hit in mail.search("rescheduled", 5)],
                ["mail::INBOX::aaa"],
            )

    def test_an_absent_generation_is_unavailable_and_recovers_later(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            mail = replica_sources.adapters_for(
                sources.Visibility.PERSONAL,
                {"mail": root / "replica"},
                refresh_seconds=0,
            )["mail"]
            with self.assertRaises(sources.SourceUnavailable):
                mail.read("mail::INBOX::aaa")
            with self.assertRaises(sources.SourceUnavailable):
                mail.search("boiler", 5)

            _mail_generation(root)
            self.assertEqual(mail.read("mail::INBOX::aaa").title, "Boiler inspection")


class SplitTests(unittest.TestCase):
    def test_a_general_deployment_cannot_gain_a_personal_source(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            _mail_generation(root)
            with self.assertRaises(ContractError):
                replica_sources.adapters_for(
                    sources.Visibility.GENERAL, {"mail": root / "replica"}
                )

    def test_an_unknown_source_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            _mail_generation(root)
            with self.assertRaises(ContractError):
                replica_sources.adapters_for(
                    sources.Visibility.PERSONAL, {"nonsense": root / "replica"}
                )

    def test_catalog_replacement_must_keep_the_contract(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            _mail_generation(root)
            personal = sources.Visibility.PERSONAL
            adapter = replica_sources.adapters_for(personal, {"mail": root / "replica"})[
                "mail"
            ]
            catalog = sources.Catalog.for_deployment(personal, replacements={"mail": adapter})
            self.assertEqual(catalog.read("mail", "mail::INBOX::aaa").title, "Boiler inspection")

            general_contract = sources.SOURCES_BY_DEPLOYMENT[sources.Visibility.GENERAL][
                "books"
            ].contract

            class Impostor:
                """A replacement carrying another deployment's contract."""

                contract = general_contract

                def read(self, record_id: str):  # pragma: no cover - refused first
                    raise AssertionError("never reached")

                def search(self, query: str, limit: int):  # pragma: no cover
                    raise AssertionError("never reached")

            with self.assertRaises(ContractError):
                sources.Catalog.for_deployment(personal, replacements={"mail": Impostor()})

    def test_replacing_a_source_the_table_lacks_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            _mail_generation(root)
            adapter = replica_sources.adapters_for(
                sources.Visibility.PERSONAL, {"mail": root / "replica"}
            )["mail"]
            with self.assertRaises(sources.UnknownSource):
                sources.Catalog.for_deployment(
                    sources.Visibility.GENERAL, replacements={"mail": adapter}
                )

    def test_an_object_without_a_capture_time_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            replica = root / "published" / "gen-0001"
            (replica / "objects").mkdir(parents=True)
            data = b'{"id": "e1", "uid": "u1"}'
            import hashlib

            (replica / "objects" / "calendar::e1").write_bytes(data)
            (replica / "manifest.json").write_text(
                json.dumps(
                    {
                        "generation_id": "gen-0001",
                        "source_id": "tuta.calendar",
                        "epoch": None,
                        "cursor": 1,
                        "objects": [
                            {
                                "object_id": "calendar::e1",
                                "filename": "calendar::e1",
                                "size": len(data),
                                "sha256": hashlib.sha256(data).hexdigest(),
                                "metadata": {"kind": "sdk-entity"},
                            }
                        ],
                        "tombstones": [],
                    }
                ),
                encoding="utf-8",
            )
            calendar = replica_sources.adapters_for(
                sources.Visibility.PERSONAL, {"calendar": root}
            )["calendar"]
            with self.assertRaises(ContractError):
                calendar.read("calendar::e1")


class QueryValidationTests(unittest.TestCase):
    def test_search_uses_the_facade_rules(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            _mail_generation(root)
            mail = replica_sources.adapters_for(
                sources.Visibility.PERSONAL, {"mail": root / "replica"}
            )["mail"]
            with self.assertRaises(ValidationError):
                mail.search("   ", 5)
            with self.assertRaises(ValidationError):
                mail.search("boiler", 0)
            self.assertEqual(len(mail.search("boiler", 10)), 1)


if __name__ == "__main__":
    unittest.main()
