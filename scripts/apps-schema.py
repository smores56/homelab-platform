#!/usr/bin/env python3
"""Validate typed app definitions for the `apps` tenant.

A definition is ``homelab-apps/apps/<name>/app.toml`` and may declare only
what the platform is willing to interpret: a digest-pinned image, one
container port, environment values, references to its own named secrets, a
data quota, and an egress class. There is deliberately no field for a host
path, an extra mount, a device, a capability, privileged mode, a socket, a
host or custom network, a published port, a user or an SELinux option, so a
definition cannot express them. Unknown keys are errors at every level.

    scripts/apps-schema.py validate --root <homelab-apps checkout> \
        [--secrets <tenant sops json>]

``validate`` prints ``apps/<name>/app.toml: <problem>`` per problem on stdout
and exits non-zero; it prints nothing when the tree is clean. It is the same
check that smortress re-runs on the fetched commit before rendering, so it
fails closed — a missing ``apps/`` directory is an error, not an empty plan —
and it reads the tenant SOPS file's *key names* only, never a value.

Stdlib only, python 3.11 or later: the image ships one python3 and no
third-party packages.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import tomllib
from pathlib import Path
from collections.abc import Callable
from typing import Any

#: The whole vocabulary of a definition. Anything else is a containment bug,
#: not a feature request.
TOP_LEVEL_KEYS = {"image", "port", "env", "secrets", "quota", "egress"}
REQUIRED_KEYS = ("image", "port", "egress")

EGRESS_CLASSES = {"internet", "none"}

#: Platform-owned ceiling on one app's data directory. The `apps` dataset has
#: its own quota, so this bounds a single app rather than the tenant.
QUOTA_CEILING = "50G"

#: The container port is never published on the host: the platform assigns its
#: own loopback port for the reverse proxy, and rootless podman binds low ports
#: inside the namespace without privilege. Any port the image listens on is
#: therefore legal.
PORT_MIN = 1
PORT_MAX = 65535

#: Control characters are refused everywhere a string is accepted: a newline in
#: an env value is how one definition becomes an extra directive in a rendered
#: unit. `\Z` rather than `$` because `$` also matches before a trailing
#: newline, which would let the same character through a name or a reference.
CONTROL = re.compile(r"[\x00-\x1f\x7f]", re.ASCII)

APP_NAME = re.compile(r"[a-z](?:[a-z0-9-]{0,29}[a-z0-9])?\Z", re.ASCII)
#: A distribution reference with no tag but a digest. Anything that is not
#: part of a repository path or a digest stay out: no `%`, `;`, `$` or space
#: ever reaches podman or a generated `Image=` line.
IMAGE_REF = re.compile(
    r"(?:[a-z0-9]+(?:[._-][a-z0-9]+)*(?:/[a-z0-9]+(?:[._-][a-z0-9]+)*)*)"
    r"(?::[A-Za-z0-9._-]{1,128})?@sha256:[a-f0-9]{64}\Z",
    re.ASCII,
)
ENV_NAME = re.compile(r"[A-Z_][A-Z0-9_]*\Z", re.ASCII)
SECRET_NAME = re.compile(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\Z", re.ASCII)
QUOTA = re.compile(r"([0-9]+)([KMGT])\Z", re.ASCII)

UNIT_BYTES = {"K": 1024, "M": 1024**2, "G": 1024**3, "T": 1024**4}

Problems = list[str]


def quota_bytes(value: str) -> int | None:
    match = QUOTA.match(value)
    if not match:
        return None
    amount, unit = match.groups()
    return int(amount) * UNIT_BYTES[unit]


def has_control(value: str) -> bool:
    return CONTROL.search(value) is not None


def check_definition(
    name: str,
    data: dict[str, Any],
    where: str,
    tenant_secrets: dict[str, Any] | None,
    problems: Problems,
) -> None:
    def add(message: str) -> None:
        problems.append(f"{where}: {message}")

    for key in sorted(set(data) - TOP_LEVEL_KEYS):
        add(f"unknown key '{key}'")
    for key in REQUIRED_KEYS:
        if key not in data:
            add(f"missing required key '{key}'")

    if "image" in data:
        image = data["image"]
        if not isinstance(image, str):
            add("image must be a string")
        elif not IMAGE_REF.match(image):
            add("image must be pinned by digest: <repo>@sha256:<64 hex>")

    if "port" in data:
        port = data["port"]
        if isinstance(port, bool) or not isinstance(port, int):
            add(f"port must be an integer in {PORT_MIN}-{PORT_MAX}")
        elif not PORT_MIN <= port <= PORT_MAX:
            add(f"port must be an integer in {PORT_MIN}-{PORT_MAX}")

    if "egress" in data:
        egress = data["egress"]
        if not isinstance(egress, str) or egress not in EGRESS_CLASSES:
            add('egress must be "internet" or "none"')

    if "env" in data:
        env = data["env"]
        if not isinstance(env, dict):
            add("env must be a table of string values")
        else:
            for key, value in env.items():
                if not ENV_NAME.match(key):
                    add(f"env name '{key}' must match {ENV_NAME.pattern[:-2]}")
                if not isinstance(value, str):
                    add(f"env value for '{key}' must be a string")
                elif has_control(value):
                    add(f"env value for '{key}' must not contain control characters")

    if "quota" in data:
        quota = data["quota"]
        if not isinstance(quota, str):
            add('quota must be a string such as "10G"')
        else:
            size = quota_bytes(quota)
            ceiling = quota_bytes(QUOTA_CEILING)
            if size is None:
                add("quota must be a whole number with a K, M, G or T unit")
            elif ceiling is not None and size > ceiling:
                add(f"quota exceeds the platform ceiling of {QUOTA_CEILING}")

    if "secrets" in data:
        secrets = data["secrets"]
        if not isinstance(secrets, list) or not all(
            isinstance(secret, str) and SECRET_NAME.match(secret) for secret in secrets
        ):
            add("secrets must be a list of lower-case names")
        else:
            check_secrets(name, secrets, tenant_secrets, add)


def check_secrets(
    name: str,
    secrets: list[str],
    tenant_secrets: dict[str, Any] | None,
    add: Callable[[str], None],
) -> None:
    """A definition may reference only secrets declared under its own name."""
    if not secrets:
        return
    if tenant_secrets is None:
        add("secrets reference the tenant SOPS file, but none was given (--secrets)")
        return
    declared = tenant_secrets.get(name, {})
    if not isinstance(declared, dict):
        add(f"'{name}' is not a table in the tenant SOPS file")
        return
    for secret in sorted(secrets):
        if secret not in declared:
            add(f"secret '{secret}' is not declared for '{name}' in the tenant SOPS file")


def load_tenant_secrets(path: Path | None) -> tuple[dict[str, Any] | None, list[str]]:
    problems: Problems = []
    if path is None:
        return None, problems
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except OSError as error:
        return None, [f"{path}: cannot read the tenant SOPS file: {error.strerror}"]
    except ValueError as error:
        return None, [f"{path}: tenant SOPS file is not valid JSON: {error}"]
    if not isinstance(document, dict):
        return None, [f"{path}: tenant SOPS file must be a JSON object"]
    apps = document.get("apps", {})
    if not isinstance(apps, dict):
        return None, [f"{path}: tenant SOPS file has no 'apps' table"]
    return apps, problems


def validate_root(root: Path, secrets: Path | None) -> Problems:
    tenant_secrets, problems = load_tenant_secrets(secrets)
    if problems:
        return problems

    apps = root / "apps"
    if not apps.is_dir():
        # The host re-runs this on a fetched commit; a wrong path or a failed
        # clone must stop the deploy, never render an empty tenant.
        return [f"{root}: no apps/ directory"]

    for directory in sorted(p for p in apps.iterdir() if p.is_dir()):
        name = directory.name
        where = f"apps/{name}/app.toml"
        if not APP_NAME.match(name):
            problems.append(f"{directory}: app name must be lower-case letters, digits and hyphens")
        definition = directory / "app.toml"
        if not definition.is_file():
            problems.append(f"apps/{name}: missing app.toml")
            continue
        try:
            data = tomllib.loads(definition.read_text(encoding="utf-8"))
        except tomllib.TOMLDecodeError as error:
            problems.append(f"{where}: not valid TOML: {error}")
            continue
        except (OSError, ValueError) as error:
            problems.append(f"{where}: cannot read: {error}")
            continue
        check_definition(name, data, where, tenant_secrets, problems)

    return problems


def main(argv: list[str] | None = None) -> int:
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
    if args.command != "validate":
        return 2
    if args.secrets is not None and not args.secrets.is_file():
        print(f"{args.secrets}: tenant SOPS file is not a file", file=sys.stderr)
        return 1
    problems = validate_root(args.root, args.secrets)
    for problem in problems:
        print(problem)
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
