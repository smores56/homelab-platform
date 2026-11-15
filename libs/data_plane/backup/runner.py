"""Native restic/ZFS runner: one recursive snapshot, one repository per group.

The shape is deliberately small. A run takes one recursive ZFS snapshot of the
declared dataset, each group is backed up from its staged path into the
group's primary repository, every other tier receives a ``restic copy`` of that
repository, and every tier is pruned after the copies land. Freshness asks each
repository for the newest snapshot under the group's path and compares its age
with the cadence-derived limit.

Every command is built from the plan and executed through the injectable
``Runner``. A missing repository never auto-initializes: only ``init_group``
creates one, because that is an operator decision.
"""

from __future__ import annotations

import socket
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Sequence

from ..errors import BackupConfigError, BackupError
from .plan import BackupPlan, Group
from .restic import (
    Command,
    CommandResult,
    DryRunRunner,
    Runner,
    backup_command,
    check_command,
    copy_command,
    forget_command,
    init_command,
    parse_snapshot_id,
    parse_snapshots,
    snapshots_command,
)

SNAPSHOT_PREFIX = "data-plane"

#: Hours a tier may lag behind for each cadence.
FRESHNESS_HOURS: dict[str, dict[str, float]] = {
    "fast": {"nvme": 0.25, "hdd": 0.25, "r2": 1.0},
    "media": {"nvme": 1.0, "hdd": 1.0, "r2": 6.0},
}

_MISSING_REPOSITORY_MARKERS = (
    "repository does not exist",
    "unable to open config file",
    "is there a repository at",
    "no repository found",
    "config file does not exist",
)


@dataclass(frozen=True)
class SnapshotPoint:
    dataset: str
    name: str
    created_at: float


@dataclass(frozen=True)
class TierRun:
    tier: str
    repository: str
    snapshot_id: str = ""
    copied: bool = False
    pruned: bool = False


@dataclass(frozen=True)
class GroupRun:
    group_id: str
    snapshot_path: str
    snapshot_id: str
    tiers: tuple[TierRun, ...]
    created_at: float


@dataclass(frozen=True)
class TierInit:
    tier: str
    repository: str
    created: bool


@dataclass(frozen=True)
class GroupInit:
    group_id: str
    tiers: tuple[TierInit, ...]


@dataclass(frozen=True)
class TierFreshness:
    group_id: str
    tier: str
    repository: str
    ok: bool
    reason: str
    snapshot_id: str = ""
    age_hours: float | None = None
    limit_hours: float | None = None


@dataclass(frozen=True)
class GroupFreshness:
    group_id: str
    tiers: tuple[TierFreshness, ...]

    @property
    def ok(self) -> bool:
        return all(tier.ok for tier in self.tiers)


@dataclass(frozen=True)
class FreshnessReport:
    generated_at: float
    groups: tuple[GroupFreshness, ...]

    @property
    def all_ok(self) -> bool:
        return all(group.ok for group in self.groups)


@dataclass(frozen=True)
class TierCheck:
    tier: str
    repository: str
    ok: bool
    reason: str


