#!/usr/bin/env python3
"""Replay the gate's suite selection over recent history.

Every commit is diffed against its first parent only, so a merge counts once,
and the changed paths go through the same rules as tests/tags.sh: rows of
tests/tags.tsv match shell `case` globs (where `*` crosses `/`), a path that
matches `all` or that no row claims selects every suite, and every other row a
path matches selects its suite in first-add order.

usage:
  scripts/gate-replay.py --commits N [--table PATH] [--json]
"""
from __future__ import annotations

import argparse
import fnmatch
import json
import math
import statistics
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TABLE = ROOT / "tests" / "tags.tsv"
ALL_TAG = "all"
NONE_TAG = "none"


def git(*args: str, stdin: str = "") -> str:
    out = subprocess.run(
        ("git", "-C", str(ROOT), *args), input=stdin, capture_output=True, text=True
    )
    if out.returncode:
        sys.exit(f"gate-replay: git {' '.join(args)}: {out.stderr.strip()}")
    return out.stdout


def read_rows(table: Path) -> list[tuple[str, list[str]]]:
    """Rows as tests/tags.sh reads them: `tag<TAB>patterns`, patterns space-split."""
    rows: list[tuple[str, list[str]]] = []
    for line in table.read_text().splitlines():
        tag, _, patterns = line.partition("\t")
        if not tag or tag.startswith("#"):
            continue
        rows.append((tag, patterns.split()))
    return rows


def matched_rows(path: str, rows: list[tuple[str, list[str]]]) -> list[str]:
    """Every row claiming a path, as shell `case` would: `*` crosses `/`."""
    return [t for t, pats in rows if any(fnmatch.fnmatchcase(path, p) for p in pats)]


def suites_on_disk() -> list[str]:
    """The `all` expansion: every suite file, in byte order (bats takes a set)."""
    return sorted(
        path.relative_to(ROOT).as_posix()
        for path in (ROOT / "tests").rglob("*.bats")
        if path.is_file()
    )


def select(paths: list[str], rows: list[tuple[str, list[str]]], every: list[str]) -> tuple[list[str], bool]:
    """(selected suites, selected everything) for one change set."""
    tags: list[str] = []
    everything = False
    for path in paths:
        hits = matched_rows(path, rows)
        if not hits:
            everything = True
        for tag in hits:
            if tag == ALL_TAG:
                everything = True
            elif tag != NONE_TAG and tag not in tags:
                tags.append(tag)
    return (every, True) if everything else ([f"tests/{tag}.bats" for tag in tags], False)


def changed_paths(sha: str) -> list[str]:
    """Paths a commit touched, against its first parent (the empty tree if none)."""
    parents = git("rev-list", "--parents", "-n", "1", sha).split()[1:]
    base = parents[0] if parents else git("hash-object", "-t", "tree", "--stdin").strip()
    return git("diff", "--name-only", "--no-renames", base, sha).split()


def percentile(values: list[int], quantile: float) -> int:
    """Nearest-rank: the smallest value at or above the quantile."""
    return sorted(values)[max(math.ceil(quantile * len(values)) - 1, 0)]


def replay(commits: int, table: Path) -> dict:
    rows = read_rows(table)
    every = suites_on_disk()
    head = git("rev-parse", "HEAD").strip()
    records: list[dict] = []
    touched: dict[str, list[str]] = {}
    for line in git("log", "-n", str(commits), "--format=%H\t%s", "HEAD").splitlines():
        sha, _, subject = line.partition("\t")
        paths = changed_paths(sha)
        # The tool measures the tree it runs in, so uncommitted work counts too.
        if sha == head:
            paths += git("ls-files", "--others", "--exclude-standard").split()
        suites, everything = select(paths, rows, every)
        records.append(
            {"sha": sha[:7], "subject": subject, "paths": paths,
             "all": everything, "count": len(suites), "suites": suites}
        )
        for path in dict.fromkeys(paths):
            touched.setdefault(path, []).append(sha[:7])
    counts = [record["count"] for record in records]
    suite_rows = [tag for tag, _ in rows if tag not in (ALL_TAG, NONE_TAG)]
    hits = {
        path: [tag for tag in matched_rows(path, rows) if tag not in (ALL_TAG, NONE_TAG)]
        for path in touched
    }
    fanout = sorted(
        (
            {"tag": tag,
             "paths": sum(tag in tags for tags in hits.values()),
             "only": sum(tags == [tag] for tags in hits.values())}
            for tag in suite_rows
        ),
        key=lambda entry: (-entry["paths"], entry["tag"]),
    )
    return {
        "table": str(table),
        "head": head,
        "commits": records,
        "summary": {
            "commits": len(records),
            "all_suite_commits": sum(record["all"] for record in records),
            "median": int(statistics.median(counts)) if counts else 0,
            "p90": percentile(counts, 0.9) if counts else 0,
            "mean": round(statistics.mean(counts), 1) if counts else 0.0,
            "suites": len(every),
        },
        "unclaimed": sorted(
            ({"path": p, "commits": s} for p, s in touched.items() if not matched_rows(p, rows)),
            key=lambda entry: (-len(entry["commits"]), entry["path"]),
        ),
        "fanout": fanout,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--commits", type=int, default=60, help="how many commits to replay")
    parser.add_argument("--table", type=Path, default=TABLE, help="candidate tests/tags.tsv")
    parser.add_argument("--json", action="store_true", help="emit JSON instead of a text report")
    args = parser.parse_args()

    report = replay(args.commits, args.table)
    if args.json:
        json.dump(report, sys.stdout, indent=2)
        print()
        return 0

    total = report["summary"]
    print(f"table {args.table}")
    print(f"head  {report['head'][:7]}  {total['commits']} commits  {total['suites']} suites")
    print()
    for record in report["commits"]:
        print(f"{record['sha']}  {'all' if record['all'] else '   '}  {record['count']:4d}"
              f"  {record['subject'][:60]}")
    print()
    share = 100 * total["all_suite_commits"] / total["commits"]
    print(f"all-suite commits  {total['all_suite_commits']}/{total['commits']} ({share:.0f}%)")
    print(f"selected suites    median {total['median']}  p90 {total['p90']}"
          f"  mean {total['mean']}")
    print()
    print(f"paths no row claims: {len(report['unclaimed'])}")
    for entry in report["unclaimed"]:
        print(f"  {len(entry['commits']):3d}  {entry['path']}  {' '.join(entry['commits'])}")
    print()
    print("row fan-out: distinct paths, paths selecting only that row")
    for entry in report["fanout"]:
        print(f"  {entry['paths']:3d}  {entry['only']:3d}  {entry['tag']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
