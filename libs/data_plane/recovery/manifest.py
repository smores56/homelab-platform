"""Public recovery manifest: one entry per group, strongest tier first.

The recovery page reads this small document, not the internals of the backup
runner. Each group names the repository the page should restore from and the
root inside the snapshot that the reader sees.
"""

from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path
from typing import Any

from ..backup.plan import BackupPlan
from ..errors import ManifestError

MANIFEST_VERSION = 1

#: Strongest first: the public page prefers the offsite copy.
TIER_PREFERENCE = ("r2", "hdd", "nvme")


def build_manifest(plan: BackupPlan) -> dict[str, Any]:
    """Build the public manifest for every group in the plan."""

    groups = []
    for group in plan.groups:
        tier = next(
            (name for name in TIER_PREFERENCE if name in group.tiers),
            group.primary_tier,
        )
        groups.append(
            {
                "id": group.id,
                "label": group.id,
                "repo": plan.repository(group.id, tier),
                "data_root": "/" + group.path,
            }
        )
    return {"schema_version": MANIFEST_VERSION, "groups": groups}


def write_manifest(
    path: str | os.PathLike[str], plan: BackupPlan, *, overwrite: bool = False
) -> Path:
    """Write the manifest through a temporary file, fsync, and atomic rename."""

    target = Path(path)
    if target.exists() and not overwrite:
        raise ManifestError(f"manifest {target} already exists; refusing to overwrite")
    data = json.dumps(build_manifest(plan), sort_keys=True, separators=(",", ":")) + "\n"
    temporary = ""
    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        handle, temporary = tempfile.mkstemp(
            prefix=f".{target.name}.", suffix=".tmp", dir=target.parent
        )
    except OSError as exc:
        raise ManifestError(f"cannot stage manifest {target}: {exc}") from exc
    try:
        with os.fdopen(handle, "wb") as file:
            file.write(data.encode("utf-8"))
            file.flush()
            os.fsync(file.fileno())
        os.replace(temporary, target)
        temporary = ""
    except OSError as exc:
        raise ManifestError(f"cannot write manifest {target}: {exc}") from exc
    finally:
        if temporary and os.path.exists(temporary):
            os.unlink(temporary)
    try:
        directory = os.open(target.parent, os.O_RDONLY)
    except OSError:
        pass
    else:
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    return target
