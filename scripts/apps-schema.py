#!/usr/bin/env python3
"""Validate and render typed app definitions for the `apps` tenant.

A definition is ``homelab-apps/apps/<name>/app.toml`` and may declare only
what the platform is willing to interpret: a digest-pinned image, one
container port, environment values, references to its own named secrets, a
data quota, and an egress class. There is deliberately no field for a host
path, an extra mount, a device, a capability, privileged mode, a socket, a
host or custom network, a published port, a user or an SELinux option, so a
definition cannot express them. Unknown keys are errors at every level.

    scripts/apps-schema.py validate --root <homelab-apps checkout> \
        [--secrets <tenant sops json>]
    scripts/apps-schema.py render --root <homelab-apps checkout> --out <dir> \
        [--secrets <tenant sops json>] [--check]

``validate`` prints ``apps/<name>/app.toml: <problem>`` per problem on stdout
and exits non-zero; it prints nothing when the tree is clean. It is the same
check that smortress re-runs on the fetched commit before rendering, so it
fails closed — a missing ``apps/`` directory is an error, not an empty plan —
and it reads the tenant SOPS file's *key names* only, never a value.

``render`` emits one rootless Podman Quadlet per app and ``plan.json``; it
validates first and writes nothing when any definition is rejected. The
Quadlets are user units for the unprivileged ``apps`` user: they publish on
loopback only, receive pasta networking for ``egress = "internet"`` and the
tenant's internal (routeless) network otherwise, mount exactly their own data
directory read-write,
drop every capability, run a read-only root with no-new-privileges, carry
a per-app SELinux MCS level, and carry their own memory, CPU and task limits
rather than inheriting them from a ``user-<uid>.slice`` drop-in that stops
applying when sysusers allocates a different id. The tenant's prerequisites are
not dependencies of these units: a user unit cannot resolve a system unit, so a
``Requires=smortress-apps-user.service`` here fails the unit outright
("Unit ... not found"). What gates the tenant is the prerequisites' own
``Before=systemd-logind.service``, which is what orders them ahead of the
lingering user manager that starts these. ``plan.json`` is what the deploy, the
Serve wiring and the quota applier read: the loopback port, the base path, the
data path, the ZFS project id and the quota.

Stdlib only, python 3.11 or later: the image ships one python3 and no
third-party packages.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import tempfile
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
#: A rendered `Environment=` line carries the value verbatim. Quadlet splits on
#: whitespace, a trailing backslash continues the line (dropping the next
#: directive), `%` is a systemd specifier, and quotes and `#` change how the
#: generator reads the value. Refuse the characters rather than escape them:
#: an app that needs them needs a platform change, not a definition.
ENV_FORBIDDEN = re.compile(r"[\s\\\"'`%#]", re.ASCII)

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

#: Platform-owned defaults. A definition cannot change them, and the schema
#: has no field that would: these are policy, not configuration.
DATA_ROOT = Path("/srv/apps")
QUOTA_DEFAULT = "1G"
PROJECT_MIN = 1
PROJECT_MAX = 2**32 - 1
LOOPBACK_BASE = 20000
LOOPBACK_SPAN = 10000
#: The tenant network for `egress = "none"`. Podman discards published ports on
#: `--network=none`, so no-egress apps get an internal network instead: they can
#: reach nothing outside their own namespace and the loopback publish still
#: exists for Serve.
#: First line of everything this renderer writes, so it can tell its own output
#: from a foreign unit in the target directory.
MARKER = "# Rendered from apps/"
INTERNAL_NETWORK = "smortress-apps"
APPS_POLICY = "/usr/share/smortress/apps-policy.json"
#: Resource limits are properties of each rendered app unit. They used to live in
#: a drop-in on `user-<uid>.slice`, which stopped applying the moment sysusers
#: allocated a different id; per app they cannot. MemoryHigh is the ceiling the
#: kernel reclaims against and MemoryMax the hard one, so the tenant's total is
#: bounded by what it runs rather than by a slice nobody could name.
MEMORY_HIGH = "768M"
MEMORY_MAX = "1G"
TASKS_MAX = 256
CPU_QUOTA = "200%"
TIMEOUT_START = 120

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
                elif ENV_FORBIDDEN.search(value):
                    add(
                        f"env value for '{key}' must not contain whitespace, quotes, "
                        "a backslash, '%' or '#'"
                    )

    if "quota" in data:
        quota = data["quota"]
        if not isinstance(quota, str):
            add('quota must be a string such as "10G"')
        else:
            size = quota_bytes(quota)
            ceiling = quota_bytes(QUOTA_CEILING)
            if size is None:
                add("quota must be a whole number with a K, M, G or T unit")
            elif size <= 0:
                add("quota must be greater than zero")
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


def scan(root: Path, secrets: Path | None) -> tuple[Problems, list[tuple[str, dict[str, Any]]]]:
    """Validate the tree and return the parsed definitions it accepted.

    Rendering uses these definitions rather than re-reading the files, so a
    definition cannot change between the check and the write.
    """
    tenant_secrets, problems = load_tenant_secrets(secrets)
    if problems:
        return problems, []

    apps = root / "apps"
    if not apps.is_dir():
        # The host re-runs this on a fetched commit; a wrong path or a failed
        # clone must stop the deploy, never render an empty tenant.
        return [f"{root}: no apps/ directory"], []

    definitions: list[tuple[str, dict[str, Any]]] = []
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
        definitions.append((name, data))

    return problems, definitions


def validate_root(root: Path, secrets: Path | None) -> Problems:
    problems, _ = scan(root, secrets)
    return problems


def stable_ports(names: list[str]) -> dict[str, int]:
    """One loopback port per app, stable while other apps come and go.

    The name is hashed rather than indexed, so adding or removing an unrelated
    app does not move a port except when a new name's start collides with an
    existing one; the probe then walks in sorted-name order, so the result
    stays deterministic and the plan is regenerated in one pass.
    """
    taken: set[int] = set()
    ports: dict[str, int] = {}
    for name in sorted(names):
        start = int.from_bytes(hashlib.sha256(name.encode("utf-8")).digest()[:4], "big")
        for step in range(LOOPBACK_SPAN):
            candidate = LOOPBACK_BASE + (start + step) % LOOPBACK_SPAN
            if candidate not in taken:
                taken.add(candidate)
                ports[name] = candidate
                break
        else:
            raise RuntimeError("the loopback port range is exhausted")
    return ports


def project_ids(names: list[str]) -> dict[str, int]:
    """One ZFS project id per app, stable while other apps come and go.

    Quota accounting lives on the project id, so it should not move when an
    unrelated app appears or disappears. The hash starts the search, which
    makes that true except when a new name's start collides with an existing
    one; the probe then walks in sorted-name order for determinism, and the
    quota applier refuses to reuse an id that is still stamped on data.
    """
    used: set[int] = set()
    ids: dict[str, int] = {}
    for name in sorted(names):
        start = int.from_bytes(hashlib.sha256(b"project:" + name.encode("utf-8")).digest()[:4], "big")
        for step in range(PROJECT_MAX):
            candidate = PROJECT_MIN + (start + step) % (PROJECT_MAX - PROJECT_MIN + 1)
            if candidate not in used:
                used.add(candidate)
                ids[name] = candidate
                break
        else:
            raise RuntimeError("the project id range is exhausted")
    return ids


def mcs_levels(names: list[str]) -> dict[str, tuple[int, int]]:
    """Two SELinux MCS categories per app, distinct and stable.

    Distinct matters: two apps sharing a pair could read each other's files
    under the same UID. The hash starts the search so nothing moves when an
    unrelated app appears, and the probe runs in sorted-name order.
    """
    used: set[tuple[int, int]] = set()
    levels: dict[str, tuple[int, int]] = {}
    for name in sorted(names):
        digest = hashlib.sha256(b"mcs:" + name.encode("utf-8")).digest()
        first0 = 1 + int.from_bytes(digest[:2], "big") % 512
        second0 = 1 + int.from_bytes(digest[2:4], "big") % 512
        for offset in range(512 * 512):
            first = 1 + (first0 - 1 + offset // 512) % 512
            second = 1 + (second0 - 1 + offset % 512) % 512
            if first != second and (first, second) not in used:
                used.add((first, second))
                levels[name] = (first, second)
                break
        else:
            raise RuntimeError("the MCS category range is exhausted")
    return levels


def network_for(egress: str) -> str:
    """The podman network the container joins, as the plan records it."""
    return "pasta" if egress == "internet" else INTERNAL_NETWORK


def quadlet_network(egress: str) -> str:
    """The value a rendered unit uses for `Network=`.

    Quadlet links a container to a Quadlet network only when the reference
    ends in `.network`; a bare name is looked up as an already-existing podman
    network, so the unit that creates it is never pulled in and the container
    fails with "network not found". `NetworkName=` in the `.network` unit keeps
    the network itself named `INTERNAL_NETWORK`, which is what `plan.json`
    records and what the deploy expects to find.
    """
    return network_for(egress) if egress == "internet" else f"{INTERNAL_NETWORK}.network"


def render_unit(name: str, data: dict[str, Any], loopback: int, level: tuple[int, int]) -> str:
    first, second = level
    lines = [
        f"# Rendered from apps/{name}/app.toml by scripts/apps-schema.py. Do not edit:",
        "# the deploy renders this again from the fetched commit and rejects drift.",
        "[Unit]",
        f"Description=apps tenant app: {name}",
        # Not a Condition: a missing mount must fail the unit loudly, not skip it.
        f"AssertPathIsMountPoint={DATA_ROOT}",
        "",
        "[Container]",
        f"Image={data['image']}",
        f"ContainerName=smortress-app-{name}",
        f"Network={quadlet_network(data['egress'])}",
        f"PublishPort=127.0.0.1:{loopback}:{data['port']}",
        f"Volume={DATA_ROOT}/{name}:/data:Z",
        "ReadOnly=true",
        # The tenant may run any digest-pinned image; the schema refuses tags.
        # The policy is root-owned and named here, so the tenant cannot widen
        # or narrow it by editing its own home.
        f"PodmanArgs=--signature-policy={APPS_POLICY}",
        "NoNewPrivileges=true",
        "DropCapability=ALL",
        f"SecurityLabelLevel=s0:c{first},c{second}",
    ]
    for key in sorted(data.get("env", {})):
        lines.append(f"Environment={key}={data['env'][key]}")
    for secret in sorted(data.get("secrets", [])):
        lines.append(f"Secret=app-{name}-{secret},type=mount,target=/run/secrets/{secret}")
    lines += [
        "",
        "[Service]",
        "Restart=on-failure",
        f"TimeoutStartSec={TIMEOUT_START}",
        f"MemoryHigh={MEMORY_HIGH}",
        f"MemoryMax={MEMORY_MAX}",
        f"TasksMax={TASKS_MAX}",
        f"CPUQuota={CPU_QUOTA}",
        "",
        "[Install]",
        "WantedBy=default.target",
    ]
    return "\n".join(lines) + "\n"


def render_network() -> str:
    return (
        f"{MARKER} The tenant internal network for egress = \"none\". Do not edit.\n"
        "[Unit]\n"
        "Description=apps tenant internal network\n"
        "\n"
        "[Network]\n"
        # The unit stem would otherwise become `systemd-smortress-apps`, while
        # every consumer names the network `smortress-apps`.
        f"NetworkName={INTERNAL_NETWORK}\n"
        # No route out of the namespace; the loopback publish for Serve remains.
        "Internal=true\n"
    )


def render_plan(
    name: str, data: dict[str, Any], loopback: int, level: tuple[int, int], project: int
) -> dict[str, Any]:
    first, second = level
    secrets = sorted(data.get("secrets", []))
    return {
        "basePath": f"/apps/{name}",
        "containerPort": data["port"],
        "dataPath": str(DATA_ROOT / name),
        "egress": data["egress"],
        "image": data["image"],
        "loopbackPort": loopback,
        "mcs": f"s0:c{first},c{second}",
        "network": network_for(data["egress"]),
        "projectId": project,
        "quota": data.get("quota", QUOTA_DEFAULT),
        "secretNames": {secret: f"app-{name}-{secret}" for secret in secrets},
        "unitName": f"{name}.container",
    }


def render_files(definitions: list[tuple[str, dict[str, Any]]]) -> dict[str, str]:
    names = [name for name, _ in definitions]
    ports = stable_ports(names)
    levels = mcs_levels(names)
    projects = project_ids(names)
    files: dict[str, str] = {}
    plan: dict[str, Any] = {}
    for name, data in definitions:
        files[f"{name}.container"] = render_unit(name, data, ports[name], levels[name])
        plan[name] = render_plan(name, data, ports[name], levels[name], projects[name])
    if any(data["egress"] == "none" for _, data in definitions):
        files[f"{INTERNAL_NETWORK}.network"] = render_network()
    files["plan.json"] = json.dumps({"version": 1, "apps": plan}, indent=2, sort_keys=True) + "\n"
    return files


def verify_plan(plan: Path) -> list[str]:
    """Re-validate a rendered plan, independently of how it was produced.

    The plan is root-owned and every consumer acts on it, so each of them runs
    this against the file it is about to trust: a foreign path, a port outside
    the platform range, a duplicate project id, a quota above the ceiling, or a
    non-object entry must fail closed. Prints one problem per line.
    """
    problems: list[str] = []

    def add(message: str) -> None:
        problems.append(f"{plan}: {message}")

    try:
        data = json.loads(plan.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        add(f"not readable as JSON: {exc}")
        return problems
    if not isinstance(data, dict):
        add("not a JSON object")
        return problems
    apps = data.get("apps")
    if not isinstance(apps, dict):
        add("has no apps object")
        return problems

    projects: dict[int, str] = {}
    for name in sorted(apps):
        where = f"apps.{name}"
        entry = apps[name]
        if not isinstance(entry, dict):
            add(f"{where} is not an object")
            continue
        if not APP_NAME.fullmatch(name):
            add(f"{where} is not a valid app name")
        base = entry.get("basePath")
        if base != f"/apps/{name}":
            add(f"{where}.basePath is {base!r}, want /apps/{name}")
        port = entry.get("loopbackPort")
        if isinstance(port, bool) or not isinstance(port, int):
            add(f"{where}.loopbackPort is not an integer: {port!r}")
        elif not LOOPBACK_BASE <= port < LOOPBACK_BASE + LOOPBACK_SPAN:
            add(f"{where}.loopbackPort {port} is outside {LOOPBACK_BASE}-{LOOPBACK_BASE + LOOPBACK_SPAN - 1}")
        project = entry.get("projectId")
        if isinstance(project, bool) or not isinstance(project, int):
            add(f"{where}.projectId is not an integer: {project!r}")
        elif not 1 <= project <= 2**32 - 1:
            add(f"{where}.projectId {project} is out of range")
        elif project in projects:
            add(f"{where}.projectId {project} is also used by {projects[project]}")
        else:
            projects[project] = name
        quota = entry.get("quota")
        if not isinstance(quota, str) or not QUOTA.fullmatch(quota):
            add(f"{where}.quota is not a quota: {quota!r}")
        elif quota_bytes(quota) is None or quota_bytes(quota) <= 0:
            add(f"{where}.quota is not a positive size: {quota!r}")
        elif quota_bytes(quota) > quota_bytes(QUOTA_CEILING):
            add(f"{where}.quota {quota} exceeds the platform ceiling {QUOTA_CEILING}")
        image = entry.get("image")
        if not isinstance(image, str) or not IMAGE_REF.fullmatch(image):
            add(f"{where}.image is not a digest-pinned reference: {image!r}")
        data_path = entry.get("dataPath")
        if data_path != str(DATA_ROOT / name):
            add(f"{where}.dataPath is {data_path!r}, want {DATA_ROOT / name}")
        network = entry.get("network")
        if network not in {"pasta", INTERNAL_NETWORK}:
            add(f"{where}.network is not a tenant network: {network!r}")
        mcs = entry.get("mcs")
        if not isinstance(mcs, str) or not re.fullmatch(r"s0:c[0-9]+,c[0-9]+", mcs):
            add(f"{where}.mcs is not an MCS level: {mcs!r}")
        secrets = entry.get("secretNames")
        if not isinstance(secrets, dict) or not all(
            isinstance(key, str) and isinstance(value, str) for key, value in secrets.items()
        ):
            add(f"{where}.secretNames is not a name map")
        unit = entry.get("unitName")
        if unit != f"{name}.container":
            add(f"{where}.unitName is {unit!r}, want {name}.container")
    return problems


def is_rendered(path: Path) -> bool:
    try:
        with path.open(encoding="utf-8") as handle:
            return handle.readline().startswith(MARKER)
    except (OSError, ValueError):
        return False


def owned(path: Path) -> bool:
    """A file this renderer wrote: a managed suffix with the rendered marker."""
    return path.suffix in {".container", ".network"} and is_rendered(path)


def render(root: Path, out: Path, secrets: Path | None, check: bool) -> int:
    problems, definitions = scan(root, secrets)
    if problems:
        # A rejected tree renders nothing: a partial tenant is worse than none.
        for problem in problems:
            print(problem)
        return 1
    if not definitions:
        print(f"{root}/apps: no app definitions; refusing to render an empty tenant", file=sys.stderr)
        return 1

    files = render_files(definitions)

    # The deploy writes as root into a directory the tenant owns; a symlink
    # there could redirect the write into the rootful generator's directory.
    if out.is_symlink():
        print(f"{out}: --out must not be a symlink", file=sys.stderr)
        return 1
    if out.exists() and not out.is_dir():
        print(f"{out}: --out must be a directory", file=sys.stderr)
        return 1

    if check:
        drifted = []
        for filename, content in sorted(files.items()):
            target = out / filename
            if not target.is_file():
                drifted.append(f"{filename}: missing")
            elif target.read_text(encoding="utf-8") != content:
                drifted.append(f"{filename}: differs")
        if out.is_dir():
            for extra in sorted(p for p in out.iterdir() if p.suffix in {".container", ".network"}):
                if extra.name not in files:
                    drifted.append(f"{extra.name}: no longer defined")
        for line in drifted:
            print(f"drift: {line}")
        return 1 if drifted else 0

    # Preflight before touching anything: a managed name that is not a regular
    # file, or a unit in the target directory this renderer did not write, is an
    # error rather than something to overwrite or delete.
    for filename in files:
        target = out / filename
        if target.exists() and not target.is_file():
            print(f"{target}: exists and is not a regular file", file=sys.stderr)
            return 1
    stale: list[Path] = []
    if out.is_dir():
        for entry in sorted(out.iterdir()):
            if entry.suffix not in {".container", ".network"} or entry.name in files:
                continue
            if not owned(entry):
                print(f"{entry}: not rendered by this tool; refusing to manage {out}", file=sys.stderr)
                return 1
            stale.append(entry)

    out.mkdir(parents=True, exist_ok=True)
    for filename, content in sorted(files.items()):
        target = out / filename
        handle = tempfile.NamedTemporaryFile(
            "w", encoding="utf-8", dir=out, prefix=f".{filename}.", delete=False
        )
        try:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        finally:
            handle.close()
        os.replace(handle.name, target)
    for entry in stale:
        entry.unlink()
    return 0


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

    render_cmd = sub.add_parser("render", help="write one Quadlet per app and plan.json")
    render_cmd.add_argument("--root", type=Path, default=Path("."))
    render_cmd.add_argument("--out", type=Path, required=True)
    render_cmd.add_argument(
        "--secrets",
        type=Path,
        help="tenant SOPS JSON file; required when a definition references secrets",
    )
    render_cmd.add_argument("--check", action="store_true", help="fail on drift instead of writing")

    verify_cmd = sub.add_parser("verify-plan", help="re-validate a rendered plan.json")
    verify_cmd.add_argument("--plan", type=Path, required=True)

    args = parser.parse_args(argv)
    if args.command in {"validate", "render"} and args.secrets is not None and not args.secrets.is_file():
        print(f"{args.secrets}: tenant SOPS file is not a file", file=sys.stderr)
        return 1
    if args.command == "validate":
        problems = validate_root(args.root, args.secrets)
        for problem in problems:
            print(problem)
        return 1 if problems else 0
    if args.command == "render":
        return render(args.root, args.out, args.secrets, args.check)
    if args.command == "verify-plan":
        problems = verify_plan(args.plan)
        for problem in problems:
            print(problem)
        return 1 if problems else 0
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
