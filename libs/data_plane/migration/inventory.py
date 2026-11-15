"""Read-only migration inventory: machine, disks, sources, credentials, Git.

This is T0 of the migration. It never writes to the host, never opens a
credential, and never changes a repository: every command is a query, every
credential is recorded by path and mode only, and a path it cannot read becomes
a named gap rather than an exception. The report is one JSON document so two
runs can be compared and a cutover decision can cite it.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import shutil
import socket
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable, Mapping, Protocol, Sequence

SCHEMA_VERSION = 1
REPORT_SCHEMA = "data-plane-inventory"

# Trees whose size and layout feed the recovery-group and capacity decisions.
SOURCE_ROOTS = ("/srv", "/var/lib/data", "/var/lib/data-plane", "/var/lib/sbctl")

# Checkout roots: the target ghq layout and the current one.
GIT_ROOTS = ("~/ghq", "~/repos")

# Tools resolved outside PATH too: the NixOS host keeps zfs under the system
# profile, and the unprivileged user may not see it at all.
TOOL_CANDIDATES = {
    "zfs": ("/run/current-system/sw/bin/zfs", "/sbin/zfs", "/usr/sbin/zfs"),
    "zpool": (
        "/run/current-system/sw/bin/zpool",
        "/sbin/zpool",
        "/usr/sbin/zpool",
    ),
}

# Credential locations, recorded by metadata only. A path here is never read.
CREDENTIAL_PATHS = (
    "/etc/homelab/secrets",
    "/etc/homelab/backup.json",
    "/etc/luks",
    "/etc/rancher/k3s/node-token",
    "/home",
)


@dataclass(frozen=True)
class CommandResult:
    rc: int
    stdout: str
    stderr: str


class Runner(Protocol):
    def run(self, argv: Sequence[str]) -> CommandResult: ...


class SubprocessRunner:
    """Argv-only runner; nothing here sees a shell."""

    def __init__(self, timeout: float = 60.0) -> None:
        self._timeout = timeout

    def run(self, argv: Sequence[str]) -> CommandResult:
        try:
            done = subprocess.run(
                list(argv),
                capture_output=True,
                text=True,
                timeout=self._timeout,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            return CommandResult(1, "", f"{type(exc).__name__}: {exc}")
        return CommandResult(done.returncode, done.stdout, done.stderr)


@dataclass(frozen=True)
class Facts:
    hostname: str
    kernel: str
    os_release: Mapping[str, str]
    cpu_count: int
    memory_kib: int


def read_facts() -> Facts:
    release: dict[str, str] = {}
    try:
        for line in Path("/etc/os-release").read_text(encoding="utf-8").splitlines():
            if "=" in line:
                key, _, value = line.partition("=")
                release[key] = value.strip().strip('"')
    except OSError:
        release = {}
    try:
        memory_kib = 0
        for line in Path("/proc/meminfo").read_text(encoding="utf-8").splitlines():
            if line.startswith("MemTotal:"):
                memory_kib = int(line.split()[1])
                break
    except (OSError, ValueError, IndexError):
        memory_kib = 0
    return Facts(
        hostname=socket.gethostname(),
        kernel=platform.release(),
        os_release=release,
        cpu_count=os.cpu_count() or 0,
        memory_kib=memory_kib,
    )


def _json(runner: Runner, argv: Sequence[str], gaps: list[str]) -> Any:
    done = runner.run(argv)
    if done.rc != 0:
        gaps.append(f"{' '.join(argv)}: {done.stderr.strip()[:200]}")
        return None
    try:
        return json.loads(done.stdout)
    except json.JSONDecodeError:
        gaps.append(f"{' '.join(argv)}: output was not JSON")
        return None


def collect_machine(facts: Facts) -> dict[str, Any]:
    return {
        "hostname": facts.hostname,
        "kernel": facts.kernel,
        "os_release": dict(sorted(facts.os_release.items())),
        "cpu_count": facts.cpu_count,
        "memory_kib": facts.memory_kib,
    }


def _tool(name: str) -> str | None:
    found = shutil.which(name)
    if found:
        return found
    for candidate in TOOL_CANDIDATES.get(name, ()):
        if Path(candidate).exists():
            return candidate
    return None


def collect_disks(
    runner: Runner, gaps: list[str], tools: Mapping[str, str | None]
) -> dict[str, Any]:
    zpool = tools.get("zpool")
    zfs = tools.get("zfs")
    lsblk = tools.get("lsblk") or "lsblk"
    if zpool is None:
        gaps.append("zpool is not installed on this host; no pool data collected")
    if zfs is None:
        gaps.append("zfs is not installed on this host; no dataset data collected")
    return {
        "block_devices": _json(
            runner,
            [lsblk, "-J", "-o", "NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS"],
            gaps,
        ),
        "pools": _text(
            runner,
            [zpool, "list", "-H", "-o", "name,size,alloc,free,health"],
            gaps,
        )
        if zpool
        else None,
        "datasets": _text(
            runner,
            [zfs, "list", "-H", "-o", "name,used,avail,mountpoint"],
            gaps,
        )
        if zfs
        else None,
    }


def _text(runner: Runner, argv: Sequence[str], gaps: list[str]) -> list[str] | None:
    done = runner.run(argv)
    if done.rc != 0:
        gaps.append(f"{' '.join(argv)}: {done.stderr.strip()[:200]}")
        return None
    return [line for line in done.stdout.splitlines() if line.strip()]


def _children(root: Path) -> list[Path]:
    try:
        return sorted((entry for entry in root.iterdir() if entry.is_dir()), key=str)
    except OSError:
        return []


def collect_sources(
    runner: Runner, roots: Iterable[str], gaps: list[str]
) -> list[dict[str, Any]]:
    report: list[dict[str, Any]] = []
    for raw in roots:
        root = Path(raw)
        if not root.is_dir():
            continue
        for child in _children(root):
            done = runner.run(["du", "-sb", "--one-file-system", str(child)])
            if done.rc != 0:
                gaps.append(f"du {child}: {done.stderr.strip()[:200]}")
                report.append({"path": str(child), "bytes": None})
                continue
            fields = done.stdout.split()
            size = int(fields[0]) if fields and fields[0].isdigit() else None
            report.append({"path": str(child), "bytes": size})
    return sorted(report, key=lambda item: item["path"])


def collect_credentials(paths: Iterable[str]) -> list[dict[str, Any]]:
    report: list[dict[str, Any]] = []
    for raw in paths:
        path = Path(raw)
        try:
            stat = os.lstat(path)
        except OSError:
            report.append({"path": str(path), "exists": False})
            continue
        report.append(
            {
                "path": str(path),
                "exists": True,
                "kind": "dir" if path.is_dir() else "file",
                "mode": oct(stat.st_mode & 0o7777),
                "uid": stat.st_uid,
                "gid": stat.st_gid,
            }
        )
    return sorted(report, key=lambda item: item["path"])


def _git_dirs(root: Path) -> list[Path]:
    # ghq layout is <host>/<owner>/<repo>.
    repos: list[Path] = []
    for host in _children(root):
        for owner in _children(host):
            for repo in _children(owner):
                if (repo / ".git").exists():
                    repos.append(repo)
    return sorted(repos, key=str)


def collect_git(
    runner: Runner, roots: Iterable[str], gaps: list[str]
) -> list[dict[str, Any]]:
    report: list[dict[str, Any]] = []
    for raw in roots:
        base = Path(raw).expanduser()
        if not base.is_dir():
            continue
        for repo in _git_dirs(base):
            head = runner.run(["git", "-C", str(repo), "rev-parse", "HEAD"])
            branch = runner.run(
                ["git", "-C", str(repo), "rev-parse", "--abbrev-ref", "HEAD"]
            )
            status = runner.run(["git", "-C", str(repo), "status", "--porcelain"])
            if head.rc != 0:
                gaps.append(f"git {repo}: {head.stderr.strip()[:200]}")
                continue
            report.append(
                {
                    "path": str(repo),
                    "head": head.stdout.strip(),
                    "branch": branch.stdout.strip(),
                    "dirty": bool(status.stdout.strip()),
                }
            )
    return sorted(report, key=lambda item: item["path"])


def build_report(
    facts: Facts,
    runner: Runner,
    *,
    source_roots: Iterable[str] = SOURCE_ROOTS,
    credential_paths: Iterable[str] = CREDENTIAL_PATHS,
    git_roots: Iterable[str] = GIT_ROOTS,
    tools: Mapping[str, str | None] | None = None,
    collected_at: str | None = None,
) -> dict[str, Any]:
    gaps: list[str] = []
    resolved = (
        dict(tools)
        if tools is not None
        else {
            name: _tool(name)
            for name in ("lsblk", "du", "git", "zfs", "zpool")
        }
    )
    report = {
        "schema": REPORT_SCHEMA,
        "schema_version": SCHEMA_VERSION,
        "collected_at": collected_at
        or datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "tools": dict(sorted(resolved.items())),
        "machine": collect_machine(facts),
        "disks": collect_disks(runner, gaps, resolved),
        "sources": collect_sources(runner, source_roots, gaps),
        "credentials": collect_credentials(credential_paths),
        "git": collect_git(runner, git_roots, gaps),
    }
    report["gaps"] = sorted(gaps)
    return report


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="data_plane.migration inventory")
    parser.add_argument("--out", help="write the report here instead of stdout")
    parser.add_argument("--json", action="store_true", help="print the report")
    parser.add_argument(
        "--git-root",
        action="append",
        default=None,
        help="checkout root to scan; repeatable (default: ~/ghq and ~/repos)",
    )
    parser.add_argument(
        "--timeout", type=float, default=60.0, help="per-command timeout in seconds"
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    report = build_report(
        read_facts(),
        SubprocessRunner(timeout=args.timeout),
        git_roots=args.git_root or GIT_ROOTS,
    )
    text = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.out:
        Path(args.out).write_text(text, encoding="utf-8")
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
