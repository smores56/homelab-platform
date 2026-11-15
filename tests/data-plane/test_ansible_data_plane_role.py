"""The host data-plane units must be able to read the secrets they mount.

One policy lives in ``host_secret_files``: an entry with a ``unit`` is mounted
by that unit at ``mount`` and installed on the data-plane host at
``0640`` with the container gid; an entry without one is read by a host daemon
on the storage host at ``0600`` root. This test fails when an env path and a
manifest entry drift apart, when the role stops deriving the mode or the host
group, when a rotation stops restarting the changed unit, or when the retired
collector-relay unit returns.
"""

from __future__ import annotations

import importlib.util
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RENDERER = ROOT / "scripts" / "render-recovery-groups.py"
ROLE = ROOT / "ansible" / "roles" / "data_plane"
SECRETS_ROLE = ROOT / "ansible" / "roles" / "secrets"

CONTAINER_GID = "65532"


def _load_renderer():
    spec = importlib.util.spec_from_file_location("render_recovery_groups", RENDERER)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


render = _load_renderer()
DEFAULTS = render.load_yaml(ROLE / "defaults" / "main.yml")
TASKS = render.load_yaml(ROLE / "tasks" / "main.yml")
SECRETS_DEFAULTS = render.load_yaml(SECRETS_ROLE / "defaults" / "main.yml")
SECRETS_TASKS = render.load_yaml(SECRETS_ROLE / "tasks" / "main.yml")
SITE = render.load_yaml(ROOT / "ansible" / "playbooks" / "site.yml")
ALL_VARS, _ = render.load_group_vars()
UNIT_TEMPLATE = (ROLE / "templates" / "unit.service.j2").read_text(encoding="utf-8")

SERVICES = DEFAULTS["data_plane_services"]
MANIFEST = ALL_VARS["host_secret_files"]


def _mounted(unit):
    return [entry for entry in MANIFEST if entry.get("unit") == unit]


def _roles_of(play):
    return [entry["role"] if isinstance(entry, dict) else entry
            for entry in play.get("roles", [])]


class DataPlaneSecretMountTests(unittest.TestCase):
    def test_every_container_secret_path_is_declared_once(self):
        for service in SERVICES:
            declared = {entry["mount"] for entry in _mounted(service["name"])}
            env_paths = {
                value
                for value in service["environment"].values()
                if isinstance(value, str) and value.startswith("/run/secrets/")
            }
            self.assertEqual(declared, env_paths, service["short"])

    def test_every_mount_is_backed_by_a_relative_source(self):
        for entry in MANIFEST:
            self.assertFalse(entry["src"].startswith("/"), entry["src"])
            self.assertNotIn("..", entry["src"].split("/"), entry["src"])
            if "mount" in entry:
                self.assertTrue(entry["mount"].startswith("/run/secrets/"))

    def test_template_mounts_every_declared_file_read_only(self):
        self.assertIn(
            "{% for secret in host_secret_files | selectattr('unit', 'defined')"
            " | selectattr('unit', 'equalto', service.name) | list %}",
            UNIT_TEMPLATE,
        )
        self.assertIn(
            "--volume {{ data_plane_secret_root }}/{{ secret.src }}:"
            "{{ secret.mount }}:ro",
            UNIT_TEMPLATE,
        )

    def test_mode_and_gid_are_derived_not_repeated(self):
        self.assertEqual(ALL_VARS["data_plane_container_gid"], CONTAINER_GID)
        self.assertEqual(ALL_VARS["host_secret_container_mode"], "0640")
        self.assertEqual(ALL_VARS["host_secret_root_mode"], "0600")
        self.assertIn("data_plane_container_gid",
                      DEFAULTS["data_plane_default_container_user"])
        self.assertNotIn("data_plane_secret_group", DEFAULTS)

    def test_missing_or_mispermissioned_secret_fails_the_converge(self):
        failing = [
            task
            for task in TASKS
            if "ansible.builtin.assert" in task
            and any("item.stat.gid" in str(term)
                    for term in task["ansible.builtin.assert"].get("that", []))
        ]
        self.assertEqual(len(failing), 1)
        self.assertEqual(failing[0]["loop"], "{{ data_plane_secret_stats.results }}")

    def test_retired_relay_unit_is_gone(self):
        self.assertNotIn("collector-relay", {s["short"] for s in SERVICES})
        self.assertNotIn("collector_relay", ALL_VARS["data_plane_images"])
        self.assertNotIn(
            "homelab-collector-relay.service", ALL_VARS["homelab_writer_units"]
        )


