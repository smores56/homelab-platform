"""The inventory collector is read-only and reports gaps instead of failing."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from data_plane.migration import inventory


class FakeRunner:
    def __init__(self, responses):
        self.responses = responses
        self.calls: list[list[str]] = []

    def run(self, argv):
        self.calls.append(list(argv))
        key = tuple(argv)
        if key in self.responses:
            return self.responses[key]
        return inventory.CommandResult(0, "", "")


class InventoryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        for name in ("photos", "notes"):
            (self.root / "srv" / name).mkdir(parents=True)
        (self.root / "srv" / "photos" / "a.jpg").write_bytes(b"x" * 10)
        self.creds = self.root / "secrets"
        self.creds.mkdir()
        (self.creds / "restic.env").write_text("AWS_SECRET_ACCESS_KEY=do-not-read")
        self.creds.chmod(0o700)
        (self.creds / "restic.env").chmod(0o600)
        self.git = self.root / "ghq" / "github.com" / "smores56"
        self.repo = self.git / "repo"
        (self.repo / ".git").mkdir(parents=True)
        self.facts = inventory.Facts(
            hostname="smortress",
            kernel="6.8.0",
            os_release={"ID": "ubuntu", "VERSION_ID": "26.04"},
            cpu_count=16,
            memory_kib=64_000_000,
        )

    def tearDown(self):
        self.tmp.cleanup()

    def runner(self):
        du = {
            ("du", "-sb", "--one-file-system", str(self.root / "srv" / "photos")):
                inventory.CommandResult(0, "10\tphotos\n", ""),
            ("du", "-sb", "--one-file-system", str(self.root / "srv" / "notes")):
                inventory.CommandResult(0, "2048\tnotes\n", ""),
        }
        git = {
            ("git", "-C", str(self.repo), "rev-parse", "HEAD"):
                inventory.CommandResult(0, "a" * 40 + "\n", ""),
            ("git", "-C", str(self.repo), "rev-parse", "--abbrev-ref", "HEAD"):
                inventory.CommandResult(0, "main\n", ""),
            ("git", "-C", str(self.repo), "status", "--porcelain"):
                inventory.CommandResult(0, " M file\n", ""),
        }
        disks = {
            ("lsblk", "-J", "-o", "NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS"):
                inventory.CommandResult(0, json.dumps({"blockdevices": []}), ""),
            ("zpool", "list", "-H", "-o", "name,size,alloc,free,health"):
                inventory.CommandResult(0, "tank 4T 1T 3T ONLINE\n", ""),
            ("zfs", "list", "-H", "-o", "name,used,avail,mountpoint"):
                inventory.CommandResult(0, "tank/data 1T 3T /srv\n", ""),
        }
        return FakeRunner({**du, **git, **disks})

    def build(self, runner):
        return inventory.build_report(
            self.facts,
            runner,
            source_roots=[str(self.root / "srv")],
            credential_paths=[str(self.creds), str(self.creds / "missing")],
            git_roots=[str(self.root / "ghq")],
            tools={
                "du": "du",
                "git": "git",
                "lsblk": "lsblk",
                "zfs": "zfs",
                "zpool": "zpool",
            },
            collected_at="2026-01-01T00:00:00+00:00",
        )

    def test_report_shape_and_sizes(self):
        report = self.build(self.runner())
        self.assertEqual(report["schema"], "data-plane-inventory")
        self.assertEqual(report["schema_version"], 1)
        self.assertEqual(
            [entry["path"] for entry in report["sources"]],
            [str(self.root / "srv" / "notes"), str(self.root / "srv" / "photos")],
        )
        self.assertEqual(report["sources"][1]["bytes"], 10)
        self.assertEqual(report["machine"]["hostname"], "smortress")
        self.assertEqual(report["git"][0]["branch"], "main")
        self.assertTrue(report["git"][0]["dirty"])

    def test_credentials_are_metadata_only(self):
        report = self.build(self.runner())
        by_path = {item["path"]: item for item in report["credentials"]}
        present = by_path[str(self.creds)]
        self.assertEqual(present["mode"], "0o700")
        self.assertEqual(present["kind"], "dir")
        self.assertNotIn("content", present)
        self.assertNotIn("do-not-read", json.dumps(report))
        self.assertFalse(by_path[str(self.creds / "missing")]["exists"])

    def test_a_failing_query_becomes_a_gap_not_an_exception(self):
        runner = self.runner()
        runner.responses[
            ("zpool", "list", "-H", "-o", "name,size,alloc,free,health")
        ] = inventory.CommandResult(1, "", "no pools available")
        report = self.build(runner)
        self.assertIsNone(report["disks"]["pools"])
        self.assertTrue(
            any("no pools available" in gap for gap in report["gaps"]), report["gaps"]
        )

    def test_the_report_is_deterministic(self):
        first = json.dumps(self.build(self.runner()), sort_keys=True)
        second = json.dumps(self.build(self.runner()), sort_keys=True)
        self.assertEqual(first, second)

    def test_only_read_commands_are_issued(self):
        runner = self.runner()
        self.build(runner)
        allowed = {"du", "git", "lsblk", "zpool", "zfs"}
        self.assertTrue(all(call[0] in allowed for call in runner.calls))
        joined = "\n".join(" ".join(call) for call in runner.calls)
        for forbidden in ("rm ", "chmod", "chown", "zfs destroy", "zpool destroy"):
            self.assertNotIn(forbidden, joined)


if __name__ == "__main__":
    unittest.main()
