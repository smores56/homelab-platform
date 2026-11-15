"""The plan-driven preflight gate: freshness, checks, read-data, CLI."""

from __future__ import annotations

import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from data_plane.backup.plan import BackupPlan, parse_plan
from data_plane.backup.restic import CommandResult
from data_plane.backup.runner import (
    FRESHNESS_HOURS,
    FreshnessReport,
    GroupFreshness,
    TierCheck,
    TierFreshness,
)
from data_plane.errors import BackupError
from data_plane.migration.cli import main
from data_plane.migration.preflight import ResticGateRunner, run_gate

PASSWORD = "/etc/homelab/secrets/restic/data-plane.password"
NVME = "/var/backups/nvme/restic"
HDD = "/var/backups/hdd/restic"
R2 = "s3:https://account.r2.cloudflarestorage.com/homelab-restic"
NOW = 1_800_000_000.0


def plan_document() -> dict:
    return {
        "schema_version": 1,
        "snapshot_dataset": "tank/data",
        "snapshot_root": "/run/data-plane/current",
        "password_file": PASSWORD,
        "tiers": [
            {"name": "nvme", "repository_root": NVME},
            {"name": "hdd", "repository_root": HDD},
            {"name": "r2", "repository_root": R2},
        ],
        "groups": [
            {
                "id": "photos",
                "path": "photos",
                "cadence": "media",
                "tiers": ["nvme", "hdd", "r2"],
            },
            {
                "id": "notes",
                "path": "notes",
                "cadence": "fast",
                "tiers": ["nvme", "hdd"],
            },
        ],
    }


def plan() -> BackupPlan:
    return parse_plan(plan_document())


class FakeGateRunner:
    """Answers freshness and checks from repository health tables."""

    def __init__(
        self,
        *,
        unhealthy: dict[str, str] | None = None,
        path_missing: dict[str, str] | None = None,
        read_data_failures: dict[str, str] | None = None,
        freshness_error: Exception | None = None,
        check_errors: dict[str, Exception] | None = None,
    ) -> None:
        self.unhealthy = unhealthy or {}
        self.path_missing = path_missing or {}
        self.read_data_failures = read_data_failures or {}
        self.freshness_error = freshness_error
        self.check_errors = check_errors or {}
        self.freshness_calls: list[float | None] = []
        self.check_calls: list[tuple[str, bool, tuple[str, ...]]] = []

    def freshness(
        self, plan: BackupPlan, now: float | None = None
    ) -> FreshnessReport:
        self.freshness_calls.append(now)
        if self.freshness_error is not None:
            raise self.freshness_error
        groups = []
        for group in plan.groups:
            limit = FRESHNESS_HOURS[group.cadence]
            tiers = []
            for tier_name in group.tiers:
                repository = plan.repository(group.id, tier_name)
                if repository in self.unhealthy:
                    tiers.append(
                        TierFreshness(
                            group_id=group.id,
                            tier=tier_name,
                            repository=repository,
                            ok=False,
                            reason=self.unhealthy[repository],
                            limit_hours=limit.get(tier_name),
                        )
                    )
                elif repository in self.path_missing:
                    tiers.append(
                        TierFreshness(
                            group_id=group.id,
                            tier=tier_name,
                            repository=repository,
                            ok=False,
                            reason=self.path_missing[repository],
                            age_hours=0.5,
                            limit_hours=limit.get(tier_name),
                        )
                    )
                else:
                    tiers.append(
                        TierFreshness(
                            group_id=group.id,
                            tier=tier_name,
                            repository=repository,
                            ok=True,
                            reason="newest snapshot is 0.50h old",
                            snapshot_id="abc123",
                            age_hours=0.5,
                            limit_hours=limit.get(tier_name),
                        )
                    )
            groups.append(GroupFreshness(group_id=group.id, tiers=tuple(tiers)))
        generated_at = NOW if now is None else float(now)
        return FreshnessReport(generated_at=generated_at, groups=tuple(groups))

    def check(
        self, plan: BackupPlan, group_id: str, read_data: bool = False
    ) -> tuple[TierCheck, ...]:
        tiers = tuple(plan.group(group_id).tiers)
        self.check_calls.append(
            (
                group_id,
                read_data,
                tuple(plan.repository(group_id, tier) for tier in tiers),
            )
        )
        if group_id in self.check_errors:
            raise self.check_errors[group_id]
        results = []
        for tier_name in tiers:
            repository = plan.repository(group_id, tier_name)
            if read_data and repository in self.read_data_failures:
                results.append(
                    TierCheck(
                        tier=tier_name,
                        repository=repository,
                        ok=False,
                        reason=self.read_data_failures[repository],
                    )
                )
            else:
                results.append(
                    TierCheck(
                        tier=tier_name,
                        repository=repository,
                        ok=True,
                        reason="ok",
                    )
                )
        return tuple(results)


