"""Raw music: a music library becomes one metadata object per track.

Navidrome scans the same tree, so the directory layout is the library's own
naming and the only thing this collector reads: ``Artist/Album/Track`` becomes
the artist and album, a leading track number becomes ``track``, and the rest of
the filename is the title.

Tags live inside the audio files, which this collector must not read at gigabyte
scale for a search index; the derived index can open them later without changing
what was published here. A file with one directory above it therefore claims
neither an artist nor an album: a ``singles/`` or ``Compilations/`` folder must
not be published as an artist.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Iterable
from urllib.parse import quote

from ...errors import PublishError
from .media import media_files
from ..state import ReplicaState
from .replica import (
    ABSENCE_NO_TOMBSTONE,
    CollectReport,
    canonical_json,
    commit_pass,
    resolve_source_dir,
)

SOURCE_ID = "music.library"

#: The audio suffixes a Navidrome-style library holds. Artwork and playlists are
#: not tracks and are skipped with everything else.
AUDIO_SUFFIXES = frozenset(
    {
        ".flac",
        ".mp3",
        ".m4a",
        ".m4b",
        ".aac",
        ".ogg",
        ".opus",
        ".wav",
        ".aif",
        ".aiff",
        ".wma",
        ".ape",
        ".dsf",
        ".wv",
    }
)

#: ``01 - Title``, ``02 Title``, ``3.Title``: a separator must follow the number,
#: so an album or track called ``1979`` keeps its name.
_TRACK_PREFIX = re.compile(r"^(\d{1,3})(?:\s*[-._]\s*|\s+)(.+)$")


def _describe_path(relative: str) -> tuple[str, str, int | None, str]:
    """``(artist, album, track, title)`` from the library-relative path alone."""

    parts = relative.split("/")
    stem = Path(parts[-1]).stem
    match = _TRACK_PREFIX.match(stem)
    track = int(match.group(1)) if match else None
    title = match.group(2).strip() if match else stem
    directories = parts[:-1]
    if len(directories) < 2:
        return "", "", track, title
    return directories[0], directories[1], track, title


def collect_music(
    entities_dir: str | Path,
    state: ReplicaState,
    *,
    captured_at: str,
) -> CollectReport:
    """Enumerate every audio file into ``generation``; never commit it."""

    root = resolve_source_dir(entities_dir, "music library")

    scan = media_files(root, AUDIO_SUFFIXES)
    files = scan.files
    if not files:
        # An empty walk would carry every previous track forward as absent and
        # look like a library someone emptied on purpose.
        raise PublishError(
            f"{root} holds no audio track; refusing to publish an empty library"
        )
    for media in files:
        try:
            object_id = f"music::{quote(media.relative, safe='')}"
            artist, album, track, title = _describe_path(media.relative)
            fields = {
                "track_id": object_id,
                "revision": media.revision,
                "path": media.relative,
                "title": title,
                "artist": artist,
                "album": album,
                "track": track,
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
                        for key in ("path", "revision", "format", "size", "artist", "album")
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
    """The schema's declared limits: transcodes and loudness stay derived."""

    return ("streaming_transcodes", "loudness_analysis")
