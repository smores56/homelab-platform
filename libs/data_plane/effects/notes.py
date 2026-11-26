"""The Markdown vault as a broker write target.

A note's identity is its relative path, so the adapter names targets exactly as
the replica does (``notes::<quoted path>``) and a write lands on the object the
facade already reads. The heading is derived with the collector's own rule so a
read-back cannot disagree with the next pass, and the record ``read`` returns
carries the body: that is what makes the broker's pre-image a real undo record.

Three refusals are deliberate. A create whose bytes are already on disk is a
success, because the file is the proof the write landed; a create that finds
other bytes is refused, because it is a different write. A write field other
than ``body`` is refused: ``heading`` and ``updated_at`` are functions of the
body and the file, and accepting them would promise a value the next read could
not reproduce. A delete declares its tombstone before it unlinks, so a crash in
between leaves evidence of an intent, never of a completed deletion.
"""

from __future__ import annotations

import hashlib
from datetime import UTC, datetime
from pathlib import Path
from urllib.parse import quote, unquote

from ..collectors.raw.notes import heading
from ..confirmation import NormalizedOperation
from ..errors import ValidationError
from ..identity import canonical_json
from .confine import MAX_FILE_BYTES, ConfinedRoot, Snapshot
from .tombstones import TombstoneLog

SOURCE_ID = "notes.markdown"
TARGET_PREFIX = "notes::"
MAX_RESULTS = 50

_WRITABLE = ("body",)


def _now() -> str:
    return datetime.now(tz=UTC).isoformat(timespec="seconds")


def _encode(text: str, relative: str) -> bytes:
    if "\x00" in text:
        raise ValidationError(f"{relative!r} body contains a NUL byte")
    data = text.encode("utf-8")
    if len(data) > MAX_FILE_BYTES:
        raise ValidationError(f"{relative!r} body is larger than {MAX_FILE_BYTES} bytes")
    return data


def _decode(snapshot: Snapshot, relative: str) -> str:
    try:
        return snapshot.data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ValidationError(f"{relative!r} is not valid UTF-8") from error


def _one_target(operation: NormalizedOperation) -> str:
    if len(operation.targets) != 1:
        raise ValidationError(
            f"{SOURCE_ID} writes one note per intent, not {len(operation.targets)}"
        )
    return operation.targets[0]


def _body(operation: NormalizedOperation) -> str:
    changes = {change.field: change.after for change in operation.field_diff}
    if set(changes) != set(_WRITABLE):
        raise ValidationError(
            f"{SOURCE_ID} writes only {', '.join(_WRITABLE)}; got {sorted(changes)}"
        )
    value = changes["body"]
    if not isinstance(value, str):
        raise ValidationError("a note body must be text")
    return value


class NotesAdapter:
    """``revision``/``read``/``search``/``apply`` over one confined vault."""

    def __init__(self, root: str | Path) -> None:
        self._root = ConfinedRoot(root, label="vault", suffix=".md")
        self._root.check()
        self._tombstones = TombstoneLog(root, source_id=SOURCE_ID)

    def revision(self, target: str) -> str | None:
        return self._root.revision(self._relative(target))

    def read(self, target: str) -> dict[str, object]:
        relative = self._relative(target)
        snapshot = self._root.read_optional(relative)
        if snapshot is None:
            return self._tombstone(target)
        return self._record(target, relative, snapshot)

    def search(self, query: str) -> list[dict[str, object]]:
        needle = str(query).strip().lower()
        found: list[dict[str, object]] = []
        for relative, snapshot in self._root.regular_files():
            try:
                record = self._record(
                    f"{TARGET_PREFIX}{quote(relative, safe='')}", relative, snapshot
                )
            except ValidationError:
                continue
            if needle and not (
                needle in str(record["body"]).lower()
                or needle in str(record["heading"]).lower()
            ):
                continue
            found.append(record)
            if len(found) >= MAX_RESULTS:
                break
        return found

    def apply(
        self, operation: NormalizedOperation, idempotency_key: str
    ) -> dict[str, object]:
        target = _one_target(operation)
        relative = self._relative(target)
        effect: dict[str, object] = {
            "source_id": SOURCE_ID,
            "target": target,
            "capability": operation.capability,
            "idempotency_key": idempotency_key,
        }
        if operation.capability == "create":
            data = _encode(_body(operation), relative)
            try:
                revision = self._root.create(relative, data)
            except ValidationError:
                # The file appeared between the broker's revision check and this
                # write. The same bytes mean this write already landed; other
                # bytes are a different write and must not be overwritten.
                snapshot = self._root.read_optional(relative)
                if snapshot is None or snapshot.data != data:
                    raise
                revision = hashlib.sha256(data).hexdigest()
            return {**effect, "revision": revision}
        if operation.capability == "update":
            data = _encode(_body(operation), relative)
            revision = self._root.write(
                relative, data, base_revision=operation.base_revision, must_exist=True
            )
            return {**effect, "revision": revision}
        if operation.capability == "delete":
            return {**effect, **self._delete(target, relative)}
        raise ValidationError(
            f"{SOURCE_ID} has no {operation.capability!r} capability"
        )

    def _delete(self, target: str, relative: str) -> dict[str, object]:
        snapshot = self._root.read_optional(relative)
        if snapshot is None:
            return {"revision": None, "deleted": False}
        revision = hashlib.sha256(snapshot.data).hexdigest()
        self._tombstones.declare(
            target=target,
            revision=revision,
            pre_image_sha256=hashlib.sha256(
                canonical_json(self._record(target, relative, snapshot))
            ).hexdigest(),
            deleted_at=_now(),
        )
        removed = self._root.remove(relative)
        return {"revision": revision, "deleted": removed is not None, "removed": removed}

    def _record(
        self, target: str, relative: str, snapshot: Snapshot
    ) -> dict[str, object]:
        text = _decode(snapshot, relative)
        return {
            "note_id": target,
            "revision": hashlib.sha256(snapshot.data).hexdigest(),
            "path": relative,
            "heading": heading(text, Path(relative).stem),
            "tags": [],
            "updated_at": datetime.fromtimestamp(
                snapshot.modified, tz=UTC
            ).isoformat(timespec="seconds"),
            "body": text,
        }

    def _tombstone(self, target: str) -> dict[str, object]:
        entry = self._tombstones.lookup(target)
        if entry is None:
            return {}
        return {
            "note_id": target,
            "tombstone": True,
            "revision": entry.get("revision", ""),
            "deleted_at": entry.get("deleted_at", ""),
        }


    @staticmethod
    def _relative(target: str) -> str:
        if not isinstance(target, str) or not target.startswith(TARGET_PREFIX):
            raise ValidationError(
                f"notes target {target!r} is not {TARGET_PREFIX}<path>"
            )
        encoded = target[len(TARGET_PREFIX) :]
        try:
            return unquote(encoded, errors="strict")
        except UnicodeDecodeError as error:
            raise ValidationError(
                f"notes target {target!r} is not valid percent-encoding"
            ) from error
