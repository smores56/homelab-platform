"""Raw tasks: each todo.txt line becomes one immutable object, named by its text.

A todo.txt line carries no id of its own, and the tools that write the file
rewrite it in place, so content is the only identity available: the object id is
a digest of the line's bytes. That choice has two consequences, both accepted:

* An edited line is a new task, and the line it replaced is carried forward as
  absent rather than tombstoned. There is no provider tombstone here -- a reorder
  or a rewrite looks exactly like a deletion -- so absence alone is not a
  deletion this replica can prove, and a task that never returns keeps its last
  text as evidence it once existed.
* Two identical lines are one task. A list of 29 lines is a set of tasks, not a
  multiset, and collapsing them is the only way to keep the id a pure function of
  the line; the collapse is counted in the report rather than hidden.

A directory with neither ``todo.txt`` nor ``done.txt`` is refused: a mistyped
path would otherwise publish an empty generation, which carries every previous
task forward as absent and looks like a real, empty list. The two files are read
through a symlink if the deployment renders them that way; a symlinked directory
is still refused by ``resolve_source_dir``.
"""

from __future__ import annotations

import hashlib
import re
from pathlib import Path
from typing import Any, Iterable

from ...errors import PublishError
from ..staging import StagingGeneration
from .replica import (
    ABSENCE_NO_TOMBSTONE,
    CollectReport,
    canonical_json,
    carry_forward,
    previous_replica,
    resolve_source_dir,
)

SOURCE_ID = "tasks.todo"

FILES = ("todo.txt", "done.txt")

_PRIORITY = re.compile(r"\(([A-Z])\)")
_KEY = re.compile(r"[a-z]+")
_DATE = re.compile(r"\d{4}-\d{2}-\d{2}")


def _parse(line: str) -> dict[str, Any]:
    """The todo.txt fields this replica understands, from the line verbatim."""

    done = line.startswith("x ")
    body = line[2:] if done else line
    priority = None
    projects: list[str] = []
    contexts: list[str] = []
    dates: dict[str, str] = {}
    created = None

    for token in body.split():
        if token.startswith("+"):
            projects.append(token[1:])
        elif token.startswith("@"):
            contexts.append(token[1:])
        else:
            key, separator, value = token.partition(":")
            if separator and value and _KEY.fullmatch(key):
                dates[key] = value
            elif created is None and _DATE.fullmatch(token):
                created = token

    opening = _PRIORITY.match(body)
    if opening:
        priority = opening.group(1)

    return {
        "done": done,
        "priority": priority,
        "projects": projects,
        "contexts": contexts,
        "dates": dates,
        "created": created,
    }


def _lines(path: Path) -> list[str]:
    """Every non-blank line of one file, verbatim and in file order."""

    try:
        raw = path.read_bytes()
    except OSError as exc:
        raise PublishError(f"{path} is unreadable") from exc
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise PublishError(f"{path} is not valid UTF-8") from exc
    return [line for line in text.splitlines() if line.strip()]


def collect_tasks(
    entities_dir: str | Path,
    generation: StagingGeneration,
    *,
    captured_at: str,
) -> CollectReport:
    """Enumerate ``todo.txt`` then ``done.txt`` into ``generation``; never commit."""

    root = resolve_source_dir(entities_dir, "todo directory")
    previous = previous_replica(generation)

    present = [name for name in FILES if (root / name).is_file()]
    if not present:
        raise PublishError(
            f"todo directory {root} holds neither "
            f"{' nor '.join(FILES)}; refusing to publish an empty list"
        )

    seen: set[str] = set()
    duplicates = 0
    lines = 0
    for name in present:
        for line in _lines(root / name):
            lines += 1
            digest = hashlib.sha256(line.encode("utf-8")).hexdigest()[:16]
            object_id = f"tasks::{digest}"
            if object_id in seen:
                duplicates += 1
                continue
            seen.add(object_id)
            parsed = _parse(line)
            generation.put(
                object_id,
                canonical_json(
                    {"task_id": object_id, "text": line, "file": name, **parsed}
                ),
                {
                    "source_id": SOURCE_ID,
                    "captured_at": captured_at,
                    "file": name,
                    **parsed,
                },
            )

    carried = carry_forward(
        generation,
        previous,
        reason=ABSENCE_NO_TOMBSTONE,
        captured_at=captured_at,
    )
    return CollectReport(
        source_id=SOURCE_ID,
        generation_id=generation.generation_id,
        objects=len(seen),
        carried=carried,
        deleted=0,
        details={
            "files": len(present),
            "lines": lines,
            "duplicates": duplicates,
        },
    )


def fidelity_fields() -> Iterable[str]:
    """No declared limits: every field is read off the line, which stays whole."""

    return ()
