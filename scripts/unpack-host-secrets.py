#!/usr/bin/env python3
"""Unpack the encrypted host-secret bundle into a decrypted directory.

The bundle (`secrets/660-host.yaml`) holds one base64 value per key; this
script writes exactly the files `host_secret_files` names, so the install play
consumes a directory whose layout cannot drift from the policy. Values never
reach argv or a log: they are decoded from the bundle file into files.

    sops -d secrets/660-host.yaml > /dev/shm/host-secrets.yaml
    sudo scripts/unpack-host-secrets.py --bundle /dev/shm/host-secrets.yaml \
      --dest /run/operator-secrets
    rm -f /dev/shm/host-secrets.yaml
"""

from __future__ import annotations

import argparse
import base64
import binascii
import os
import sys
from pathlib import Path

# bundle key -> (destination relative to the secret root, kind)
# `env` composes a key=value file from several bundle keys.
FILES = {
    "restic_password": ("restic/data-plane.password", "raw"),
    "r2_access_key_id": ("restic/r2.env", "env"),
    "r2_secret_access_key": ("restic/r2.env", "env"),
    "event_append_token": ("event-service/append-token", "raw"),
    "event_read_token": ("event-service/read-token", "raw"),
    "consumers_json": ("event-service/consumers.json", "raw"),
    "broker_identity": ("write-broker/identity", "raw"),
    "broker_operator_key": ("write-broker/operator-key", "raw"),
}
ENV_NAMES = {
    "r2_access_key_id": "AWS_ACCESS_KEY_ID",
    "r2_secret_access_key": "AWS_SECRET_ACCESS_KEY",
}
REQUIRED = (
    "restic_password",
    "event_append_token",
    "event_read_token",
    "consumers_json",
    "broker_identity",
    "broker_operator_key",
)


def parse_bundle(text: str) -> dict[str, bytes]:
    values: dict[str, bytes] = {}
    for number, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        key, sep, value = stripped.partition(":")
        if not sep:
            raise ValueError(f"line {number} is not key: value")
        key = key.strip()
        if key in values:
            raise ValueError(f"duplicate key {key}")
        try:
            values[key] = base64.b64decode(value.strip(), validate=True)
        except (binascii.Error, ValueError) as exc:
            raise ValueError(f"{key} is not valid base64: {exc}") from exc
    unknown = set(values) - set(FILES)
    if unknown:
        raise ValueError(f"unknown bundle keys: {', '.join(sorted(unknown))}")
    missing = [key for key in REQUIRED if key not in values]
    r2 = {"r2_access_key_id", "r2_secret_access_key"} & set(values)
    if r2 and len(r2) != 2:
        missing.append("r2_secret_access_key" if "r2_access_key_id" in r2 else "r2_access_key_id")
    if missing:
        raise ValueError(f"bundle is missing: {', '.join(sorted(missing))}")
    return values


def unpack(values: dict[str, bytes], dest: Path) -> list[str]:
    written: list[str] = []
    grouped: dict[str, dict[str, bytes]] = {}
    for key, (relative, kind) in FILES.items():
        if key not in values:
            continue
        grouped.setdefault(relative, {})
        if kind == "env":
            grouped[relative][ENV_NAMES[key]] = values[key]
    for key, (relative, kind) in FILES.items():
        if key in values and kind == "raw":
            grouped[relative] = {"": values[key]}
    for relative in sorted(grouped):
        target = dest / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        os.chmod(target.parent, 0o700)
        entries = grouped[relative]
        if "" in entries:
            data = entries[""]
        else:
            data = b"".join(
                name.encode() + b"=" + entries[name].strip() + b"\n"
                for name in sorted(entries)
            )
        handle = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(handle, "wb") as stream:
            stream.write(data)
        os.chmod(target, 0o600)
        written.append(relative)
    return written


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="unpack-host-secrets")
    parser.add_argument("--bundle", required=True, help="decrypted bundle YAML")
    parser.add_argument("--dest", required=True, help="bundle directory to fill")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        values = parse_bundle(Path(args.bundle).read_text(encoding="utf-8"))
        written = unpack(values, Path(args.dest))
    except (OSError, ValueError) as exc:
        print(f"unpack-host-secrets: {exc}", file=sys.stderr)
        return 1
    for relative in written:
        print(relative)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
