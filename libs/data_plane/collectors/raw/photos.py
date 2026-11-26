"""Raw photos: a photo library becomes one metadata object per asset.

Immich keeps the library as plain files under one dataset, so the tree is the
only thing this collector needs: an asset's relative path is its identity, and
one object per file makes a re-upload a new revision rather than a delete plus a
create.

What the filesystem proves is all the generation carries: the path, the original
filename, the format, the size and the mtime. Camera EXIF, albums and dimensions
live in Immich's own database, and reading a second application's schema would
make every Immich migration a collector outage -- the derived index can reach
for richer metadata later without changing what was published here.
"""

from __future__ import annotations

from pathlib import Path
from typing import Iterable
from urllib.parse import quote

from ..staging import StagingGeneration
from .media import media_files
from .replica import (
    ABSENCE_NO_TOMBSTONE,
    CollectReport,
    canonical_json,
    carry_forward,
    previous_replica,
    resolve_source_dir,
)

SOURCE_ID = "photos.library"

#: The suffixes an Immich-style library holds. Anything else in the tree is a
#: sidecar, a thumbnail cache or the database, and is skipped.
PHOTO_SUFFIXES = frozenset(
    {
        ".jpg",
        ".jpeg",
        ".png",
        ".heic",
        ".heif",
        ".webp",
        ".gif",
        ".tif",
        ".tiff",
        ".dng",
        ".cr2",
        ".nef",
        ".arw",
        ".raf",
        ".mov",
        ".mp4",
    }
)


def collect_photos(
    entities_dir: str | Path,
    generation: StagingGeneration,
    *,
    captured_at: str,
) -> CollectReport:
    """Enumerate every media file into ``generation``; never commit it."""

    root = resolve_source_dir(entities_dir, "photo library")
    previous = previous_replica(generation)

    files = media_files(root, PHOTO_SUFFIXES)
    for media in files:
        object_id = f"photos::{quote(media.relative, safe='')}"
        fields = {
            "photo_id": object_id,
            "revision": media.revision,
            "path": media.relative,
            "title": media.path.stem,
            "format": media.path.suffix.lstrip(".").lower(),
            "size": media.size,
            "updated_at": media.updated_at,
        }
        generation.put(
            object_id,
            canonical_json(fields),
            {
                "source_id": SOURCE_ID,
                "captured_at": captured_at,
                **{key: fields[key] for key in ("path", "revision", "format", "size")},
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
    """The schema's declared limits: previews and face model output stay derived."""

    return ("preview_renders", "face_embeddings")
