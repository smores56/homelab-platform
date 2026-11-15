"""The host-secret bundle unpacks to exactly the files the policy mounts."""

from __future__ import annotations

import base64
import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "unpack-host-secrets.py"
RENDERER = ROOT / "scripts" / "render-recovery-groups.py"


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


unpacker = _load("unpack_host_secrets", SCRIPT)
render = _load("render_recovery_groups", RENDERER)


def b64(value: bytes) -> str:
    return base64.b64encode(value).decode()


class BundleTests(unittest.TestCase):
    def bundle(self, **overrides) -> str:
        values = {
            "restic_password": b"pw" * 24,
            "event_append_token": b"a" * 32,
            "event_read_token": b"b" * 32,
            "consumers_json": b'{"confirmation-surface":"x"}',
            "broker_identity": b"c" * 32,
            "broker_operator_key": b"d" * 32,
            "r2_access_key_id": b"key-id",
            "r2_secret_access_key": b"secret",
        }
        values.update(overrides)
        return "\n".join(f"{key}: {b64(value)}" for key, value in values.items()) + "\n"

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
            self.assertEqual(password.read_bytes(), b"pw" * 24)
            self.assertEqual(password.stat().st_mode & 0o777, 0o600)
            env = (Path(tmp) / "restic/r2.env").read_text()
            self.assertEqual(
                env, "AWS_ACCESS_KEY_ID=key-id\nAWS_SECRET_ACCESS_KEY=secret\n"
            )

    def test_missing_key_is_refused(self):
        text = self.bundle().replace(
            f"event_read_token: {b64(b'b' * 32)}\n", ""
        )
        with self.assertRaises(ValueError) as raised:
            unpacker.parse_bundle(text)
        self.assertIn("event_read_token", str(raised.exception))

    def test_half_an_r2_pair_is_refused(self):
        text = self.bundle().replace(f"r2_secret_access_key: {b64(b'secret')}\n", "")
        with self.assertRaises(ValueError) as raised:
            unpacker.parse_bundle(text)
        self.assertIn("r2_secret_access_key", str(raised.exception))

    def test_unknown_key_is_refused(self):
        with self.assertRaises(ValueError):
            unpacker.parse_bundle(self.bundle(extra=b"x"))

    def test_the_mapping_is_the_host_secret_policy(self):
        all_vars, _ = render.load_group_vars()
        declared = {entry["src"] for entry in all_vars["host_secret_files"]}
        mounted = {relative for relative, _ in unpacker.FILES.values()}
        self.assertEqual(declared, mounted)

    def test_no_value_reaches_stdout(self):
        with tempfile.TemporaryDirectory() as tmp:
            import contextlib
            import io

            bundle = Path(tmp) / "bundle.yaml"
            bundle.write_text(self.bundle())
            buffer = io.StringIO()
            with contextlib.redirect_stdout(buffer):
                unpacker.main(["--bundle", str(bundle), "--dest", str(Path(tmp) / "out")])
            self.assertNotIn("pw" * 24, buffer.getvalue())
            self.assertNotIn("secret", buffer.getvalue())


if __name__ == "__main__":
    unittest.main()
