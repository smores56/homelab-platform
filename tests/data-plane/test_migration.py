"""Migration phases, data-loss verification, and rollback planning."""

from __future__ import annotations

import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path

from data_plane.migration import (
    PHASE_NAMES,
    DataLossError,
    GateBlocked,
    RollbackError,
    Snapshot,
    advance,
    apply_rollback,
    assert_no_data_loss,
    compare,
    compare_evidence,
    next_phase,
    plan_rollback,
)
from data_plane.migration.cli import main
from data_plane.migration.phases import (
    CUTOVER_REHEARSAL_PASSED,
    GATE_READY,
)
from data_plane.migration.verify import SnapshotEntry, Tombstone

NOW = 1_800_000_000.0
CONFIRMED_AT = "2026-11-14T05:00:00+00:00"


def confirmations() -> dict[str, object]:
    return {
        "cutover": {"confirmed": True, "by": "smores", "at": CONFIRMED_AT},
        "retire_old": {"confirmed": True, "by": "smores", "at": CONFIRMED_AT},
    }


def ssh_path(name: str, kind: str = "direct", **overrides) -> dict[str, object]:
    values: dict[str, object] = {
        "name": name,
        "kind": kind,
        "verified": True,
        "independent_of_data_plane": True,
        "verified_at": NOW - 600.0,
    }
    values.update(overrides)
    return values


def snapshot(name: str, entries, tombstones=()) -> Snapshot:
    return Snapshot(
        name=name,
        entries=tuple(SnapshotEntry(item_id, sha256) for item_id, sha256 in entries),
        tombstones=tuple(Tombstone(item_id, audited) for item_id, audited in tombstones),
    )


SHA_A = "a" * 64
SHA_B = "b" * 64
SHA_C = "c" * 64


def rollback_evidence(**overrides) -> dict[str, object]:
    values: dict[str, object] = {
        "new_writer_units": [
            "homelab-backup-media.service",
            "homelab-event-service.service",
        ],
        "old_boot_entry": "nixos-old",
        "old_generation": {
            "generation_id": "old-notes-7",
            "repo": "s3:https://account.r2.cloudflarestorage.com/restic-backup",
            "snapshot_id": "40dc1520",
            "password_file": "/root/restic.password",
            "target": "/mnt/recovery-scratch",
            "verified": True,
        },
        "rescue_ssh_units": ["ssh.service"],
        "ssh_paths": [ssh_path("lan"), ssh_path("tunnel", "cloudflared-rescue")],
        "rollback_disk": {"converted": False},
    }
    values.update(overrides)
    return values


class PhaseTest(unittest.TestCase):
    def test_phases_are_ordered_and_terminal(self):
        self.assertEqual(
            PHASE_NAMES,
            (
                "inventory",
                "protect_old",
                "pilot",
                "scratch_stack",
                "shadow_backfill",
                "cutover",
                "retire_old",
            ),
        )
        self.assertEqual(next_phase("inventory").name, "protect_old")
        self.assertIsNone(next_phase("retire_old"))

    def test_protect_old_needs_the_gate(self):
        with self.assertRaises(GateBlocked) as raised:
            advance("protect_old", {})
        missing = {key for failure in raised.exception.failures for key in failure.missing}
        self.assertEqual(missing, {GATE_READY})

    def test_protect_old_advances_with_the_gate_report(self):
        self.assertEqual(
            advance("protect_old", {GATE_READY: True}).name, "pilot"
        )

    def test_cutover_needs_a_confirmation_not_just_evidence(self):
        complete = {GATE_READY: True, CUTOVER_REHEARSAL_PASSED: True}
        with self.assertRaises(GateBlocked) as raised:
            advance("cutover", complete)
        self.assertTrue(
            any("confirmation" in failure.detail for failure in raised.exception.failures)
        )
        self.assertEqual(
            advance("cutover", dict(complete, operator_confirmations=confirmations())).name,
            "retire_old",
        )

    def test_gate_report_feeds_the_cutover_and_retirement_gates(self):
        full = {
            GATE_READY: True,
            CUTOVER_REHEARSAL_PASSED: True,
            "retired_writers_stopped": True,
            "new_generation_verified": True,
            "rollback_no_longer_required": True,
            "operator_confirmations": confirmations(),
        }
        self.assertEqual(advance("cutover", full).name, "retire_old")
        self.assertIsNone(advance("retire_old", full))

    def test_retire_old_refuses_without_confirmation(self):
        gate_evidence = {
            "retired_writers_stopped": True,
            "new_generation_verified": True,
            "rollback_no_longer_required": True,
        }
        with self.assertRaises(GateBlocked):
            advance("retire_old", gate_evidence)


