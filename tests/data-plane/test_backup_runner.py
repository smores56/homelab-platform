"""The native runner: exact argv, copy order, prune coverage, and freshness."""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock

from data_plane.backup.plan import parse_plan
from data_plane.backup.restic import (
    Command,
    CommandResult,
    SubprocessRunner,
    parse_snapshot_id,
    parse_snapshots,
    restic_binary,
)
from data_plane.backup.runner import (
    check,
    freshness,
    init_group,
    run_group,
    snapshot,
)
from data_plane.errors import BackupConfigError, BackupError

PASSWORD = "/etc/homelab/secrets/restic/data-plane.password"
PRIMARY = "/var/backups/primary/restic"
SECONDARY = "/var/backups/secondary/restic"
R2 = "s3:https://account.r2.cloudflarestorage.com/homelab-restic"
NOW = 10_000_000.0


def plan_document() -> dict:
    return {
        "schema_version": 1,
        "snapshot_dataset": "tank/data",
        "snapshot_root": "/run/data-plane/current",
        "password_file": PASSWORD,
        "tiers": [
            {"name": "nvme", "repository_root": PRIMARY},
            {"name": "hdd", "repository_root": SECONDARY},
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
                "tiers": ["nvme"],
            },
        ],
    }


class FakeRunner:
    """Records argv and answers from a predicate table."""

    def __init__(self, responses=None):
        self.commands: list[tuple[str, ...]] = []
        self.responses = responses or []

    def run(self, command):
        self.commands.append(command.argv)
        for predicate, result in self.responses:
            if predicate(command.argv):
                return result
        return CommandResult(0, "", "")


def backup_summary(snapshot_id: str = "abc123") -> CommandResult:
    return CommandResult(
        0,
        json.dumps({"message_type": "summary", "snapshot_id": snapshot_id}) + "\n",
        "",
    )


def iso(at: float) -> str:
    stamp = datetime.fromtimestamp(at, tz=timezone.utc)
    return stamp.strftime("%Y-%m-%dT%H:%M:%S.%f") + "123Z"


def snapshots_payload(
    *entries: tuple[str, float, tuple[str, ...]], hostname: str = "data-plane"
) -> CommandResult:
    return CommandResult(
        0,
        json.dumps(
            [
                {
                    "id": identifier,
                    "time": iso(at),
                    "paths": list(paths),
                    "hostname": hostname,
                }
                for identifier, at, paths in entries
            ]
        ),
        "",
    )


def snapshots_argv(repo: str, path: str) -> tuple[str, ...]:
    return (
        "restic",
        "--repo",
        repo,
        "--password-file",
        PASSWORD,
        "snapshots",
        "--json",
        "--path",
        path,
    )


def repo_of(argv: tuple[str, ...]) -> str:
    return argv[argv.index("--repo") + 1]


def backup_argv(repo: str, path: str) -> tuple[str, ...]:
    return (
        "restic",
        "--repo",
        repo,
        "--password-file",
        PASSWORD,
        "backup",
        "--host",
        "data-plane",
        "--json",
        path,
    )


def copy_argv(source: str, target: str) -> tuple[str, ...]:
    return (
        "restic",
        "copy",
        "--from-repo",
        source,
        "--from-password-file",
        PASSWORD,
        "-r",
        target,
        "--password-file",
        PASSWORD,
    )


def forget_argv(repo: str) -> tuple[str, ...]:
    return (
        "restic",
        "--repo",
        repo,
        "--password-file",
        PASSWORD,
        "forget",
        "--keep-daily",
        "14",
        "--keep-weekly",
        "8",
        "--keep-monthly",
        "12",
        "--group-by",
        "host,paths",
        "--prune",
    )


def snapshots_for(*mapping):
    """Route snapshots queries to a result by repository path."""

    return [
        (
            lambda argv, repo=repo: "snapshots" in argv and repo_of(argv) == repo,
            result,
        )
        for repo, result in mapping
    ]


