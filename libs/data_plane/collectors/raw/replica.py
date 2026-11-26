"""Reading a published raw generation, and the absence rule every collector shares.

A raw replica is the provider's own bytes, written object by object into a
staging generation and published by one rename. Nothing in this module
normalizes: the object ids and payloads are the collector's, and a reader only
verifies that what it returns is what the manifest recorded.

The one policy here is the answer to "where did it go?":

* A generation that no longer enumerates an object may only drop it with a
  *tombstone*, and a tombstone is evidence of deletion the provider supplied.
  Maildir expunges and explicit ``deleted`` flags are that evidence.
* Retention expiry, a bounded 90-day finance window, a user deleting history in
  Brave, and an SDK that simply stops listing an event are *not* evidence. Those
  objects are carried forward unchanged and marked ``absent_since`` with a
  reason, so a Restic retention window can never quietly erase the last copy of
  something the provider stopped mentioning.

``carry_forward`` implements the second rule and is the reason the collectors
never call ``delete`` on their own judgement.
"""

from __future__ import annotations

import hashlib
import json
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable, Mapping

from ...errors import ManifestError, PublishError, ValidationError
from ..staging import MANIFEST_NAME, PUBLISHED_DIR, StagingGeneration
from ..state import ABSENCE_REASON, ABSENT_SINCE

ABSENCE_PROVIDER_WINDOW = "provider-window"
ABSENCE_NO_TOMBSTONE = "provider-supplies-no-tombstone"
ABSENCE_RETENTION = "provider-retention-expiry"


@dataclass(frozen=True)
class RawObject:
    object_id: str
    data: bytes
    metadata: Mapping[str, Any]


@dataclass(frozen=True)
class CollectReport:
    """What one enumeration produced."""

    source_id: str
    objects: int
    carried: int
    deleted: int
    details: Mapping[str, Any] = field(default_factory=dict)
    #: The published generation, for a collector that still writes one.
    generation_id: str = ""
    #: The committed replica version, for a collector that writes the live store.
    version: int | None = None


