"""The migration CLI's inventory command wires its arguments to the collector."""

from __future__ import annotations

import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from data_plane.migration import cli, inventory

FACTS = inventory.Facts(
    hostname="smortress",
    kernel="6.8.0",
    os_release={"ID": "ubuntu"},
    cpu_count=8,
    memory_kib=16_000_000,
)

REPORT = {"schema": "data-plane-inventory", "schema_version": 1, "gaps": []}


def run(*argv: str) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = cli.main(list(argv))
    return code, out.getvalue(), err.getvalue()


class InventoryCommandTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.build = mock.patch.object(
            cli.inventory, "build_report", return_value=dict(REPORT)
        ).start()
        mock.patch.object(cli.inventory, "read_facts", return_value=FACTS).start()
        mock.patch.object(cli.inventory, "SubprocessRunner").start()
        self.addCleanup(mock.patch.stopall)
        self.addCleanup(self.tmp.cleanup)

    def test_writes_the_report_and_uses_both_default_roots(self):
        out = self.root / "inventory.json"
        code, stdout, _ = run("inventory", "--json", "--out", str(out))

        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out.read_text(encoding="utf-8")), REPORT)
        self.assertEqual(stdout.strip(), str(out))
        kwargs = self.build.call_args.kwargs
        self.assertEqual(kwargs["git_roots"], tuple(inventory.GIT_ROOTS))

    def test_repeatable_git_root_reaches_the_collector_as_a_list(self):
        code, _, _ = run(
            "inventory", "--git-root", "/home/smores/ghq", "--git-root", "/srv/ghq"
        )

        self.assertEqual(code, 0)
        self.assertEqual(
            self.build.call_args.kwargs["git_roots"],
            ["/home/smores/ghq", "/srv/ghq"],
        )

    def test_prints_to_stdout_without_out(self):
        code, stdout, _ = run("inventory")

        self.assertEqual(code, 0)
        self.assertEqual(json.loads(stdout), REPORT)


if __name__ == "__main__":
    unittest.main()
