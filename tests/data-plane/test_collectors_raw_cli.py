"""The collector command: what a unit runs, and what an operator runs by hand."""

from __future__ import annotations

import io
import json
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

from data_plane.collectors.raw import RawReplica
from data_plane.collectors.raw import cli as raw_cli
from data_plane.collectors.raw.cli import EXIT_REFUSED, main

CAPTURED = "2026-11-19T00:00:00+00:00"


def _run(argv: list[str]) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    with redirect_stdout(out), redirect_stderr(err):
        code = main(argv)
    return code, out.getvalue(), err.getvalue()


def _maildir(root: Path) -> Path:
    maildir = root / "mail"
    for spool in ("cur", "new", "tmp"):
        (maildir / spool).mkdir(parents=True, exist_ok=True)
    (maildir / "new" / "aaa").write_bytes(
        b"From: a@example.com\r\nSubject: Hello\r\nMessage-ID: <aaa@x>\r\n\r\nBody\r\n"
    )
    return maildir


class MailCommandTests(unittest.TestCase):
    def test_publishes_and_reports(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            maildir = _maildir(root)
            code, out, err = _run(
                [
                    "--root",
                    str(root / "replica"),
                    "--generation",
                    "gen-0001",
                    "--captured-at",
                    CAPTURED,
                    "mail",
                    "--maildir",
                    str(maildir),
                    "--uidvalidity",
                    "INBOX=7",
                ]
            )
            self.assertEqual(code, 0, err)
            payload = json.loads(out)
            self.assertEqual(payload["source_id"], "tuta.mail")
            self.assertEqual(payload["objects"], 1)
            self.assertFalse(payload["dry_run"])
            self.assertEqual(
                RawReplica(root / "replica").generation_id, "gen-0001"
            )
            self.assertEqual(
                RawReplica(root / "replica").source_id, "tuta.mail"
            )

    def test_dry_run_publishes_nothing(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            maildir = _maildir(root)
            code, out, err = _run(
                [
                    "--root",
                    str(root / "replica"),
                    "--dry-run",
                    "mail",
                    "--maildir",
                    str(maildir),
                    "--uidvalidity",
                    "INBOX=7",
                ]
            )
            self.assertEqual(code, 0, err)
            self.assertIsNone(json.loads(out)["published"])
            self.assertIsNone(RawReplica.latest_generation(root / "replica"))

    def test_a_bad_uidvalidity_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            maildir = _maildir(root)
            code, _, err = _run(
                ["--root", str(root / "r"), "mail", "--maildir", str(maildir)]
            )
            self.assertEqual(code, EXIT_REFUSED)
            self.assertIn("uidvalidity", err)

    def test_a_refusal_leaves_no_published_generation(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            maildir = _maildir(root)
            (maildir / "tmp" / "in-flight").write_bytes(b"partial")
            code, _, err = _run(
                [
                    "--root",
                    str(root / "replica"),
                    "mail",
                    "--maildir",
                    str(maildir),
                    "--uidvalidity",
                    "INBOX=7",
                ]
            )
            self.assertEqual(code, EXIT_REFUSED)
            self.assertIn("being written", err)
            self.assertIsNone(RawReplica.latest_generation(root / "replica"))


class FinanceCommandTests(unittest.TestCase):
    def test_pending_must_be_requested(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            accountset = root / "accountset.json"
            accountset.write_text(
                json.dumps(
                    {
                        "connections": [{"conn_id": "c1"}],
                        "accounts": [{"id": "a1", "transactions": []}],
                    }
                ),
                encoding="utf-8",
            )
            code, _, err = _run(
                [
                    "--root",
                    str(root / "replica"),
                    "finance",
                    "--accountset",
                    str(accountset),
                    "--accountset-url",
                    "https://sfin.example/access",
                ]
            )
            self.assertEqual(code, EXIT_REFUSED)
            self.assertIn("pending", err)

    def test_publishes_with_pending(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            accountset = root / "accountset.json"
            accountset.write_text(
                json.dumps(
                    {
                        "connections": [{"conn_id": "c1"}],
                        "accounts": [{"id": "a1", "transactions": []}],
                    }
                ),
                encoding="utf-8",
            )
            code, out, err = _run(
                [
                    "--root",
                    str(root / "replica"),
                    "--generation",
                    "gen-0001",
                    "finance",
                    "--accountset",
                    str(accountset),
                    "--accountset-url",
                    "https://sfin.example/access",
                    "--include-pending",
                ]
            )
            self.assertEqual(code, 0, err)
            self.assertEqual(json.loads(out)["source_id"], "finance.ledger")
            self.assertIsNotNone(RawReplica.latest_generation(root / "replica"))


class FinanceWindowTests(unittest.TestCase):
    def test_the_window_is_asked_for_in_epoch_seconds(self) -> None:
        # SimpleFIN refuses `start-date=2026-08-21` with
        # "Invalid start-date provided. It must be a UNIX timestamp integer."
        start, end = raw_cli._window(1_800_000_000, 30)
        self.assertEqual(end, 1_800_000_000)
        self.assertEqual(start, 1_800_000_000 - 37 * 86400)

    def test_the_window_never_exceeds_the_providers_recommendation(self) -> None:
        # "Requested date range exceeds recommended range of 45 days." A longer
        # read lands in the AccountSet's `errors`, which the collector refuses.
        start, end = raw_cli._window(1_800_000_000, 90)
        self.assertEqual(end, 1_800_000_000)
        self.assertEqual(start, 1_800_000_000 - 45 * 86400)


class EntryPointTests(unittest.TestCase):
    """What a unit names is `-m data_plane.collectors.raw`, not a module inside it."""

    def test_the_package_is_the_entry_point(self) -> None:
        # A package without `__main__` cannot be executed that way at all:
        # `No module named data_plane.collectors.raw.__main__`, which every
        # collector unit in `units/systemd/` names.
        import subprocess
        import sys

        import data_plane.collectors.raw.__main__ as entry
        from data_plane.collectors.raw import cli

        self.assertIs(entry.main, cli.main)
        process = subprocess.run(
            [sys.executable, "-m", "data_plane.collectors.raw", "--help"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertIn("--root", process.stdout)


if __name__ == "__main__":
    unittest.main()