class GateTest(unittest.TestCase):
    def test_all_ok(self):
        runner = FakeGateRunner()
        report = run_gate(plan(), runner, now=NOW)
        self.assertTrue(report.ok, report.failure_details())
        self.assertEqual(report.failure_details(), ())
        self.assertEqual(len(report.freshness.groups), 2)
        self.assertEqual(runner.freshness_calls, [NOW])
        self.assertEqual(len(report.checks), 2)
        self.assertEqual(len(report.read_data), 2)

        structural = [call for call in runner.check_calls if not call[1]]
        self.assertEqual([call[0] for call in structural], ["photos", "notes"])
        self.assertEqual(
            structural[0][2],
            (
                f"{NVME}/photos",
                f"{HDD}/photos",
                f"{R2}/photos",
            ),
        )
        self.assertEqual(
            structural[1][2],
            (f"{NVME}/notes", f"{HDD}/notes"),
        )
        self.assertTrue(all(check.ok for check in report.checks))

    def test_read_data_runs_only_on_the_primary_tier(self):
        runner = FakeGateRunner()
        report = run_gate(plan(), runner, now=NOW)
        read_data = [call for call in runner.check_calls if call[1]]
        self.assertEqual(
            read_data,
            [
                ("photos", True, (f"{NVME}/photos",)),
                ("notes", True, (f"{NVME}/notes",)),
            ],
        )
        self.assertEqual(
            [(item.group_id, item.tier) for item in report.read_data],
            [("photos", "nvme"), ("notes", "nvme")],
        )

    def test_no_read_data_skips_the_primary_pass(self):
        runner = FakeGateRunner()
        report = run_gate(plan(), runner, now=NOW, read_data=False)
        self.assertTrue(report.ok)
        self.assertFalse(report.read_data_requested)
        self.assertEqual(report.read_data, ())
        self.assertFalse(any(call[1] for call in runner.check_calls))

    def test_stale_repository_fails_freshness_only(self):
        runner = FakeGateRunner(
            unhealthy={f"{HDD}/photos": "newest snapshot is 40.00h old, over the 6.0h limit"}
        )
        report = run_gate(plan(), runner, now=NOW)
        self.assertFalse(report.ok)
        self.assertEqual(
            report.failure_details(),
            (
                "photos/hdd: newest snapshot is 40.00h old, over the 6.0h limit",
            ),
        )
        self.assertTrue(all(check.ok for check in report.checks))

    def test_path_coverage_failure_is_reported(self):
        missing = f"{R2}/photos"
        runner = FakeGateRunner(
            path_missing={
                missing: "newest snapshot does not cover /run/data-plane/current/photos"
            }
        )
        report = run_gate(plan(), runner, now=NOW)
        self.assertFalse(report.ok)
        self.assertEqual(
            report.failure_details(),
            (
                "photos/r2: newest snapshot does not cover "
                "/run/data-plane/current/photos",
            ),
        )

    def test_missing_repository_is_a_failed_entry_not_an_exception(self):
        message = (
            f"restic repository '{NVME}/notes' for group 'notes' tier 'nvme' is "
            "not initialized; run 'data_plane backup-init --plan <plan> --group "
            "notes' first"
        )
        runner = FakeGateRunner(check_errors={"notes": BackupError(message)})
        report = run_gate(plan(), runner, now=NOW)
        self.assertFalse(report.ok)
        details = report.failure_details()
        self.assertTrue(any(detail.startswith("notes/nvme: check: ") for detail in details))
        self.assertTrue(all(message in detail for detail in details if "notes/" in detail))
        self.assertTrue(report.freshness.all_ok)

    def test_freshness_backup_error_fails_every_tier(self):
        runner = FakeGateRunner(
            freshness_error=BackupError("cannot read the restic password file")
        )
        report = run_gate(plan(), runner, now=NOW)
        self.assertFalse(report.ok)
        self.assertFalse(report.freshness.all_ok)
        self.assertEqual(
            sum(1 for detail in report.failure_details() if "/" in detail),
            5,
        )
        self.assertTrue(
            all(
                "cannot read the restic password file" in detail
                for detail in report.failure_details()
            )
        )

    def test_read_data_failure_fails_the_gate(self):
        runner = FakeGateRunner(
            read_data_failures={f"{NVME}/photos": "read-data failed: pack is damaged"}
        )
        report = run_gate(plan(), runner, now=NOW)
        self.assertFalse(report.ok)
        self.assertEqual(
            report.failure_details(),
            ("photos/nvme: read-data: read-data failed: pack is damaged",),
        )


