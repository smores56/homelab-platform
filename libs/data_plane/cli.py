"""Command-line surface for the portable data-plane libraries.

Most commands are offline: they read local fixtures, validate contracts, and
print JSON. The ``backup-*`` commands operate on the host backup plan; they use
a real subprocess runner unless ``--dry-run`` records the argv instead.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from dataclasses import asdict
from pathlib import Path
from typing import Any, Mapping, Sequence

from .backup.plan import BackupPlan, Group, load_plan
from .backup.restic import DryRunRunner, Runner, SubprocessRunner
from .backup.runner import check, freshness, init_group, run_group, snapshot
from .confirmation import NormalizedOperation, operation_hash, render
from .errors import DataPlaneError
from .github.backup import GithubBackupPlan
from .memory.file_memory import FileMemory
from .model import (
    Authority,
    Capability,
    EffectClass,
    FidelityLimit,
    FieldAuthority,
    SourceContract,
    Visibility,
    validate_many,
)

DEFAULT_PLAN = "/etc/homelab/backup.json"


def _load_json(path: str | Path) -> Any:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def _as_list(value: Any, key: str) -> list[Any]:
    if isinstance(value, list):
        return value
    if isinstance(value, Mapping) and isinstance(value.get(key), list):
        return list(value[key])
    raise DataPlaneError(f"expected a list or a mapping with {key!r}")


def _source(raw: Mapping[str, Any]) -> SourceContract:
    return SourceContract(
        source_id=str(raw["source_id"]),
        visibility=Visibility(str(raw["visibility"])),
        version=int(raw.get("version", 1)),
        recovery_group=str(raw["recovery_group"]),
        stable_id_fields=tuple(str(item) for item in raw.get("stable_id_fields", ())),
        capabilities=tuple(
            Capability(
                name=str(item["name"]),
                effect=EffectClass(str(item["effect"])),
                requires_confirmation=bool(item.get("requires_confirmation", False)),
                reversible=bool(item.get("reversible", True)),
                description=str(item.get("description", "")),
            )
            for item in raw.get("capabilities", ())
        ),
        authority=tuple(
            FieldAuthority(
                field=str(item["field"]),
                authority=Authority(str(item["authority"])),
                exportable=bool(item.get("exportable", True)),
                note=str(item.get("note", "")),
            )
            for item in raw.get("authority", ())
        ),
        revision_field=raw.get("revision_field"),
        tombstone_field=raw.get("tombstone_field"),
        attachment_hash_fields=tuple(
            str(item) for item in raw.get("attachment_hash_fields", ())
        ),
        fidelity_limits=tuple(
            FidelityLimit(field=str(item["field"]), reason=str(item["reason"]))
            for item in raw.get("fidelity_limits", ())
        ),
        epoch=int(raw.get("epoch", 1)),
        notes=str(raw.get("notes", "")),
    )


def _cmd_validate_catalog(args: argparse.Namespace) -> int:
    contracts = validate_many(
        _source(raw) for raw in _as_list(_load_json(args.path), "sources")
    )
    print(
        json.dumps(
            {"sources": len(contracts), "ids": [item.source_id for item in contracts]}
        )
    )
    return 0


def _cmd_render_confirmation(args: argparse.Namespace) -> int:
    operation = NormalizedOperation.from_normalized(_load_json(args.path))
    print(f"hash: {operation_hash(operation)}")
    print(render(operation))
    return 0


def _backup_runner(args: argparse.Namespace) -> Runner:
    return DryRunRunner() if args.dry_run else SubprocessRunner()


def _selected_groups(plan: BackupPlan, args: argparse.Namespace) -> tuple[Group, ...]:
    requested = tuple(getattr(args, "group", None) or ())
    if not requested:
        return plan.groups
    return tuple(plan.group(group_id) for group_id in requested)


def _cmd_backup_run(args: argparse.Namespace) -> int:
    plan = load_plan(args.plan)
    runner = _backup_runner(args)
    point = snapshot(plan, runner=runner)
    runs = [
        run_group(plan, group.id, now=point.created_at, runner=runner, host=args.host)
        for group in _selected_groups(plan, args)
    ]
    print(
        json.dumps(
            {
                "snapshot": point.name,
                "snapshot_dataset": point.dataset,
                "groups": [asdict(run) for run in runs],
            },
            indent=2,
        )
    )
    return 0


def _cmd_backup_init(args: argparse.Namespace) -> int:
    plan = load_plan(args.plan)
    runner = _backup_runner(args)
    results = [
        init_group(plan, group.id, runner=runner)
        for group in _selected_groups(plan, args)
    ]
    print(json.dumps({"groups": [asdict(result) for result in results]}, indent=2))
    return 0


def _cmd_backup_freshness(args: argparse.Namespace) -> int:
    plan = load_plan(args.plan)
    report = freshness(plan, runner=_backup_runner(args), host=args.host)
    if args.json:
        payload = {
            "generated_at": report.generated_at,
            "all_ok": report.all_ok,
            "groups": [
                {
                    "group_id": group.group_id,
                    "ok": group.ok,
                    "tiers": [asdict(tier) for tier in group.tiers],
                }
                for group in report.groups
            ],
        }
        print(json.dumps(payload, indent=2))
    else:
        for group in report.groups:
            for tier in group.tiers:
                state = "ok" if tier.ok else "NOT OK"
                print(f"{group.group_id}/{tier.tier}: {state} - {tier.reason}")
    return 0 if report.all_ok else 1


def _cmd_backup_check(args: argparse.Namespace) -> int:
    plan = load_plan(args.plan)
    runner = _backup_runner(args)
    results = []
    all_ok = True
    for group in _selected_groups(plan, args):
        tiers = check(plan, group.id, read_data=args.read_data, runner=runner)
        all_ok = all_ok and all(tier.ok for tier in tiers)
        results.append({"group_id": group.id, "tiers": [asdict(t) for t in tiers]})
    print(json.dumps({"all_ok": all_ok, "groups": results}, indent=2))
    return 0 if all_ok else 1


def _cmd_memory_search(args: argparse.Namespace) -> int:
    memory = FileMemory(args.root, None if args.profile == "all" else args.profile)
    records = memory.search(
        args.query, tags=tuple(args.tag or ()), include_deleted=args.include_deleted
    )
    print(json.dumps([record.as_dict() for record in records], indent=2))
    return 0


def _cmd_github_plan(args: argparse.Namespace) -> int:
    plan = GithubBackupPlan(
        owner=args.owner,
        repos=tuple(args.repos),
        out_dir=args.out,
        mirror=True,
        bundle=not args.no_bundle,
    )
    print(json.dumps(plan.commands(), indent=2))
    return 0


def _add_backup_plan(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--plan",
        default=os.environ.get("DATA_PLANE_BACKUP_PLAN", DEFAULT_PLAN),
        help=f"host backup plan (default: {DEFAULT_PLAN})",
    )


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="data_plane", description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    catalog = sub.add_parser("validate-catalog", help="validate source contracts")
    catalog.add_argument("path")
    catalog.set_defaults(handler=_cmd_validate_catalog)

    confirmation = sub.add_parser(
        "render-confirmation", help="hash and render a normalized operation"
    )
    confirmation.add_argument("path")
    confirmation.set_defaults(handler=_cmd_render_confirmation)

    run = sub.add_parser(
        "backup-run",
        help="snapshot once, back up each group, copy to the other tiers, prune",
    )
    _add_backup_plan(run)
    run.add_argument("--group", action="append")
    run.add_argument("--host", help="restic host name (default: this host)")
    run.add_argument("--dry-run", action="store_true")
    run.set_defaults(handler=_cmd_backup_run)

    init = sub.add_parser(
        "backup-init", help="create the missing repositories for a group"
    )
    _add_backup_plan(init)
    init.add_argument("--group", action="append")
    init.add_argument("--dry-run", action="store_true")
    init.set_defaults(handler=_cmd_backup_init)

    fresh = sub.add_parser(
        "backup-freshness", help="check per-group, per-tier snapshot freshness"
    )
    _add_backup_plan(fresh)
    fresh.add_argument("--host", help="restic host name to expect (default: this host)")
    fresh.add_argument("--json", action="store_true")
    fresh.add_argument("--dry-run", action="store_true")
    fresh.set_defaults(handler=_cmd_backup_freshness)

    verify = sub.add_parser("backup-check", help="run restic check per tier")
    _add_backup_plan(verify)
    verify.add_argument("--group", action="append")
    verify.add_argument("--read-data", action="store_true")
    verify.add_argument("--dry-run", action="store_true")
    verify.set_defaults(handler=_cmd_backup_check)

    memory = sub.add_parser("memory-search", help="search portable file memory")
    memory.add_argument("root")
    memory.add_argument("profile", choices=("local", "external", "all"))
    memory.add_argument("query")
    memory.add_argument("--tag", action="append")
    memory.add_argument("--include-deleted", action="store_true")
    memory.set_defaults(handler=_cmd_memory_search)

    github = sub.add_parser("github-plan", help="print safe GitHub backup argv")
    github.add_argument("owner")
    github.add_argument("repos", nargs="+")
    github.add_argument("--out", required=True)
    github.add_argument("--no-bundle", action="store_true")
    github.set_defaults(handler=_cmd_github_plan)

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
