"""Offline CLI tests: contracts, confirmation rendering, backup plan, memory."""

from __future__ import annotations

import contextlib
import io
import json
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

from data_plane.backup.restic import CommandResult
from data_plane.cli import main
from data_plane.memory.file_memory import FileMemory, MemoryRecord

PASSWORD = "/etc/homelab/secrets/restic/data-plane.password"


def run(*argv: str) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = main(list(argv))
    return code, out.getvalue(), err.getvalue()


CATALOG = {
    "sources": [
        {
            "source_id": "books",
            "visibility": "general",
            "version": 1,
            "recovery_group": "books",
            "stable_id_fields": ["id"],
            "capabilities": [
                {"name": "read", "effect": "read"},
                {"name": "create", "effect": "create"},
            ],
        }
    ]
}

OPERATION = {
    "intent_id": "intent-1",
    "source_id": "books",
    "capability": "delete",
    "targets": ["book-1"],
    "base_revision": "rev-1",
    "field_diff": [["title", "Old", "New"]],
    "affected_count": 1,
    "epoch": 2,
    "recurrence": None,
    "attendee_scope": [],
    "destination": None,
}

PLAN = {
    "schema_version": 1,
    "snapshot_dataset": "tank/data",
    "snapshot_root": "/run/data-plane/current",
    "password_file": PASSWORD,
    "tiers": [
        {"name": "nvme", "repository_root": "/var/backups/primary/restic"},
        {
            "name": "r2",
            "repository_root": "s3:https://account.r2.cloudflarestorage.com/homelab-restic",
        },
    ],
    "groups": [
        {
            "id": "photos",
            "path": "photos",
            "cadence": "media",
            "tiers": ["nvme", "r2"],
        }
    ],
}


def write_plan(tmp: str) -> Path:
    path = Path(tmp) / "backup.json"
    path.write_text(json.dumps(PLAN), encoding="utf-8")
    return path


class ScriptedRunner:
    def __init__(self, result: CommandResult) -> None:
        self.result = result
        self.commands: list[tuple[str, ...]] = []

    def run(self, command):
        self.commands.append(command.argv)
        return self.result


def snapshots_result(at: datetime) -> CommandResult:
    return CommandResult(
        0,
        json.dumps(
            [
                {
                    "id": "snap-1",
                    "time": at.strftime("%Y-%m-%dT%H:%M:%S.%f000Z"),
                    "paths": ["/run/data-plane/current"],
                    "hostname": "data-plane",
                }
            ]
        ),
        "",
    )


