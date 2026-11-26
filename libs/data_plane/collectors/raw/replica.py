"""The absence ledger every collector shares, and the report one pass returns.

A raw replica is the provider's own bytes, written object by object into the
live state. Nothing here normalizes: the object ids and payloads are the
collector's, and a reader only verifies that what it returns is what the state
recorded.

The one policy here is the answer to "where did it go?":

* An object the pass no longer enumerates may only be dropped with a
  *tombstone*, and a tombstone is evidence of deletion the provider supplied.
  Maildir expunges and explicit ``deleted`` flags are that evidence.
* Retention expiry, a bounded 90-day finance window, a user deleting history in
  Brave, and an SDK that simply stops listing an event are *not* evidence. Those
  objects keep their bytes and are marked absent with a reason, so a Restic
  retention window can never quietly erase the last copy of something the
  provider stopped mentioning.
"""

from __future__ import annotations

import hashlib
import json
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable, Mapping

from ...errors import PublishError, ValidationError
from ..state import ABSENCE_REASON, ABSENT_SINCE

ABSENCE_PROVIDER_WINDOW = "provider-window"
ABSENCE_NO_TOMBSTONE = "provider-supplies-no-tombstone"
ABSENCE_RETENTION = "provider-retention-expiry"


@dataclass(frozen=True)
class CollectReport:
    """What one enumeration produced."""

    source_id: str
    objects: int
    carried: int
    deleted: int
    details: Mapping[str, Any] = field(default_factory=dict)
    #: The committed replica version: every pass advances it by one.
    version: int | None = None
    #: Kept for callers that still name a published generation; empty now.
    generation_id: str = ""


def commit_pass(
    state,
    *,
    source_id: str,
    objects: int,
    details: Mapping[str, Any],
    captured_at: str,
    absence_reason: str | None = None,
    deleted: int | None = None,
) -> CollectReport:
    """Commit one complete pass and report it, or report a dry run and commit none.

    Every raw collector enumerates its whole provider, so every one of them is a
    complete pass: what it did not see must be tombstoned by the collector or
    carried by ``absence_reason``. ``deleted`` lets a collector report deletions
    in its own unit (entities, not objects) when that differs from the number of
    tombstoned rows.
    """

    if state.dry_run:
        return CollectReport(
            source_id=source_id,
            objects=objects,
            carried=0,
            deleted=deleted or 0,
            details=details,
        )
    stats = state.commit(
        complete=True, absence_reason=absence_reason, captured_at=captured_at
    )
    return CollectReport(
        source_id=source_id,
        objects=objects,
        carried=stats.absent,
        deleted=stats.tombstoned if deleted is None else deleted,
        details=details,
        version=stats.version,
    )


def canonical_json(value: Any) -> bytes:
    """One byte representation per value, so a re-collection is reproducible."""

    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode(
        "utf-8"
    )


def resolve_source_dir(root: str | Path, label: str) -> Path:
    """A collector's input directory, or a refusal naming what was missing."""

    path = Path(root)
    if path.is_symlink():
        raise PublishError(f"{label} {path} is a symlink; refusing to follow it")
    if not path.is_dir():
        raise PublishError(f"{label} {path} is not a directory")
    return path


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def refuse_nonempty_dir_entries(entries: Iterable[os.DirEntry[str]], label: str) -> None:
    """A directory the collector should have consumed and did not."""

    leftovers = [entry.name for entry in entries]
    if leftovers:
        raise ValidationError(f"{label} has unconsumed entries: {', '.join(sorted(leftovers))}")