class VerifyTest(unittest.TestCase):
    def source(self) -> Snapshot:
        return snapshot(
            "source",
            [("a", SHA_A), ("b", SHA_B)],
            [("c", True)],
        )

    def replica(self) -> Snapshot:
        return snapshot(
            "replica",
            [("a", SHA_A), ("b", SHA_B)],
            [("c", True)],
        )

    def test_matching_snapshots_have_no_data_loss(self):
        comparison = assert_no_data_loss(self.source(), self.replica())
        self.assertTrue(comparison.ok)
        self.assertFalse(comparison.count_drift)
        self.assertEqual(comparison.source_count, comparison.replica_count)

    def test_missing_id_fails(self):
        replica = snapshot("replica", [("a", SHA_A)], [("c", True)])
        with self.assertRaises(DataLossError) as raised:
            assert_no_data_loss(self.source(), replica)
        self.assertEqual(raised.exception.comparison.missing_ids, ("b",))

    def test_count_drift_fails(self):
        replica = snapshot(
            "replica",
            [("a", SHA_A), ("b", SHA_B), ("z", SHA_C)],
            [("c", True)],
        )
        comparison = compare(self.source(), replica)
        self.assertTrue(comparison.count_drift)
        self.assertEqual(comparison.extra_ids, ("z",))
        self.assertFalse(comparison.ok)

    def test_hash_mismatch_fails(self):
        replica = snapshot("replica", [("a", SHA_A), ("b", SHA_C)], [("c", True)])
        comparison = compare(self.source(), replica)
        self.assertFalse(comparison.ok)
        self.assertEqual(
            comparison.hash_mismatches,
            (("b", SHA_B, SHA_C),),
        )
        with self.assertRaises(DataLossError):
            assert_no_data_loss(self.source(), replica)

    def test_unaudited_tombstone_fails(self):
        source = snapshot("source", [("a", SHA_A)], [("c", False)])
        replica = snapshot("replica", [("a", SHA_A)], [("c", True)])
        with self.assertRaises(DataLossError) as raised:
            assert_no_data_loss(source, replica)
        self.assertEqual(
            raised.exception.comparison.unaudited_tombstones,
            ("source:c",),
        )

    def test_unpropagated_and_resurrected_tombstones_fail(self):
        source = snapshot("source", [("a", SHA_A)], [("c", True)])
        replica = snapshot("replica", [("a", SHA_A), ("c", SHA_C)], [])
        comparison = compare(source, replica)
        self.assertFalse(comparison.ok)
        self.assertEqual(comparison.missing_tombstones, ("c",))
        self.assertEqual(comparison.resurrected_ids, ("c",))

    def test_invalid_hash_is_not_a_pass(self):
        comparison = compare(
            snapshot("source", [("a", SHA_A)]),
            snapshot("replica", [("a", "not-a-hash")]),
        )
        self.assertFalse(comparison.ok)
        self.assertEqual(comparison.invalid_hashes, ("replica:a",))

    def test_compare_evidence_round_trip(self):
        comparison = compare_evidence(
            {"source": self.source().to_dict(), "replica": self.replica().to_dict()}
        )
        self.assertTrue(comparison.ok)


