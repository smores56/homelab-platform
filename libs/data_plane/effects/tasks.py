"""The todo.txt pair as a broker write target.

A task's identity is the digest of its line, so the adapter names targets
exactly as the replica does (``tasks::<16 hex>``) and reports the line's full
digest as the revision. Revision stability is therefore a property of the file
rather than of the adapter: a line keeps its id only while its text is
unchanged, so a stale revision here means the line is gone, not that it moved.

Two consequences are accepted rather than worked around. There is no ``update``
capability, because rewriting a line is a new task; completing one is delete
plus create, and the second op needs its own approval. And a delete removes
every occurrence from both files, because the replica collapsed duplicate lines
into one id: removing one would leave the target alive and turn a completed
mutation into an unknown outcome.
"""

from __future__ import annotations

import hashlib
from datetime import UTC, datetime
from pathlib import Path

from ..collectors.raw.tasks import parse
from ..confirmation import NormalizedOperation
from ..errors import StaleError, ValidationError
from ..identity import canonical_json
from .confine import MAX_FILE_BYTES, ConfinedRoot
from .tombstones import TombstoneLog

SOURCE_ID = "tasks.todo"
TARGET_PREFIX = "tasks::"
TODO = "todo.txt"
DONE = "done.txt"
FILES = (TODO, DONE)
MAX_RESULTS = 50
_ID_LENGTH = 16

_ALLOWED_CONTROL = frozenset("\t")

#: Every terminator ``str.splitlines`` recognises, longest first. A line's
#: identity is the text the replica saw, so the rewrite must strip exactly the
#: terminator the reader stripped; anything else leaves a line that can be read
#: and never removed.
_TERMINATORS = (
    "\r\n",
    "\n",
    "\r",
    "\x0b",
    "\x0c",
    "\x1c",
    "\x1d",
    "\x1e",
    "\x85",
    "\u2028",
    "\u2029",
)


def _now() -> str:
    return datetime.now(tz=UTC).isoformat(timespec="seconds")


def _digest(line: str) -> str:
    return hashlib.sha256(line.encode("utf-8")).hexdigest()


def _target(line: str) -> str:
    return f"{TARGET_PREFIX}{_digest(line)[:_ID_LENGTH]}"


def _without_terminator(raw: str) -> str:
    for terminator in _TERMINATORS:
        if raw.endswith(terminator):
            return raw[: -len(terminator)]
    return raw


def _digest_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _text(data: bytes, name: str) -> str:
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ValidationError(f"{name} is not valid UTF-8") from error


def _one_target(operation: NormalizedOperation) -> str:
    # A create carries one line and that line is the id, so a second target would
    # be the same id twice and the broker refuses the request before this runs.
    if len(operation.targets) != 1:
        raise ValidationError(
            f"{SOURCE_ID} creates one task per intent, not {len(operation.targets)}"
        )
    return operation.targets[0]


def _line(operation: NormalizedOperation) -> str:
    changes = {change.field: change.after for change in operation.field_diff}
    if set(changes) != {"text"}:
        raise ValidationError(
            f"{SOURCE_ID} writes only text; got {sorted(changes)}"
        )
    value = changes["text"]
    if not isinstance(value, str) or not value.strip():
        raise ValidationError("a task text must be a non-blank line")
    if any(
        (ord(character) < 0x20 and character not in _ALLOWED_CONTROL)
        or 0x7F <= ord(character) <= 0x9F
        for character in value
    ):
        raise ValidationError("a task text is one line and holds no control character")
    if len(value.encode("utf-8")) > MAX_FILE_BYTES:
        raise ValidationError(f"a task text is larger than {MAX_FILE_BYTES} bytes")
    return value


