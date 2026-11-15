"""The deploy manifest and the Ansible backup vars cannot drift.

One backup model: every recovery group owns one restic repository per tier and
one subtree of the single recursive ZFS snapshot. Host dataset names come from
``recovery_inventory``/``zfs_datasets``/``backup_host_paths`` in ``all.yml`` and
policy from ``backup.yml``. This test fails when the checked-in public manifest
is stale, when the host plan has the wrong shape, or when a retired per-domain
variable survives.
"""

from __future__ import annotations

import contextlib
import copy
import importlib.util
import io
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RENDERER = ROOT / "scripts" / "render-recovery-groups.py"
INVENTORY = ROOT / "deploy" / "data-plane" / "config" / "recovery-groups.json"

RETIRED_VARS = {
    "backup_domains",
    "backup_destinations",
    "backup_manifest_dir",
    "backup_pending_host_groups",
    "backup_repositories",
    "backup_request_archive",
    "backup_request_dir",
}
RETIRED_GROUP_KEYS = {"writer", "databases", "fence", "checkpoint", "resume"}


def load_renderer():
    spec = importlib.util.spec_from_file_location("render_recovery_groups", RENDERER)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


render = load_renderer()
ALL_VARS, BACKUP_VARS = render.load_group_vars()


class InventoryContractTests(unittest.TestCase):
    def setUp(self):
        self.groups = render.build_recovery_groups(ALL_VARS, BACKUP_VARS)
        self.host_plan = render.build_host_plan(ALL_VARS, BACKUP_VARS)
        self.by_id = {group["id"]: group for group in self.groups["groups"]}

    def test_checked_in_json_is_current(self):
        expected = json.dumps(self.groups, indent=2) + "\n"
        self.assertEqual(INVENTORY.read_text(encoding="utf-8"), expected)

    def test_renderer_check_mode_accepts_the_checked_in_file(self):
        self.assertEqual(render.main(["--check"]), 0)

    def test_public_manifest_shape(self):
        self.assertEqual(set(self.groups), {"schema_version", "groups"})
        self.assertEqual(self.groups["schema_version"], 1)
        for group in self.groups["groups"]:
            self.assertEqual(set(group), {"id", "label", "repo", "data_root"})
            self.assertTrue(group["label"])

    def test_host_plan_shape(self):
        self.assertEqual(
            set(self.host_plan),
            {
                "schema_version",
                "snapshot_dataset",
                "snapshot_root",
                "password_file",
                "tiers",
                "groups",
            },
        )
        self.assertEqual(self.host_plan["schema_version"], 1)
        self.assertEqual(self.host_plan["snapshot_dataset"], ALL_VARS["zfs_pool"])
        self.assertEqual(self.host_plan["snapshot_root"], "/run/data-plane/current")
        for group in self.host_plan["groups"]:
            self.assertEqual(
                set(group), {"id", "path", "cadence", "tiers", "live"}
            )
            self.assertIsInstance(group["live"], bool)

    def test_only_host_path_groups_are_live(self):
        live = {
            group["id"] for group in self.host_plan["groups"] if group["live"]
        }
        self.assertEqual(live, {row["id"] for row in ALL_VARS["backup_host_paths"]})
        self.assertIn("host-keys", live)

    def test_every_group_carries_the_offsite_tier(self):
        for group in self.host_plan["groups"]:
            self.assertIn("r2", group["tiers"], group["id"])

    def test_tiers_are_nvme_hdd_r2(self):
        tiers = self.host_plan["tiers"]
        self.assertEqual([tier["name"] for tier in tiers], ["nvme", "hdd", "r2"])
        self.assertEqual(
            [tier["repository_root"] for tier in tiers],
            [
                "/var/backups/primary/restic",
                "/var/backups/secondary/restic",
                BACKUP_VARS["backup_r2_repository_root"],
            ],
        )

    def test_one_shared_password_file(self):
        password = self.host_plan["password_file"]
        self.assertTrue(password.startswith("/"))
        self.assertEqual(password, BACKUP_VARS["backup_password_file"])
        self.assertTrue(password.endswith(".password"))
        self.assertIn("/restic/", password)
        text = json.dumps(self.host_plan)
        self.assertEqual(text.count(".password"), 1)

    def test_cadence_values_are_fast_or_media(self):
        for group in self.host_plan["groups"]:
            self.assertIn(group["cadence"], {"fast", "media"})

    def test_group_ids_match_the_inventory(self):
        expected = render.expected_group_ids(ALL_VARS, BACKUP_VARS)
        self.assertEqual([group["id"] for group in self.groups["groups"]], expected)
        self.assertEqual([group["id"] for group in self.host_plan["groups"]], expected)
        self.assertEqual(len(expected), len(set(expected)))

    def test_every_inventory_group_and_host_path_is_present(self):
        ids = {group["id"] for group in self.host_plan["groups"]}
        for key in ALL_VARS["recovery_inventory"]:
            self.assertIn(key.replace("_", "-"), ids)
        for row in ALL_VARS["backup_host_paths"]:
            self.assertIn(row["id"], ids)

    def test_repo_and_data_root_follow_the_tier_and_path(self):
        r2_root = BACKUP_VARS["backup_r2_repository_root"].rstrip("/")
        plan_paths = {group["id"]: group["path"] for group in self.host_plan["groups"]}
        for group in self.groups["groups"]:
            self.assertEqual(group["repo"], f"{r2_root}/{group['id']}")
            self.assertEqual(group["data_root"], "/" + plan_paths[group["id"]])

    def test_host_keys_group(self):
        group = self.by_id["host-keys"]
        self.assertEqual(group["data_root"], "/var/lib/sbctl")
        self.assertEqual(group["repo"], BACKUP_VARS["backup_r2_repository_root"] + "/host-keys")
        plan_group = next(
            item for item in self.host_plan["groups"] if item["id"] == "host-keys"
        )
        self.assertEqual(plan_group["path"], "var/lib/sbctl")
        self.assertEqual(plan_group["cadence"], "media")
        self.assertEqual(plan_group["tiers"], ["nvme", "hdd", "r2"])
        self.assertIn(
            {"id": "host-keys", "path": "/var/lib/sbctl"},
            ALL_VARS["backup_host_paths"],
        )

    def test_every_dataset_sits_inside_its_group_subtree(self):
        plan_paths = {group["id"]: group["path"] for group in self.host_plan["groups"]}
        for row in ALL_VARS["zfs_datasets"]:
            group_id = row["recovery_group"].replace("_", "-")
            self.assertIn(group_id, plan_paths)
            root = "/" + plan_paths[group_id]
            self.assertTrue(
                row["mountpoint"] == root
                or row["mountpoint"].startswith(root + "/"),
                row["mountpoint"],
            )

    def test_every_group_has_a_dataset_or_a_host_path(self):
        host_paths = {row["id"] for row in ALL_VARS["backup_host_paths"]}
        for key in ALL_VARS["recovery_inventory"]:
            self.assertTrue(
                [
                    row
                    for row in ALL_VARS["zfs_datasets"]
                    if row["recovery_group"] == key
                ],
                key,
            )
        for group in self.host_plan["groups"]:
            self.assertTrue(
                render.group_rows(ALL_VARS, group["id"]) or group["id"] in host_paths,
                group["id"],
            )

    def test_retired_per_domain_vars_are_gone(self):
        self.assertEqual(RETIRED_VARS & set(BACKUP_VARS), set())
        for group_id, spec in BACKUP_VARS["backup_group_specs"].items():
            self.assertEqual(RETIRED_GROUP_KEYS & set(spec), set(), group_id)
            self.assertEqual(set(spec) - {"label", "path", "cadence", "tiers"}, set())

    def test_no_fixture_or_dry_run_backend_in_the_plan(self):
        text = (json.dumps(self.host_plan) + json.dumps(self.groups)).lower()
        for forbidden in (
            "fixture",
            "inmemorydestination",
            "dryrunrunner",
            "example.invalid",
        ):
            self.assertNotIn(forbidden, text)

    def test_host_plan_cli_matches_the_builder(self):
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            self.assertEqual(render.main(["--host-plan"]), 0)
        self.assertEqual(json.loads(buffer.getvalue()), self.host_plan)