class ResticParsingTests(unittest.TestCase):
    def test_nanoseconds_and_offset_are_normalized_to_utc(self):
        payload = json.dumps(
            [
                {
                    "id": "abc",
                    "time": "2026-11-14T05:04:05.123456789+02:00",
                    "paths": ["/run/data-plane/current/photos"],
                    "hostname": "data-plane",
                }
            ]
        )
        snapshot = parse_snapshots(payload)[0]
        self.assertEqual(
            snapshot.time,
            datetime(2026, 11, 14, 3, 4, 5, 123456, tzinfo=timezone.utc),
        )
        self.assertEqual(snapshot.paths, ("/run/data-plane/current/photos",))
        self.assertEqual(snapshot.hostname, "data-plane")

    def test_malformed_snapshot_output_fails_closed(self):
        with self.assertRaises(BackupError):
            parse_snapshots("not json")
        with self.assertRaises(BackupError):
            parse_snapshots(json.dumps([{"time": "2026-11-14T00:00:00Z"}]))

    def test_summary_line_carries_the_snapshot_id(self):
        stdout = (
            json.dumps({"message_type": "status", "percent_done": 0.5})
            + "\n"
            + json.dumps({"message_type": "summary", "snapshot_id": "abc123"})
            + "\n"
        )
        self.assertEqual(parse_snapshot_id(stdout), "abc123")
        self.assertEqual(parse_snapshot_id(""), "")


class SnapshotTests(unittest.TestCase):
    def test_snapshot_is_one_recursive_zfs_command(self):
        runner = FakeRunner()
        point = snapshot(parse_plan(plan_document()), now=0.0, runner=runner)
        self.assertEqual(point.name, "data-plane-19700101T000000Z")
        self.assertEqual(
            runner.commands,
            [("zfs", "snapshot", "-r", "tank/data@data-plane-19700101T000000Z")],
        )

    def test_existing_snapshot_fails_closed(self):
        runner = FakeRunner(
            [
                (
                    lambda argv: argv[0] == "zfs",
                    CommandResult(
                        1, "", "cannot create snapshot: dataset already exists"
                    ),
                )
            ]
        )
        with self.assertRaises(BackupError) as caught:
            snapshot(parse_plan(plan_document()), now=0.0, runner=runner)
        self.assertIn("already exists", str(caught.exception))

    def test_other_zfs_failure_is_an_error(self):
        runner = FakeRunner(
            [(lambda argv: argv[0] == "zfs", CommandResult(1, "", "permission denied"))]
        )
        with self.assertRaises(BackupError):
            snapshot(parse_plan(plan_document()), now=0.0, runner=runner)


class RunGroupTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        for group_id in ("photos", "notes"):
            (self.root / group_id).mkdir()
            (self.root / group_id / "content").write_text("x", encoding="utf-8")

    def plan(self):
        document = plan_document()
        document["snapshot_root"] = self.root.as_posix()
        return parse_plan(document)

    def path(self, group_id: str) -> str:
        return f"{self.root.as_posix()}/{group_id}"

    def back_up(self, runner, group_id: str = "photos"):
        return run_group(self.plan(), group_id, now=NOW, runner=runner, host="data-plane")

    def test_backup_then_copies_then_prune_on_every_tier(self):
        primary_repo = PRIMARY + "/photos"
        path = self.path("photos")
        runner = FakeRunner(
            [
                (lambda argv: "backup" in argv, backup_summary("abc123")),
                *snapshots_for(
                    (primary_repo, snapshots_payload(("abc123", NOW - 20, (path,)))),
                    (
                        SECONDARY + "/photos",
                        snapshots_payload(("abc123", NOW - 19, (path,))),
                    ),
                    (R2 + "/photos", snapshots_payload(("abc123", NOW - 19, (path,)))),
                ),
            ]
        )
        report = self.back_up(runner)
        self.assertEqual(report.snapshot_id, "abc123")
        self.assertEqual(report.snapshot_path, path)
        self.assertEqual(
            [tier.tier for tier in report.tiers], ["nvme", "hdd", "r2"]
        )
        self.assertEqual(
            [tier.pruned for tier in report.tiers], [True, True, True]
        )
        self.assertEqual(
            [tier.copied for tier in report.tiers], [False, True, True]
        )
        self.assertEqual(
            runner.commands,
            [
                backup_argv(primary_repo, path),
                snapshots_argv(primary_repo, path),
                copy_argv(primary_repo, SECONDARY + "/photos"),
                snapshots_argv(SECONDARY + "/photos", path),
                copy_argv(primary_repo, R2 + "/photos"),
                snapshots_argv(R2 + "/photos", path),
                forget_argv(primary_repo),
                forget_argv(SECONDARY + "/photos"),
                forget_argv(R2 + "/photos"),
            ],
        )
        for argv in runner.commands:
            self.assertNotIn("--tag", argv)

    def test_forget_groups_by_host_and_paths(self):
        # A repository may hold more than one path or host; one shared 14/8/12
        # budget would let one group starve another. Assert the argv directly.
        runner = FakeRunner([(lambda argv: "backup" in argv, backup_summary())])
        self.back_up(runner, "notes")
        forget = next(argv for argv in runner.commands if "forget" in argv)
        position = forget.index("--group-by")
        self.assertEqual(forget[position + 1], "host,paths")

    def test_single_tier_group_still_prunes(self):
        runner = FakeRunner([(lambda argv: "backup" in argv, backup_summary())])
        report = self.back_up(runner, "notes")
        self.assertEqual(len(report.tiers), 1)
        self.assertEqual(
            runner.commands,
            [
                backup_argv(PRIMARY + "/notes", self.path("notes")),
                forget_argv(PRIMARY + "/notes"),
            ],
        )

    def test_missing_group_path_refuses_to_back_up(self):
        (self.root / "photos" / "content").unlink()
        (self.root / "photos").rmdir()
        runner = FakeRunner()
        with self.assertRaises(BackupError) as caught:
            self.back_up(runner)
        self.assertIn(self.path("photos"), str(caught.exception))
        self.assertIn("does not exist", str(caught.exception))
        self.assertEqual(runner.commands, [])

    def test_empty_group_path_refuses_to_back_up(self):
        (self.root / "photos" / "content").unlink()
        runner = FakeRunner()
        with self.assertRaises(BackupError) as caught:
            self.back_up(runner)
        self.assertIn(self.path("photos"), str(caught.exception))
        self.assertIn("empty", str(caught.exception))
        self.assertEqual(runner.commands, [])

    def test_missing_primary_repository_is_actionable(self):
        runner = FakeRunner(
            [
                (
                    lambda argv: "backup" in argv,
                    CommandResult(10, "", "unable to open config file"),
                )
            ]
        )
        with self.assertRaises(BackupConfigError) as caught:
            self.back_up(runner)
        message = str(caught.exception)
        self.assertIn("backup-init", message)
        self.assertIn(PRIMARY + "/photos", message)

    def test_missing_copy_repository_is_actionable(self):
        runner = FakeRunner(
            [
                (lambda argv: "backup" in argv, backup_summary()),
                *snapshots_for(
                    (
                        PRIMARY + "/photos",
                        snapshots_payload(("abc123", NOW, (self.path("photos"),))),
                    )
                ),
                (
                    lambda argv: "copy" in argv,
                    CommandResult(10, "", "repository does not exist"),
                ),
            ]
        )
        with self.assertRaises(BackupConfigError) as caught:
            self.back_up(runner)
        self.assertIn(SECONDARY + "/photos", str(caught.exception))

    def test_backup_without_a_snapshot_id_fails(self):
        runner = FakeRunner(
            [(lambda argv: "backup" in argv, CommandResult(0, "{}\n", ""))]
        )
        with self.assertRaises(BackupError):
            self.back_up(runner)

    def test_failed_prune_is_an_error(self):
        runner = FakeRunner(
            [
                (lambda argv: "backup" in argv, backup_summary()),
                (lambda argv: "forget" in argv, CommandResult(1, "", "lock held")),
            ]
        )
        with self.assertRaises(BackupError):
            self.back_up(runner, "notes")

    def copy_runner(self, secondary_payload, *, r2_payload=None):
        path = self.path("photos")
        primary_repo = PRIMARY + "/photos"
        responses = [
            (lambda argv: "backup" in argv, backup_summary("abc123")),
            *snapshots_for(
                (primary_repo, snapshots_payload(("abc123", NOW, (path,))))
            ),
        ]
        responses.extend(
            snapshots_for(
                (SECONDARY + "/photos", secondary_payload),
                (
                    R2 + "/photos",
                    r2_payload
                    if r2_payload is not None
                    else snapshots_payload(("abc123", NOW, (path,))),
                ),
            )
        )
        return FakeRunner(responses)

    def test_copy_that_does_not_land_is_an_error(self):
        # The copy command succeeded, but the target holds no matching snapshot.
        runner = self.copy_runner(snapshots_payload())
        with self.assertRaises(BackupError) as caught:
            self.back_up(runner)
        self.assertIn("did not land", str(caught.exception))
        self.assertIn(SECONDARY + "/photos", str(caught.exception))

    def test_copy_at_the_wrong_time_does_not_land(self):
        path = self.path("photos")
        runner = self.copy_runner(snapshots_payload(("abc123", NOW - 60, (path,))))
        with self.assertRaises(BackupError) as caught:
            self.back_up(runner)
        self.assertIn("did not land", str(caught.exception))

    def test_copy_without_the_group_path_does_not_land(self):
        runner = self.copy_runner(
            snapshots_payload(("abc123", NOW, (f"{self.path('photos')}/other",)))
        )
        with self.assertRaises(BackupError) as caught:
            self.back_up(runner)
        self.assertIn("did not land", str(caught.exception))

    def test_copy_written_by_another_host_does_not_land(self):
        path = self.path("photos")
        runner = self.copy_runner(
            snapshots_payload(("abc123", NOW, (path,)), hostname="other-host")
        )
        with self.assertRaises(BackupError) as caught:
            self.back_up(runner)
        self.assertIn("newest snapshot was written by", str(caught.exception))
        self.assertIn("other-host", str(caught.exception))

    def test_restic_binary_comes_from_the_environment(self):
        runner = FakeRunner([(lambda argv: "backup" in argv, backup_summary())])
        with mock.patch.dict(
            os.environ, {"DATA_PLANE_RESTIC": "/usr/local/bin/restic"}
        ):
            self.back_up(runner, "notes")
        self.assertTrue(runner.commands)
        for argv in runner.commands:
            self.assertEqual(argv[0], "/usr/local/bin/restic")