class UnitSandboxTests(unittest.TestCase):
    def test_podman_storage_root_is_writable(self):
        self.assertIn("--root {{ data_plane_podman_root }}/{{ service.short }}", UNIT_TEMPLATE)
        self.assertIn(
            "ReadWritePaths={{ data_plane_podman_root }}/{{ service.short }}",
            UNIT_TEMPLATE,
        )

    def test_podman_storage_root_is_created_first(self):
        creators = []
        for task in TASKS:
            spec = task.get("ansible.builtin.file", {})
            path = str(spec.get("path", ""))
            if (
                spec.get("state") == "directory"
                and "data_plane_podman_root" in path
                and "item.short" in path
            ):
                creators.append(task)
        self.assertTrue(creators, "ReadWritePaths would name a missing directory")

    def test_unit_receives_the_rendered_environment(self):
        self.assertIn(
            "--env-file {{ data_plane_config_root }}/{{ service.short }}.env",
            UNIT_TEMPLATE,
        )
        self.assertNotIn("EnvironmentFile=", UNIT_TEMPLATE)

    def test_retired_unit_is_removed(self):
        self.assertIn("homelab-collector-relay", DEFAULTS["data_plane_retired_units"])
        removal = [
            task
            for task in TASKS
            if task.get("ansible.builtin.file", {}).get("state") == "absent"
        ]
        self.assertTrue(removal, "nothing removes the retired unit file")


class SecretsRoleTests(unittest.TestCase):
    def test_the_manifest_is_the_only_list(self):
        flat = json.dumps(SECRETS_TASKS)
        self.assertIn("host_secret_files", flat)
        self.assertNotIn("secrets_files", flat)
        self.assertEqual(SECRETS_DEFAULTS["secrets_source_dir"], "")

    def test_host_group_is_derived_from_the_unit(self):
        flat = json.dumps(SECRETS_TASKS)
        self.assertIn("data_plane_hosts", flat)
        self.assertIn("storage_hosts", flat)
        self.assertIn("selectattr('unit', 'defined')", flat)

    def test_the_copy_owns_the_final_owner_and_mode(self):
        copies = [task for task in SECRETS_TASKS if "ansible.builtin.copy" in task]
        self.assertEqual(len(copies), 1)
        spec = copies[0]["ansible.builtin.copy"]
        self.assertIn("data_plane_container_gid", spec["group"])
        self.assertIn("host_secret_container_mode", spec["mode"])
        self.assertIn("host_secret_root_mode", spec["mode"])

    def test_a_content_rotation_restarts_only_that_unit(self):
        flat = json.dumps(SECRETS_TASKS)
        self.assertIn("try-restart", flat)
        self.assertIn("checksum", flat)
        self.assertIn("secrets_changed_units", flat)

    def test_mount_and_unit_must_agree(self):
        flat = json.dumps(SECRETS_TASKS)
        self.assertIn("(item.mount is defined) == (item.unit is defined)", flat)

    def test_parent_directories_and_traversal_guards(self):
        flat = json.dumps(SECRETS_TASKS)
        self.assertIn("dirname", flat)
        self.assertIn("search", flat)
        self.assertIn("realpath", flat)


class SecretsPlayTests(unittest.TestCase):
    def test_secrets_install_before_the_data_plane_play(self):
        secrets_play = next(p for p in SITE if "secrets" in _roles_of(p))
        data_play = next(p for p in SITE if "data_plane" in _roles_of(p))
        self.assertLess(SITE.index(secrets_play), SITE.index(data_play))
        entry = next(e for e in secrets_play["roles"] if isinstance(e, dict))
        self.assertIn("secrets_source_dir | length > 0", entry["when"])
        self.assertIn("secrets", secrets_play["tags"])
        self.assertEqual(secrets_play["hosts"], "storage_hosts:data_plane_hosts")