class RawReplica:
    """One published generation, read back and verified against its manifest.

    The manifest is the authority: a reader checks every object's size and
    sha256 before returning it, refuses a filename that is not a plain name, and
    refuses a symlink, so a damaged or hand-edited replica fails loudly instead
    of serving different bytes than the generation recorded.
    """

    def __init__(self, root: str | Path, generation_id: str | None = None) -> None:
        self._root = Path(root)
        self._published = self._root / PUBLISHED_DIR
        if self._published.is_symlink():
            raise ManifestError(f"{self._published} is a symlink; refusing to follow it")
        if generation_id is None:
            generation_id = self.latest_generation(self._root)
            if generation_id is None:
                raise ManifestError(f"{self._root} has no published generation")
        self._generation_id = generation_id
        self._path = self._published / generation_id
        if not self._path.is_dir():
            raise ManifestError(f"generation {generation_id!r} is not published")
        self._manifest = self._load_manifest()
        # The manifest is the reader's hot path: ``read`` resolves one id per
        # object it projects, and scanning the list each time is quadratic over a
        # library-sized generation.
        self._entries_by_id: dict[str, Mapping[str, Any]] = {
            entry["object_id"]: entry for entry in self._manifest["objects"]
        }

    @staticmethod
    def latest_generation(root: str | Path) -> str | None:
        """The newest published generation id, or ``None`` before the first one."""

        published = Path(root) / PUBLISHED_DIR
        if not published.is_dir() or published.is_symlink():
            return None
        names = sorted(
            entry.name
            for entry in published.iterdir()
            if entry.is_dir() and not entry.is_symlink()
        )
        return names[-1] if names else None

    @property
    def generation_id(self) -> str:
        return self._generation_id

    @property
    def path(self) -> Path:
        return self._path

    @property
    def snapshot(self) -> str:
        """The name a derivation of this replica can be cached under."""

        return self._generation_id

    @property
    def manifest(self) -> Mapping[str, Any]:
        return self._manifest

    @property
    def source_id(self) -> str:
        value = self._manifest.get("source_id")
        return value if isinstance(value, str) else ""

    @property
    def epoch(self) -> int | None:
        value = self._manifest.get("epoch")
        return value if isinstance(value, int) and not isinstance(value, bool) else None

    @property
    def cursor(self) -> int:
        value = self._manifest.get("cursor")
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise ManifestError(f"generation {self._generation_id!r} has no cursor")
        return value

    def entries(self) -> tuple[Mapping[str, Any], ...]:
        """Every object entry, in the manifest's sorted order."""

        return tuple(self._manifest["objects"])

    def object_ids(self) -> tuple[str, ...]:
        return tuple(entry["object_id"] for entry in self._manifest["objects"])

    def metadata(self, object_id: str) -> Mapping[str, Any]:
        return dict(self._entry(object_id)["metadata"])

    def read(self, object_id: str) -> bytes:
        entry = self._entry(object_id)
        filename = entry["filename"]
        if not isinstance(filename, str) or "/" in filename or filename in {".", ".."}:
            raise ManifestError(
                f"generation {self._generation_id!r} has an unsafe filename {filename!r}"
            )
        path = self._path / "objects" / filename
        if path.is_symlink():
            raise ManifestError(f"{path} is a symlink; refusing to follow it")
        try:
            data = path.read_bytes()
        except OSError as exc:
            raise ManifestError(f"{object_id!r} is unreadable") from exc
        recorded = entry.get("sha256")
        if hashlib.sha256(data).hexdigest() != recorded:
            raise ManifestError(f"{object_id!r} does not match its recorded sha256")
        size = entry.get("size")
        if isinstance(size, int) and size != len(data):
            raise ManifestError(f"{object_id!r} does not match its recorded size")
        return data

    def object(self, object_id: str) -> RawObject:
        entry = self._entry(object_id)
        return RawObject(
            object_id=object_id,
            data=self.read(object_id),
            metadata=dict(entry["metadata"]),
        )

    def iter_objects(self) -> Iterable[RawObject]:
        for object_id in self.object_ids():
            yield self.object(object_id)

    def carry_into(
        self,
        generation: StagingGeneration,
        object_id: str,
        metadata: Mapping[str, Any],
    ) -> None:
        """Put this generation's object into ``generation`` without reading it.

        The previous manifest already holds the size and the digest, and this
        generation is immutable, so a carry is a link plus a manifest entry rather
        than a read and a hash.
        """

        entry = self._entry(object_id)
        generation.link(
            object_id,
            self._path / "objects" / entry["filename"],
            dict(metadata),
            size=int(entry["size"]),
            sha256=str(entry["sha256"]),
        )

    def _entry(self, object_id: str) -> Mapping[str, Any]:
        if not isinstance(object_id, str):
            raise ValidationError("object id must be a string")
        try:
            return self._entries_by_id[object_id]
        except KeyError:
            raise ManifestError(
                f"generation {self._generation_id!r} has no object {object_id!r}"
            ) from None

    def _load_manifest(self) -> dict[str, Any]:
        path = self._path / MANIFEST_NAME
        if path.is_symlink() or not path.is_file():
            raise ManifestError(f"generation {self._generation_id!r} has no manifest")
        try:
            manifest = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise ManifestError(
                f"generation {self._generation_id!r} has an unreadable manifest"
            ) from exc
        if not isinstance(manifest, dict) or not isinstance(
            manifest.get("objects"), list
        ):
            raise ManifestError(f"generation {self._generation_id!r} has an invalid manifest")
        for entry in manifest["objects"]:
            if (
                not isinstance(entry, dict)
                or not isinstance(entry.get("object_id"), str)
                or not isinstance(entry.get("metadata"), dict)
            ):
                raise ManifestError(
                    f"generation {self._generation_id!r} has an invalid object entry"
                )
        return manifest


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


def previous_replica(generation: StagingGeneration) -> RawReplica | None:
    """The published generation a new commit must account for, if there is one.

    ``StagingGeneration`` picks the same generation for its tombstone check; this
    is the reader's copy of that choice, so a collector can carry objects
    forward before the commit refuses the ones it forgot.
    """

    root = generation.root
    current = generation.generation_id
    published = root / PUBLISHED_DIR
    if not published.is_dir() or published.is_symlink():
        return None
    earlier = sorted(
        entry.name
        for entry in published.iterdir()
        if entry.is_dir() and not entry.is_symlink() and entry.name < current
    )
    return RawReplica(root, earlier[-1]) if earlier else None


def carry_forward(
    generation: StagingGeneration,
    previous: RawReplica | None,
    *,
    reason: str,
    captured_at: str,
) -> int:
    """Keep every earlier object this enumeration did not produce.

    The object keeps its bytes and its metadata; ``absent_since`` is added the
    first time it goes missing and never moves afterwards, so a later generation
    can tell "gone since March" from "gone since this run".
    """

    if not reason.strip():
        raise ValidationError("carry_forward needs an absence reason")
    if previous is None:
        return 0
    carried = 0
    for entry in previous.entries():
        object_id = entry["object_id"]
        if generation.has_object(object_id):
            continue
        # A tombstone is the one thing that outranks carrying forward: the
        # provider said it was deleted, so re-adding it would resurrect it.
        if generation.is_tombstoned(object_id):
            continue
        metadata = dict(entry["metadata"])
        metadata.setdefault(ABSENT_SINCE, captured_at)
        metadata[ABSENCE_REASON] = reason
        previous.carry_into(generation, object_id, metadata)
        carried += 1
    return carried


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
