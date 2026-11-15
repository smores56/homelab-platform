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
        stats = [task for task in TASKS if "secret_files" in json.dumps(task.get("loop", ""))]
        self.assertTrue(stats, "no task iterates the declared secret files")
        self.assertTrue(
            any(
                "stat" in json.dumps(task) or "assert" in json.dumps(task)
                for task in stats
            )
        )

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


class SecretsPlayTests(unittest.TestCase):
    def test_secrets_install_before_the_data_plane_play(self):
        secrets_play = next(p for p in SITE if "secrets" in _roles_of(p))
        data_play = next(p for p in SITE if "data_plane" in _roles_of(p))
        self.assertLess(SITE.index(secrets_play), SITE.index(data_play))
        entry = next(e for e in secrets_play["roles"] if isinstance(e, dict))
        self.assertIn("secrets_source_dir is defined", entry["when"])
        self.assertIn("secrets", secrets_play["tags"])

    def test_secrets_role_creates_parent_directories(self):
        self.assertTrue(
            any("dirname" in json.dumps(task) for task in SECRETS_TASKS),
            "a nested secrets_files entry cannot be copied without its parent",
        )
