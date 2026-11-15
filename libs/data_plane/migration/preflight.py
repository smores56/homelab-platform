"""Plan-driven pre-migration gate: freshness, repository integrity, read-data.

The gate is the backup plan itself. For every recovery group it proves:

* every tier holds a snapshot under the group's staged path that is newer than
  the cadence-derived limit and covers the whole path (the runner's
  ``freshness`` report);
* every tier's repository passes a structural ``restic check``;
* the group's primary (first) tier passes ``restic check --read-data``.

A missing repository never raises: the runner reports it as a failed entry, so
one operator run shows every gap at once. Signatures and a separate evidence
file are gone; this report is the record.
"""

from __future__ import annotations

import time
from dataclasses import asdict, dataclass, replace
from typing import Protocol

from ..backup import runner as backup_runner
from ..backup.plan import BackupPlan
from ..backup.restic import Runner as CommandRunner
from ..backup.runner import (
    FRESHNESS_HOURS,
    FreshnessReport,
    GroupFreshness,
    TierCheck,
    TierFreshness,
)
from ..errors import BackupError


class GateRunner(Protocol):
    """What ``run_gate`` needs from the backup runner."""

    def freshness(
        self, plan: BackupPlan, now: float | None = None
    ) -> FreshnessReport: ...

    def check(
        self, plan: BackupPlan, group_id: str, read_data: bool = False
    ) -> tuple[TierCheck, ...]: ...


@dataclass(frozen=True)
class ResticGateRunner:
    """Bind the backup runner's functions to one restic command runner.

    The module-level functions default to a dry-run command runner, which
    cannot prove freshness and reports every ``check`` as ok without reading a
    repository; the operator-facing CLI must pass the real one.
    """

    commands: CommandRunner

    def freshness(
        self, plan: BackupPlan, now: float | None = None
    ) -> FreshnessReport:
        return backup_runner.freshness(plan, now=now, runner=self.commands)

    def check(
        self, plan: BackupPlan, group_id: str, read_data: bool = False
    ) -> tuple[TierCheck, ...]:
        return backup_runner.check(
            plan, group_id, read_data=read_data, runner=self.commands
        )


@dataclass(frozen=True)
class GroupCheck:
    """Structural ``restic check`` results for one group, one per tier."""

    group_id: str
    tiers: tuple[TierCheck, ...]

    @property
    def ok(self) -> bool:
        return bool(self.tiers) and all(tier.ok for tier in self.tiers)


@dataclass(frozen=True)
class ReadDataCheck:
    """The ``--read-data`` result for one group's primary tier."""

    group_id: str
    tier: str
    repository: str
    ok: bool
    reason: str


@dataclass(frozen=True)
class GateReport:
    """Everything the gate proved and everything it could not."""

    freshness: FreshnessReport
    checks: tuple[GroupCheck, ...]
    read_data: tuple[ReadDataCheck, ...]
    read_data_requested: bool = True

    @property
    def ok(self) -> bool:
        return (
            self.freshness.all_ok
            and all(check.ok for check in self.checks)
            and all(item.ok for item in self.read_data)
        )

    def failure_details(self) -> tuple[str, ...]:
        """One readable line per failed condition, never just the first."""

        details: list[str] = []
        for group in self.freshness.groups:
            for tier in group.tiers:
                if not tier.ok:
                    details.append(f"{group.group_id}/{tier.tier}: {tier.reason}")
        for check in self.checks:
            for tier in check.tiers:
                if not tier.ok:
                    details.append(
                        f"{check.group_id}/{tier.tier}: check: {tier.reason}"
                    )
            if not check.tiers:
                details.append(f"{check.group_id}: no repository was checked")
        for item in self.read_data:
            if not item.ok:
                details.append(
                    f"{item.group_id}/{item.tier}: read-data: {item.reason}"
                )
        return tuple(details)

    def to_dict(self) -> dict[str, object]:
        return {
            "ok": self.ok,
            "read_data_requested": self.read_data_requested,
            "freshness": {
                "generated_at": self.freshness.generated_at,
                "all_ok": self.freshness.all_ok,
                "groups": [
                    {
                        "group_id": group.group_id,
                        "ok": group.ok,
                        "tiers": [asdict(tier) for tier in group.tiers],
                    }
                    for group in self.freshness.groups
                ],
            },
            "checks": [asdict(check) for check in self.checks],
            "read_data": [asdict(item) for item in self.read_data],
            "failures": list(self.failure_details()),
        }


