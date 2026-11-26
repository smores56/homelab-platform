"""The one durable record that a target was deleted on purpose.

The replica's absence marker is not proof of deletion, and neither is a missing
file: an unmounted vault looks exactly like an empty one, and a sync still
landing looks like a delete. A target-keyed ledger is the smallest record that
answers "did the effect owner delete this", survives a crash between the write
and the read-back, and does not pretend to be a second copy of the source.

The ledger is appended before the unlink, never after. A crash in between leaves
a declared tombstone for a file that still exists, and a read reports the live
file, so the ledger can only ever over-promise a deletion to a caller that does
not look at the file — which is why the read path looks first.

It lives in ``<root>/.data-plane/``: both file collectors ignore that name (the
notes pass collects only ``*.md``, the tasks pass reads only its two files), so
the ledger produces no replica object.
"""

from __future__ import annotations

import json
import os
from pathlib import Path

from ..errors import ValidationError
from ..identity import canonical_json

DIRECTORY = ".data-plane"
LEDGER = "tombstones.jsonl"

#: A lookup reads at most this much of the ledger's tail. The newest entry
#: wins, so an old ledger stays readable instead of failing closed once it grows
#: past a bound nobody can raise from inside the process.
MAX_LEDGER_BYTES = 4 << 20


def _tail(stream) -> bytes:
    """The newest entries of a ledger, bounded, without splitting a line."""

    info = os.fstat(stream.fileno())
    if info.st_size <= MAX_LEDGER_BYTES:
        return stream.read()
    stream.seek(info.st_size - MAX_LEDGER_BYTES)
    raw = stream.read()
    newline = raw.find(b"\n")
    return b"" if newline < 0 else raw[newline + 1 :]


class TombstoneLog:
    """Append-only proof of deletion, keyed by the target the owner deleted."""

    def __init__(self, root: str | os.PathLike[str], *, source_id: str) -> None:
        self._root = Path(root)
        self._source_id = source_id

    def declare(
        self, *, target: str, revision: str, pre_image_sha256: str, deleted_at: str
    ) -> dict[str, str]:
        """Append one tombstone and return the record that was written."""

        record = {
            "source_id": self._source_id,
            "target": target,
            "revision": revision,
            "pre_image_sha256": pre_image_sha256,
            "deleted_at": deleted_at,
        }
        root = self._open_root()
        try:
            directory = self._control_directory(root)
            try:
                handle = self._open_ledger(directory)
                try:
                    os.write(handle, canonical_json(record) + b"\n")
                    os.fsync(handle)
                    # The directory entry has to be durable too, or a power loss
                    # can keep the unlink and lose the record that explains it.
                    os.fsync(directory)
                    os.fsync(root)
                finally:
                    os.close(handle)
            finally:
                os.close(directory)
        finally:
            os.close(root)
        return record

    def lookup(self, target: str) -> dict[str, str] | None:
        """The newest tombstone for ``target``, or ``None`` if it was never deleted."""

        root = self._open_root()
        try:
            try:
                directory = os.open(
                    DIRECTORY,
                    os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                    dir_fd=root,
                )
            except FileNotFoundError:
                return None
            except OSError as error:
                raise ValidationError(
                    f"the tombstone directory {DIRECTORY} cannot be opened: {error.strerror}"
                ) from error
            try:
                try:
                    handle = os.open(
                        LEDGER, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=directory
                    )
                except FileNotFoundError:
                    return None
                except OSError as error:
                    raise ValidationError(
                        f"the tombstone ledger {LEDGER} cannot be opened:"
                        f" {error.strerror}"
                    ) from error
                try:
                    with os.fdopen(handle, "rb") as stream:
                        raw = _tail(stream)
                except OSError as error:
                    raise ValidationError(
                        f"the tombstone ledger {LEDGER} cannot be read: {error.strerror}"
                    ) from error
            finally:
                os.close(directory)
        finally:
            os.close(root)
        found: dict[str, str] | None = None
        for line in raw.splitlines():
            if not line.strip():
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                # One damaged line must not make every deleted target unreadable;
                # the file itself is still the authority for a live target.
                continue
            if not isinstance(entry, dict) or entry.get("target") != target:
                continue
            found = {key: str(value) for key, value in entry.items()}
        return found

    def check(self) -> None:
        """Fail now if the ledger cannot be written, before an approval is spent."""

        root = self._open_root()
        try:
            os.close(self._control_directory(root))
        finally:
            os.close(root)

    def _open_root(self) -> int:
        try:
            return os.open(
                self._root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
            )
        except OSError as error:
            raise ValidationError(
                f"the effect owner's root {self._root} cannot be used: {error.strerror}"
            ) from error

    @staticmethod
    def _control_directory(root: int) -> int:
        try:
            os.mkdir(DIRECTORY, 0o700, dir_fd=root)
        except FileExistsError:
            pass
        except OSError as error:
            raise ValidationError(
                f"the tombstone directory {DIRECTORY} cannot be created: {error.strerror}"
            ) from error
        try:
            return os.open(
                DIRECTORY,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                dir_fd=root,
            )
        except OSError as error:
            raise ValidationError(
                f"the tombstone directory {DIRECTORY} cannot be opened: {error.strerror}"
            ) from error

    @staticmethod
    def _open_ledger(directory: int) -> int:
        try:
            return os.open(
                LEDGER,
                os.O_WRONLY
                | os.O_APPEND
                | os.O_CREAT
                | os.O_NOFOLLOW
                | os.O_CLOEXEC,
                0o600,
                dir_fd=directory,
            )
        except OSError as error:
            raise ValidationError(
                f"the tombstone ledger {LEDGER} cannot be opened: {error.strerror}"
            ) from error
