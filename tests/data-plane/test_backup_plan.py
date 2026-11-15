"""The host backup plan: strict loading, tier order, and repository paths."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from data_plane.backup.plan import load_plan, parse_plan
from data_plane.errors import BackupConfigError

PASSWORD = "/etc/homelab/secrets/restic/data-plane.password"


def plan_document() -> dict:
    return {
        "schema_version": 1,
        "snapshot_dataset": "tank/data",
        "snapshot_root": "/run/data-plane/current",
        "password_file": PASSWORD,
        "tiers": [
            {"name": "nvme", "repository_root": "/var/backups/primary/restic"},
            {"name": "hdd", "repository_root": "/var/backups/secondary/restic"},
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
                "tiers": ["nvme", "hdd", "r2"],
            },
            {
                "id": "notes",
                "path": "notes",
                "cadence": "fast",
                "tiers": ["nvme", "r2"],
            },
        ],
    }


class PlanLoadingTests(unittest.TestCase):
    def test_load_plan_from_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "backup.json"
            path.write_text(json.dumps(plan_document()), encoding="utf-8")
            plan = load_plan(path)
        self.assertEqual(plan.schema_version, 1)
        self.assertEqual(plan.snapshot_dataset, "tank/data")
        self.assertEqual([group.id for group in plan.groups], ["photos", "notes"])

    def test_repository_and_snapshot_paths(self):
        plan = parse_plan(plan_document())
        self.assertEqual(
            plan.repository("photos", "nvme"),
            "/var/backups/primary/restic/photos",
        )
        self.assertEqual(
            plan.repository("photos", "r2"),
            "s3:https://account.r2.cloudflarestorage.com/homelab-restic/photos",
        )
        self.assertEqual(
            plan.snapshot_path("photos"), "/run/data-plane/current/photos"
        )
        self.assertEqual(plan.group("photos").primary_tier, "nvme")

    def test_trailing_slashes_do_not_double_up(self):
        document = plan_document()
        document["snapshot_root"] = "/run/data-plane/current/"
        document["tiers"][0]["repository_root"] = "/var/backups/primary/restic/"
        plan = parse_plan(document)
        self.assertEqual(
            plan.snapshot_path("photos"), "/run/data-plane/current/photos"
        )
        self.assertEqual(
            plan.repository("photos", "nvme"),
            "/var/backups/primary/restic/photos",
        )

    def test_group_live_defaults_to_false_and_parses_true(self):
        self.assertFalse(parse_plan(plan_document()).group("photos").live)
        document = plan_document()
        document["groups"][0]["live"] = True
        self.assertTrue(parse_plan(document).group("photos").live)

    def test_unknown_group_or_tier_is_rejected(self):
        plan = parse_plan(plan_document())
        with self.assertRaises(BackupConfigError):
            plan.group("music")
        with self.assertRaises(BackupConfigError):
            plan.repository("photos", "usb")


class PlanValidationTests(unittest.TestCase):
    def assert_rejected(self, mutate) -> None:
        document = plan_document()
        mutate(document)
        with self.assertRaises(BackupConfigError):
            parse_plan(document)

    def test_unknown_top_level_key(self):
        self.assert_rejected(lambda doc: doc.update(extra=True))

    def test_schema_version_must_be_one(self):
        self.assert_rejected(lambda doc: doc.update(schema_version=2))
        self.assert_rejected(lambda doc: doc.update(schema_version="1"))

    def test_absolute_snapshot_root_and_password_file(self):
        self.assert_rejected(lambda doc: doc.update(snapshot_root="run/data"))
        self.assert_rejected(lambda doc: doc.update(password_file="secrets/pw"))

    def test_snapshot_dataset_must_be_a_dataset(self):
        self.assert_rejected(lambda doc: doc.update(snapshot_dataset="tank/data@x"))

    def test_duplicate_tier_names(self):
        self.assert_rejected(
            lambda doc: doc["tiers"].append(
                {"name": "nvme", "repository_root": "/var/backups/other"}
            )
        )

    def test_r2_root_must_be_s3(self):
        self.assert_rejected(lambda doc: doc["tiers"][2].update(repository_root="/srv/r2"))

    def test_local_root_must_be_absolute(self):
        self.assert_rejected(
            lambda doc: doc["tiers"][0].update(repository_root="relative/restic")
        )

    def test_duplicate_group_ids(self):
        self.assert_rejected(lambda doc: doc["groups"][0].update(id="notes"))

    def test_group_tiers_must_be_known_and_non_empty(self):
        self.assert_rejected(lambda doc: doc["groups"][0].update(tiers=[]))
        self.assert_rejected(lambda doc: doc["groups"][0].update(tiers=["usb"]))
        self.assert_rejected(
            lambda doc: doc["groups"][0].update(tiers=["nvme", "nvme"])
        )

    def test_unsafe_group_paths(self):
        for path in ("/photos", "photos/../secrets", "photos//nested", ""):
            with self.subTest(path=path):
                self.assert_rejected(lambda doc: doc["groups"][0].update(path=path))

    def test_unknown_cadence(self):
        self.assert_rejected(lambda doc: doc["groups"][0].update(cadence="slow"))

    def test_unknown_group_key(self):
        self.assert_rejected(lambda doc: doc["groups"][0].update(destination="x"))

    def test_live_must_be_a_boolean(self):
        self.assert_rejected(lambda doc: doc["groups"][0].update(live="yes"))
        self.assert_rejected(lambda doc: doc["groups"][0].update(live=1))

    def test_missing_key_is_rejected(self):
        self.assert_rejected(lambda doc: doc.pop("groups"))
        self.assert_rejected(lambda doc: doc.pop("password_file"))

    def test_non_object_plan(self):
        with self.assertRaises(BackupConfigError):
            parse_plan([])


if __name__ == "__main__":
    unittest.main()
