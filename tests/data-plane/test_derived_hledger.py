"""The hledger projection: mapping, sign, status, dates, and the atomic write.

Every case builds a real committed state with ``ReplicaState`` -- the
manifest, the object hashes and the rename are the collector's own -- and renders
it. Nothing stands in for the renderer, because the question this module answers
is exactly what the journal says about the bytes a bank sent.
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any, Iterable, Mapping

from data_plane.collectors.raw.replica import canonical_json
from data_plane.collectors.state import ReplicaState
from data_plane.derived.hledger import (
    COUNTER_ACCOUNT,
    EXIT_REFUSED,
    load_accounts,
    main,
    render_journal,
    sanitized_account,
    write_journal,
)
from data_plane.errors import PublishError, ValidationError

CAPTURED = "2026-11-19T00:00:00+00:00"
REPO = Path(__file__).resolve().parents[2]
#: 2025-11-19T00:00:00Z, a date that needs no arithmetic in an assertion.
DAY = 1763510400


def _posted(record: Mapping[str, Any]) -> int | None:
    """The provider's own preference order, as the collector applies it."""

    for key in ("posted", "transacted_at", "posted_at"):
        value = record.get(key)
        if isinstance(value, int) and not isinstance(value, bool):
            return value
    return None


def _publish(
    root: Path,
    accounts: Iterable[Mapping[str, Any]] = (),
    transactions: Iterable[Mapping[str, Any]] = (),
    *,
    accountset: bool = True,
) -> ReplicaState:
    """One committed replica state, written the way the finance collector writes it.

    A transaction is a mapping of ``account_id`` and ``record``; an explicit
    ``posted`` overrides what the record's own fields would give, which is how a
    state that carries no date at all is built.
    """

    state = ReplicaState(root, source_id="finance.ledger")
    for account in accounts:
        state.put(
            f"finance::account::{account['id']}",
            canonical_json(dict(account)),
            {
                "source_id": "finance.ledger",
                "kind": "account",
                "account_id": account["id"],
                "conn_id": "conn-1",
                "captured_at": CAPTURED,
            },
        )
    for transaction in transactions:
        record = dict(transaction["record"])
        account_id = str(transaction["account_id"])
        posted = transaction["posted"] if "posted" in transaction else _posted(record)
        state.put(
            f"finance::txn::{account_id}::{record['id']}",
            canonical_json(record),
            {
                "source_id": "finance.ledger",
                "kind": "transaction",
                "account_id": account_id,
                "transaction_id": str(record["id"]),
                "pending": bool(record.get("pending")),
                "posted": posted,
                "conn_id": "conn-1",
                "captured_at": CAPTURED,
            },
        )
    if accountset:
        state.put(
            "finance::accountset",
            canonical_json({"accounts": [dict(account) for account in accounts]}),
            {
                "source_id": "finance.ledger",
                "kind": "accountset",
                "accountset_url": "https://sfin.example/access",
                "captured_at": CAPTURED,
            },
        )
    state.commit(
        complete=True,
        absence_reason="provider-window",
        captured_at=CAPTURED,
    )
    return state


def _replica(root: Path) -> ReplicaState:
    return ReplicaState(root, read_only=True)


def _postings(text: str) -> list[tuple[str, str, str]]:
    """Every posting as ``(account, amount, commodity)``, in file order."""

    return [
        tuple(line.split())  # type: ignore[misc]
        for line in text.splitlines()
        if line.startswith("    ")
    ]


def _headings(text: str) -> list[str]:
    """The transaction lines, in file order."""

    return [
        line
        for line in text.splitlines()
        if line and not line.startswith((" ", ";", "account "))
    ]


def _plain_transaction(record_id: str, amount: str, **extra: Any) -> dict[str, Any]:
    record: dict[str, Any] = {
        "id": record_id,
        "amount": amount,
        "description": f"Payment {record_id}",
        "posted": DAY,
    }
    record.update(extra)
    return record


class _Base(unittest.TestCase):
    def setUp(self) -> None:
        work = tempfile.TemporaryDirectory()
        self.addCleanup(work.cleanup)
        self.work = Path(work.name)

    @property
    def replica_root(self) -> Path:
        return self.work / "replica"


