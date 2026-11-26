"""One root, and no path that leaves it.

A file effect owner is the only component that writes a person's own files, so
the rule is not "check the path" but "never resolve a path twice": a symlink
created between a check and a later pathname open would redirect the write.
Every component is therefore opened relative to its parent descriptor with
``O_NOFOLLOW``, and the caller acts on the descriptor, never on a path string.

The same walk is the refusal list. A value is refused before anything is opened
if it is absolute, if it is not already canonical (``a//b``, ``./a``, ``a/``,
``a/../b``), if any component is a VCS control name or this adapter's own
control directory, if it carries a control byte, or if the leaf is not the
expected suffix. Opening then refuses a symlink at any depth, a leaf that is not
a regular file, and a file larger than the cap.
"""

from __future__ import annotations

import hashlib
import os
import posixpath
import secrets
import stat
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator

from ..errors import StaleError, ValidationError

#: One path component, as the kernel counts it.
MAX_COMPONENT_BYTES = 255

#: A file this adapter will read or write. The broker caps a write field at the
#: same size, so a note the owner refuses here could never have been written.
MAX_FILE_BYTES = 1 << 20

CONTROL_COMPONENTS = frozenset({".git", ".hg", ".svn", ".bzr"})
CONTROL_ROOT = ".data-plane"

_OPEN_DIRECTORY = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
_OPEN_LEAF = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC


@dataclass(frozen=True)
class Snapshot:
    """One file's bytes and its modification time, read under one descriptor."""

    data: bytes
    modified: float


def _reason(error: OSError) -> str:
    if error.errno == getattr(os, "ELOOP", None):
        return "it is a symlink or a symlink loop"
    if error.errno == getattr(os, "ENOTDIR", None):
        return "a path component is not a directory"
    if error.errno == getattr(os, "ENOENT", None):
        return "it does not exist"
    if error.errno == getattr(os, "EACCES", None):
        return "permission denied"
    if error.errno == getattr(os, "ENAMETOOLONG", None):
        return "a path component is too long"
    return error.strerror or "it cannot be opened"


