"""The host backup plan: one restic repository per recovery group and tier.

``/etc/homelab/backup.json`` is written by the Ansible backup role and read
here. The plan is the only input the runner needs: it names the dataset the
run snapshots, the staged mount that restic reads, the password file, the
repository roots per tier, and the recovery groups with their cadence.

A group's first listed tier is its primary (the one restic backs up into);
every other tier receives a ``restic copy`` from that primary.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping

from ..errors import BackupConfigError

SCHEMA_VERSION = 1
CADENCES = ("fast", "media")
_TOP_LEVEL_KEYS = frozenset(
    {
        "schema_version",
        "snapshot_dataset",
        "snapshot_root",
        "password_file",
        "tiers",
        "groups",
    }
)
_TIER_KEYS = frozenset({"name", "repository_root"})
_GROUP_KEYS = frozenset({"id", "path", "cadence", "tiers", "live"})


@dataclass(frozen=True)
class Tier:
    """One restic repository root; each group gets a repository below it."""

    name: str
    repository_root: str

    def repository_for(self, group_id: str) -> str:
        return f"{self.repository_root.rstrip('/')}/{group_id}"


@dataclass(frozen=True)
class Group:
    """One recovery group: a staged path and its ordered destination tiers."""

    id: str
    path: str
    cadence: str
    tiers: tuple[str, ...]
    #: Backed up from its live path, not from the recursive snapshot tree.
    live: bool = False

    @property
    def primary_tier(self) -> str:
        return self.tiers[0]


@dataclass(frozen=True)
class BackupPlan:
    """The whole host plan, validated at load time."""

    schema_version: int
    snapshot_dataset: str
    snapshot_root: str
    password_file: str
    tiers: tuple[Tier, ...]
    groups: tuple[Group, ...]

    def tier(self, name: str) -> Tier:
        for tier in self.tiers:
            if tier.name == name:
                return tier
        raise BackupConfigError(f"backup plan has no tier {name!r}")

    def group(self, group_id: str) -> Group:
        for group in self.groups:
            if group.id == group_id:
                return group
        raise BackupConfigError(f"backup plan has no group {group_id!r}")

    def repository(self, group_id: str, tier_name: str) -> str:
        group = self.group(group_id)
        if tier_name not in group.tiers:
            raise BackupConfigError(
                f"group {group_id!r} does not use tier {tier_name!r}"
            )
        return self.tier(tier_name).repository_for(group.id)

    def snapshot_path(self, group_id: str) -> str:
        group = self.group(group_id)
        return f"{self.snapshot_root.rstrip('/')}/{group.path}"


def load_plan(path: str | Path) -> BackupPlan:
    """Read and validate one plan file."""

    target = Path(path)
    try:
        text = target.read_text(encoding="utf-8")
    except OSError as exc:
        raise BackupConfigError(f"cannot read backup plan {target}: {exc}") from exc
    try:
        payload = json.loads(text)
    except json.JSONDecodeError as exc:
        raise BackupConfigError(
            f"backup plan {target} is not valid JSON: {exc}"
        ) from exc
    return parse_plan(payload)


def parse_plan(payload: Any) -> BackupPlan:
    """Validate an already-decoded plan document."""

    if not isinstance(payload, Mapping):
        raise BackupConfigError("backup plan must be a JSON object")
    unknown = sorted(set(payload) - _TOP_LEVEL_KEYS)
    if unknown:
        raise BackupConfigError(
            "backup plan has unknown keys: " + ", ".join(unknown)
        )
    schema_version = payload.get("schema_version")
    if type(schema_version) is not int or schema_version != SCHEMA_VERSION:
        raise BackupConfigError(
            f"backup plan schema_version must be {SCHEMA_VERSION}"
        )
    snapshot_dataset = _dataset(payload.get("snapshot_dataset"))
    snapshot_root = _absolute(payload.get("snapshot_root"), "snapshot_root")
    password_file = _absolute(payload.get("password_file"), "password_file")
    tiers = _tiers(payload.get("tiers"))
    known_tiers = {tier.name for tier in tiers}
    groups = _groups(payload.get("groups"), known_tiers)
    return BackupPlan(
        schema_version=schema_version,
        snapshot_dataset=snapshot_dataset,
        snapshot_root=snapshot_root,
        password_file=password_file,
        tiers=tiers,
        groups=groups,
    )


def _dataset(value: Any) -> str:
    if not isinstance(value, str) or not value.strip():
        raise BackupConfigError("snapshot_dataset must be a non-empty string")
    dataset = value.strip()
    if "@" in dataset:
        raise BackupConfigError("snapshot_dataset must be a dataset, not a snapshot")
    return dataset


def _absolute(value: Any, field_name: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise BackupConfigError(f"{field_name} must be a non-empty string")
    text = value.strip()
    if not text.startswith("/"):
        raise BackupConfigError(f"{field_name} must be an absolute path")
    return text.rstrip("/") or "/"


def _tiers(value: Any) -> tuple[Tier, ...]:
    if not isinstance(value, list) or not value:
        raise BackupConfigError("tiers must be a non-empty list")
    tiers: list[Tier] = []
    for index, raw in enumerate(value):
        if not isinstance(raw, Mapping):
            raise BackupConfigError(f"tiers[{index}] must be an object")
        unknown = sorted(set(raw) - _TIER_KEYS)
        if unknown:
            raise BackupConfigError(
                f"tiers[{index}] has unknown keys: " + ", ".join(unknown)
            )
        name = _text(raw.get("name"), f"tiers[{index}].name")
        root = _repository_root(raw.get("repository_root"), name)
        tiers.append(Tier(name=name, repository_root=root))
    names = [tier.name for tier in tiers]
    duplicates = sorted({name for name in names if names.count(name) > 1})
    if duplicates:
        raise BackupConfigError(
            "tiers repeat a name: " + ", ".join(duplicates)
        )
    return tuple(tiers)


def _repository_root(value: Any, tier_name: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise BackupConfigError(
            f"tier {tier_name!r} needs a non-empty repository_root"
        )
    root = value.strip()
    if tier_name == "r2":
        if not root.startswith("s3:"):
            raise BackupConfigError(
                "tier 'r2' repository_root must start with 's3:'"
            )
        return root
    if not root.startswith("/"):
        raise BackupConfigError(
            f"tier {tier_name!r} repository_root must be an absolute path"
        )
    return root.rstrip("/") or "/"


def _groups(value: Any, known_tiers: set[str]) -> tuple[Group, ...]:
    if not isinstance(value, list) or not value:
        raise BackupConfigError("groups must be a non-empty list")
    groups: list[Group] = []
    for index, raw in enumerate(value):
        if not isinstance(raw, Mapping):
            raise BackupConfigError(f"groups[{index}] must be an object")
        unknown = sorted(set(raw) - _GROUP_KEYS)
        if unknown:
            raise BackupConfigError(
                f"groups[{index}] has unknown keys: " + ", ".join(unknown)
            )
        group_id = _text(raw.get("id"), f"groups[{index}].id")
        path = _relative_path(raw.get("path"), f"groups[{index}].path")
        cadence = _text(raw.get("cadence"), f"groups[{index}].cadence")
        if cadence not in CADENCES:
            raise BackupConfigError(
                f"group {group_id!r} cadence must be one of {', '.join(CADENCES)}"
            )
        tiers = _group_tiers(raw.get("tiers"), group_id, known_tiers)
        live = _boolean(raw.get("live"), f"groups[{index}].live")
        groups.append(
            Group(id=group_id, path=path, cadence=cadence, tiers=tiers, live=live)
        )
    ids = [group.id for group in groups]
    duplicates = sorted({group_id for group_id in ids if ids.count(group_id) > 1})
    if duplicates:
        raise BackupConfigError(
            "groups repeat an id: " + ", ".join(duplicates)
        )
    return tuple(groups)


def _group_tiers(
    value: Any, group_id: str, known_tiers: set[str]
) -> tuple[str, ...]:
    if not isinstance(value, list) or not value:
        raise BackupConfigError(f"group {group_id!r} needs at least one tier")
    tiers: list[str] = []
    for item in value:
        name = _text(item, f"group {group_id!r} tier")
        if name not in known_tiers:
            raise BackupConfigError(
                f"group {group_id!r} names unknown tier {name!r}"
            )
        if name in tiers:
            raise BackupConfigError(
                f"group {group_id!r} repeats tier {name!r}"
            )
        tiers.append(name)
    return tuple(tiers)


def _text(value: Any, field_name: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise BackupConfigError(f"{field_name} must be a non-empty string")
    return value.strip()


def _boolean(value: Any, field_name: str) -> bool:
    """An optional flag: absent means false, anything but a bool is a bug."""

    if value is None:
        return False
    if not isinstance(value, bool):
        raise BackupConfigError(f"{field_name} must be a boolean")
    return value


def _relative_path(value: Any, field_name: str) -> str:
    path = _text(value, field_name)
    if path.startswith("/"):
        raise BackupConfigError(f"{field_name} must be relative")
    parts = path.split("/")
    if any(part in {"", ".", ".."} for part in parts):
        raise BackupConfigError(f"{field_name} is not a safe relative path")
    return path