class InitTests(unittest.TestCase):
    def runner(self, initialized: set[str]):
        class InitRunner(FakeRunner):
            def __init__(self) -> None:
                super().__init__()
                self.initialized = initialized

            def run(self, command):
                self.commands.append(command.argv)
                return self.respond(command.argv)

            def respond(self, argv):
                if "snapshots" in argv:
                    if repo_of(argv) in self.initialized:
                        return CommandResult(0, "[]", "")
                    return CommandResult(10, "", "unable to open config file")
                if "init" in argv:
                    self.initialized.add(repo_of(argv))
                    return CommandResult(0, "", "")
                return CommandResult(0, "", "")

        return InitRunner()

    def test_missing_repositories_are_initialized(self):
        runner = self.runner(set())
        report = init_group(parse_plan(plan_document()), "photos", runner=runner)
        self.assertEqual([tier.created for tier in report.tiers], [True, True, True])
        init_commands = [argv for argv in runner.commands if "init" in argv]
        self.assertEqual(
            init_commands,
            [
                ("restic", "--repo", PRIMARY + "/photos", "--password-file", PASSWORD, "init"),
                ("restic", "--repo", SECONDARY + "/photos", "--password-file", PASSWORD, "init"),
                ("restic", "--repo", R2 + "/photos", "--password-file", PASSWORD, "init"),
            ],
        )

    def test_existing_repositories_are_kept(self):
        runner = self.runner({PRIMARY + "/photos", SECONDARY + "/photos", R2 + "/photos"})
        report = init_group(parse_plan(plan_document()), "photos", runner=runner)
        self.assertEqual([tier.created for tier in report.tiers], [False, False, False])
        self.assertFalse(any("init" in argv for argv in runner.commands))

    def test_init_is_idempotent(self):
        runner = self.runner(set())
        plan = parse_plan(plan_document())
        init_group(plan, "notes", runner=runner)
        report = init_group(plan, "notes", runner=runner)
        self.assertEqual([tier.created for tier in report.tiers], [False])
        self.assertEqual(
            sum(1 for argv in runner.commands if "init" in argv), 1
        )

    def test_unexpected_probe_failure_is_an_error(self):
        runner = FakeRunner(
            [(lambda argv: True, CommandResult(5, "", "boom"))]
        )
        with self.assertRaises(BackupError):
            init_group(parse_plan(plan_document()), "notes", runner=runner)


def group_report(report, group_id):
    return next(group for group in report.groups if group.group_id == group_id)