class RenderTests(_Base):
    def test_the_mapping_names_the_account(self) -> None:
        replica = _publish(
            self.replica_root,
            [{"id": "acct-1", "currency": "USD"}],
            [{"account_id": "acct-1", "record": _plain_transaction("txn-1", "-12.34")}],
        )
        with contextlib.redirect_stdout(io.StringIO()):
            text, report = render_journal(replica, {"acct-1": "assets:bank:checking"})

        self.assertIn("account assets:bank:checking\n", text)
        self.assertIn(f"account {COUNTER_ACCOUNT}\n", text)
        self.assertIn("assets:bank:checking  -12.34 USD\n", text)
        self.assertNotIn("assets:unknown", text)
        self.assertEqual((report.objects, report.skipped, report.accounts), (1, 0, 2))
        self.assertEqual(report.snapshot, replica.snapshot)

    def test_an_unmapped_account_falls_back_to_its_sanitized_id(self) -> None:
        replica = _publish(
            self.replica_root,
            [{"id": "acct odd:1", "currency": "USD"}],
            [
                {
                    "account_id": "acct odd:1",
                    "record": _plain_transaction("txn-1", "-1.00"),
                }
            ],
        )
        text, _ = render_journal(replica, {})

        self.assertEqual(sanitized_account("acct odd:1"), "assets:unknown:acct_odd_1")
        self.assertIn("account assets:unknown:acct_odd_1\n", text)

    def test_an_empty_id_still_falls_back_to_a_name(self) -> None:
        self.assertEqual(sanitized_account(""), "assets:unknown:unknown")

    def test_a_name_with_a_newline_is_refused(self) -> None:
        replica = _publish(
            self.replica_root,
            [{"id": "acct-1", "currency": "USD"}],
            [{"account_id": "acct-1", "record": _plain_transaction("txn-1", "-1.00")}],
        )
        with self.assertRaises(ValidationError):
            render_journal(replica, {"acct-1": "assets:bank\nchecking"})
        with self.assertRaises(ValidationError):
            render_journal(replica, {"acct-1": "assets:bank\rchecking"})

    def test_a_name_that_starts_a_directive_is_refused(self) -> None:
        replica = _publish(
            self.replica_root,
            [{"id": "acct-1", "currency": "USD"}],
            [{"account_id": "acct-1", "record": _plain_transaction("txn-1", "-1.00")}],
        )
        for name in ("-assets:bank", "!assets:bank", ";assets:bank", "   "):
            with self.subTest(name=name):
                with self.assertRaises(ValidationError):
                    render_journal(replica, {"acct-1": name})

    def test_the_sign_is_the_providers_and_the_counter_carries_its_negation(self) -> None:
        replica = _publish(
            self.replica_root,
            [{"id": "acct-1", "currency": "USD"}],
            [
                {"account_id": "acct-1", "record": _plain_transaction("a-debit", "-12.34")},
                {"account_id": "acct-1", "record": _plain_transaction("b-credit", "250.50")},
            ],
        )
        text, _ = render_journal(replica, {"acct-1": "assets:bank:checking"})
        postings = _postings(text)

        self.assertEqual(postings[0][:2], ("assets:bank:checking", "-12.34"))
        self.assertEqual(postings[1][:2], (COUNTER_ACCOUNT, "12.34"))
        # The provider's sign, not the other one around: a debit stays negative.
        self.assertEqual(postings[2][:2], ("assets:bank:checking", "250.50"))
        self.assertEqual(postings[3][:2], (COUNTER_ACCOUNT, "-250.50"))
        for asset, counter in ((postings[0], postings[1]), (postings[2], postings[3])):
            self.assertEqual(
                float(asset[1]) + float(counter[1]), 0.0, "the two postings sum to zero"
            )
            self.assertEqual(asset[2], counter[2])

    def test_pending_uses_the_pending_status(self) -> None:
        replica = _publish(
            self.replica_root,
            [{"id": "acct-1", "currency": "USD"}],
            [
                {"account_id": "acct-1", "record": _plain_transaction("cleared", "-1.00")},
                {
                    "account_id": "acct-1",
                    "record": _plain_transaction("pending", "-2.00", pending=True),
                },
            ],
        )
        text, _ = render_journal(replica, {"acct-1": "assets:bank:checking"})

        self.assertIn("2025-11-19 *", text)
        self.assertIn("2025-11-19 !", text)

    def test_an_undated_pending_record_falls_back_to_transacted_at(self) -> None:
        replica = _publish(
            self.replica_root,
            [{"id": "acct-1", "currency": "USD"}],
            [
                {
                    "account_id": "acct-1",
                    "posted": None,
                    "record": {
                        "id": "txn-1",
                        "amount": "-1.00",
                        "description": "Card hold",
                        "pending": True,
                        "transacted_at": DAY,
                    },
                }
            ],
        )
        text, report = render_journal(replica, {"acct-1": "assets:bank:checking"})

        self.assertIn("2025-11-19 ! Card hold", text)
        self.assertEqual((report.objects, report.skipped), (1, 0))

    def test_an_undated_record_is_skipped_and_counted(self) -> None:
        replica = _publish(
            self.replica_root,
            [{"id": "acct-1", "currency": "USD"}],
            [
                {"account_id": "acct-1", "record": _plain_transaction("dated", "-1.00")},
                {
                    "account_id": "acct-1",
                    "posted": None,
                    "record": {"id": "undated", "amount": "-2.00", "description": "Who?"},
                },
            ],
        )
        text, report = render_journal(replica, {"acct-1": "assets:bank:checking"})

        self.assertNotIn("Who?", text)
        self.assertEqual((report.objects, report.skipped), (2, 1))
        self.assertEqual(_headings(text), ["2025-11-19 * Payment dated"])

    def test_an_epoch_of_zero_is_not_a_date(self) -> None:
        replica = _publish(
            self.replica_root,
            [{"id": "acct-1", "currency": "USD"}],
            [
                {
                    "account_id": "acct-1",
                    "posted": 0,
                    "record": {"id": "zero", "amount": "-1.00", "pending": True, "posted": 0},
                }
            ],
        )
        text, report = render_journal(replica, {"acct-1": "assets:bank:checking"})

        self.assertEqual((report.objects, report.skipped), (1, 1))
        self.assertNotIn("1970", text)

    def test_the_order_is_date_then_account_then_transaction(self) -> None:
        later = DAY + 86400
        replica = _publish(
            self.replica_root,
            [
                {"id": "acct-b", "currency": "USD"},
                {"id": "acct-a", "currency": "USD"},
            ],
            [
                {"account_id": "acct-b", "record": _plain_transaction("b2", "1.00")},
                {"account_id": "acct-a", "record": _plain_transaction("a2", "1.00")},
                {"account_id": "acct-b", "record": _plain_transaction("b1", "1.00")},
                {
                    "account_id": "acct-a",
                    "record": {"id": "a3", "amount": "1.00", "posted": later},
                },
            ],
        )
        accounts = {"acct-a": "assets:bank:a", "acct-b": "assets:bank:b"}
        text, _ = render_journal(replica, accounts)

        self.assertEqual(
            [posting[0] for posting in _postings(text)],
            [
                "assets:bank:a",
                COUNTER_ACCOUNT,
                "assets:bank:b",
                COUNTER_ACCOUNT,
                "assets:bank:b",
                COUNTER_ACCOUNT,
                "assets:bank:a",
                COUNTER_ACCOUNT,
            ],
        )
        self.assertEqual(
            _headings(text),
            [
                "2025-11-19 * Payment a2",
                "2025-11-19 * Payment b1",
                "2025-11-19 * Payment b2",
                "2025-11-20 *",
            ],
        )

    def test_a_rerender_is_byte_identical(self) -> None:
        replica = _publish(
            self.replica_root,
            [{"id": "acct-1", "currency": "USD"}],
            [
                {"account_id": "acct-1", "record": _plain_transaction("txn-1", "-12.34")},
                {"account_id": "acct-1", "record": _plain_transaction("txn-2", "7")},
            ],
        )
        accounts = {"acct-1": "assets:bank:checking"}
        first, _ = render_journal(replica, accounts)
        second, _ = render_journal(_replica(self.replica_root), accounts)

        self.assertEqual(first, second)
        self.assertTrue(first.endswith("\n"))

    def test_amounts_keep_two_decimals_and_strip_trailing_zeros(self) -> None:
        replica = _publish(
            self.replica_root,
            [{"id": "acct-1", "currency": "USD"}],
            [
                {"account_id": "acct-1", "record": _plain_transaction("a", "12.3")},
                {"account_id": "acct-1", "record": _plain_transaction("b", "1.005")},
                {"account_id": "acct-1", "record": _plain_transaction("c", "-1")},
                {"account_id": "acct-1", "record": _plain_transaction("d", "12.3400")},
            ],
        )
        text, _ = render_journal(replica, {"acct-1": "assets:bank:checking"})
        asset_amounts = [
            line.split()[1]
            for line in text.splitlines()
            if line.startswith("    assets:")
        ]

        self.assertEqual(asset_amounts, ["12.30", "1.005", "-1.00", "12.34"])

    def test_the_currency_falls_back_to_the_transaction(self) -> None:
        replica = _publish(
            self.replica_root,
            [{"id": "acct-1"}],
            [
                {
                    "account_id": "acct-1",
                    "record": _plain_transaction("txn-1", "-1.00", currency="EUR"),
                }
            ],
        )
        text, _ = render_journal(replica, {"acct-1": "assets:bank:checking"})

        self.assertIn("assets:bank:checking  -1.00 EUR", text)

    def test_a_transaction_with_no_currency_anywhere_is_refused(self) -> None:
        replica = _publish(
            self.replica_root,
            [{"id": "acct-1"}],
            [{"account_id": "acct-1", "record": _plain_transaction("txn-1", "-1.00")}],
        )
        with self.assertRaises(ValidationError):
            render_journal(replica, {"acct-1": "assets:bank:checking"})

    def test_a_replica_of_accounts_only_renders_the_header(self) -> None:
        replica = _publish(self.replica_root, [{"id": "acct-1", "currency": "USD"}])
        text, report = render_journal(replica, {"acct-1": "assets:bank:checking"})

        self.assertEqual((report.objects, report.skipped, report.accounts), (0, 0, 0))
        self.assertEqual(_postings(text), [])
        self.assertNotIn("account ", text)
        self.assertIn(f"replica {replica.snapshot}", text)