class ResticGateRunnerTest(unittest.TestCase):
    def test_read_data_argv_only_targets_each_primary(self):
        class RecordingCommands:
            def __init__(self) -> None:
                self.argv: list[tuple[str, ...]] = []

            def run(self, command):
                self.argv.append(command.argv)
                return CommandResult(0, "", "")

        commands = RecordingCommands()
        run_gate(plan(), ResticGateRunner(commands), now=NOW)
        read_data = [
            argv[argv.index("--repo") + 1]
            for argv in commands.argv
            if "--read-data" in argv
        ]
        self.assertEqual(read_data, [f"{NVME}/photos", f"{NVME}/notes"])


class CliTest(unittest.TestCase):
    def run_cli(self, *argv: str) -> tuple[int, str, str]:
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = main(list(argv))
        return code, stdout.getvalue(), stderr.getvalue()

    def write_plan(self, directory: Path, payload) -> Path:
        path = directory / "plan.json"
        path.write_text(json.dumps(payload), encoding="utf-8")
        return path

    def test_ok_plan_exits_zero_and_prints_the_report(self):
        with tempfile.TemporaryDirectory() as raw:
            path = self.write_plan(Path(raw), plan_document())
            with mock.patch(
                "data_plane.migration.cli._gate_runner",
                return_value=FakeGateRunner(),
            ):
                code, out, _ = self.run_cli(
                    "preflight", "--plan", str(path), "--json"
                )
        self.assertEqual(code, 0)
        payload = json.loads(out)
        self.assertTrue(payload["ok"])
        self.assertEqual(len(payload["checks"]), 2)
        self.assertEqual(len(payload["read_data"]), 2)
        self.assertEqual(payload["failures"], [])

    def test_failed_gate_exits_one_and_names_the_failure(self):
        with tempfile.TemporaryDirectory() as raw:
            path = self.write_plan(Path(raw), plan_document())
            runner = FakeGateRunner(unhealthy={f"{HDD}/notes": "repository is not initialized"})
            with mock.patch(
                "data_plane.migration.cli._gate_runner", return_value=runner
            ):
                code, out, _ = self.run_cli("preflight", "--plan", str(path))
        self.assertEqual(code, 1)
        self.assertIn("preflight: FAILED", out)
        self.assertIn("notes/hdd: repository is not initialized", out)

    def test_no_read_data_is_visible_in_the_report(self):
        with tempfile.TemporaryDirectory() as raw:
            path = self.write_plan(Path(raw), plan_document())
            with mock.patch(
                "data_plane.migration.cli._gate_runner",
                return_value=FakeGateRunner(),
            ):
                code, out, _ = self.run_cli(
                    "preflight", "--plan", str(path), "--json", "--no-read-data"
                )
        self.assertEqual(code, 0)
        payload = json.loads(out)
        self.assertFalse(payload["read_data_requested"])
        self.assertEqual(payload["read_data"], [])

    def test_unreadable_plan_is_an_input_error(self):
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "missing.json"
            code, _, err = self.run_cli("preflight", "--plan", str(path))
        self.assertEqual(code, 2)
        self.assertIn("cannot read backup plan", err)


if __name__ == "__main__":
    unittest.main()
