"""Argv-only restic adapter.

Every command is built here and executed through the injectable ``Runner``; no
shell is ever involved. The default runner records commands instead of running
them, so importing or testing this module never touches a repository.

There are no tags and no generation ids: a repository holds one snapshot per
run, grouped by the restic host name, and freshness is answered by path.
"""

from __future__ import annotations

import json
import os
import subprocess
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Mapping, Protocol, Sequence

from ..errors import BackupError


@dataclass(frozen=True)
class Command:
    """One argv-only command. No shell, ever."""

    argv: tuple[str, ...]
    timeout: int = 3600
    env: tuple[tuple[str, str], ...] = ()

    def environment(self) -> dict[str, str]:
        base = {key: value for key, value in os.environ.items() if key != "RESTIC_PASSWORD"}
        base.update(dict(self.env))
        return base


@dataclass(frozen=True)
class CommandResult:
    returncode: int
    stdout: str = ""
    stderr: str = ""


class Runner(Protocol):
    def run(self, command: Command) -> CommandResult: ...


class SubprocessRunner:
    """Runs an argv list without a shell and with a timeout."""

    def run(self, command: Command) -> CommandResult:
        completed = subprocess.run(
            list(command.argv),
            capture_output=True,
            text=True,
            timeout=command.timeout,
            check=False,
            env=command.environment(),
        )
        return CommandResult(
            returncode=completed.returncode,
            stdout=completed.stdout,
            stderr=completed.stderr,
        )


@dataclass
class DryRunRunner:
    """Records commands and returns success without executing anything."""

    commands: list[Command] = field(default_factory=list)

    def run(self, command: Command) -> CommandResult:
        self.commands.append(command)
        return CommandResult(0, "", "")


@dataclass(frozen=True)
class Retention:
    """Human-only retention: prune keeps one snapshot per day/week/month."""

    daily: int = 14
    weekly: int = 8
    monthly: int = 12
    prune: bool = True


@dataclass(frozen=True)
class Snapshot:
    """One snapshot as reported by ``restic snapshots --json``."""

    id: str
    time: datetime
    paths: tuple[str, ...] = ()
    hostname: str = ""


def repository_args(repository: str, password_file: str) -> list[str]:
    return ["restic", "--repo", repository, "--password-file", password_file]


def snapshots_command(
    repository: str, password_file: str, path: str | None = None
) -> Command:
    argv = repository_args(repository, password_file) + ["snapshots", "--json"]
    if path:
        argv += ["--path", path]
    return Command(tuple(argv), timeout=600)


def backup_command(
    repository: str, password_file: str, host: str, path: str
) -> Command:
    argv = repository_args(repository, password_file) + [
        "backup",
        "--host",
        host,
        "--json",
        path,
    ]
    return Command(tuple(argv), timeout=6 * 3600)


def copy_command(
    source_repository: str,
    source_password_file: str,
    repository: str,
    password_file: str,
) -> Command:
    argv = ["restic", "copy"] + [
        "--from-repo",
        source_repository,
        "--from-password-file",
        source_password_file,
        "-r",
        repository,
        "--password-file",
        password_file,
    ]
    return Command(tuple(argv), timeout=6 * 3600)


def forget_command(
    repository: str,
    password_file: str,
    retention: Retention = Retention(),
) -> Command:
    argv = repository_args(repository, password_file) + [
        "forget",
        "--keep-daily",
        str(retention.daily),
        "--keep-weekly",
        str(retention.weekly),
        "--keep-monthly",
        str(retention.monthly),
        "--group-by",
        "host",
    ]
    if retention.prune:
        argv.append("--prune")
    return Command(tuple(argv), timeout=6 * 3600)


def init_command(repository: str, password_file: str) -> Command:
    return Command(tuple(repository_args(repository, password_file) + ["init"]))


def check_command(
    repository: str, password_file: str, read_data: bool = False
) -> Command:
    argv = repository_args(repository, password_file) + ["check"]
    if read_data:
        argv.append("--read-data")
    return Command(tuple(argv), timeout=24 * 3600)


def parse_snapshots(stdout: str) -> tuple[Snapshot, ...]:
    """Parse ``restic snapshots --json`` output; malformed output fails closed."""

    if not stdout.strip():
        return ()
    try:
        payload: Any = json.loads(stdout)
    except json.JSONDecodeError as exc:
        raise BackupError(f"restic snapshots output is not valid JSON: {exc}") from exc
    if not isinstance(payload, list):
        raise BackupError("restic snapshots output is not a JSON list")
    snapshots = []
    for index, raw in enumerate(payload):
        if not isinstance(raw, Mapping):
            raise BackupError(f"restic snapshot {index} is not an object")
        identifier = raw.get("id")
        if not isinstance(identifier, str) or not identifier:
            raise BackupError(f"restic snapshot {index} has no id")
        paths = raw.get("paths", ())
        if not isinstance(paths, Sequence) or isinstance(paths, (str, bytes)):
            raise BackupError(f"restic snapshot {index} has invalid paths")
        snapshots.append(
            Snapshot(
                id=identifier,
                time=_parse_time(raw.get("time"), index),
                paths=tuple(str(path) for path in paths),
                hostname=str(raw.get("hostname", "")),
            )
        )
    return tuple(snapshots)


def parse_snapshot_id(stdout: str) -> str:
    """Find the snapshot id in ``restic backup --json`` output.

    Restic emits one JSON object per line and ends with a summary object that
    carries ``snapshot_id``; older versions emit a single object.
    """

    for line in stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            payload: Any = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(payload, Mapping):
            continue
        for key in ("snapshot_id", "id"):
            value = payload.get(key)
            if isinstance(value, str) and value:
                return value
    return ""


def _parse_time(value: Any, index: int) -> datetime:
    if not isinstance(value, str) or not value:
        raise BackupError(f"restic snapshot {index} has no time")
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    # restic prints nanosecond precision; fromisoformat accepts at most
    # microseconds, so keep the first six fractional digits.
    if "." in text:
        head, _, rest = text.partition(".")
        cut = len(rest)
        for marker in ("+", "-"):
            position = rest.find(marker)
            if position != -1:
                cut = min(cut, position)
        fraction, suffix = rest[:cut], rest[cut:]
        text = f"{head}.{fraction[:6]}{suffix}"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError as exc:
        raise BackupError(f"restic snapshot {index} time is invalid: {exc}") from exc
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)