class RollbackTest(unittest.TestCase):
    def test_plan_is_ordered_and_dry_by_default(self):
        plan = plan_rollback(rollback_evidence())
        self.assertTrue(plan.dry_run)
        self.assertEqual(
            [step.name for step in plan.steps],
            [
                "stop_new_writers",
                "restore_old_boot_target",
                "restore_old_generation",
                "enable_rescue_ssh",
            ],
        )
        self.assertEqual(
            plan.commands()[1],
            ["bootctl", "set-default", "nixos-old"],
        )
        self.assertEqual(
            plan.steps[2].environment,
            (),
        )
        self.assertEqual(
            plan.steps[2].argv[1:3],
            ("restore", "40dc1520"),
        )
        self.assertTrue(plan.steps[2].irreversible)

    def test_plan_refuses_unverified_generation(self):
        bad = rollback_evidence(
            old_generation={
                "generation_id": "old-notes-7",
                "manifest": "/root/old-generation.json",
                "verified": False,
            }
        )
        with self.assertRaises(RollbackError):
            plan_rollback(bad)

    def test_plan_refuses_after_the_970_is_converted(self):
        with self.assertRaises(RollbackError):
            plan_rollback(rollback_evidence(rollback_disk={"converted": True}))

    def test_apply_needs_non_dry_plan_and_literal_confirmation(self):
        dry = plan_rollback(rollback_evidence())
        with self.assertRaises(RollbackError):
            apply_rollback(dry, object(), "rollback")

        executable = plan_rollback(rollback_evidence(), dry_run=False)
        with self.assertRaises(RollbackError):
            apply_rollback(executable, object(), "yes")

        calls = []

        class Backend:
            def run(self, argv, *, environment=None):
                calls.append((list(argv), dict(environment or {})))

        executed = apply_rollback(executable, Backend(), "rollback")
        self.assertEqual(executed[-1], "enable_rescue_ssh")
        self.assertEqual(calls[2][1], {})
        self.assertEqual(calls[2][0][1:3], ["restore", "40dc1520"])
        self.assertIn("--verify", calls[2][0])

    def test_fewer_than_two_verified_ssh_paths_warns(self):
        plan = plan_rollback(rollback_evidence(ssh_paths=[ssh_path("lan")]))
        self.assertTrue(any("fewer than two" in item for item in plan.warnings))


class CliTest(unittest.TestCase):
    def run_cli(self, *argv):
        stdout = io.StringIO()
        stderr = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = main(list(argv))
        return code, stdout.getvalue(), stderr.getvalue()

    def write(self, directory: Path, name: str, payload) -> Path:
        path = directory / name
        path.write_text(json.dumps(payload), encoding="utf-8")
        return path

    def test_verify_reports_data_loss(self):
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            bad = self.write(
                directory,
                "verify.json",
                {
                    "source": snapshot("source", [("a", SHA_A)]).to_dict(),
                    "replica": snapshot("replica", []).to_dict(),
                },
            )
            code, out, _ = self.run_cli("verify", str(bad))
            self.assertEqual(code, 1)
            self.assertEqual(json.loads(out)["missing_ids"], ["a"])

    def test_rollback_plan_is_a_dry_run(self):
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            path = self.write(directory, "rollback.json", rollback_evidence())
            code, out, _ = self.run_cli("rollback-plan", str(path))
            self.assertEqual(code, 0)
            payload = json.loads(out)
            self.assertTrue(payload["dry_run"])
            self.assertEqual(len(payload["steps"]), 4)

    def test_invalid_evidence_is_an_input_error(self):
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "broken.json"
            path.write_text("{", encoding="utf-8")
            code, _, err = self.run_cli("verify", str(path))
            self.assertEqual(code, 2)
            self.assertIn("not valid JSON", err)


if __name__ == "__main__":
    unittest.main()