class WriteTests(_Base):
    def test_writes_the_parent_at_0750_and_the_journal_at_0644(self) -> None:
        target = self.work / "index" / "hledger" / "finance.journal"

        self.assertTrue(write_journal("; journal\n", target))

        self.assertEqual(target.read_text(encoding="utf-8"), "; journal\n")
        self.assertEqual(target.stat().st_mode & 0o777, 0o644)
        self.assertEqual(target.parent.stat().st_mode & 0o777, 0o750)
        self.assertEqual([entry.name for entry in target.parent.iterdir()], [target.name])

    def test_an_unchanged_journal_is_not_touched(self) -> None:
        target = self.work / "index" / "hledger" / "finance.journal"
        write_journal("; journal\n", target)
        before = target.stat().st_mtime_ns

        self.assertFalse(write_journal("; journal\n", target))

        self.assertEqual(target.stat().st_mtime_ns, before)

    def test_a_changed_journal_replaces_the_file(self) -> None:
        target = self.work / "index" / "hledger" / "finance.journal"
        write_journal("; one\n", target)

        self.assertTrue(write_journal("; two\n", target))

        self.assertEqual(target.read_text(encoding="utf-8"), "; two\n")
        self.assertEqual([entry.name for entry in target.parent.iterdir()], [target.name])

    def test_an_unwritable_target_is_a_refusal(self) -> None:
        # A file where the parent directory should be: the write cannot land, and
        # the failure names the path instead of a traceback.
        blocked = self.work / "index" / "hledger"
        blocked.parent.mkdir(parents=True)
        blocked.write_text("not a directory\n", encoding="utf-8")

        with self.assertRaises(PublishError):
            write_journal("; journal\n", blocked / "finance.journal")

    def test_a_symlink_target_is_refused(self) -> None:
        real = self.work / "elsewhere.journal"
        real.write_text("; keep me\n", encoding="utf-8")
        link = self.work / "finance.journal"
        link.symlink_to(real)

        with self.assertRaises(PublishError):
            write_journal("; journal\n", link)

        self.assertEqual(real.read_text(encoding="utf-8"), "; keep me\n")