class RendererRefusalTests(unittest.TestCase):
    """The renderer refuses what the public page would refuse."""

    def backup_vars(self):
        return copy.deepcopy(BACKUP_VARS)

    def test_a_group_without_the_offsite_tier_is_refused(self):
        backup_vars = self.backup_vars()
        group = next(iter(backup_vars["backup_group_specs"]))
        backup_vars["backup_group_specs"][group]["tiers"] = ["nvme", "hdd"]
        with self.assertRaises(SystemExit) as caught:
            render.validate(ALL_VARS, backup_vars)
        self.assertIn("r2", str(caught.exception))

    def test_a_blank_label_is_refused(self):
        backup_vars = self.backup_vars()
        group = next(iter(backup_vars["backup_group_specs"]))
        # A blank label is present, so it is not replaced by the derived default.
        backup_vars["backup_group_specs"][group]["label"] = "   "
        with self.assertRaises(SystemExit) as caught:
            render.validate(ALL_VARS, backup_vars)
        self.assertIn("label", str(caught.exception))

    def test_a_label_with_a_control_character_is_refused(self):
        backup_vars = self.backup_vars()
        group = next(iter(backup_vars["backup_group_specs"]))
        backup_vars["backup_group_specs"][group]["label"] = "Broken\u0000"
        with self.assertRaises(SystemExit) as caught:
            render.validate(ALL_VARS, backup_vars)
        self.assertIn("control character", str(caught.exception))

    def test_an_invalid_group_id_is_refused(self):
        all_vars = copy.deepcopy(ALL_VARS)
        backup_vars = self.backup_vars()
        all_vars["recovery_inventory"]["bad id"] = all_vars["recovery_inventory"][
            next(iter(all_vars["recovery_inventory"]))
        ]
        backup_vars["backup_group_specs"]["bad id"] = {
            "path": "srv/bad",
            "cadence": "media",
            "tiers": ["nvme", "hdd", "r2"],
        }
        with self.assertRaises(SystemExit) as caught:
            render.validate(all_vars, backup_vars)
        self.assertIn("valid manifest id", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
