"""Media trees: one metadata object per photo or track, and never the bytes.

Photos and music are the two sources whose objects are large: one photo is
megabytes, one track tens of them. The facade answers read and search from
metadata, so the state carries identifiers, titles, timestamps and the size
and format the filesystem proves -- the media itself stays on its own dataset
and is never copied into the agent's state.

Four limits are deliberate:

* The walk stats, never reads. A revision is ``size:mtime_ns`` hashed, so a pass
  over a library of a hundred thousand files costs metadata I/O and nothing
  else; the revision a record cites is the hash of the metadata object, as for
  every other replica source.
* Symlinked files and directories are refused, never followed: a library that
  links outside itself must not pull foreign media into a replica that claims
  to be the library.
* ``MAX_MEDIA_OBJECTS`` and an empty walk are refusals, not truncation. A tree
  that suddenly holds more media than this is a wrong mount or a library this
  collector was not sized for, and a silent prefix would publish something that
  is not the library. An empty walk is the same mistake seen from the other
  side: it would carry every previous object forward as absent and look like a
  library that was emptied on purpose.
* A directory the walk cannot read is a refusal. ``os.walk`` swallows the error
  by default and yields fewer files, which would publish a partial library with
  a green unit -- the one thing the refusal design exists to prevent.
"""

from __future__ import annotations

import hashlib
import os
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from ...errors import PublishError

#: One media pass is bounded. Raising this is a deliberate act, not a side effect.
MAX_MEDIA_OBJECTS = 100_000

#: Immich keeps the originals in ``library/`` beside the trees it derives from
#: them (``thumbs/``, ``encoded-video/``, ``profile/``, ``upload/``), and the
#: media location is what gets mounted. Walking the location itself would publish
#: every thumbnail and transcode as a second copy of an asset, so the originals
#: root is walked when it is there and the given root otherwise.
ORIGINALS_DIRECTORY = "library"


@dataclass(frozen=True)
class MediaFile:
    """One media file, described by the stat a collection is allowed to make."""

    relative: str
    path: Path
    size: int
    updated_at: str
    revision: str


@dataclass(frozen=True)
class MediaScan:
    """One walk's result: the media, and how many other files it passed."""

    files: tuple[MediaFile, ...]
    skipped: int


def originals_root(root: Path) -> Path:
    """The directory holding the originals, allowing for Immich's layout."""

    library = root / ORIGINALS_DIRECTORY
    if library.is_dir() and not library.is_symlink():
        return library
    return root


def _describe(relative: str, path: Path) -> MediaFile:
    try:
        info = path.stat()
    except OSError as exc:
        raise PublishError(
            f"{path} could not be read: {exc.strerror or exc}"
        ) from exc
    try:
        updated_at = datetime.fromtimestamp(info.st_mtime, tz=timezone.utc).isoformat(
            timespec="seconds"
        )
    except (OverflowError, ValueError) as exc:
        # A restored or corrupt archive can carry an mtime outside what a datetime
        # can name; refusing names the file instead of aborting with a traceback.
        raise PublishError(f"{path} has an mtime that cannot be represented") from exc
    return MediaFile(
        relative=relative,
        path=path,
        size=info.st_size,
        updated_at=updated_at,
        revision=hashlib.sha256(
            f"{info.st_size}:{info.st_mtime_ns}".encode("ascii")
        ).hexdigest(),
    )


def _refuse_walk_error(error: OSError) -> None:
    raise PublishError(
        f"{error.filename} could not be walked: {error.strerror or error}"
    ) from error


def media_files(root: Path, suffixes: frozenset[str]) -> MediaScan:
    """Every file with one of ``suffixes``, sorted by its library-relative path.

    ``os.walk`` yields directories in filesystem order, which is why the result
    is sorted here: a re-collection must produce the same manifest every run.
    """

    found: list[MediaFile] = []
    skipped = 0
    for current, directories, filenames in os.walk(
        root, onerror=_refuse_walk_error, followlinks=False
    ):
        base = Path(current)
        for name in directories:
            if (base / name).is_symlink():
                raise PublishError(f"{base / name} is a symlink; refusing to follow it")
        for name in filenames:
            path = base / name
            if path.suffix.lower() not in suffixes:
                skipped += 1
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
    return MediaScan(files=tuple(found), skipped=skipped)
