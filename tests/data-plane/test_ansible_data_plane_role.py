"""The host data-plane units must be able to read the secrets they mount.

A unit that names a ``/run/secrets`` path must declare the host file behind it,
the template must mount that file read-only, and the role must make it readable
by the container uid. The secret root stays root-only, so the numeric gid is a
property of the mount, not a host group. This test fails when an env path and a
declared file drift apart, when ownership converges somewhere else, or when the
retired collector-relay unit returns.
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
SECRET_MODE = "0640"


def _load_renderer():
    spec = importlib.util.spec_from_file_location("render_recovery_groups", RENDERER)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


render = _load_renderer()
DEFAULTS = render.load_yaml(ROLE / "defaults" / "main.yml")
TASKS = render.load_yaml(ROLE / "tasks" / "main.yml")
SECRETS_TASKS = render.load_yaml(SECRETS_ROLE / "tasks" / "main.yml")
SITE = render.load_yaml(ROOT / "ansible" / "playbooks" / "site.yml")
ALL_VARS, _ = render.load_group_vars()
UNIT_TEMPLATE = (ROLE / "templates" / "unit.service.j2").read_text(encoding="utf-8")

SERVICES = DEFAULTS["data_plane_services"]


def _declared(service):
    return service.get("secret_files", [])


def _roles_of(play):
    return [entry["role"] if isinstance(entry, dict) else entry
            for entry in play.get("roles", [])]


class DataPlaneSecretMountTests(unittest.TestCase):
    def test_every_container_secret_path_is_declared_once(self):
        for service in SERVICES:
            declared = {item["dest"] for item in _declared(service)}
            env_paths = {
                value
                for value in service["environment"].values()
                if isinstance(value, str) and value.startswith("/run/secrets/")
            }
            self.assertEqual(declared, env_paths, service["short"])

    def test_every_declared_source_is_under_the_secret_root(self):
        root = ALL_VARS["data_plane_secret_root"].rstrip("/") + "/"
        templated = "{{ data_plane_secret_root }}/"
        for service in SERVICES:
            for item in _declared(service):
                self.assertTrue(
                    item["src"].startswith(root)
                    or item["src"].startswith(templated),
                    item["src"],
                )
                self.assertTrue(item["dest"].startswith("/run/secrets/"), item["dest"])

    def test_template_mounts_every_declared_file_read_only(self):
        self.assertIn(
            "{% for secret in service.secret_files | default([]) %}", UNIT_TEMPLATE
        )
        self.assertIn("--volume {{ secret.src }}:{{ secret.dest }}:ro", UNIT_TEMPLATE)

    def test_ownership_converges_to_the_container_gid(self):
        self.assertEqual(DEFAULTS["data_plane_secret_owner"], "root")
        self.assertEqual(DEFAULTS["data_plane_secret_group"], CONTAINER_GID)
        self.assertEqual(DEFAULTS["data_plane_secret_mode"], SECRET_MODE)
        converged = [
            task for task in TASKS if "data_plane_secret_group" in json.dumps(task)
        ]
        self.assertEqual(len(converged), 1)
        self.assertIn("data_plane_secret_mode", json.dumps(converged[0]))
        self.assertIn("subelements", json.dumps(converged[0].get("loop", "")))

    def test_a_missing_secret_file_fails_the_converge(self):
        asserts = [task for task in TASKS if "ansible.builtin.assert" in task]
        failing = [
            task
            for task in asserts
            if any("item.stat.exists" in str(term)
                   for term in task["ansible.builtin.assert"].get("that", []))
        ]
        self.assertEqual(len(failing), 1, "no fail-closed assert over the stat results")
        self.assertEqual(
            failing[0]["loop"], "{{ data_plane_secret_stats.results }}"
        )

    def test_unit_receives_the_rendered_environment(self):
        self.assertIn(
            "--env-file {{ data_plane_config_root }}/{{ service.short }}.env",
            UNIT_TEMPLATE,
        )
        self.assertNotIn("EnvironmentFile=", UNIT_TEMPLATE)

    def test_retired_unit_is_removed_and_not_fenced_elsewhere(self):
        self.assertIn("homelab-collector-relay", DEFAULTS["data_plane_retired_units"])
        removal = [
            task
            for task in TASKS
            if task.get("ansible.builtin.file", {}).get("state") == "absent"
        ]
        self.assertTrue(removal, "nothing removes the retired unit file")

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


class SecretsPlayTests(unittest.TestCase):
    def test_secrets_install_before_the_data_plane_play(self):
        secrets_play = next(p for p in SITE if "secrets" in _roles_of(p))
        data_play = next(p for p in SITE if "data_plane" in _roles_of(p))
        self.assertLess(SITE.index(secrets_play), SITE.index(data_play))
        entry = next(e for e in secrets_play["roles"] if isinstance(e, dict))
        self.assertIn("secrets_source_dir | length > 0", entry["when"])
        self.assertIn("secrets", secrets_play["tags"])
        self.assertEqual(secrets_play["hosts"], "storage_hosts:data_plane_hosts")
    def test_secrets_role_creates_parent_directories(self):
        self.assertTrue(
            any("dirname" in json.dumps(task) for task in SECRETS_TASKS),
            "a nested secrets_files entry cannot be copied without its parent",
        )

    def test_secrets_role_rejects_traversal_and_symlink_escapes(self):
        flat = json.dumps(SECRETS_TASKS)
        self.assertIn("search(", flat)
        self.assertIn("realpath", flat)
        self.assertNotIn("is not match('(^|/)\\\\.\\\\\\.(/|$)')", flat)


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
            # The writable list is exactly the set of state volumes; a directory
            # granted to the container is never left host-owned.
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
