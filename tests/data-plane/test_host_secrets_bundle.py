"""The host-secret bundle unpacks to exactly the files the policy mounts."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "unpack-host-secrets.py"
RENDERER = ROOT / "scripts" / "render-recovery-groups.py"

PASSWORD = "p" * 64
APPEND = "a1" * 22
READ = "b2" * 22


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


unpacker = _load("unpack_host_secrets", SCRIPT)
render = _load("render_recovery_groups", RENDERER)


class BundleTests(unittest.TestCase):
    def bundle(self, **overrides) -> str:
        values = {
            "restic_password": PASSWORD,
            "r2_access_key_id": "a" * 32,
            "r2_secret_access_key": "b" * 64,
            "event_append_token": APPEND,
            "event_read_token": READ,
            "consumers_json": '{"confirmation-surface":"ccc"}',
            "broker_identity": "d" * 44,
            "broker_operator_key": "e" * 44,
        }
        values.update(overrides)
        return "\n".join(f"{key}: {value}" for key, value in values.items()) + "\n"

    def test_round_trip_writes_the_declared_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            values = unpacker.parse_bundle(self.bundle())
            written = unpacker.unpack(values, Path(tmp))
            self.assertEqual(
                written,
                [
                    "event-service/append-token",
                    "event-service/consumers.json",
                    "event-service/read-token",
                    "restic/data-plane.password",
                    "restic/r2.env",
                    "write-broker/identity",
                    "write-broker/operator-key",
                ],
            )
            password = Path(tmp) / "restic/data-plane.password"
            self.assertEqual(password.read_text(), PASSWORD)
            self.assertEqual(password.stat().st_mode & 0o777, 0o600)
            env = (Path(tmp) / "restic/r2.env").read_text()
            self.assertEqual(
                env,
                f"AWS_ACCESS_KEY_ID={'a' * 32}\nAWS_SECRET_ACCESS_KEY={'b' * 64}\n",
            )
            self.assertEqual(
                (Path(tmp) / "event-service/consumers.json").read_text(),
                '{"confirmation-surface":"ccc"}',
            )

    def test_quoted_json_is_unquoted_not_decoded(self):
        values = unpacker.parse_bundle(self.bundle())
        self.assertEqual(values["consumers_json"], '{"confirmation-surface":"ccc"}')

    def test_base64_values_are_refused_with_the_reason(self):
        with self.assertRaises(ValueError) as raised:
            unpacker.parse_bundle(self.bundle(r2_access_key_id="QUJD" * 8))
        self.assertIn("raw 32-character hex", str(raised.exception))

        with self.assertRaises(ValueError) as raised:
            unpacker.parse_bundle(
                self.bundle(consumers_json="eyJjb25maXJtYXRpb24iOiJ4In0=")
            )
        self.assertIn("JSON text", str(raised.exception))

    def test_equal_tokens_are_refused(self):
        with self.assertRaises(ValueError):
            unpacker.parse_bundle(self.bundle(event_read_token=APPEND))

    def test_missing_key_is_refused(self):
        text = self.bundle().replace(f"event_read_token: {READ}\n", "")
        with self.assertRaises(ValueError) as raised:
            unpacker.parse_bundle(text)
        self.assertIn("event_read_token", str(raised.exception))

    def test_half_an_r2_pair_is_refused(self):
        text = self.bundle().replace(f"r2_secret_access_key: {'b' * 64}\n", "")
        with self.assertRaises(ValueError) as raised:
            unpacker.parse_bundle(text)
        self.assertIn("r2_secret_access_key", str(raised.exception))

    def test_unknown_key_is_refused(self):
        with self.assertRaises(ValueError):
            unpacker.parse_bundle(self.bundle(extra="x"))

    def test_the_mapping_is_the_host_secret_policy(self):
        all_vars, _ = render.load_group_vars()
        declared = {entry["src"] for entry in all_vars["host_secret_files"]}
        mounted = {relative for relative, _ in unpacker.FILES.values()}
        self.assertEqual(declared, mounted)

    def test_no_value_reaches_stdout(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = Path(tmp) / "bundle.yaml"
            bundle.write_text(self.bundle())
            buffer = io.StringIO()
            with contextlib.redirect_stdout(buffer):
                unpacker.main(
                    ["--bundle", str(bundle), "--dest", str(Path(tmp) / "out")]
                )
            self.assertNotIn(PASSWORD, buffer.getvalue())
            self.assertNotIn("ccc", buffer.getvalue())


if __name__ == "__main__":
    unittest.main()
