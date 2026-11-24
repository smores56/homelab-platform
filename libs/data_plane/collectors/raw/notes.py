"""Raw notes: a Markdown vault becomes one immutable object per file.

A vault is a directory tree, and the file's relative path is the only identity
it has that survives an edit: an editor rewrites lines on save, so content
cannot name a note, and two notes can carry the same heading. The path is
therefore the object id -- URL-quoted, so a name with a space or a slash cannot
become a second path component in the replica -- and one object per file means
an edit is a new revision of the same id rather than a delete plus a create.

Three limits are deliberate:

* Frontmatter is not parsed. ``tags`` is always empty and the file's text stays
  whole in ``body``; a derived index can parse it later, while a parser bug here
  would quietly mangle the only copy of a note.
* Symlinked notes and directories are refused, never followed; a symlinked
  attachment is skipped with the other non-Markdown files. A vault that links
  outside itself must not pull foreign notes into a replica that claims to be
  the vault, and a linked directory skipped in silence would drop notes.
* A file the previous generation held and this one no longer sees is carried
  forward with a reason, not tombstoned: a vault copy can be a partial mount or
  a sync still landing, so absence alone is not a deletion this replica proves.
"""

from __future__ import annotations

import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable
from urllib.parse import quote

from ...errors import PublishError
from ..staging import StagingGeneration
from .replica import (
    ABSENCE_NO_TOMBSTONE,
    CollectReport,
    canonical_json,
    carry_forward,
    file_sha256,
    previous_replica,
    resolve_source_dir,
)

SOURCE_ID = "notes.markdown"


def _heading(text: str, stem: str) -> str:
    """The first ATX heading, else the file stem: a note always has a title."""

    for line in text.splitlines():
        if line.startswith("# "):
            title = line[2:].strip()
            if title:
                return title
    return stem


def _updated_at(path: Path) -> str:
    return datetime.fromtimestamp(
        path.stat().st_mtime, tz=timezone.utc
    ).isoformat(timespec="seconds")


def _markdown_files(root: Path) -> list[tuple[str, Path]]:
    """Every ``*.md`` file as (vault-relative POSIX path, path), sorted by that path.

    ``os.walk`` yields directories in filesystem order, which is why the result
    is sorted here: a re-collection must produce the same manifest every run.
    """

    found: list[tuple[str, Path]] = []
    for current, directories, filenames in os.walk(root, followlinks=False):
        base = Path(current)
        for name in directories:
            if (base / name).is_symlink():
                raise PublishError(f"{base / name} is a symlink; refusing to follow it")
        for name in filenames:
            path = base / name
            if path.suffix != ".md":
                continue
            if path.is_symlink():
                raise PublishError(f"{path} is a symlink; refusing to follow it")
            found.append((path.relative_to(root).as_posix(), path))
    found.sort(key=lambda item: item[0])
    return found


def collect_notes(
    entities_dir: str | Path,
    generation: StagingGeneration,
    *,
    captured_at: str,
) -> CollectReport:
    """Enumerate every Markdown file into ``generation``; never commit it."""

    root = resolve_source_dir(entities_dir, "vault")
    previous = previous_replica(generation)

    files = _markdown_files(root)
    for relative, path in files:
        try:
            raw = path.read_bytes()
        except OSError as exc:
            raise PublishError(f"{path} is unreadable") from exc
        try:
            body = raw.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise PublishError(f"{path} is not valid UTF-8") from exc
        digest = file_sha256(path)
        heading = _heading(body, path.stem)
        updated_at = _updated_at(path)
        object_id = f"notes::{quote(relative, safe='')}"
        generation.put(
            object_id,
            canonical_json(
                {
                    "note_id": object_id,
                    "revision": digest,
                    "path": relative,
                    "heading": heading,
                    "tags": [],
                    "updated_at": updated_at,
                    "body": body,
                }
            ),
            {
                "source_id": SOURCE_ID,
                "captured_at": captured_at,
                "path": relative,
                "heading": heading,
                "tags": [],
                "updated_at": updated_at,
                "body_sha256": digest,
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
        objects=len(files),
        carried=carried,
        deleted=0,
        details={"files": len(files)},
    )


def fidelity_fields() -> Iterable[str]:
    """The schema's declared limits: links and embeds stay text, never fetched."""

    return ("resolved_wikilinks", "remote_embeds")