def snapshot_name(now: float) -> str:
    stamp = datetime.fromtimestamp(now, tz=timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return f"{SNAPSHOT_PREFIX}-{stamp}"


def snapshot_command(plan: BackupPlan, name: str) -> Command:
    return Command(("zfs", "snapshot", "-r", f"{plan.snapshot_dataset}@{name}"))


def snapshot(
    plan: BackupPlan, now: float | None = None, *, runner: Runner | None = None
) -> SnapshotPoint:
    """Take one recursive snapshot; an existing name fails closed."""

    created_at = time.time() if now is None else float(now)
    name = snapshot_name(created_at)
    command = snapshot_command(plan, name)
    result = (runner or DryRunRunner()).run(command)
    if result.returncode != 0:
        detail = result.stderr.strip()[:400]
        if "exists" in detail.lower():
            raise BackupError(
                f"snapshot {plan.snapshot_dataset}@{name} already exists; "
                "refusing to reuse it"
            )
        raise BackupError(
            f"zfs snapshot {plan.snapshot_dataset}@{name} failed with "
            f"{result.returncode}: {detail}"
        )
    return SnapshotPoint(dataset=plan.snapshot_dataset, name=name, created_at=created_at)


def run_group(
    plan: BackupPlan,
    group_id: str,
    now: float | None = None,
    *,
    runner: Runner | None = None,
    host: str | None = None,
) -> GroupRun:
    """Back up one group to its primary tier, copy to the rest, then prune all."""

    group = plan.group(group_id)
    active = runner or DryRunRunner()
    hostname = host or socket.gethostname()
    created_at = time.time() if now is None else float(now)
    path = plan.snapshot_path(group_id)
    primary = group.primary_tier
    primary_repository = plan.repository(group_id, primary)

    backed_up = _require_success(
        active.run(
            backup_command(
                primary_repository, plan.password_file, hostname, path
            )
        ),
        action=f"restic backup of group {group_id!r}",
        group_id=group_id,
        tier=primary,
        repository=primary_repository,
    )
    snapshot_id = parse_snapshot_id(backed_up.stdout)
    if not snapshot_id:
        raise BackupError(
            f"restic backup of group {group_id!r} reported no snapshot id"
        )

    tiers: list[dict[str, object]] = [
        {
            "tier": primary,
            "repository": primary_repository,
            "snapshot_id": snapshot_id,
            "copied": False,
            "pruned": False,
        }
    ]
    for tier_name in group.tiers[1:]:
        repository = plan.repository(group_id, tier_name)
        _require_success(
            active.run(
                copy_command(
                    primary_repository,
                    plan.password_file,
                    repository,
                    plan.password_file,
                )
            ),
            action=f"restic copy into group {group_id!r} tier {tier_name!r}",
            group_id=group_id,
            tier=tier_name,
            repository=repository,
        )
        tiers.append(
            {
                "tier": tier_name,
                "repository": repository,
                "snapshot_id": "",
                "copied": True,
                "pruned": False,
            }
        )

    # Copies must land before any prune, on the primary too: a prune on the
    # primary could otherwise drop the snapshot this run just copied.
    for entry in tiers:
        tier_name = str(entry["tier"])
        repository = str(entry["repository"])
        _require_success(
            active.run(forget_command(repository, plan.password_file)),
            action=f"restic forget/prune of group {group_id!r} tier {tier_name!r}",
            group_id=group_id,
            tier=tier_name,
            repository=repository,
        )
        entry["pruned"] = True

    return GroupRun(
        group_id=group_id,
        snapshot_path=path,
        snapshot_id=snapshot_id,
        tiers=tuple(
            TierRun(
                tier=str(entry["tier"]),
                repository=str(entry["repository"]),
                snapshot_id=str(entry["snapshot_id"]),
                copied=bool(entry["copied"]),
                pruned=bool(entry["pruned"]),
            )
            for entry in tiers
        ),
        created_at=created_at,
    )


def init_group(
    plan: BackupPlan, group_id: str, *, runner: Runner | None = None
) -> GroupInit:
    """Create the missing repositories for one group; existing ones are kept."""

    group = plan.group(group_id)
    active = runner or DryRunRunner()
    tiers: list[TierInit] = []
    for tier_name in group.tiers:
        repository = plan.repository(group_id, tier_name)
        probe = active.run(snapshots_command(repository, plan.password_file))
        if probe.returncode == 0:
            tiers.append(
                TierInit(tier=tier_name, repository=repository, created=False)
            )
            continue
        if not _repository_missing(probe):
            raise BackupError(
                f"cannot inspect restic repository {repository!r} for group "
                f"{group_id!r} tier {tier_name!r}: "
                f"{probe.stderr.strip()[:400]}"
            )
        _require_success(
            active.run(init_command(repository, plan.password_file)),
            action=f"restic init for group {group_id!r} tier {tier_name!r}",
            group_id=group_id,
            tier=tier_name,
            repository=repository,
        )
        tiers.append(TierInit(tier=tier_name, repository=repository, created=True))
    return GroupInit(group_id=group_id, tiers=tuple(tiers))


def freshness(
    plan: BackupPlan, now: float | None = None, *, runner: Runner | None = None
) -> FreshnessReport:
    """Report per group and tier whether a recent snapshot covers the group."""

    generated_at = time.time() if now is None else float(now)
    current = datetime.fromtimestamp(generated_at, tz=timezone.utc)
    active = runner or DryRunRunner()
    groups = []
    for group in plan.groups:
        limits = FRESHNESS_HOURS[group.cadence]
        tiers = tuple(
            _tier_freshness(plan, group, tier_name, limits.get(tier_name), current, active)
            for tier_name in group.tiers
        )
        groups.append(GroupFreshness(group_id=group.id, tiers=tiers))
    return FreshnessReport(generated_at=generated_at, groups=tuple(groups))


def check(
    plan: BackupPlan,
    group_id: str,
    read_data: bool = False,
    *,
    runner: Runner | None = None,
) -> tuple[TierCheck, ...]:
    """Run ``restic check`` against every repository of one group."""

    group = plan.group(group_id)
    active = runner or DryRunRunner()
    results = []
    for tier_name in group.tiers:
        repository = plan.repository(group_id, tier_name)
        result = active.run(
            check_command(repository, plan.password_file, read_data=read_data)
        )
        if result.returncode == 0:
            results.append(
                TierCheck(tier=tier_name, repository=repository, ok=True, reason="ok")
            )
            continue
        if _repository_missing(result):
            reason = "repository is not initialized"
        else:
            reason = (
                f"restic check failed with {result.returncode}: "
                f"{result.stderr.strip()[:400]}"
            )
        results.append(
            TierCheck(
                tier=tier_name, repository=repository, ok=False, reason=reason
            )
        )
    return tuple(results)


def _tier_freshness(
    plan: BackupPlan,
    group: Group,
    tier_name: str,
    limit_hours: float | None,
    current: datetime,
    runner: Runner,
) -> TierFreshness:
    repository = plan.repository(group.id, tier_name)
    if limit_hours is None:
        return TierFreshness(
            group_id=group.id,
            tier=tier_name,
            repository=repository,
            ok=False,
            reason=f"no freshness limit is defined for tier {tier_name!r}",
        )
    path = plan.snapshot_path(group.id)
    result = runner.run(snapshots_command(repository, plan.password_file, path=path))
    if result.returncode != 0:
        reason = (
            "repository is not initialized"
            if _repository_missing(result)
            else f"snapshot query failed with {result.returncode}: "
            f"{result.stderr.strip()[:400]}"
        )
        return TierFreshness(
            group_id=group.id,
            tier=tier_name,
            repository=repository,
            ok=False,
            reason=reason,
            limit_hours=limit_hours,
        )
    try:
        snapshots = parse_snapshots(result.stdout)
    except BackupError as exc:
        return TierFreshness(
            group_id=group.id,
            tier=tier_name,
            repository=repository,
            ok=False,
            reason=str(exc),
            limit_hours=limit_hours,
        )
    if not snapshots:
        return TierFreshness(
            group_id=group.id,
            tier=tier_name,
            repository=repository,
            ok=False,
            reason=f"no snapshots under {path}",
            limit_hours=limit_hours,
        )
    newest = max(snapshots, key=lambda snap: snap.time)
    age_hours = (current - newest.time).total_seconds() / 3600
    missing = [
        expected
        for expected in _expected_paths(plan, group)
        if not _covers(newest.paths, expected)
    ]
    if missing:
        reason = "newest snapshot does not cover " + ", ".join(missing)
        ok = False
    elif age_hours > limit_hours:
        reason = (
            f"newest snapshot is {age_hours:.2f}h old, over the {limit_hours}h limit"
        )
        ok = False
    else:
        reason = f"newest snapshot is {age_hours:.2f}h old (limit {limit_hours}h)"
        ok = True
    return TierFreshness(
        group_id=group.id,
        tier=tier_name,
        repository=repository,
        ok=ok,
        reason=reason,
        snapshot_id=newest.id,
        age_hours=age_hours,
        limit_hours=limit_hours,
    )


def _expected_paths(plan: BackupPlan, group: Group) -> tuple[str, ...]:
    return (plan.snapshot_path(group.id),)


def _covers(paths: Sequence[str], expected: str) -> bool:
    target = expected.rstrip("/")
    for path in paths:
        covered = path.rstrip("/")
        if target == covered or target.startswith(covered + "/"):
            return True
    return False


def _repository_missing(result: CommandResult) -> bool:
    if result.returncode == 10:
        return True
    stderr = result.stderr.lower()
    return any(marker in stderr for marker in _MISSING_REPOSITORY_MARKERS)


def _require_success(
    result: CommandResult,
    *,
    action: str,
    group_id: str,
    tier: str,
    repository: str,
) -> CommandResult:
    if result.returncode == 0:
        return result
    if _repository_missing(result):
        raise BackupConfigError(
            f"restic repository {repository!r} for group {group_id!r} tier "
            f"{tier!r} is not initialized; run 'data_plane backup-init --plan "
            f"<plan> --group {group_id}' first"
        )
    raise BackupError(
        f"{action} failed with {result.returncode}: "
        f"{result.stderr.strip()[:400]}"
    )
