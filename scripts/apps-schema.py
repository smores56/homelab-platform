#!/usr/bin/env python3
"""Validate (and later render) typed app definitions for the `apps` tenant.

A definition is ``homelab-apps/apps/<name>/app.toml`` and may declare only
what the platform is willing to interpret: a digest-pinned image, one
container port, environment values, references to its own named secrets, a
data quota, and an egress class. There is deliberately no field for a host
path, an extra mount, a device, a capability, privileged mode, a socket, a
host or custom network, a published port, a user or an SELinux option, so a
definition cannot express them. Unknown keys are errors at every level.

    scripts/apps-schema.py validate --root <homelab-apps checkout> \
        [--secrets <tenant sops json>]

``validate`` prints ``apps/<name>/app.toml: <problem>`` per problem and exits
non-zero; it prints nothing when the tree is clean. It is the same check that
smortress re-runs on the fetched commit before rendering, so it reads the
tenant SOPS file's *key names* only and never decrypts a value.

Stdlib only: the image ships one python3 and no third-party packages.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import tomllib
from pathlib import Path
from typing import Any

#: The whole vocabulary of a definition. Anything else is a containment bug,
#: not a feature request.
TOP_LEVEL_KEYS = {"image", "port", "env", "secrets", "quota", "egress"}
REQUIRED_KEYS = ("image", "port", "egress")

EGRESS_CLASSES = {"internet", "none"}

#: Platform-owned ceiling on one app's data directory. The `apps` dataset has
#: its own quota, so this bounds a single app rather than the tenant.
QUOTA_CEILING = "50G"

#: Container ports below 1024 would be privileged inside the namespace, and
#: the platform assigns a loopback port outside this range for the reverse
#: proxy; refuse the overlap instead of rendering something unusable.
PORT_MIN = 1024
PORT_MAX = 65535

APP_NAME = re.compile(r"^[a-z][a-z0-9-]{0,30}$")
IMAGE_REF = re.compile(r"^[^\s@]+@sha256:[0-9a-f]{64}$")
ENV_NAME = re.compile(r"^[A-Z_][A-Z0-9_]*$")
SECRET_NAME = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")
QUOTA = re.compile(r"^([0-9]+)([KMGT])$")

UNIT_BYTES = {"K": 1024, "M": 1024**2, "G": 1024**3, "T": 1024**4}


class Problems(list):
    """Collects ``(file, message)`` pairs so every defect is reported at once."""

    def add(self, where: str, message: str) -> None:
        self.append((where, message))


def quota_bytes(value: str) -> int | None:
    match = QUOTA.match(value)
    if not match:
        return None
    amount, unit = match.groups()
    return int(amount) * UNIT_BYTES[unit]


def check_definition(name: str, data: dict[str, Any], where: str, problems: Problems) -> None:
    for key in sorted(set(data) - TOP_LEVEL_KEYS):
        problems.add(where, f"unknown key '{key}'")
    for key in REQUIRED_KEYS:
        if key not in data:
            problems.add(where, f"missing required key '{key}'")

    image = data.get("image")
    if "image" in data:
        if not isinstance(image, str):
            problems.add(where, "image must be a string")
        elif not IMAGE_REF.match(image):
            problems.add(where, "image must be pinned by digest: <repo>@sha256:<64 hex>")

    port = data.get("port")
    if "port" in data:
        if isinstance(port, bool) or not isinstance(port, int):
            problems.add(where, f"port must be an integer in {PORT_MIN}-{PORT_MAX}")
        elif not PORT_MIN <= port <= PORT_MAX:
            problems.add(where, f"port must be an integer in {PORT_MIN}-{PORT_MAX}")

    egress = data.get("egress")
    if "egress" in data and egress not in EGRESS_CLASSES:
        problems.add(where, "egress must be \"internet\" or \"none\"")

    env = data.get("env", {})
    if "env" in data:
        if not isinstance(env, dict):
            problems.add(where, "env must be a table of string values")
        else:
            for key, value in env.items():
                if not isinstance(key, str) or not ENV_NAME.match(key):
                    problems.add(where, f"env name '{key}' must match {ENV_NAME.pattern}")
                if not isinstance(value, str):
                    problems.add(where, f"env value for '{key}' must be a string")

    quota = data.get("quota")
    if "quota" in data:
        if not isinstance(quota, str):
            problems.add(where, "quota must be a string such as \"10G\"")
        else:
            size = quota_bytes(quota)
            ceiling = quota_bytes(QUOTA_CEILING)
            if size is None:
                problems.add(where, "quota must be a whole number with a K, M, G or T unit")
            elif ceiling is not None and size > ceiling:
                problems.add(where, f"quota exceeds the platform ceiling of {QUOTA_CEILING}")

    secrets = data.get("secrets", [])
    if "secrets" in data and not (
        isinstance(secrets, list) and all(isinstance(s, str) and SECRET_NAME.match(s) for s in secrets)
    ):
        problems.add(where, "secrets must be a list of lower-case names")
    elif "secrets" in data:
        check_secrets(name, secrets, where, problems)


def check_secrets(name: str, secrets: list[str], where: str, problems: Problems) -> None:
    """A definition may reference only secrets declared under its own name."""
    if not secrets:
        return
    declared = TENANT_SECRETS.get(name, {})
    if TENANT_SECRETS_MISSING:
        problems.add(where, "secrets reference the tenant SOPS file, but none was given (--secrets)")
        return
    if not isinstance(declared, dict):
        problems.add(where, f"'{name}' is not a table in the tenant SOPS file")
        return
    for secret in sorted(secrets):
        if secret not in declared:
            problems.add(where, f"secret '{secret}' is not declared for '{name}' in the tenant SOPS file")


def load_tenant_secrets(path: Path | None, problems: Problems) -> None:
    global TENANT_SECRETS, TENANT_SECRETS_MISSING
    TENANT_SECRETS = {}
    TENANT_SECRETS_MISSING = path is None
    if path is None:
        return
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except OSError as error:
        problems.add(str(path), f"cannot read the tenant SOPS file: {error.strerror}")
        return
    except json.JSONDecodeError as error:
        problems.add(str(path), f"tenant SOPS file is not valid JSON: {error}")
        return
    apps = document.get("apps", {})
    if not isinstance(apps, dict):
        problems.add(str(path), "tenant SOPS file has no 'apps' table")
        return
    TENANT_SECRETS = apps


TENANT_SECRETS: dict[str, Any] = {}
TENANT_SECRETS_MISSING = True


def validate_root(root: Path, secrets: Path | None) -> Problems:
    problems = Problems()
    load_tenant_secrets(secrets, problems)
    if problems:
        return problems

    apps = root / "apps"
    if not apps.is_dir():
        return problems

    for directory in sorted(p for p in apps.iterdir() if p.is_dir()):
        name = directory.name
        if not APP_NAME.match(name):
            problems.add(str(directory), "app name must be lower-case letters, digits and hyphens")
        definition = directory / "app.toml"
        where = f"apps/{name}/app.toml"
        if not definition.is_file():
            problems.add(f"apps/{name}", "missing app.toml")
            continue
        try:
            data = tomllib.loads(definition.read_text(encoding="utf-8"))
        except tomllib.TOMLDecodeError as error:
            problems.add(where, f"not valid TOML: {error}")
            continue
        except OSError as error:
            problems.add(where, f"cannot read: {error.strerror}")
            continue
        check_definition(name, data, where, problems)

    return problems


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)

    validate = sub.add_parser("validate", help="check every app.toml under <root>/apps")
    validate.add_argument("--root", type=Path, default=Path("."))
    validate.add_argument(
        "--secrets",
        type=Path,
        help="tenant SOPS JSON file; required when a definition references secrets",
    )

    args = parser.parse_args(argv)
    if args.command == "validate":
        secrets = args.secrets
        if secrets is not None and not secrets.is_file():
            print(f"{secrets}: tenant SOPS file not found", file=sys.stderr)
            return 1
        problems = validate_root(args.root, secrets)
        for where, message in problems:
            print(f"{where}: {message}")
        return 1 if problems else 0
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
