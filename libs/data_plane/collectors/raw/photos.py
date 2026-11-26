"""Raw photos: a photo library becomes one metadata object per asset.

Immich keeps the originals under ``library/`` inside its media location, beside
``thumbs/``, ``encoded-video/`` and ``upload/``; the collector walks that
directory when it is there, so a thumbnail or a transcode never becomes a second
object for one asset.

What the filesystem proves is all the generation carries: the path, the original
filename, the format, the size and the mtime. Camera EXIF, albums and dimensions
live in Immich's own database, and reading a second application's schema would
make every Immich migration a collector outage -- the derived index can reach
for richer metadata later without changing what was published here.
"""

from __future__ import annotations

import base64
import json
from pathlib import Path
from typing import Iterable
from urllib.parse import quote

from ...errors import PublishError
from .media import media_files, originals_root
from ..state import ReplicaState
from .replica import (
    ABSENCE_NO_TOMBSTONE,
    CollectReport,
    canonical_json,
    commit_pass,
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
        ".rw2",
        ".orf",
        ".3fr",
        ".srw",
        ".avif",
        ".mov",
        ".mp4",
        ".mts",
        ".3gp",
    }
)


def _title(path: Path) -> str:
    """The file's own name, or the name a branded upload path encodes.

    One upload path this library holds stores the original location as base64
    JSON in the filename, so the stem is 200 unsearchable characters. A stem that
    decodes to an object with a ``key`` takes the basename of that key; anything
    else keeps its stem, because a guess is worse than a name that is merely
    ugly.
    """

    stem = path.stem
    if not stem.startswith("eyJ"):
        return stem
    try:
        payload = json.loads(
            base64.urlsafe_b64decode(stem + "=" * (-len(stem) % 4))
        )
    except ValueError:
        return stem
    key = payload.get("key") if isinstance(payload, dict) else None
    if not isinstance(key, str):
        return stem
    name = key.rsplit("/", 1)[-1].rsplit(".", 1)[0]
    return name or stem


def collect_photos(
    entities_dir: str | Path,
    state: ReplicaState,
    *,
    captured_at: str,
) -> CollectReport:
    """Enumerate every media file into ``generation``; never commit it."""

    root = resolve_source_dir(entities_dir, "photo library")

    scan = media_files(originals_root(root), PHOTO_SUFFIXES)
    files = scan.files
    if not files:
        # An empty walk would carry every previous object forward as absent and
        # look like a library someone emptied on purpose.
        raise PublishError(
            f"{root} holds no photo or video; refusing to publish an empty library"
        )
    for media in files:
        try:
            object_id = f"photos::{quote(media.relative, safe='')}"
            fields = {
                "photo_id": object_id,
                "revision": media.revision,
                "path": media.relative,
                "title": _title(media.path),
                "format": media.path.suffix.lstrip(".").lower(),
                "size": media.size,
                "updated_at": media.updated_at,
            }
            state.put(
                object_id,
                canonical_json(fields),
                {
                    "source_id": SOURCE_ID,
                    "captured_at": captured_at,
                    **{
                        key: fields[key]
                        for key in ("path", "revision", "format", "size")
                    },
                },
            )
        except (OSError, UnicodeError) as exc:
            # A name the replica cannot store -- too long once quoted, or not
            # UTF-8 -- must refuse and name the file instead of aborting the run
            # with a traceback and leaving the staging generation behind.
            raise PublishError(f"{media.relative!r} could not be stored: {exc}") from exc

    return commit_pass(
        state,
        source_id=SOURCE_ID,
        objects=len(files),
        details={"files": len(files), "skipped": scan.skipped},
        captured_at=captured_at,
        absence_reason=ABSENCE_NO_TOMBSTONE,
    )


def fidelity_fields() -> Iterable[str]:
    """The schema's declared limits: previews and face model output stay derived."""

    return ("preview_renders", "face_embeddings")