def run_gate(
    plan: BackupPlan,
    runner: GateRunner,
    now: float | None = None,
    read_data: bool = True,
) -> GateReport:
    """Run the whole gate; a ``BackupError`` becomes a failed report entry."""

    moment = time.time() if now is None else float(now)
    freshness_report = _safe_freshness(plan, runner, moment)
    checks: list[GroupCheck] = []
    read_results: list[ReadDataCheck] = []
    for group in plan.groups:
        try:
            structural = tuple(runner.check(plan, group.id, read_data=False))
        except BackupError as exc:
            structural = _failed_tiers(plan, group.id, str(exc))
        checks.append(GroupCheck(group_id=group.id, tiers=structural))
        if read_data:
            read_results.append(_read_data_check(plan, runner, group.id))
    return GateReport(
        freshness=freshness_report,
        checks=tuple(checks),
        read_data=tuple(read_results),
        read_data_requested=read_data,
    )


def _read_data_check(
    plan: BackupPlan, runner: GateRunner, group_id: str
) -> ReadDataCheck:
    primary = plan.group(group_id).primary_tier
    repository = plan.repository(group_id, primary)
    # runner.check covers every tier of a group and the read-data pass must
    # touch only the primary, so scope a plan whose group has just that tier.
    try:
        results = tuple(
            runner.check(_primary_only(plan, group_id), group_id, read_data=True)
        )
    except BackupError as exc:
        return ReadDataCheck(
            group_id=group_id,
            tier=primary,
            repository=repository,
            ok=False,
            reason=str(exc),
        )
    result = next((item for item in results if item.tier == primary), None)
    if result is None:
        return ReadDataCheck(
            group_id=group_id,
            tier=primary,
            repository=repository,
            ok=False,
            reason="the runner reported no read-data result for the primary tier",
        )
    return ReadDataCheck(
        group_id=group_id,
        tier=primary,
        repository=repository,
        ok=result.ok,
        reason=result.reason,
    )


def _safe_freshness(
    plan: BackupPlan, runner: GateRunner, moment: float
) -> FreshnessReport:
    try:
        return runner.freshness(plan, now=moment)
    except BackupError as exc:
        detail = str(exc)
        return FreshnessReport(
            generated_at=moment,
            groups=tuple(
                GroupFreshness(
                    group_id=group.id,
                    tiers=tuple(
                        TierFreshness(
                            group_id=group.id,
                            tier=tier,
                            repository=plan.repository(group.id, tier),
                            ok=False,
                            reason=detail,
                            limit_hours=FRESHNESS_HOURS[group.cadence].get(tier),
                        )
                        for tier in group.tiers
                    ),
                )
                for group in plan.groups
            ),
        )


def _failed_tiers(
    plan: BackupPlan, group_id: str, reason: str
) -> tuple[TierCheck, ...]:
    return tuple(
        TierCheck(
            tier=tier,
            repository=plan.repository(group_id, tier),
            ok=False,
            reason=reason,
        )
        for tier in plan.group(group_id).tiers
    )


def _primary_only(plan: BackupPlan, group_id: str) -> BackupPlan:
    group = plan.group(group_id)
    scoped = replace(group, tiers=group.tiers[:1])
    return replace(
        plan,
        groups=tuple(scoped if item.id == group_id else item for item in plan.groups),
    )
