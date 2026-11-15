#!/usr/bin/env python3
"""Unpack the encrypted host-secret bundle into a decrypted directory.

Each bundle value is the exact content of one file: the restic password is the
same printable string kept in the password manager, the R2 pair is the raw
32/64-character hex value, and ``consumers_json`` is JSON text. Nothing is
decoded, so what the operator stores is what the host uses.

    sops -d secrets/660-host.yaml > /dev/shm/host-secrets.yaml
    sudo scripts/unpack-host-secrets.py --bundle /dev/shm/host-secrets.yaml \
      --dest /run/operator-secrets
    shred -u /dev/shm/host-secrets.yaml
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

# bundle key -> destination relative to the secret root, and how it is written.
# `env` composes a KEY=value file from several bundle keys.
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
REQUIRED = tuple(FILES)
HEX_ID = re.compile(r"^[0-9a-f]{32}$")
HEX_SECRET = re.compile(r"^[0-9a-f]{64}$")


def _scalar(raw: str) -> str:
    value = raw.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
        quote = value[0]
        value = value[1:-1]
        if quote == "'":
            value = value.replace("''", "'")
        else:
            value = value.replace('\\"', '"').replace("\\\\", "\\")
    return value


def parse_bundle(text: str) -> dict[str, str]:
    values: dict[str, str] = {}
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
        values[key] = _scalar(value)

    unknown = set(values) - set(FILES)
    if unknown:
        raise ValueError(f"unknown bundle keys: {', '.join(sorted(unknown))}")
    missing = [key for key in REQUIRED if not values.get(key)]
    if missing:
        raise ValueError(f"bundle is missing: {', '.join(sorted(missing))}")

    if not HEX_ID.fullmatch(values["r2_access_key_id"]):
        raise ValueError(
            "r2_access_key_id must be the raw 32-character hex value, not base64"
        )
    if not HEX_SECRET.fullmatch(values["r2_secret_access_key"]):
        raise ValueError(
            "r2_secret_access_key must be the raw 64-character hex value, not base64"
        )
    if values["event_append_token"] == values["event_read_token"]:
        raise ValueError("the append and read tokens must differ")
    try:
        consumers = json.loads(values["consumers_json"])
    except json.JSONDecodeError as exc:
        raise ValueError(
            f"consumers_json must be JSON text, not base64: {exc}"
        ) from exc
    if (
        not isinstance(consumers, dict)
        or not consumers
        or any(
            not isinstance(name, str) or not name or not isinstance(secret, str) or not secret
            for name, secret in consumers.items()
        )
    ):
        raise ValueError("consumers_json must be an object of name to non-empty string")
    if len(values["restic_password"]) < 32:
        raise ValueError("restic_password must be at least 32 characters")
    return values


def unpack(values: dict[str, str], dest: Path) -> list[str]:
    grouped: dict[str, dict[str, str]] = {}
    for key, (relative, kind) in FILES.items():
        if kind == "env":
            grouped.setdefault(relative, {})[ENV_NAMES[key]] = values[key]
        else:
            grouped[relative] = {"": values[key]}
    written: list[str] = []
    for relative in sorted(grouped):
        target = dest / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        os.chmod(target.parent, 0o700)
        entries = grouped[relative]
        if "" in entries:
            data = entries[""]
        else:
            data = "".join(
                f"{name}={entries[name]}\n" for name in sorted(entries)
            )
        handle = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
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