class FreshnessTests(unittest.TestCase):
    def plan(self):
        return parse_plan(plan_document())

    def report(self, responses, now=NOW):
        return freshness(
            self.plan(), now=now, runner=FakeRunner(responses), host="data-plane"
        )

    def test_all_tiers_fresh(self):
        responses = snapshots_for(
            (
                PRIMARY + "/notes",
                snapshots_payload(
                    ("notes-1", NOW - 600, ("/run/data-plane/current/notes",))
                ),
            ),
            (
                PRIMARY + "/photos",
                snapshots_payload(
                    ("photos-1", NOW - 1800, ("/run/data-plane/current/photos",))
                ),
            ),
            (
                SECONDARY + "/photos",
                snapshots_payload(
                    ("photos-1", NOW - 1800, ("/run/data-plane/current/photos",))
                ),
            ),
            (
                R2 + "/photos",
                snapshots_payload(
                    ("photos-1", NOW - 5 * 3600, ("/run/data-plane/current/photos",))
                ),
            ),
        )
        report = self.report(responses)
        self.assertTrue(report.all_ok)
        notes = group_report(report, "notes")
        self.assertTrue(notes.tiers[0].ok)
        self.assertAlmostEqual(notes.tiers[0].age_hours, 600 / 3600, places=3)
        self.assertEqual(notes.tiers[0].limit_hours, 0.25)
        self.assertEqual(group_report(report, "photos").tiers[2].limit_hours, 6.0)

    def test_fast_tier_is_stale_past_its_quarter_hour(self):
        responses = snapshots_for(
            (
                PRIMARY + "/notes",
                snapshots_payload(
                    ("notes-1", NOW - 1200, ("/run/data-plane/current/notes",))
                ),
            ),
            (
                PRIMARY + "/photos",
                snapshots_payload(
                    ("photos-1", NOW - 600, ("/run/data-plane/current/photos",))
                ),
            ),
            (
                SECONDARY + "/photos",
                snapshots_payload(
                    ("photos-1", NOW - 600, ("/run/data-plane/current/photos",))
                ),
            ),
            (
                R2 + "/photos",
                snapshots_payload(
                    ("photos-1", NOW - 600, ("/run/data-plane/current/photos",))
                ),
            ),
        )
        report = self.report(responses)
        self.assertFalse(report.all_ok)
        notes = group_report(report, "notes").tiers[0]
        self.assertFalse(notes.ok)
        self.assertIn("over the 0.25h limit", notes.reason)

    def test_r2_lag_limit_for_media(self):
        responses = snapshots_for(
            (
                PRIMARY + "/notes",
                snapshots_payload(
                    ("notes-1", NOW - 60, ("/run/data-plane/current/notes",))
                ),
            ),
            (
                PRIMARY + "/photos",
                snapshots_payload(
                    ("photos-1", NOW - 60, ("/run/data-plane/current/photos",))
                ),
            ),
            (
                SECONDARY + "/photos",
                snapshots_payload(
                    ("photos-1", NOW - 60, ("/run/data-plane/current/photos",))
                ),
            ),
            (
                R2 + "/photos",
                snapshots_payload(
                    ("photos-1", NOW - 7 * 3600, ("/run/data-plane/current/photos",))
                ),
            ),
        )
        tier = group_report(self.report(responses), "photos").tiers[2]
        self.assertFalse(tier.ok)
        self.assertIn("over the 6.0h limit", tier.reason)

    def test_path_coverage_accepts_a_parent_or_exact_path(self):
        for paths in (
            ("/run/data-plane/current/photos",),
            ("/run/data-plane/current",),
            ("/run/data-plane/current/photos/",),
        ):
            with self.subTest(paths=paths):
                responses = snapshots_for(
                    (
                        PRIMARY + "/photos",
                        snapshots_payload(("photos-1", NOW - 60, paths)),
                    ),
                    (
                        SECONDARY + "/photos",
                        snapshots_payload(("photos-1", NOW - 60, paths)),
                    ),
                    (
                        R2 + "/photos",
                        snapshots_payload(("photos-1", NOW - 60, paths)),
                    ),
                    (
                        PRIMARY + "/notes",
                        snapshots_payload(
                            ("notes-1", NOW - 60, ("/run/data-plane/current/notes",))
                        ),
                    ),
                )
                self.assertTrue(self.report(responses).all_ok)

    def test_snapshot_without_the_group_path_is_not_fresh(self):
        responses = snapshots_for(
            (
                PRIMARY + "/notes",
                snapshots_payload(
                    ("notes-1", NOW - 60, ("/run/data-plane/current/music",))
                ),
            ),
            (
                PRIMARY + "/photos",
                snapshots_payload(
                    ("photos-1", NOW - 60, ("/run/data-plane/current/photos",))
                ),
            ),
            (
                SECONDARY + "/photos",
                snapshots_payload(
                    ("photos-1", NOW - 60, ("/run/data-plane/current/photos",))
                ),
            ),
            (
                R2 + "/photos",
                snapshots_payload(
                    ("photos-1", NOW - 60, ("/run/data-plane/current/photos",))
                ),
            ),
        )
        tier = group_report(self.report(responses), "notes").tiers[0]
        self.assertFalse(tier.ok)
        self.assertIn("does not cover", tier.reason)

    def test_newest_snapshot_wins(self):
        responses = snapshots_for(
            (
                PRIMARY + "/notes",
                snapshots_payload(
                    ("old", NOW - 800, ("/run/data-plane/current/notes",)),
                    ("new", NOW - 60, ("/run/data-plane/current/notes",)),
                ),
            ),
            (
                PRIMARY + "/photos",
                snapshots_payload(
                    ("photos-1", NOW - 60, ("/run/data-plane/current/photos",))
                ),
            ),
            (
                SECONDARY + "/photos",
                snapshots_payload(
                    ("photos-1", NOW - 60, ("/run/data-plane/current/photos",))
                ),
            ),
            (
                R2 + "/photos",
                snapshots_payload(
                    ("photos-1", NOW - 60, ("/run/data-plane/current/photos",))
                ),
            ),
        )
        tier = group_report(self.report(responses), "notes").tiers[0]
        self.assertTrue(tier.ok)
        self.assertEqual(tier.snapshot_id, "new")

    def test_missing_repository_is_not_fresh(self):
        responses = snapshots_for(
            (
                PRIMARY + "/notes",
                CommandResult(10, "", "unable to open config file"),
            )
        )
        report = self.report(responses)
        self.assertFalse(report.all_ok)
        self.assertIn(
            "not initialized", group_report(report, "notes").tiers[0].reason
        )

    def test_no_snapshots_is_not_fresh(self):
        responses = snapshots_for(
            (PRIMARY + "/notes", CommandResult(0, "[]", ""))
        )
        tier = group_report(self.report(responses), "notes").tiers[0]
        self.assertFalse(tier.ok)
        self.assertIn("no snapshots under", tier.reason)

    def test_query_failure_becomes_a_reason(self):
        responses = snapshots_for(
            (PRIMARY + "/notes", CommandResult(1, "", "boom"))
        )
        tier = group_report(self.report(responses), "notes").tiers[0]
        self.assertFalse(tier.ok)
        self.assertIn("snapshot query failed", tier.reason)

    def test_future_only_snapshot_is_not_fresh(self):
        # A snapshot dated ahead of now makes the age negative; it must never
        # count as fresh, or one bad clock would hide a dead backup forever.
        responses = snapshots_for(
            (
                PRIMARY + "/notes",
                snapshots_payload(
                    ("future", NOW + 3600, ("/run/data-plane/current/notes",))
                ),
            )
        )
        tier = group_report(self.report(responses), "notes").tiers[0]
        self.assertFalse(tier.ok)
        self.assertEqual(tier.reason, "newest snapshot is dated in the future")

    def test_future_snapshot_does_not_hide_an_ancient_one(self):
        responses = snapshots_for(
            (
                PRIMARY + "/notes",
                snapshots_payload(
                    ("ancient", NOW - 10 * 3600, ("/run/data-plane/current/notes",)),
                    ("future", NOW + 3600, ("/run/data-plane/current/notes",)),
                ),
            )
        )
        tier = group_report(self.report(responses), "notes").tiers[0]
        self.assertFalse(tier.ok)
        self.assertEqual(tier.snapshot_id, "ancient")
        self.assertIn("over the 0.25h limit", tier.reason)

    def test_snapshot_within_the_skew_tolerance_is_not_negative(self):
        responses = snapshots_for(
            (
                PRIMARY + "/notes",
                snapshots_payload(
                    ("skewed", NOW + 120, ("/run/data-plane/current/notes",))
                ),
            )
        )
        tier = group_report(self.report(responses), "notes").tiers[0]
        self.assertTrue(tier.ok)
        self.assertEqual(tier.age_hours, 0.0)

    def test_snapshot_from_another_host_is_not_fresh(self):
        responses = snapshots_for(
            (
                PRIMARY + "/notes",
                snapshots_payload(
                    ("elsewhere", NOW - 60, ("/run/data-plane/current/notes",)),
                    hostname="other-host",
                ),
            )
        )
        tier = group_report(self.report(responses), "notes").tiers[0]
        self.assertFalse(tier.ok)
        self.assertIn("newest snapshot was written by", tier.reason)
        self.assertIn("other-host", tier.reason)

    def test_unknown_tier_is_reported_clearly(self):
        document = plan_document()
        document["tiers"].append({"name": "usb", "repository_root": "/mnt/usb/restic"})
        document["groups"] = [
            {"id": "notes", "path": "notes", "cadence": "fast", "tiers": ["usb"]}
        ]
        report = freshness(
            parse_plan(document), now=NOW, runner=FakeRunner(), host="data-plane"
        )
        tier = report.groups[0].tiers[0]
        self.assertFalse(tier.ok)
        self.assertIn("unknown tier", tier.reason)


