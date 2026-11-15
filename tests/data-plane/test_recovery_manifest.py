"""The public recovery manifest: strongest tier first and atomic writes."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from data_plane.backup.plan import parse_plan
from data_plane.errors import ManifestError
from data_plane.recovery.manifest import build_manifest, write_manifest

PASSWORD = "/etc/homelab/secrets/restic/data-plane.password"
PRIMARY = "/var/backups/primary/restic"
SECONDARY = "/var/backups/secondary/restic"
R2 = "s3:https://account.r2.cloudflarestorage.com/homelab-restic"


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
                "id": "music",
                "path": "music",
                "cadence": "media",
                "tiers": ["nvme", "hdd"],
            },
            {
                "id": "notes",
                "path": "notes",
                "cadence": "fast",
                "tiers": ["nvme"],
            },
        ],
    }


class BuildManifestTests(unittest.TestCase):
    def test_each_group_prefers_the_strongest_available_tier(self):
        manifest = build_manifest(parse_plan(plan_document()))
        self.assertEqual(manifest["schema_version"], 1)
        self.assertEqual(
            manifest["groups"],
            [
                {
                    "id": "photos",
                    "label": "photos",
                    "repo": R2 + "/photos",
                    "data_root": "/photos",
                },
                {
                    "id": "music",
                    "label": "music",
                    "repo": SECONDARY + "/music",
                    "data_root": "/music",
                },
                {
                    "id": "notes",
                    "label": "notes",
                    "repo": PRIMARY + "/notes",
                    "data_root": "/notes",
                },
            ],
        )

    def test_custom_tier_falls_back_to_the_primary(self):
        document = plan_document()
        document["tiers"].append(
            {"name": "usb", "repository_root": "/mnt/usb/restic"}
        )
        document["groups"] = [
            {
                "id": "notes",
                "path": "notes",
                "cadence": "fast",
                "tiers": ["usb"],
            }
        ]
        manifest = build_manifest(parse_plan(document))
        self.assertEqual(manifest["groups"][0]["repo"], "/mnt/usb/restic/notes")


class WriteManifestTests(unittest.TestCase):
    def test_writes_atomically_and_refuses_overwrite(self):
        plan = parse_plan(plan_document())
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "nested" / "recovery.json"
            written = write_manifest(target, plan)
            self.assertEqual(written, target)
            self.assertEqual(
                json.loads(target.read_text(encoding="utf-8")), build_manifest(plan)
            )
            self.assertEqual(list(target.parent.glob("*.tmp")), [])
            with self.assertRaises(ManifestError):
                write_manifest(target, plan)

    def test_overwrite_replaces_the_document(self):
        plan = parse_plan(plan_document())
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "recovery.json"
            target.write_text('{"schema_version": 1, "groups": []}\n', encoding="utf-8")
            write_manifest(target, plan, overwrite=True)
            self.assertEqual(
                json.loads(target.read_text(encoding="utf-8")), build_manifest(plan)
            )


if __name__ == "__main__":
    unittest.main()
