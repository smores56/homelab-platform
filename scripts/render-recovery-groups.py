#!/usr/bin/env python3
"""Render the backup plan from the recovery inventory.

One model: every recovery group owns one restic repository per tier
(``<repository_root>/<group id>``) and one subtree of the single recursive ZFS
snapshot. ``recovery/inventory.yml`` remains the only source of dataset names
and mount points; ``recovery/backup.yml`` adds display paths, cadences, and
tiers.

The script writes the public page manifest
``deploy/data-plane/config/recovery-groups.json``, can print the host plan the
host installs as ``/etc/homelab/backup.json``, and fails on drift:

    scripts/render-recovery-groups.py            # write the public manifest
    scripts/render-recovery-groups.py --check    # fail when it drifted
    scripts/render-recovery-groups.py --host-plan

Stdlib only: the data-plane test suite runs on a bare ``python3`` with no
PyYAML, so a small, strict YAML-subset reader handles these two files. It
refuses constructs it does not understand instead of guessing.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
ALL_VARS = ROOT / "recovery" / "inventory.yml"
BACKUP_VARS = ROOT / "recovery" / "backup.yml"
TARGET = ROOT / "deploy" / "data-plane" / "config" / "recovery-groups.json"

TIER_NAMES = ["nvme", "hdd", "r2"]
CADENCES = {"fast", "media"}
GROUP_SPEC_KEYS = {"label", "path", "cadence", "tiers"}
#: The recovery page refuses anything else as a group id.
GROUP_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
#: The page also refuses empty labels and control characters in them.
CONTROL_CHARS = re.compile(r"[\x00-\x1f\x7f]")
RETIRED_BACKUP_VARS = {
    "backup_domains",
    "backup_destinations",
    "backup_manifest_dir",
    "backup_pending_host_groups",
    "backup_repositories",
    "backup_request_archive",
    "backup_request_dir",
}
RETIRED_GROUP_KEYS = {"databases", "fence", "checkpoint", "resume", "writer"}


class YamlSubsetError(ValueError):
    """The file uses YAML this script intentionally does not support."""


def _strip_comment(line: str) -> str:
    out: list[str] = []
    quote = ""
    escaped = False
    for index, char in enumerate(line):
        if quote:
            out.append(char)
            if escaped:
                escaped = False
            elif char == "\\" and quote == '"':
                escaped = True
            elif char == quote:
                quote = ""
            continue
        if char in "\"'":
            quote = char
            out.append(char)
        elif char == "#" and (index == 0 or line[index - 1].isspace()):
            break
        else:
            out.append(char)
    return "".join(out).rstrip()


def _unquote(text: str) -> str:
    if len(text) >= 2 and text[0] == text[-1] and text[0] in "\"'":
        body = text[1:-1]
        if text[0] == "'":
            return body.replace("''", "'")
        return (
            body.replace('\\"', '"')
            .replace("\\n", "\n")
            .replace("\\t", "\t")
            .replace("\\\\", "\\")
        )
    return text


def _scalar(text: str) -> Any:
    text = text.strip()
    if not text:
        return None
    if text[0] in "[{":
        return _flow(text)
    if len(text) >= 2 and text[0] == text[-1] and text[0] in "\"'":
        return _unquote(text)
    if text.lower() in {"true", "false"}:
        return text.lower() == "true"
    if text.lower() in {"null", "~"}:
        return None
    if re.fullmatch(r"-?\d+", text):
        return int(text)
    if re.fullmatch(r"-?\d+\.\d+", text):
        return float(text)
    return text


def _split_flow(text: str) -> list[str]:
    body = text[1:-1]
    parts: list[str] = []
    depth = 0
    quote = ""
    current: list[str] = []
    for char in body:
        if quote:
            current.append(char)
            if char == quote:
                quote = ""
            continue
        if char in "\"'":
            quote = char
            current.append(char)
        elif char in "[{":
            depth += 1
            current.append(char)
        elif char in "]}":
            depth -= 1
            current.append(char)
        elif char == "," and depth == 0:
            parts.append("".join(current).strip())
            current = []
        else:
            current.append(char)
    if current:
        parts.append("".join(current).strip())
    return [part for part in parts if part]


def _flow(text: str) -> Any:
    text = text.strip()
    if text.startswith("[") and text.endswith("]"):
        return [_scalar(item) for item in _split_flow(text)]
    if text.startswith("{") and text.endswith("}"):
        result: dict[str, Any] = {}
        for item in _split_flow(text):
            key, _, value = item.partition(":")
            result[_unquote(key.strip())] = _scalar(value)
        return result
    raise YamlSubsetError(f"unsupported flow value: {text[:40]}")


def _looks_like_pair(text: str) -> bool:
    quote = ""
    for index, char in enumerate(text):
        if quote:
            if char == quote:
                quote = ""
            continue
        if char in "\"'":
            quote = char
        elif char == ":" and (index + 1 == len(text) or text[index + 1] == " "):
            return index > 0
        elif char in "[{":
            return False
    return False


def _split_pair(text: str) -> tuple[str, str]:
    quote = ""
    for index, char in enumerate(text):
        if quote:
            if char == quote:
                quote = ""
            continue
        if char in "\"'":
            quote = char
        elif char == ":" and (index + 1 == len(text) or text[index + 1] == " "):
            return _unquote(text[:index].strip()), text[index + 1 :].strip()
    raise YamlSubsetError(f"not a mapping entry: {text[:40]}")


def _read_lines(text: str) -> list[tuple[int, str]]:
    lines: list[tuple[int, str]] = []
    for raw in text.splitlines():
        stripped = _strip_comment(raw)
        if not stripped.strip() or stripped.strip() in {"---", "..."}:
            continue
        indent = len(stripped) - len(stripped.lstrip(" "))
        if "\t" in stripped[:indent]:
            raise YamlSubsetError("tabs are not valid indentation")
        lines.append((indent, stripped[indent:]))
    return lines


def _block_scalar(
    lines: list[tuple[int, str]], index: int, indent: int, marker: str
) -> tuple[str, int]:
    chunks: list[str] = []
    while index < len(lines) and lines[index][0] > indent:
        chunks.append(lines[index][1])
        index += 1
    if marker.startswith(">"):
        value = " ".join(chunk for chunk in chunks if chunk)
    else:
        value = "\n".join(chunks)
    if not marker.endswith("-"):
        value += "\n"
    return value, index


def _parse_block(
    lines: list[tuple[int, str]], index: int, indent: int
) -> tuple[Any, int]:
    if lines[index][1].startswith("- "):
        return _parse_sequence(lines, index, indent)
    return _parse_mapping(lines, index, indent)


def _parse_mapping(
    lines: list[tuple[int, str]], index: int, indent: int
) -> tuple[dict[str, Any], int]:
    result: dict[str, Any] = {}
    while index < len(lines) and lines[index][0] == indent:
        content = lines[index][1]
        if content.startswith("- "):
            raise YamlSubsetError("sequence entry inside a mapping")
        key, rest = _split_pair(content)
        index += 1
        if rest[:1] in {">", "|"}:
            result[key], index = _block_scalar(lines, index, indent, rest)
        elif rest:
            result[key] = _scalar(rest)
        elif index < len(lines) and lines[index][0] > indent:
            result[key], index = _parse_block(lines, index, lines[index][0])
        else:
            result[key] = None
    if index < len(lines) and lines[index][0] > indent:
        raise YamlSubsetError(f"unexpected indentation near {lines[index][1][:40]}")
    return result, index


def _parse_sequence(
    lines: list[tuple[int, str]], index: int, indent: int
) -> tuple[list[Any], int]:
    result: list[Any] = []
    while index < len(lines) and lines[index][0] == indent:
        content = lines[index][1]
        if not content.startswith("- "):
            break
        rest = content[2:].strip()
        index += 1
        if not rest:
            if index < len(lines) and lines[index][0] > indent:
                value, index = _parse_block(lines, index, lines[index][0])
            else:
                value = None
            result.append(value)
            continue
        if _looks_like_pair(rest):
            key, value_text = _split_pair(rest)
            item: dict[str, Any] = {}
            if value_text[:1] in {">", "|"}:
                item[key], index = _block_scalar(lines, index, indent, value_text)
            elif value_text:
                item[key] = _scalar(value_text)
            elif index < len(lines) and lines[index][0] > indent + 1:
                item[key], index = _parse_block(lines, index, lines[index][0])
            else:
                item[key] = None
            while index < len(lines) and lines[index][0] > indent:
                nested_indent = lines[index][0]
                nested, index = _parse_mapping(lines, index, nested_indent)
                item.update(nested)
            result.append(item)
        else:
            result.append(_scalar(rest))
    return result, index


def load_yaml(path: str | Path) -> Any:
    """Load the strict YAML subset used by the recovery inventory."""

    lines = _read_lines(Path(path).read_text(encoding="utf-8"))
    if not lines:
        return {}
    value, index = _parse_block(lines, 0, lines[0][0])
    if index != len(lines):
        raise YamlSubsetError(f"trailing content near {lines[index][1][:40]}")
    return value


def resolve_templates(value: Any, variables: dict[str, Any]) -> Any:
    """Resolve simple ``{{ var }}`` references, as the inventory expects them."""

    if isinstance(value, dict):
        return {key: resolve_templates(item, variables) for key, item in value.items()}
    if isinstance(value, list):
        return [resolve_templates(item, variables) for item in value]
    if isinstance(value, str):
        pattern = re.compile(r"\{\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*\}\}")

        def replace(match: re.Match[str]) -> str:
            name = match.group(1)
            if name not in variables:
                raise YamlSubsetError(f"unknown template variable {name!r}")
            return str(variables[name])

        if "{%" in value:
            return value
        return pattern.sub(replace, value)
    return value


def load_group_vars() -> tuple[dict[str, Any], dict[str, Any]]:
    all_raw = load_yaml(ALL_VARS)
    all_vars = resolve_templates(all_raw, all_raw)
    backup_raw = load_yaml(BACKUP_VARS)
    backup_vars = resolve_templates(backup_raw, {**all_vars, **backup_raw})
    return all_vars, backup_vars


def canonical_id(name: str) -> str:
    return name.replace("_", "-")


def expected_group_ids(
    all_vars: dict[str, Any], backup_vars: dict[str, Any]
) -> list[str]:
    host = [canonical_id(name) for name in all_vars["recovery_inventory"]]
    host_paths = [row["id"] for row in all_vars.get("backup_host_paths", [])]
    return host + host_paths


def tier_roots(backup_vars: dict[str, Any]) -> dict[str, str]:
    tiers = backup_vars["backup_tiers"]
    if not isinstance(tiers, list):
        raise SystemExit("backup_tiers must be a list")
    roots = {}
    for tier in tiers:
        name = tier.get("name")
        root = tier.get("repository_root")
        if name in roots:
            raise SystemExit(f"backup_tiers repeats tier {name!r}")
        if not name or not root:
            raise SystemExit("every backup tier needs a name and repository_root")
        roots[name] = root
    if list(roots) != TIER_NAMES:
        raise SystemExit("backup_tiers must be exactly nvme, hdd, r2 in order")
    for name, root in roots.items():
        if name != "r2" and not root.startswith("/"):
            raise SystemExit(f"local tier {name!r} needs an absolute repository_root")
        if name == "r2" and not root.startswith("s3:"):
            raise SystemExit("the r2 tier needs an s3: repository_root")
    return roots


def group_rows(all_vars: dict[str, Any], group_id: str) -> list[dict[str, Any]]:
    inventory_key = group_id.replace("-", "_")
    return [
        row
        for row in all_vars["zfs_datasets"]
        if row.get("recovery_group") == inventory_key
    ]


def safe_path(path: Any) -> str:
    text = str(path or "")
    if not text or text.startswith("/"):
        raise SystemExit(f"group path {text!r} must be relative")
    parts = text.split("/")
    if any(part in {"", ".", ".."} for part in parts):
        raise SystemExit(f"group path {text!r} is not a clean relative path")
    return text


def validate(all_vars: dict[str, Any], backup_vars: dict[str, Any]) -> list[str]:
    """Validate the shared plan; return the ordered group ids."""

    retired = sorted(RETIRED_BACKUP_VARS & set(backup_vars))
    if retired:
        raise SystemExit("recovery/backup.yml still declares retired vars: " + ", ".join(retired))
    order = expected_group_ids(all_vars, backup_vars)
    if len(order) != len(set(order)):
        raise SystemExit("backup group ids are not unique")

    roots = tier_roots(backup_vars)
    specs = backup_vars["backup_group_specs"]
    if sorted(specs) != sorted(order):
        extra = sorted(set(specs) - set(order))
        missing = sorted(set(order) - set(specs))
        raise SystemExit(
            "backup_group_specs does not match the inventory"
            + (f"; unknown {', '.join(extra)}" if extra else "")
            + (f"; missing {', '.join(missing)}" if missing else "")
        )
    cadences = backup_vars["backup_cadences"]
    if set(cadences) != CADENCES:
        raise SystemExit("backup_cadences must be exactly fast and media")

    host_paths = {row["id"]: row["path"] for row in all_vars.get("backup_host_paths", [])}
    for group_id in order:
        spec = specs[group_id]
        if not GROUP_ID.fullmatch(group_id):
            raise SystemExit(
                f"backup group id {group_id!r} is not a valid manifest id"
            )
        if not isinstance(spec, dict):
            raise SystemExit(f"backup_group_specs.{group_id} must be a mapping")
        label = group_label(group_id, spec)
        if not label.strip():
            raise SystemExit(f"backup_group_specs.{group_id} needs a non-empty label")
        if CONTROL_CHARS.search(label):
            raise SystemExit(
                f"backup_group_specs.{group_id} label has a control character"
            )
        unknown = set(spec) - GROUP_SPEC_KEYS
        if unknown:
            raise SystemExit(
                f"backup_group_specs.{group_id} declares retired keys: "
                + ", ".join(sorted(unknown))
            )
        retired_keys = RETIRED_GROUP_KEYS & set(spec)
        if retired_keys:
            raise SystemExit(
                f"backup_group_specs.{group_id} declares retired keys: "
                + ", ".join(sorted(retired_keys))
            )
        path = safe_path(spec.get("path"))
        if spec.get("cadence") not in CADENCES:
            raise SystemExit(f"backup_group_specs.{group_id} cadence must be fast or media")
        tiers = spec.get("tiers")
        if not isinstance(tiers, list) or not tiers:
            raise SystemExit(f"backup_group_specs.{group_id} has no tiers")
        if [tier for tier in tiers if tier not in roots]:
            raise SystemExit(
                f"backup_group_specs.{group_id} names an unknown tier"
            )
        # The public page restores from the offsite copy; a group without r2
        # would otherwise be published with an r2 repo it never receives.
        if "r2" not in tiers:
            raise SystemExit(
                f"backup_group_specs.{group_id} must include the r2 tier"
            )
        if group_id in host_paths:
            if path != host_paths[group_id].lstrip("/"):
                raise SystemExit(
                    f"backup_group_specs.{group_id} path must show {host_paths[group_id]}"
                )
            continue
        rows = group_rows(all_vars, group_id)
        if not rows:
            raise SystemExit(
                f"recovery_inventory group {group_id!r} has no zfs_datasets rows; "
                "declare the dataset in recovery/inventory.yml"
            )
        for row in rows:
            mountpoint = row["mountpoint"]
            if mountpoint != "/" + path and not mountpoint.startswith("/" + path + "/"):
                raise SystemExit(
                    f"{mountpoint} is outside the {group_id} subtree /{path}"
                )

    for inventory_key in all_vars["recovery_inventory"]:
        if not group_rows(all_vars, canonical_id(inventory_key)):
            raise SystemExit(
                f"recovery_inventory group {inventory_key!r} has no zfs_datasets rows"
            )

    password_file = str(backup_vars["backup_password_file"])
    password_root = str(backup_vars["backup_password_root"]).rstrip("/")
    if not re.fullmatch(re.escape(password_root) + r"/[a-z0-9-]+\.password", password_file):
        raise SystemExit(
            f"one shared password file must live under {password_root}: {password_file}"
        )
    if not str(backup_vars["backup_snapshot_dataset"]).strip():
        raise SystemExit("backup_snapshot_dataset must name the data pool root")
    if not str(backup_vars["backup_snapshot_root"]).startswith("/run/"):
        raise SystemExit("backup_snapshot_root must be a stable /run path")
    return order


def group_label(group_id: str, spec: dict[str, Any]) -> str:
    if spec.get("label"):
        return str(spec["label"])
    return group_id.replace("-", " ").replace("_", " ").capitalize()


def build_recovery_groups(
    all_vars: dict[str, Any], backup_vars: dict[str, Any]
) -> dict[str, Any]:
    """The public, credential-free manifest the recovery page reads."""

    order = validate(all_vars, backup_vars)
    roots = tier_roots(backup_vars)
    specs = backup_vars["backup_group_specs"]
    groups = []
    for group_id in order:
        spec = specs[group_id]
        groups.append(
            {
                "id": group_id,
                "label": group_label(group_id, spec),
                "repo": f"{roots['r2'].rstrip('/')}/{group_id}",
                "data_root": "/" + str(spec["path"]),
            }
        )
    return {"schema_version": 1, "groups": groups}


def build_host_plan(
    all_vars: dict[str, Any], backup_vars: dict[str, Any]
) -> dict[str, Any]:
    """The plan the host installs as /etc/homelab/backup.json."""

    order = validate(all_vars, backup_vars)
    specs = backup_vars["backup_group_specs"]
    live_ids = {row["id"] for row in all_vars.get("backup_host_paths", [])}
    tiers = [
        {"name": tier["name"], "repository_root": tier["repository_root"]}
        for tier in backup_vars["backup_tiers"]
    ]
    return {
        "schema_version": int(backup_vars["backup_schema_version"]),
        "snapshot_dataset": str(backup_vars["backup_snapshot_dataset"]),
        "snapshot_root": str(backup_vars["backup_snapshot_root"]),
        "password_file": str(backup_vars["backup_password_file"]),
        "tiers": tiers,
        "groups": [
            {
                "id": group_id,
                "path": str(specs[group_id]["path"]),
                "cadence": specs[group_id]["cadence"],
                "tiers": list(specs[group_id]["tiers"]),
                # A host path sits outside the pool and is read live; every
                # other group is backed up from the frozen snapshot tree.
                "live": group_id in live_ids,
            }
            for group_id in order
        ],
    }


def rendered_text() -> str:
    all_vars, backup_vars = load_group_vars()
    payload = build_recovery_groups(all_vars, backup_vars)
    return json.dumps(payload, indent=2) + "\n"


def host_plan_text() -> str:
    all_vars, backup_vars = load_group_vars()
    return json.dumps(build_host_plan(all_vars, backup_vars), indent=2) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--check",
        action="store_true",
        help="fail if the checked-in file differs instead of writing it",
    )
    mode.add_argument(
        "--host-plan",
        action="store_true",
        help="print the host /etc/homelab/backup.json instead of writing the manifest",
    )
    args = parser.parse_args(argv)
    try:
        if args.host_plan:
            sys.stdout.write(host_plan_text())
            return 0
        text = rendered_text()
    except (OSError, YamlSubsetError) as exc:
        print(f"render-recovery-groups: {exc}", file=sys.stderr)
        return 1
    if args.check:
        try:
            current = TARGET.read_text(encoding="utf-8")
        except OSError as exc:
            print(f"render-recovery-groups: {exc}", file=sys.stderr)
            return 1
        if current != text:
            print(
                f"{TARGET.relative_to(ROOT)} is stale; run "
                "scripts/render-recovery-groups.py",
                file=sys.stderr,
            )
            return 1
        return 0
    TARGET.write_text(text, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