class CheckTests(unittest.TestCase):
    def test_check_runs_on_every_tier(self):
        runner = FakeRunner(
            [
                (
                    lambda argv: argv[argv.index("--repo") + 1].startswith(SECONDARY),
                    CommandResult(1, "", "pack missing"),
                )
            ]
        )
        results = check(parse_plan(plan_document()), "photos", runner=runner)
        self.assertEqual([result.tier for result in results], ["nvme", "hdd", "r2"])
        self.assertEqual([result.ok for result in results], [True, False, True])
        self.assertIn("pack missing", results[1].reason)
        self.assertEqual(
            [argv for argv in runner.commands],
            [
                ("restic", "--repo", PRIMARY + "/photos", "--password-file", PASSWORD, "check"),
                ("restic", "--repo", SECONDARY + "/photos", "--password-file", PASSWORD, "check"),
                ("restic", "--repo", R2 + "/photos", "--password-file", PASSWORD, "check"),
            ],
        )

    def test_read_data_flag_and_missing_repository(self):
        runner = FakeRunner(
            [
                (
                    lambda argv: argv[argv.index("--repo") + 1].startswith(R2),
                    CommandResult(10, "", "repository does not exist"),
                )
            ]
        )
        results = check(
            parse_plan(plan_document()), "photos", read_data=True, runner=runner
        )
        self.assertIn("--read-data", runner.commands[0])
        self.assertFalse(results[2].ok)
        self.assertEqual(results[2].reason, "repository is not initialized")