class MappingFileTests(_Base):
    def test_reads_and_trims_the_operators_mapping(self) -> None:
        path = self.work / "accounts.json"
        path.write_text(
            json.dumps({"acct-1": "  assets:bank:checking  "}), encoding="utf-8"
        )

        self.assertEqual(load_accounts(path), {"acct-1": "assets:bank:checking"})

    def test_an_empty_object_is_a_valid_mapping(self) -> None:
        path = self.work / "accounts.json"
        path.write_text("{}\n", encoding="utf-8")

        self.assertEqual(load_accounts(path), {})

    def test_malformed_json_is_a_refusal(self) -> None:
        path = self.work / "accounts.json"
        path.write_text("{not json", encoding="utf-8")

        with self.assertRaises(ValidationError):
            load_accounts(path)

    def test_a_mapping_that_is_not_an_object_is_a_refusal(self) -> None:
        path = self.work / "accounts.json"
        path.write_text('["assets:bank:checking"]', encoding="utf-8")

        with self.assertRaises(ValidationError):
            load_accounts(path)

    def test_a_mapping_to_something_but_a_string_is_a_refusal(self) -> None:
        path = self.work / "accounts.json"
        path.write_text(json.dumps({"acct-1": 7}), encoding="utf-8")

        with self.assertRaises(ValidationError):
            load_accounts(path)

    def test_a_missing_mapping_file_is_a_refusal(self) -> None:
        with self.assertRaises(ValidationError):
            load_accounts(self.work / "accounts.json")