class ConfinedRoot:
    """A directory a caller names files in, without ever naming a path."""

    def __init__(
        self, root: str | os.PathLike[str], *, label: str, suffix: str | None = None
    ) -> None:
        self._path = Path(root)
        self._label = label
        self._suffix = suffix

    @property
    def path(self) -> Path:
        return self._path

    def components(self, relative: object) -> tuple[str, ...]:
        """The checked components of ``relative``, or a refusal naming why not."""

        if not isinstance(relative, str) or not relative:
            raise ValidationError(f"a {self._label} target must be a non-empty string")
        if any(ord(character) < 0x20 or ord(character) == 0x7F for character in relative):
            raise ValidationError(
                f"{self._label} target {relative!r} contains a control character"
            )
        if relative.startswith("/"):
            raise ValidationError(f"{self._label} target {relative!r} is absolute")
        if posixpath.normpath(relative) != relative:
            raise ValidationError(
                f"{self._label} target {relative!r} is not a canonical relative path"
            )
        parts = relative.split("/")
        for part in parts:
            if part in {"", ".", ".."}:
                raise ValidationError(
                    f"{self._label} target {relative!r} contains {part!r}"
                )
            if len(part.encode("utf-8")) > MAX_COMPONENT_BYTES:
                raise ValidationError(
                    f"{self._label} target {relative!r} has a component over"
                    f" {MAX_COMPONENT_BYTES} bytes"
                )
            if part in CONTROL_COMPONENTS:
                raise ValidationError(
                    f"{self._label} target {relative!r} names a version-control path"
                )
            if part.startswith(CONTROL_ROOT):
                raise ValidationError(
                    f"{self._label} target {relative!r} names the effect owner's control"
                    " directory"
                )
        if self._suffix and not parts[-1].endswith(self._suffix):
            raise ValidationError(
                f"{self._label} target {relative!r} does not end in {self._suffix!r}"
            )
        return tuple(parts)

    @contextmanager
    def parent(self, relative: object) -> Iterator[tuple[int, str]]:
        """The descriptor of the leaf's directory and the leaf's name."""

        parts = self.components(relative)
        *directories, leaf = parts
        current = self._open_root()
        try:
            for name in directories:
                following = self._descend(current, name, relative)
                os.close(current)
                current = following
            yield current, leaf
        finally:
            os.close(current)

    def read_optional(self, relative: object) -> Snapshot | None:
        """The file's bytes, or ``None`` when it does not exist."""

        with self.parent(relative) as (directory, leaf):
            info = self._stat(directory, leaf, relative)
            if info is None:
                return None
            return Snapshot(self._read(directory, leaf, info, relative), info.st_mtime)

    def revision(self, relative: object) -> str | None:
        """The content digest, or ``None`` when the file does not exist."""

        snapshot = self.read_optional(relative)
        return None if snapshot is None else hashlib.sha256(snapshot.data).hexdigest()

    def write(
        self,
        relative: object,
        data: bytes,
        *,
        base_revision: str | None,
        must_exist: bool = False,
    ) -> str:
        """Atomically replace the file, refusing a revision that moved.

        ``must_exist`` is what separates an update from a create: with no base
        revision, a missing file is a legitimate create only when the caller is
        creating.
        """

        if len(data) > MAX_FILE_BYTES:
            raise ValidationError(
                f"{relative!r} is larger than {MAX_FILE_BYTES} bytes"
            )
        with self.parent(relative) as (directory, leaf):
            info = self._stat(directory, leaf, relative)
            if must_exist and info is None:
                raise StaleError(f"{relative!r} does not exist")
            current = (
                None
                if info is None
                else hashlib.sha256(self._read(directory, leaf, info, relative)).hexdigest()
            )
            if current != base_revision:
                raise StaleError(
                    f"{relative!r} is at revision {current!r}, not {base_revision!r}"
                )
            self._replace(directory, leaf, data, relative)
            return hashlib.sha256(data).hexdigest()

    def create(self, relative: object, data: bytes) -> str:
        """Write a file that must not exist yet."""

        if len(data) > MAX_FILE_BYTES:
            raise ValidationError(
                f"{relative!r} is larger than {MAX_FILE_BYTES} bytes"
            )
        with self.parent(relative) as (directory, leaf):
            if self._stat(directory, leaf, relative) is not None:
                raise ValidationError(f"{relative!r} already exists")
            self._replace(directory, leaf, data, relative)
            return hashlib.sha256(data).hexdigest()

    def remove(self, relative: object) -> str | None:
        """Delete the file and return the digest it had, or ``None`` if absent."""

        with self.parent(relative) as (directory, leaf):
            info = self._stat(directory, leaf, relative)
            if info is None:
                return None
            digest = hashlib.sha256(self._read(directory, leaf, info, relative)).hexdigest()
            try:
                os.unlink(leaf, dir_fd=directory)
            except OSError as error:
                raise ValidationError(
                    f"{self._label} target {relative!r} cannot be removed: {_reason(error)}"
                ) from error
            os.fsync(directory)
            return digest

    def regular_files(self) -> Iterator[tuple[str, Snapshot]]:
        """Every regular file the owner may read, walking under the root descriptor.

        The walk is read-only, but it uses descriptors all the same: a symlinked
        directory must not pull a file from outside the root into a search result.
        """

        root = self._open_root()
        try:
            yield from self._walk(root, "")
        finally:
            os.close(root)

    def _walk(self, directory: int, prefix: str) -> Iterator[tuple[str, Snapshot]]:
        for name, info in self._entries(directory):
            relative = f"{prefix}{name}"
            if stat.S_ISLNK(info.st_mode):
                continue
            if stat.S_ISDIR(info.st_mode):
                if name in CONTROL_COMPONENTS or name.startswith(CONTROL_ROOT):
                    continue
                try:
                    child = os.open(name, _OPEN_DIRECTORY, dir_fd=directory)
                except OSError:
                    continue
                try:
                    yield from self._walk(child, f"{relative}/")
                finally:
                    os.close(child)
            elif stat.S_ISREG(info.st_mode):
                if self._suffix and not name.endswith(self._suffix):
                    continue
                if info.st_size > MAX_FILE_BYTES:
                    continue
                try:
                    data = self._read(directory, name, info, relative)
                except ValidationError:
                    continue
                yield relative, Snapshot(data, info.st_mtime)

    def _entries(self, directory: int) -> Iterator[tuple[str, os.stat_result]]:
        try:
            names = sorted(os.listdir(directory))
        except OSError:
            return
        for name in names:
            try:
                yield name, os.stat(name, dir_fd=directory, follow_symlinks=False)
            except OSError:
                continue

    def _open_root(self) -> int:
        try:
            return os.open(self._path, _OPEN_DIRECTORY)
        except OSError as error:
            raise ValidationError(
                f"{self._label} {self._path} cannot be used: {_reason(error)}"
            ) from error

    @staticmethod
    def _descend(directory: int, name: str, relative: object) -> int:
        try:
            return os.open(name, _OPEN_DIRECTORY, dir_fd=directory)
        except OSError as error:
            raise ValidationError(
                f"{relative!r} cannot be followed: {name} {_reason(error)}"
            ) from error

    @staticmethod
    def _stat(
        directory: int, leaf: str, relative: object
    ) -> os.stat_result | None:
        try:
            info = os.stat(leaf, dir_fd=directory, follow_symlinks=False)
        except FileNotFoundError:
            return None
        except OSError as error:
            raise ValidationError(
                f"{relative!r} cannot be examined: {_reason(error)}"
            ) from error
        if stat.S_ISLNK(info.st_mode):
            raise ValidationError(f"{relative!r} is a symlink; refusing to follow it")
        if not stat.S_ISREG(info.st_mode):
            raise ValidationError(f"{relative!r} is not a regular file")
        return info

    @staticmethod
    def _read(
        directory: int, leaf: str, info: os.stat_result, relative: object
    ) -> bytes:
        if info.st_size > MAX_FILE_BYTES:
            raise ValidationError(
                f"{relative!r} is larger than {MAX_FILE_BYTES} bytes"
            )
        try:
            handle = os.open(leaf, _OPEN_LEAF, dir_fd=directory)
        except OSError as error:
            raise ValidationError(
                f"{relative!r} cannot be read: {_reason(error)}"
            ) from error
        try:
            with os.fdopen(handle, "rb") as stream:
                data = stream.read(MAX_FILE_BYTES + 1)
        except OSError as error:
            raise ValidationError(
                f"{relative!r} cannot be read: {_reason(error)}"
            ) from error
        if len(data) > MAX_FILE_BYTES:
            raise ValidationError(
                f"{relative!r} grew past {MAX_FILE_BYTES} bytes while it was read"
            )
        return data

    @staticmethod
    def _replace(directory: int, leaf: str, data: bytes, relative: object) -> None:
        temporary = f".{leaf}.tmp-{secrets.token_hex(8)}"
        try:
            writer = os.open(
                temporary,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                0o600,
                dir_fd=directory,
            )
        except OSError as error:
            raise ValidationError(
                f"{relative!r} cannot be staged: {_reason(error)}"
            ) from error
        try:
            try:
                view = memoryview(data)
                while view:
                    view = view[os.write(writer, view) :]
                os.fsync(writer)
            finally:
                os.close(writer)
            os.replace(temporary, leaf, src_dir_fd=directory, dst_dir_fd=directory)
        except BaseException:
            try:
                os.unlink(temporary, dir_fd=directory)
            except OSError:
                pass
            raise
        os.fsync(directory)