class TasksAdapter:
    """``revision``/``read``/``search``/``apply`` over one todo.txt directory."""

    def __init__(self, root: str | Path) -> None:
        self._root = ConfinedRoot(root, label="todo directory")
        self._root.check()
        self._tombstones = TombstoneLog(root, source_id=SOURCE_ID)
        self._tombstones.check()

    def revision(self, target: str) -> str | None:
        found = self._locate(target)
        return None if found is None else _digest(found[1])

    def read(self, target: str) -> dict[str, object]:
        found = self._locate(target)
        if found is None:
            return self._tombstone(target)
        return self._record(*found)

    def search(self, query: str) -> list[dict[str, object]]:
        needle = str(query).strip().lower()
        found: list[dict[str, object]] = []
        seen: set[str] = set()
        for name in FILES:
            for line in self._lines(name):
                target = _target(line)
                if target in seen:
                    continue
                if needle and needle not in line.lower():
                    continue
                seen.add(target)
                found.append(self._record(name, line))
                if len(found) >= MAX_RESULTS:
                    return found
        return found

    def apply(
        self, operation: NormalizedOperation, idempotency_key: str
    ) -> dict[str, object]:
        if not operation.targets:
            raise ValidationError(f"{SOURCE_ID} needs at least one target")
        effect: dict[str, object] = {
            "source_id": SOURCE_ID,
            "capability": operation.capability,
            "idempotency_key": idempotency_key,
        }
        if operation.capability == "create":
            target = _one_target(operation)
            line = _line(operation)
            if self._locate(target) is not None:
                raise ValidationError(f"{target} already exists")
            self._append(TODO, line)
            return {
                **effect,
                "applied": 1,
                "results": [
                    {"target": target, "revision": _digest(line), "deleted": False}
                ],
            }
        if operation.capability == "delete":
            return {**effect, **self._delete(operation)}
        raise ValidationError(
            f"{SOURCE_ID} has no {operation.capability!r} capability"
        )

    def _delete(self, operation: NormalizedOperation) -> dict[str, object]:
        results: list[dict[str, object]] = []
        wanted: dict[str, str] = {}
        for target in operation.targets:
            found = self._locate(target)
            if found is None:
                results.append(
                    {"target": target, "revision": None, "deleted": False, "removed": 0}
                )
                continue
            name, line = found
            self._tombstones.declare(
                target=target,
                revision=_digest(line),
                pre_image_sha256=_digest_bytes(
                    canonical_json(self._record(name, line))
                ),
                deleted_at=_now(),
            )
            wanted[line] = target
            results.append(
                {
                    "target": target,
                    "revision": _digest(line),
                    "deleted": True,
                    "removed": 0,
                }
            )
        if not wanted:
            return {"applied": 0, "results": results}
        counts = self._remove(set(wanted))
        for result in results:
            line = next(
                (item for item, target in wanted.items() if target == result["target"]),
                None,
            )
            if line is not None:
                result["removed"] = counts.get(line, 0)
                result["deleted"] = result["removed"] > 0
        return {"applied": sum(int(item["removed"]) for item in results), "results": results}

    def _append(self, name: str, line: str) -> None:
        snapshot = self._root.read_optional(name)
        base = None if snapshot is None else _digest_bytes(snapshot.data)
        body = b"" if snapshot is None else snapshot.data
        if body and not body.endswith(b"\n"):
            body += b"\n"
        self._root.write(
            name, body + line.encode("utf-8") + b"\n", base_revision=base
        )

    def _remove(self, wanted: set[str]) -> dict[str, int]:
        counts = {line: 0 for line in wanted}
        rewrites: list[tuple[str, bytes, str, bytes]] = []
        for name in FILES:
            snapshot = self._root.read_optional(name)
            if snapshot is None:
                continue
            kept: list[str] = []
            touched = 0
            for raw in _text(snapshot.data, name).splitlines(keepends=True):
                line = _without_terminator(raw)
                if line in wanted:
                    counts[line] += 1
                    touched += 1
                    continue
                kept.append(raw)
            if touched:
                rewrites.append(
                    (
                        name,
                        snapshot.data,
                        _digest_bytes(snapshot.data),
                        "".join(kept).encode("utf-8"),
                    )
                )
        if not rewrites:
            raise StaleError(f"no occurrence of {sorted(wanted)!r} is left")
        # Both base revisions are checked before either file is written, and a
        # failure between the two writes restores the first: the pair is not
        # one atomic unit on this filesystem, so the smallest possible window and
        # a rollback are the honest guarantee.
        for name, _, base, _ in rewrites:
            if self._root.revision(name) != base:
                raise StaleError(f"{name} moved before the rewrite")
        written: list[tuple[str, str, bytes]] = []
        try:
            for name, _, base, body in rewrites:
                self._root.write(name, body, base_revision=base)
                written.append((name, _digest_bytes(body), body))
        except BaseException:
            for name, original, _, _ in rewrites[: len(written)]:
                try:
                    self._root.write(
                        name,
                        original,
                        base_revision=next(
                            base for written_name, base, _ in written if written_name == name
                        ),
                    )
                except (ValidationError, StaleError):
                    pass
            raise
        return counts

    def _lines(self, name: str) -> list[str]:
        snapshot = self._root.read_optional(name)
        if snapshot is None:
            return []
        return [
            line for line in _text(snapshot.data, name).splitlines() if line.strip()
        ]

    def _locate(self, target: str) -> tuple[str, str] | None:
        needle = self._digest_part(target)
        for name in FILES:
            for line in self._lines(name):
                if _digest(line)[:_ID_LENGTH] == needle:
                    return name, line
        return None

    def _record(self, name: str, line: str) -> dict[str, object]:
        return {
            "task_id": _target(line),
            "revision": _digest(line),
            "text": line,
            "file": name,
            **parse(line),
        }

    def _tombstone(self, target: str) -> dict[str, object]:
        entry = self._tombstones.lookup(target)
        if entry is None:
            return {}
        return {
            "task_id": target,
            "tombstone": True,
            "revision": entry.get("revision", ""),
            "deleted_at": entry.get("deleted_at", ""),
        }

    @staticmethod
    def _digest_part(target: str) -> str:
        if not isinstance(target, str) or not target.startswith(TARGET_PREFIX):
            raise ValidationError(
                f"tasks target {target!r} is not {TARGET_PREFIX}<digest>"
            )
        digest = target[len(TARGET_PREFIX) :]
        if len(digest) != _ID_LENGTH or any(
            character not in "0123456789abcdef" for character in digest
        ):
            raise ValidationError(
                f"tasks target {target!r} is not {_ID_LENGTH} lowercase hex digits"
            )
        return digest
