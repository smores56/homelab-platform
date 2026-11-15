"""Command line for the migration gates: preflight, verify, rollback-plan.

``preflight`` runs the plan-driven backup gate through restic: freshness and
path coverage per group and tier, a structural ``restic check`` on every
repository, and ``--read-data`` on each group's primary. ``verify`` and
``rollback-plan`` stay offline: they read one JSON evidence file and print
JSON.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Mapping, Sequence

from ..backup.plan import load_plan
from ..backup.restic import SubprocessRunner
from ..errors import DataPlaneError
from .phases import MigrationError
from .preflight import GateReport, ResticGateRunner, run_gate
from .rollback import plan_rollback
from .verify import compare_evidence


def _load(path: str | Path) -> Mapping[str, Any]:
    try:
        payload = json.loads(Path(path).read_text(encoding="utf-8"))
    except OSError as exc:
        raise MigrationError(f"cannot read evidence {path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise MigrationError(f"evidence {path} is not valid JSON: {exc}") from exc
    if not isinstance(payload, Mapping):
        raise MigrationError(f"evidence {path} is not a JSON object")
    return payload


def _print(payload: Mapping[str, Any]) -> None:
    print(json.dumps(payload, indent=2, sort_keys=True))


def _gate_runner() -> ResticGateRunner:
    # A dry-run commander would call every check ok without reading a
    # repository, so the operator command always shells out to restic.
    return ResticGateRunner(SubprocessRunner())


def _print_gate(report: GateReport) -> None:
    print(f"preflight: {'ok' if report.ok else 'FAILED'}")
    for detail in report.failure_details():
        print(f"  {detail}")


def _cmd_preflight(args: argparse.Namespace) -> int:
    report = run_gate(
        load_plan(args.plan),
        _gate_runner(),
        read_data=not args.no_read_data,
    )
    if args.json:
        _print(report.to_dict())
    else:
        _print_gate(report)
    return 0 if report.ok else 1


def _cmd_verify(args: argparse.Namespace) -> int:
    comparison = compare_evidence(_load(args.evidence))
    _print(comparison.to_dict())
    return 0 if comparison.ok else 1


def _cmd_rollback_plan(args: argparse.Namespace) -> int:
    plan = plan_rollback(_load(args.evidence), dry_run=True)
    _print(plan.to_dict())
    return 0


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m data_plane.migration",
        description=__doc__,
    )
    sub = parser.add_subparsers(dest="command", required=True)

    preflight = sub.add_parser(
        "preflight", help="run the plan-driven backup gate"
    )
    preflight.add_argument("--plan", required=True, help="host backup plan JSON")
    preflight.add_argument(
        "--json", action="store_true", help="print the full report"
    )
    preflight.add_argument(
        "--no-read-data",
        action="store_true",
        help="skip restic check --read-data on each group's primary",
    )
    preflight.set_defaults(handler=_cmd_preflight)

    verify = sub.add_parser(
        "verify", help="compare source and replica snapshots for data loss"
    )
    verify.add_argument("evidence")
    verify.set_defaults(handler=_cmd_verify)

    rollback = sub.add_parser(
        "rollback-plan", help="print the old-system rollback plan (dry run)"
    )
    rollback.add_argument("evidence")
    rollback.set_defaults(handler=_cmd_rollback_plan)

    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        return args.handler(args)
    except DataPlaneError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
