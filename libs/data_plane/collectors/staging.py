"""Staging generations, atomic publication, and durable source cursors.

A collector writes one complete enumeration under ``.staging/<generation>`` and
publishes it with a single rename into ``published/<generation>``. Nothing
partial ever appears under ``published``. Deletion is never inferred: an object
missing from the new generation must be named by a tombstone, or publication is
refused.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
from pathlib import Path
from typing import Any, Mapping
from urllib.parse import quote

from ..errors import CursorError, EpochError, PublishError, ValidationError

MANIFEST_NAME = "manifest.json"
STAGING_DIR = ".staging"
PUBLISHED_DIR = "published"

_UNSAFE_IDS = frozenset({".", ".."})


def _object_filename(object_id: str) -> str:
    if (
        not isinstance(object_id, str)
        or not object_id.strip()
        or object_id in _UNSAFE_IDS
        or "/" in object_id
        or "\x00" in object_id
    ):
        raise ValidationError(f"invalid object id {object_id!r}")
    return quote(object_id, safe="")


def _check_generation_id(generation_id: str) -> None:
    if (
        not isinstance(generation_id, str)
        or not generation_id.strip()
        or generation_id in _UNSAFE_IDS
        or "/" in generation_id
        or "\x00" in generation_id
    ):
        raise ValidationError(f"invalid generation id {generation_id!r}")


def _reject_symlink(path: Path, label: str) -> None:
    if path.is_symlink():
        raise PublishError(f"{label} {path} is a symlink; refusing to follow it")


class CursorStore:
    """A durable epoch and per-source high-water cursors.

    A rebuilt source gets a new epoch and no cursors: an old numeric cursor must
    never continue into a log that was rebuilt underneath it.
    """

    def __init__(self, path: str | Path) -> None:
        self._path = Path(path)
        self._epoch, self._cursors = self._load()

    @property
    def epoch(self) -> int:
        return self._epoch

    @property
    def cursors(self) -> Mapping[str, int]:
        return dict(self._cursors)

    def cursor(self, source: str) -> int | None:
        return self._cursors.get(source)

    def advance(self, source: str, cursor: int) -> None:
        if not isinstance(source, str) or not source.strip():
            raise ValidationError("source is required")
        if isinstance(cursor, bool) or not isinstance(cursor, int) or cursor < 1:
            raise CursorError(f"cursor {cursor!r} must be a positive integer")
        current = self._cursors.get(source)
        if current is not None and cursor <= current:
            raise CursorError(
                f"cursor {cursor} is not beyond {current} for source {source!r}"
            )
        self._cursors[source] = cursor
        self._write()

    def rebuild(self, epoch: int | None = None) -> int:
        next_epoch = self._epoch + 1 if epoch is None else epoch
        if next_epoch <= self._epoch:
            raise EpochError(f"epoch {next_epoch} does not advance {self._epoch}")
        self._epoch = next_epoch
        self._cursors.clear()
        self._write()
        return self._epoch

    def _load(self) -> tuple[int, dict[str, int]]:
        if not self._path.exists():
            return 1, {}
        try:
            raw = json.loads(self._path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise ValidationError(f"cursor store {self._path} is unreadable") from exc
        if not isinstance(raw, dict):
            raise ValidationError(f"cursor store {self._path} is not an object")
        epoch = raw.get("epoch", 1)
        cursors = raw.get("cursors", {})
        if isinstance(epoch, bool) or not isinstance(epoch, int) or epoch < 1:
            raise ValidationError(f"cursor store {self._path} has an invalid epoch")
        if not isinstance(cursors, dict):
            raise ValidationError(f"cursor store {self._path} has invalid cursors")
        for source, cursor in cursors.items():
            if not isinstance(source, str) or not source.strip():
                raise ValidationError(f"cursor store {self._path} has an invalid source")
            if isinstance(cursor, bool) or not isinstance(cursor, int) or cursor < 1:
                raise ValidationError(
                    f"cursor store {self._path} has an invalid cursor for {source!r}"
                )
        return epoch, dict(cursors)

    def _write(self) -> None:
        self._path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self._path.with_name(self._path.name + ".tmp")
        payload = {"epoch": self._epoch, "cursors": dict(sorted(self._cursors.items()))}
        temporary.write_text(
            json.dumps(payload, sort_keys=True, indent=2) + "\n", encoding="utf-8"
        )
        os.replace(temporary, self._path)


class StagingGeneration:
    """One private generation tree that can become the published replica.

    Generation ids must sort chronologically (for example ``gen-0001``); the
    latest earlier id is the generation whose objects a new commit must either
    keep or tombstone.
    """

    def __init__(
        self,
        root: str | Path,
        generation_id: str,
        *,
        cursor_store: CursorStore | None = None,
        source_id: str = "",
    ) -> None:
        _check_generation_id(generation_id)
        if cursor_store is not None and not source_id.strip():
            raise ValidationError("a cursor store needs a source id")
        self._root = Path(root)
        self._generation_id = generation_id
        self._staging = self._root / STAGING_DIR / generation_id
        self._published = self._root / PUBLISHED_DIR / generation_id
        self._cursor_store = cursor_store
        self._source_id = source_id
        self._epoch = cursor_store.epoch if cursor_store is not None else None
        self._objects: dict[str, dict[str, Any]] = {}
        self._tombstones: set[str] = set()
        self._reusable: dict[str, tuple[Path, int, str]] | None = None
        self._closed = False
        self._published_path: Path | None = None
        _reject_symlink(self._root / STAGING_DIR, "staging root")
        _reject_symlink(self._staging, "staging generation")
        self._staging.mkdir(parents=True, exist_ok=True)

    @property
    def root(self) -> Path:
        return self._root

    @property
    def generation_id(self) -> str:
        return self._generation_id

    @property
    def published_path(self) -> Path:
        if self._published_path is None:
            raise PublishError("generation is not published")
        return self._published_path

    def has_object(self, object_id: str) -> bool:
        """True when this generation already holds that object."""

        return object_id in self._objects

    def is_tombstoned(self, object_id: str) -> bool:
        """True when this generation names the object as deleted."""

        return object_id in self._tombstones

    def put(self, object_id: str, data: bytes, metadata: dict) -> None:
        self._require_open()
        filename = _object_filename(object_id)
        if not isinstance(data, bytes):
            raise ValidationError("object data must be bytes")
        if not isinstance(metadata, dict):
            raise ValidationError("object metadata must be a dict")
        try:
            json.dumps(metadata)
        except (TypeError, ValueError) as exc:
            raise ValidationError("object metadata is not JSON serializable") from exc

        objects = self._staging / "objects"
        _reject_symlink(objects, "object directory")
        objects.mkdir(parents=True, exist_ok=True)
        destination = objects / filename
        _reject_symlink(destination, "object path")
        digest = hashlib.sha256(data).hexdigest()
        if not self._link_previous(object_id, destination, len(data), digest):
            destination.write_bytes(data)
        self._objects[object_id] = {
            "object_id": object_id,
            "filename": filename,
            "size": len(data),
            "sha256": digest,
            "metadata": dict(metadata),
        }
        self._tombstones.discard(object_id)

    def _reusable_objects(self) -> dict[str, tuple[Path, int, str]]:
        """The previous generation's object files, for linking instead of copying.

        Every collector re-enumerates its whole source, so a scheduled run would
        otherwise write a second full copy of the source on every tick, and the
        mail collector -- one run per hour, every message every time -- is the
        case that makes that untenable. An object is immutable by contract, so an
        unchanged object id with unchanged bytes can share the previous
        generation's inode; a changed byte writes a new file.

        Only the immediately previous generation is consulted. Reaching further
        back would resurrect the bytes of an object that a later generation
        tombstoned, which is the one thing a replica must not quietly do.
        """

        if self._reusable is not None:
            return self._reusable
        index: dict[str, tuple[Path, int, str]] = {}
        previous = self._previous_manifest()
        if previous is not None:
            objects = (
                self._root
                / PUBLISHED_DIR
                / previous["generation_id"]
                / "objects"
            )
            for entry in previous["objects"]:
                size, digest = entry.get("size"), entry.get("sha256")
                if isinstance(size, int) and not isinstance(size, bool) and isinstance(
                    digest, str
                ):
                    index[entry["object_id"]] = (objects, size, digest)
        self._reusable = index
        return index

    def _link_previous(
        self, object_id: str, destination: Path, size: int, digest: str
    ) -> bool:
        """Link the previous generation's file when it holds these exact bytes.

        Returns whether the file is in place. A link that the filesystem refuses
        is not an error: the bytes still get written below.
        """

        previous = self._reusable_objects().get(object_id)
        if previous is None or previous[1] != size or previous[2] != digest:
            return False
        source = previous[0] / _object_filename(object_id)
        if source.is_symlink() or not source.is_file():
            return False
        try:
            os.link(source, destination)
        except OSError:
            return False
        return True

    def link(
        self,
        object_id: str,
        source: Path,
        metadata: dict,
        *,
        size: int,
        sha256: str,
    ) -> None:
        """Record an object whose bytes already exist at ``source``.

        Carrying a whole mailbox forward means recording a hundred thousand
        objects whose bytes are already in the previous generation. Reading each
        one back into Python to hash it would make every pass cost the size of the
        mailbox, so this records the previous generation's own digest instead --
        it was verified when that generation was published, and a reader still
        verifies the bytes against the manifest.

        The source is linked rather than copied, so the cost is one inode update.
        """

        self._require_open()
        filename = _object_filename(object_id)
        if not isinstance(source, Path):
            source = Path(source)
        if source.is_symlink() or not source.is_file():
            raise PublishError(f"{source} is not a regular file to carry forward")
        if isinstance(size, bool) or not isinstance(size, int) or size < 0:
            raise ValidationError("carried size must be a non-negative integer")
        if (
            not isinstance(sha256, str)
            or len(sha256) != 64
            or any(character not in "0123456789abcdef" for character in sha256)
        ):
            raise ValidationError("carried sha256 must be 64 lowercase hex digits")
        if not isinstance(metadata, dict):
            raise ValidationError("object metadata must be a dict")
        try:
            json.dumps(metadata)
        except (TypeError, ValueError) as exc:
            raise ValidationError("object metadata is not JSON serializable") from exc

        objects = self._staging / "objects"
        _reject_symlink(objects, "object directory")
        objects.mkdir(parents=True, exist_ok=True)
        destination = objects / filename
        _reject_symlink(destination, "object path")
        if destination.exists():
            raise PublishError(f"object {object_id!r} is already in this generation")
        try:
            os.link(source, destination)
        except OSError:
            # A different filesystem or a refusing policy is not a corruption: the
            # bytes are still the previous generation's, so copy them.
            shutil.copyfile(source, destination)
        self._objects[object_id] = {
            "object_id": object_id,
            "filename": filename,
            "size": size,
            "sha256": sha256,
            "metadata": dict(metadata),
        }
        self._tombstones.discard(object_id)

    def delete(self, object_id: str) -> None:
        self._require_open()
        filename = _object_filename(object_id)
        objects = self._staging / "objects"
        _reject_symlink(objects, "object directory")
        if object_id in self._objects:
            _reject_symlink(objects / filename, "object path")
            (objects / filename).unlink(missing_ok=True)
            del self._objects[object_id]
        self._tombstones.add(object_id)

    def commit_next(self, *, complete: bool = False) -> Path:
        """Publish with the next cursor, for a source that has none of its own.

        A file-backed collector has no external cursor: its completeness is the
        enumeration itself. Giving each generation the next number keeps the
        commit's monotonic, gapless rule meaningful without inventing state a
        provider never supplied.
        """

        return self.commit(self._base_cursor() + 1, complete=complete)

    def abort(self) -> None:
        if self._closed:
            return
        shutil.rmtree(self._staging, ignore_errors=True)
        self._closed = True

    def commit(self, cursor: int, *, complete: bool = False) -> Path:
        """Publish the generation when enumeration is complete and gapless."""

        self._require_open()
        if not complete:
            raise PublishError("enumeration is not complete")
        if isinstance(cursor, bool) or not isinstance(cursor, int) or cursor < 1:
            raise ValidationError("cursor must be a positive integer")

        base = self._base_cursor()
        if cursor <= base:
            raise CursorError(f"cursor {cursor} is not beyond {base}")
        if cursor != base + 1:
            raise CursorError(f"cursor {cursor} skips a gap after {base}")

        if self._cursor_store is not None:
            if self._cursor_store.epoch != self._epoch:
                raise EpochError(
                    "cursor epoch changed; reconcile the source before publishing"
                )

        previous = self._previous_manifest()
        if previous is not None:
            prior = {entry["object_id"] for entry in previous["objects"]}
            missing = prior - set(self._objects) - self._tombstones
            if missing:
                raise PublishError(
                    "missing tombstones for published objects: "
                    + ", ".join(sorted(missing))
                )

        self._write_manifest(cursor)
        _reject_symlink(self._staging, "staging generation")
        published_root = self._root / PUBLISHED_DIR
        _reject_symlink(published_root, "published root")
        published_root.mkdir(parents=True, exist_ok=True)
        if self._published.is_symlink() or self._published.exists():
            raise PublishError(f"generation {self._generation_id!r} already exists")
        os.replace(self._staging, self._published)
        self._closed = True
        self._published_path = self._published
        if self._cursor_store is not None:
            self._cursor_store.advance(self._source_id, cursor)
        return self._published

    def _require_open(self) -> None:
        if self._closed:
            raise PublishError("generation is already closed")

    def _base_cursor(self) -> int:
        base = 0
        previous = self._previous_manifest()
        if previous is not None:
            base = int(previous["cursor"])
        if self._cursor_store is not None:
            stored = self._cursor_store.cursor(self._source_id)
            if stored is not None:
                base = max(base, stored)
        return base

    def _previous_manifest(self) -> dict[str, Any] | None:
        published = self._root / PUBLISHED_DIR
        if not published.is_dir():
            return None
        earlier = sorted(
            entry.name
            for entry in published.iterdir()
            if entry.is_dir() and entry.name < self._generation_id
        )
        if not earlier:
            return None
        path = published / earlier[-1] / MANIFEST_NAME
        if not path.is_file():
            raise PublishError(f"published generation {earlier[-1]!r} has no manifest")
        try:
            manifest = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise PublishError(
                f"published generation {earlier[-1]!r} is unreadable"
            ) from exc
        if not isinstance(manifest, dict) or not isinstance(
            manifest.get("objects"), list
        ):
            raise PublishError(f"published generation {earlier[-1]!r} is invalid")
        cursor = manifest.get("cursor")
        if isinstance(cursor, bool) or not isinstance(cursor, int) or cursor < 0:
            raise PublishError(
                f"published generation {earlier[-1]!r} has an invalid cursor"
            )
        for entry in manifest["objects"]:
            if not isinstance(entry, dict) or not isinstance(
                entry.get("object_id"), str
            ):
                raise PublishError(
                    f"published generation {earlier[-1]!r} has an invalid object entry"
                )
        return manifest

    def _write_manifest(self, cursor: int) -> None:
        manifest = {
            "generation_id": self._generation_id,
            "source_id": self._source_id,
            "epoch": self._epoch,
            "cursor": cursor,
            "objects": sorted(self._objects.values(), key=lambda item: item["object_id"]),
            "tombstones": [
                {"object_id": object_id, "tombstone": True}
                for object_id in sorted(self._tombstones)
            ],
        }
        temporary = self._staging / (MANIFEST_NAME + ".tmp")
        temporary.write_text(
            json.dumps(manifest, sort_keys=True, indent=2) + "\n", encoding="utf-8"
        )
        os.replace(temporary, self._staging / MANIFEST_NAME)