class ResticBinaryTests(unittest.TestCase):
    def test_binary_defaults_and_reads_the_environment(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertEqual(restic_binary(), "restic")
        with mock.patch.dict(os.environ, {"DATA_PLANE_RESTIC": "/opt/restic"}):
            self.assertEqual(restic_binary(), "/opt/restic")

    def test_builders_pass_the_binary_through(self):
        from data_plane.backup.restic import backup_command, forget_command

        backup = backup_command("repo", "pw", "host", "/stage", binary="/opt/restic")
        forget = forget_command("repo", "pw", binary="/opt/restic")
        self.assertEqual(backup.argv[0], "/opt/restic")
        self.assertEqual(forget.argv[0], "/opt/restic")


class SubprocessRunnerTests(unittest.TestCase):
    def test_missing_binary_is_a_backup_error(self):
        with self.assertRaises(BackupError) as caught:
            SubprocessRunner().run(
                Command(("/nonexistent/data-plane-restic", "snapshots"))
            )
        self.assertIn("/nonexistent/data-plane-restic", str(caught.exception))

    def test_timeout_is_a_backup_error(self):
        with mock.patch(
            "data_plane.backup.restic.subprocess.run",
            side_effect=subprocess.TimeoutExpired(cmd=["restic"], timeout=5),
        ):
            with self.assertRaises(BackupError) as caught:
                SubprocessRunner().run(
                    Command(("restic", "snapshots"), timeout=5)
                )
        self.assertIn("restic", str(caught.exception))
        self.assertIn("timed out", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