class CliTests(_Base):
    def setUp(self) -> None:
        super().setUp()
        _publish(
            self.replica_root,
            [{"id": "acct-1", "currency": "USD"}],
            [{"account_id": "acct-1", "record": _plain_transaction("txn-1", "-12.34")}],
        )
        self.accounts = self.work / "index" / "hledger" / "accounts.json"
        self.accounts.parent.mkdir(parents=True)
        self.accounts.write_text(json.dumps({"acct-1": "assets:bank:checking"}), "utf-8")
        self.journal = self.work / "index" / "hledger" / "finance.journal"

    def _run(self, *extra: str, report: bool = True) -> tuple[int, dict[str, Any] | None]:
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = main(
                [
                    "--replica",
                    str(self.replica_root),
                    "--accounts",
                    str(self.accounts),
                    "--out",
                    str(self.journal),
                    *extra,
                ]
            )
        lines = out.getvalue().splitlines()
        if not report:
            self.assertEqual(lines, [], "a refusal reports on stderr, not stdout")
            return code, None
        self.assertEqual(len(lines), 1, "the command prints one JSON line")
        return code, json.loads(lines[0])

    def test_the_command_writes_the_journal(self) -> None:
        code, report = self._run()

        self.assertEqual(code, 0)
        self.assertEqual(
            report,
            {"accounts": 2, "objects": 1, "path": str(self.journal), "skipped": 0},
        )
        self.assertIn("assets:bank:checking  -12.34 USD", self.journal.read_text("utf-8"))

    def test_the_dry_run_writes_nothing(self) -> None:
        code, report = self._run("--dry-run")

        self.assertEqual(code, 0)
        self.assertIsNone(report["path"])
        self.assertEqual(report["objects"], 1)
        self.assertFalse(self.journal.exists())

    def test_a_bad_mapping_exits_3_and_writes_nothing(self) -> None:
        self.accounts.write_text('{"acct-1": "-assets:bank"}', encoding="utf-8")
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            code, _ = self._run(report=False)

        self.assertEqual(code, EXIT_REFUSED)
        self.assertFalse(self.journal.exists())
        self.assertIn("directive", stderr.getvalue())

    def test_a_missing_replica_exits_3(self) -> None:
        empty = self.work / "empty-replica"
        empty.mkdir()
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            code = main(
                [
                    "--replica",
                    str(empty),
                    "--accounts",
                    str(self.accounts),
                    "--out",
                    str(self.journal),
                ]
            )

        self.assertEqual(code, EXIT_REFUSED)
        self.assertIn("no replica state", stderr.getvalue())

    def test_the_module_entry_point_prints_one_json_line(self) -> None:
        environment = dict(os.environ)
        environment["PYTHONPATH"] = str(REPO / "libs")
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        completed = subprocess.run(
            [
                sys.executable,
                "-m",
                "data_plane.derived.hledger",
                "--replica",
                str(self.replica_root),
                "--accounts",
                str(self.accounts),
                "--out",
                str(self.journal),
            ],
            cwd=REPO,
            env=environment,
            capture_output=True,
            text=True,
            check=False,
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(completed.stderr, "")
        self.assertEqual(len(completed.stdout.splitlines()), 1)
        self.assertEqual(json.loads(completed.stdout)["objects"], 1)
        self.assertTrue(self.journal.exists())


if __name__ == "__main__":
    unittest.main()