class StateAndImageTests(unittest.TestCase):
    STATE_ROOT_PREFIXES = (
        ALL_VARS["data_plane_state_root"],
        "{{ data_plane_state_root }}",
    )

    def _volume_sources(self, service):
        sources = []
        for volume in service.get("volumes", []):
            source = volume.split(":", 1)[0]
            if source.startswith(self.STATE_ROOT_PREFIXES):
                sources.append(source)
        return sources

    def test_every_writable_volume_belongs_to_the_container_uid(self):
        for service in SERVICES:
            writable = set(service.get("writable_dirs", []))
            for source in self._volume_sources(service):
                self.assertIn(source, writable, f"{service['short']} {source}")
            for path in writable:
                self.assertTrue(path.startswith(self.STATE_ROOT_PREFIXES), path)

    def test_unit_grants_each_writable_dir(self):
        self.assertIn(
            "{% for path in service.writable_dirs | default([]) %}",
            UNIT_TEMPLATE,
        )
        self.assertIn("ReadWritePaths={{ path }}", UNIT_TEMPLATE)

    def test_source_catalog_is_installed_and_mounted(self):
        copied = [
            task
            for task in TASKS
            if "data_plane_source_catalog_src" in json.dumps(task)
        ]
        self.assertTrue(copied, "the host broker catalog is never installed")
        broker = next(s for s in SERVICES if s["short"] == "write-broker")
        catalog = broker["environment"]["DATA_PLANE_CATALOG"]
        self.assertIn(f"{catalog}:{catalog}:ro", broker["volumes"])

    def test_image_store_is_checked_then_loaded_from_the_archive(self):
        flat = json.dumps(TASKS)
        self.assertIn("image", flat)
        self.assertIn("exists", flat)
        self.assertIn("data_plane_image_archive", flat)
        self.assertNotIn("--pull=always", UNIT_TEMPLATE)


class StorageContractTests(unittest.TestCase):
    def test_storage_accepts_the_data_plane_tree(self):
        text = (
            ROOT / "ansible" / "roles" / "storage" / "tasks" / "main.yml"
        ).read_text(encoding="utf-8")
        self.assertIn("^/(srv|var/lib/data-plane)/", text)
        self.assertIn("'infrastructure'", text)

    def test_infrastructure_mode_is_root_only(self):
        defaults = render.load_yaml(
            ROOT / "ansible" / "roles" / "storage" / "defaults" / "main.yml"
        )
        self.assertEqual(defaults["storage_infrastructure_mode"], "0700")
        self.assertEqual(defaults["storage_infrastructure_owner"], "root")
        self.assertEqual(defaults["storage_infrastructure_group"], "root")

    def test_data_trees_belong_to_the_host_data_owner(self):
        defaults = render.load_yaml(
            ROOT / "ansible" / "roles" / "storage" / "defaults" / "main.yml"
        )
        self.assertEqual(defaults["storage_default_owner"], "{{ homelab_data_owner }}")
        self.assertEqual(defaults["storage_default_group"], "{{ homelab_data_group }}")
        self.assertEqual(ALL_VARS["homelab_data_owner"], "smores")
        self.assertEqual(ALL_VARS["homelab_data_group"], "users")
        # setgid, so a write by the broker uid or a guest's mapped uid keeps the
        # shared group.
        self.assertEqual(defaults["storage_personal_mode"], "2770")
        self.assertEqual(defaults["storage_general_mode"], "2775")
        self.assertEqual(defaults["storage_public_mode"], "2775")

    def test_broker_joins_the_shared_data_group(self):
        broker = next(s for s in SERVICES if s["short"] == "write-broker")
        self.assertEqual(broker["data_group"], "{{ homelab_data_group }}")
        self.assertIn("--group-add {{ data_plane_data_gid }}", UNIT_TEMPLATE)
        self.assertIn("data_plane_data_lookup", json.dumps(TASKS))
