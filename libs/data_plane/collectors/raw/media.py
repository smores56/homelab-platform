"""Media trees: one metadata object per photo or track, and never the bytes.

Photos and music are the two sources whose objects are large: one photo is
megabytes, one track tens of them. The facade answers read and search from
metadata, so a generation carries identifiers, titles, timestamps and the size
and format the filesystem proves -- the media itself stays on its own dataset
and is never copied into the agent's state.

Three limits are deliberate:

* The walk stats, never reads. A revision is ``size:mtime_ns`` hashed, so a pass
  over a library of a hundred thousand files costs metadata I/O and nothing
  else; the revision a record cites is the hash of the metadata object, as for
  every other replica source.
* Symlinked files and directories are refused, never followed: a library that
  links outside itself must not pull foreign media into a replica that claims
  to be the library.
* ``MAX_MEDIA_OBJECTS`` is a refusal, not a truncation. A tree that suddenly
  holds more media than this is a wrong mount or a library this collector was
  not sized for, and a silent prefix would publish something that is not the
  library.
"""

from __future__ import annotations

import hashlib
import os
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from ...errors import PublishError

#: A generation is bounded. Raising this is a deliberate act, not a side effect.
MAX_MEDIA_OBJECTS = 100_000


@dataclass(frozen=True)
class MediaFile:
    """One media file, described by the stat a collection is allowed to make."""

    relative: str
    path: Path
    size: int
    updated_at: str
    revision: str


def _describe(relative: str, path: Path) -> MediaFile:
    info = path.stat()
    return MediaFile(
        relative=relative,
        path=path,
        size=info.st_size,
        updated_at=datetime.fromtimestamp(info.st_mtime, tz=timezone.utc).isoformat(
            timespec="seconds"
        ),
        revision=hashlib.sha256(
            f"{info.st_size}:{info.st_mtime_ns}".encode("ascii")
        ).hexdigest(),
    )


def media_files(root: Path, suffixes: frozenset[str]) -> list[MediaFile]:
    """Every file with one of ``suffixes``, sorted by its library-relative path.

    ``os.walk`` yields directories in filesystem order, which is why the result
    is sorted here: a re-collection must produce the same manifest every run.
    """

    found: list[MediaFile] = []
    for current, directories, filenames in os.walk(root, followlinks=False):
        base = Path(current)
        for name in directories:
            if (base / name).is_symlink():
                raise PublishError(f"{base / name} is a symlink; refusing to follow it")
        for name in filenames:
            path = base / name
            if path.suffix.lower() not in suffixes:
                continue
            if path.is_symlink():
                raise PublishError(f"{path} is a symlink; refusing to follow it")
            found.append(_describe(path.relative_to(root).as_posix(), path))
            if len(found) > MAX_MEDIA_OBJECTS:
                raise PublishError(
                    f"{root} holds more than {MAX_MEDIA_OBJECTS} media files; "
                    "refusing to publish a partial library"
                )
    found.sort(key=lambda media: media.relative)
    return found