class CliTests(unittest.TestCase):
    def test_validate_catalog(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "catalog.json"
            path.write_text(json.dumps(CATALOG), encoding="utf-8")
            code, out, _ = run("validate-catalog", str(path))
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out), {"sources": 1, "ids": ["books"]})

    def test_validate_catalog_rejects_bad_contract(self):
        bad = json.loads(json.dumps(CATALOG))
        bad["sources"][0]["capabilities"].append(
            {"name": "delete", "effect": "delete", "reversible": False}
        )
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "catalog.json"
            path.write_text(json.dumps(bad), encoding="utf-8")
            code, _, err = run("validate-catalog", str(path))
        self.assertEqual(code, 2)
        self.assertIn("must require confirmation", err)

    def test_render_confirmation(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "operation.json"
            path.write_text(json.dumps(OPERATION), encoding="utf-8")
            code, out, _ = run("render-confirmation", str(path))
        self.assertEqual(code, 0)
        self.assertIn("Confirmation required", out)
        self.assertIn("affected count: 1", out)
        self.assertIn("hash: ", out)

    def test_backup_manifest_prints_and_writes(self):
        with tempfile.TemporaryDirectory() as tmp:
            plan = write_plan(tmp)
            code, out, _ = run("backup-manifest", "--plan", str(plan))
            self.assertEqual(code, 0)
            manifest = json.loads(out)
            self.assertEqual(
                manifest["groups"],
                [
                    {
                        "id": "photos",
                        "label": "photos",
                        "repo": "s3:https://account.r2.cloudflarestorage.com/"
                        "homelab-restic/photos",
                        "data_root": "/photos",
                    }
                ],
            )

            target = Path(tmp) / "recovery.json"
            code, out, _ = run(
                "backup-manifest", "--plan", str(plan), "--out", str(target)
            )
            self.assertEqual(code, 0)
            self.assertEqual(json.loads(out)["groups"], 1)
            self.assertTrue(target.exists())

            code, _, err = run(
                "backup-manifest", "--plan", str(plan), "--out", str(target)
            )
            self.assertEqual(code, 2)
            self.assertIn("refusing to overwrite", err)

            code, _, _ = run(
                "backup-manifest",
                "--plan",
                str(plan),
                "--out",
                str(target),
                "--overwrite",
            )
            self.assertEqual(code, 0)

    def test_backup_freshness_reports_and_exits_one_when_stale(self):
        with tempfile.TemporaryDirectory() as tmp:
            plan = write_plan(tmp)
            code, out, _ = run(
                "backup-freshness", "--plan", str(plan), "--json", "--dry-run"
            )
        self.assertEqual(code, 1)
        payload = json.loads(out)
        self.assertFalse(payload["all_ok"])
        self.assertEqual(payload["groups"][0]["group_id"], "photos")

    def test_backup_freshness_exits_zero_when_every_tier_is_fresh(self):
        with tempfile.TemporaryDirectory() as tmp:
            plan = write_plan(tmp)
            runner = ScriptedRunner(
                snapshots_result(datetime.now(tz=timezone.utc) - timedelta(minutes=5))
            )
            with mock.patch(
                "data_plane.cli._backup_runner", return_value=runner
            ):
                code, out, _ = run("backup-freshness", "--plan", str(plan), "--json")
        self.assertEqual(code, 0)
        self.assertTrue(json.loads(out)["all_ok"])

    def test_backup_check_and_init_run_offline_with_dry_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            plan = write_plan(tmp)
            code, out, _ = run("backup-check", "--plan", str(plan), "--dry-run")
            self.assertEqual(code, 0)
            self.assertTrue(json.loads(out)["all_ok"])

            code, out, _ = run("backup-init", "--plan", str(plan), "--dry-run")
            self.assertEqual(code, 0)
            self.assertEqual(json.loads(out)["groups"][0]["group_id"], "photos")

    def test_backup_run_snapshots_once_and_copies(self):
        runner = ScriptedRunner(
            CommandResult(0, json.dumps({"snapshot_id": "abc123"}) + "\n", "")
        )
        with tempfile.TemporaryDirectory() as tmp:
            plan = write_plan(tmp)
            with mock.patch(
                "data_plane.cli._backup_runner", return_value=runner
            ):
                code, out, _ = run(
                    "backup-run", "--plan", str(plan), "--host", "data-plane"
                )
        self.assertEqual(code, 0)
        payload = json.loads(out)
        self.assertTrue(payload["snapshot"].startswith("data-plane-"))
        self.assertEqual(payload["groups"][0]["snapshot_id"], "abc123")
        self.assertEqual(runner.commands[0][:3], ("zfs", "snapshot", "-r"))
        self.assertEqual(
            runner.commands[0][3],
            f"tank/data@{payload['snapshot']}",
        )
        verbs = []
        for argv in runner.commands:
            if argv[0] == "zfs":
                verbs.append("zfs")
            elif "copy" in argv:
                verbs.append("copy")
            elif "backup" in argv:
                verbs.append("backup")
            elif "forget" in argv:
                verbs.append("forget")
        self.assertEqual(verbs, ["zfs", "backup", "copy", "forget", "forget"])

    def test_memory_search(self):
        with tempfile.TemporaryDirectory() as tmp:
            FileMemory(tmp, "local").put(
                MemoryRecord(
                    id="m-1",
                    profile="local",
                    source="notes",
                    content="hello",
                    provenance={
                        "source_id": "notes",
                        "revision": "r1",
                        "captured_at": "2026-01-01T00:00:00Z",
                    },
                )
            )
            code, out, _ = run("memory-search", tmp, "local", "hello")
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out)[0]["id"], "m-1")

    def test_github_plan(self):
        code, out, _ = run(
            "github-plan", "smores56", "books", "--out", "/var/backups/github"
        )
        self.assertEqual(code, 0)
        commands = json.loads(out)
        self.assertTrue(any(command[0] == "git" for command in commands))


if __name__ == "__main__":
    unittest.main()
