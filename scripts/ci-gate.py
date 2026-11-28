#!/usr/bin/env python3
"""Decide the `PR gate` check from the jobs it depends on.

The gate job carries `if: always()`, so it reports even when a dependency
failed; this is what that report says. `skipped` is a pass -- the selector did
not name that area for this diff -- and `failure`, `cancelled` or any other
result is a fail. A job missing from `needs` is a fail too, and so is a job in
`needs` that the selector does not name: otherwise deleting an area job, or
growing a dependency the gate's list does not cover, would quietly narrow the
required check while it still turned green.

usage:
  scripts/ci-gate.py --expected <job>... [--require-success <job>...] [--needs FILE]
  scripts/ci-gate.py --expected $(scripts/ci-areas.sh --jobs) < needs.json

`--expected` is every job the gate depends on; `--require-success` names the
jobs a skip cannot satisfy (the selector itself: without it nothing is known
about the diff). Reads the `needs` context as JSON, from stdin by default.

tests/ci-gate.bats drives every rule below with fixtures.
"""

from __future__ import annotations

import argparse
import json
import sys

PASS = "success"
SKIP = "skipped"


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--expected",
        nargs="+",
        required=True,
        metavar="JOB",
        help="a job the gate depends on; every one must appear in needs",
    )
    parser.add_argument(
        "--require-success",
        nargs="+",
        default=[],
        metavar="JOB",
        help="a job that must have run, not been skipped",
    )
    parser.add_argument(
        "--needs",
        metavar="FILE",
        help="the needs context as JSON (default: stdin)",
    )
    return parser.parse_args(argv)


def verdict(job: str, result: str | None, required: frozenset[str]) -> str | None:
    """Why this job fails the gate, or None when it does not."""
    if result is None:
        return f"{job}: missing from needs; the gate no longer depends on it"
    if result == PASS:
        return None
    if result == SKIP:
        if job in required:
            return f"{job}: skipped, and the gate needs it to have run"
        return None
    return f"{job}: {result}"


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    source = open(args.needs, encoding="utf-8") if args.needs else sys.stdin
    with source as handle:
        text = handle.read()
    try:
        needs = json.loads(text) if text.strip() else {}
    except json.JSONDecodeError as err:
        print(f"pr gate: needs is not JSON ({err}); nothing can be proved", file=sys.stderr)
        return 1
    if not isinstance(needs, dict):
        print("pr gate: needs is not a mapping of job to result", file=sys.stderr)
        return 1

    expected = list(dict.fromkeys(args.expected))
    required = frozenset(args.require_success)
    failures = []

    width = max((len(job) for job in expected), default=0)
    for job in expected:
        entry = needs.get(job)
        result = entry.get("result") if isinstance(entry, dict) else None
        reason = verdict(job, result, required)
        status = "FAIL" if reason else "ok"
        print(f"{status:<4} {job:<{width}} {result or '-'}")
        if reason:
            failures.append(reason)

    for job in sorted(set(needs) - set(expected)):
        failures.append(f"{job}: needs it, and the selector does not name it")

    for reason in failures:
        print(f"pr gate: {reason}", file=sys.stderr)
    if failures:
        print(f"pr gate: failed ({len(failures)})", file=sys.stderr)
        return 1
    print(f"pr gate: {len(expected)} jobs reported; every selected area passed")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
