"""Live adapters over the two general trees: ``/srv/git`` and ``/srv/books``.

SDLC #851 (T9 of #702). The general profile reads two trees the operator already
maintains, and neither is a published generation:

* ``repos`` is one **file at HEAD** in a clean-bare clone under
  ``/srv/git/<host>/<owner>/<repo>/.git``. The id names the clone and the path,
  and the revision is the commit the file was read at, so a citation stays
  reproducible after the tree moves on.
* ``books`` is one OPDShelf entry: ``/srv/books/<author>/<title>/metadata.opf``.
  The record is that OPF's metadata, never the epub's bytes.

Both trees are live: a file that lands in a clone is readable as soon as it is
committed, with no publication step and no generation to resolve. What keeps that
safe is the bounds, not a snapshot -- a search walks a bounded number of
repositories under a deadline, ``git grep -I`` never reads a binary blob, and a
body is capped and says when it was cut.

Nothing here writes to either tree: every git call runs with
``GIT_OPTIONAL_LOCKS=0`` against a read-only mount, and the OPF read is a plain
file read. A path is validated segment by segment, so a record id from a caller
can never step outside the clone or the library.
"""

from __future__ import annotations

import hashlib
import os
import subprocess
import time
import xml.etree.ElementTree as ElementTree
from dataclasses import dataclass
from pathlib import Path
from types import MappingProxyType
from typing import Iterator, Mapping

from data_plane.errors import ContractError, ValidationError
from data_plane.model import EffectClass, SourceContract, Visibility

from . import contracts, sources

#: The git binary inside the pinned runtime image (``git version 2.47.3``); a
#: test may point this at a stub, nothing else reads the variable.
GIT = "git"
MAX_FILE_BYTES = 64 * 1024
#: A search is a walk, so it gets a wall clock rather than a promise: past it the
#: adapter answers with what it has instead of holding a request.
SEARCH_DEADLINE_SECONDS = 5.0
#: Upper bounds on how much a single query may look at. Both trees are small
#: today (142 MiB of clones, a few hundred books); these exist so that a future
#: tree cannot turn one query into a full scan.
MAX_SCAN_PATHS = 20000
MAX_SCAN_BOOKS = 4000
MAX_OPF_BYTES = 1024 * 1024
GIT_TIMEOUT_SECONDS = 10.0
OPF_METADATA = "metadata.opf"

#: A repo name is ``<host>/<owner>/<repo>`` and a book id ``<author>/<title>``:
#: path components, each one that cannot escape its root. The rule is structural
#: rather than an ASCII allowlist, because an author folder is not ASCII.
MAX_SEGMENT_CHARS = 255
MAX_RECORD_ID_CHARS = 1024


class InvalidRecordId(ValidationError):
    """A record id this source cannot have produced."""


class TreeUnavailable(sources.SourceUnavailable):
    """The tree is not mounted, or the one record in it cannot be read."""


def _declares(contract: SourceContract, effect: EffectClass) -> bool:
    return any(capability.effect is effect for capability in contract.capabilities)


def _segment(name: str, what: str) -> str:
    """One path component that can only stay under its root."""

    if not name or name in {".", ".."} or "/" in name or "\x00" in name:
        raise InvalidRecordId(f"{what} {name!r} is not one path component")
    if len(name) > MAX_SEGMENT_CHARS:
        raise InvalidRecordId(f"{what} {name!r} is longer than a path component")
    if name != name.strip():
        raise InvalidRecordId(f"{what} {name!r} is padded with whitespace")
    for character in name:
        if ord(character) < 32 or ord(character) == 127:
            raise InvalidRecordId(f"{what} {name!r} carries a control character")
    return name


def _path_segments(path: str) -> tuple[str, ...]:
    """A repository path, validated as relative components and nothing else."""

    if not path or path.startswith("/") or "\x00" in path:
        raise InvalidRecordId(f"path {path!r} is not a relative repository path")
    if ".." in path:
        raise InvalidRecordId(f"path {path!r} may not step up a directory")
    if len(path) > MAX_RECORD_ID_CHARS:
        raise InvalidRecordId(f"path {path!r} is longer than a record id may be")
    return tuple(_segment(segment, "path segment") for segment in path.split("/"))


def _git(git_dir: Path, *arguments: str, timeout: float) -> subprocess.CompletedProcess[bytes]:
    """One read-only git call against one clone; never a shell."""

    environment = {
        "PATH": "/usr/bin:/bin",
        "LC_ALL": "C",
        "TZ": "UTC",
        # A read must not take a lock in a tree mounted read-only, and HOME keeps
        # git from looking for a user configuration that is not there.
        "GIT_OPTIONAL_LOCKS": "0",
        "HOME": "/tmp",
    }
    return subprocess.run(
        [GIT, f"--git-dir={git_dir}", "--no-pager", *arguments],
        capture_output=True,
        timeout=timeout,
        env=environment,
        check=False,
    )


@dataclass(frozen=True)
class _Repo:
    """One clean-bare clone, named by the three directories above its git dir."""

    name: str
    git_dir: Path


@dataclass(frozen=True)
class _Head:
    """What a clone answered about the commit to read at."""

    revision: str
    captured_at: str


class RepoTreeAdapter:
    """``repos``: a file at HEAD in one of the bare clones under the root."""

    def __init__(self, contract: SourceContract, root: str | os.PathLike[str]) -> None:
        contract.validate()
        if contract.source_id != "repos":
            raise ContractError(f"RepoTreeAdapter cannot answer for {contract.source_id!r}")
        self.contract = contract
        self.root = Path(root)

    @property
    def name(self) -> str:
        return self.contract.source_id

    def read(self, record_id: str) -> sources.SourceRecord:
        if not _declares(self.contract, EffectClass.READ):
            raise sources.SourceUnsupported(f"source {self.name!r} does not expose read")
        repo = self._repo_from(record_id)
        path = self._path_from(record_id)
        head = self._head(repo)
        data = self._blob(repo, path)
        if b"\x00" in data:
            raise sources.SourceUnsupported(
                f"{repo.name}:{path} is a binary file; this source answers text"
            )
        truncated = len(data) > MAX_FILE_BYTES
        body = data[:MAX_FILE_BYTES].decode("utf-8", "replace")
        provenance = {
            "source_id": f"{self.name}/{repo.name}@{head.revision}:{path}",
            "revision": head.revision,
            "captured_at": head.captured_at,
        }
        if truncated:
            provenance["truncated"] = "true"
        return sources.SourceRecord(
            id=record_id,
            source=self.name,
            title=f"{repo.name}:{path}",
            body=body,
            provenance=MappingProxyType(provenance),
            revision=head.revision,
        )

    def search(self, query: str, limit: int) -> tuple[sources.SearchHit, ...]:
        if not _declares(self.contract, EffectClass.SEARCH):
            raise sources.SourceUnsupported(f"source {self.name!r} does not expose search")
        if limit < 1:
            raise ValidationError("limit must be at least 1")
        words = contracts.query_words(query)
        if not words:
            raise ValidationError("query must contain at least one word")
        folded = tuple(word.casefold() for word in words)
        deadline = time.monotonic() + SEARCH_DEADLINE_SECONDS
        hits: list[sources.SearchHit] = []
        seen: set[str] = set()
        for repo in self._repos():
            if len(hits) >= limit or time.monotonic() >= deadline:
                break
            for path in self._content_paths(repo, words, deadline):
                if len(hits) >= limit:
                    break
                record_id = self._record_id(repo, path)
                if record_id in seen:
                    continue
                seen.add(record_id)
                # The file itself is the haystack: git listed it as a match for
                # every word, and the excerpt is taken where the caller looked.
                try:
                    body = self._blob(repo, path)[:MAX_FILE_BYTES].decode("utf-8", "replace")
                except (sources.SourceNotFound, TreeUnavailable):
                    body = ""
                hits.append(
                    sources.SearchHit(
                        id=record_id,
                        title=f"{repo.name}:{path}",
                        snippet=contracts.snippet(f"{path}\n{body}", words[0]),
                    )
                )
            if len(hits) >= limit:
                break
            for path in self._path_matches(repo, folded, deadline):
                if len(hits) >= limit:
                    break
                record_id = self._record_id(repo, path)
                if record_id in seen:
                    continue
                seen.add(record_id)
                hits.append(
                    sources.SearchHit(
                        id=record_id,
                        title=f"{repo.name}:{path}",
                        snippet=contracts.snippet(path, words[0]),
                    )
                )
        return tuple(hits)

    # -- the clones ------------------------------------------------------------

    def _repos(self) -> list[_Repo]:
        if not self.root.is_dir():
            raise TreeUnavailable(f"{self.root} is not mounted; repos has nothing to read")
        repos = [
            _Repo(name=git_dir.parent.relative_to(self.root).as_posix(), git_dir=git_dir)
            for git_dir in sorted(self.root.glob("*/*/*/.git"))
            if git_dir.is_dir()
        ]
        return repos

    def _find(self, name: str) -> _Repo:
        return _Repo(name=name, git_dir=self.root.joinpath(*name.split("/"), ".git"))

    def _repo_from(self, record_id: str) -> _Repo:
        name, path = self._split(record_id)
        segments = [segment for segment in name.split("/") if segment]
        if len(segments) != 3:
            raise InvalidRecordId(f"record {record_id!r} does not name <host>/<owner>/<repo>")
        validated = "/".join(_segment(segment, "repository segment") for segment in segments)
        repo = self._find(validated)
        if not repo.git_dir.is_dir():
            raise sources.SourceNotFound(f"source {self.name!r} has no clone {validated!r}")
        return repo

    def _path_from(self, record_id: str) -> str:
        _name, path = self._split(record_id)
        return "/".join(_path_segments(path))

    def _split(self, record_id: str) -> tuple[str, str]:
        prefix = f"{self.name}::"
        if not record_id.startswith(prefix):
            raise InvalidRecordId(f"record {record_id!r} is not a {self.name} record")
        name, separator, path = record_id[len(prefix) :].partition("::")
        if not separator or not path:
            raise InvalidRecordId(
                f"record {record_id!r} is not {self.name}::<host>/<owner>/<repo>::<path>"
            )
        return name, path

    def _record_id(self, repo: _Repo, path: str) -> str:
        return f"{self.name}::{repo.name}::{path}"

    def _head(self, repo: _Repo) -> _Head:
        if not repo.git_dir.is_dir():
            raise sources.SourceNotFound(f"source {self.name!r} has no clone {repo.name!r}")
        result = _git(
            repo.git_dir,
            "log",
            "-1",
            "--format=%H %cI",
            "HEAD",
            timeout=GIT_TIMEOUT_SECONDS,
        )
        line = result.stdout.decode("utf-8", "replace").strip()
        revision, _, captured_at = line.partition(" ")
        if result.returncode != 0 or not revision:
            raise TreeUnavailable(f"{repo.name} has no commit at HEAD")
        return _Head(revision=revision, captured_at=captured_at or "")

    def _blob(self, repo: _Repo, path: str) -> bytes:
        size = _git(
            repo.git_dir, "cat-file", "-s", f"HEAD:{path}", timeout=GIT_TIMEOUT_SECONDS
        )
        if size.returncode != 0:
            raise sources.SourceNotFound(
                f"source {self.name!r} has no file {path!r} in {repo.name!r} at HEAD"
            )
        # One byte past the cap is all that is needed to say "truncated"; git can
        # still hand the whole blob, so the read is capped afterwards.
        result = _git(
            repo.git_dir, "cat-file", "blob", f"HEAD:{path}", timeout=GIT_TIMEOUT_SECONDS
        )
        if result.returncode != 0:
            raise TreeUnavailable(f"{repo.name}:{path} could not be read from the clone")
        return result.stdout

    def _content_paths(
        self, repo: _Repo, words: tuple[str, ...], deadline: float
    ) -> Iterator[str]:
        """Files whose HEAD content holds every word, as git reports them."""

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return
        arguments = ["grep", "-I", "-l", "-F", "--all-match"]
        for word in words:
            arguments += ["-e", word]
        arguments.append("HEAD")
        try:
            result = _git(repo.git_dir, *arguments, timeout=remaining)
        except subprocess.TimeoutExpired:
            return
        for count, path in enumerate(result.stdout.decode("utf-8", "replace").splitlines()):
            if count >= MAX_SCAN_PATHS:
                return
            # A bare clone has no work tree, so git prefixes the tree it read.
            if path.startswith("HEAD:"):
                path = path[len("HEAD:") :]
            if path:
                yield path

    def _path_matches(
        self, repo: _Repo, words: tuple[str, ...], deadline: float
    ) -> Iterator[str]:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return
        try:
            result = _git(
                repo.git_dir,
                "ls-tree",
                "-r",
                "--name-only",
                "HEAD",
                timeout=remaining,
            )
        except subprocess.TimeoutExpired:
            return
        for count, path in enumerate(result.stdout.decode("utf-8", "replace").splitlines()):
            if count >= MAX_SCAN_PATHS:
                return
            folded = path.casefold()
            if all(word in folded for word in words):
                yield path


class BooksTreeAdapter:
    """``books``: one OPDShelf entry's metadata from ``metadata.opf``."""

    def __init__(self, contract: SourceContract, root: str | os.PathLike[str]) -> None:
        contract.validate()
        if contract.source_id != "books":
            raise ContractError(f"BooksTreeAdapter cannot answer for {contract.source_id!r}")
        self.contract = contract
        self.root = Path(root)

    @property
    def name(self) -> str:
        return self.contract.source_id

    def read(self, record_id: str) -> sources.SourceRecord:
        if not _declares(self.contract, EffectClass.READ):
            raise sources.SourceUnsupported(f"source {self.name!r} does not expose read")
        opf = self._opf(record_id)
        data = self._read_opf(opf)
        book = _book(opf, data)
        return sources.SourceRecord(
            id=record_id,
            source=self.name,
            title=book.title,
            body=book.body,
            provenance=MappingProxyType(
                {
                    "source_id": f"{self.name}/{book.author}/{book.title}",
                    "revision": book.revision,
                    "captured_at": book.captured_at,
                }
            ),
            revision=book.revision,
        )

    def search(self, query: str, limit: int) -> tuple[sources.SearchHit, ...]:
        if not _declares(self.contract, EffectClass.SEARCH):
            raise sources.SourceUnsupported(f"source {self.name!r} does not expose search")
        if limit < 1:
            raise ValidationError("limit must be at least 1")
        words = contracts.query_words(query)
        if not words:
            raise ValidationError("query must contain at least one word")
        deadline = time.monotonic() + SEARCH_DEADLINE_SECONDS
        hits: list[sources.SearchHit] = []
        for count, opf in enumerate(self._entries()):
            if len(hits) >= limit or time.monotonic() >= deadline:
                break
            if count >= MAX_SCAN_BOOKS:
                break
            try:
                data = self._read_opf(opf)
                book = _book(opf, data)
            except (TreeUnavailable, sources.SourceUnavailable):
                continue
            haystack = f"{book.title}\n{book.body}"
            folded = haystack.casefold()
            if not all(word.casefold() in folded for word in words):
                continue
            hits.append(
                sources.SearchHit(
                    id=self._record_id(opf),
                    title=book.title,
                    snippet=contracts.snippet(haystack, words[0]),
                )
            )
        return tuple(hits)

    # -- the library -----------------------------------------------------------

    def _entries(self) -> Iterator[Path]:
        if not self.root.is_dir():
            raise TreeUnavailable(f"{self.root} is not mounted; books has nothing to read")
        yield from sorted(self.root.glob(f"*/*/{OPF_METADATA}"))

    def _record_id(self, opf: Path) -> str:
        return f"{self.name}::{opf.parent.parent.name}/{opf.parent.name}"

    def _opf(self, record_id: str) -> Path:
        prefix = f"{self.name}::"
        if not record_id.startswith(prefix):
            raise InvalidRecordId(f"record {record_id!r} is not a {self.name} record")
        rest = record_id[len(prefix) :]
        author, separator, title = rest.partition("/")
        if not separator:
            raise InvalidRecordId(f"record {record_id!r} does not name <author>/<title>")
        if "/" in title:
            raise InvalidRecordId(f"record {record_id!r} names more than two components")
        opf = self.root / _segment(author, "author") / _segment(title, "title") / OPF_METADATA
        if not opf.is_file():
            raise sources.SourceNotFound(f"source {self.name!r} has no book {rest!r}")
        return opf

    def _read_opf(self, opf: Path) -> bytes:
        try:
            size = opf.stat().st_size
        except OSError as error:
            raise TreeUnavailable(f"{opf} cannot be read: {error.strerror}") from error
        if size > MAX_OPF_BYTES:
            raise sources.SourceUnavailable(f"{opf} is larger than an OPF file should be")
        try:
            return opf.read_bytes()
        except OSError as error:
            raise TreeUnavailable(f"{opf} cannot be read: {error.strerror}") from error


@dataclass(frozen=True)
class _Book:
    title: str
    author: str
    body: str
    revision: str
    captured_at: str


def _dc_texts(data: bytes) -> Mapping[str, str]:
    """The Dublin Core fields an OPF carries, keyed by local name."""

    try:
        root = ElementTree.fromstring(data)
    except ElementTree.ParseError as error:
        raise sources.SourceUnavailable(f"metadata.opf is not parseable: {error}") from error
    fields: dict[str, str] = {}
    for element in root.iter():
        name = element.tag.rsplit("}", 1)[-1]
        if name not in {"title", "creator", "description", "date", "language", "identifier"}:
            continue
        text = (element.text or "").strip()
        if text and name not in fields:
            fields[name] = " ".join(text.split())
    return MappingProxyType(fields)


def _book(opf: Path, data: bytes) -> _Book:
    fields = _dc_texts(data)
    title = fields.get("title") or opf.parent.name
    author = fields.get("creator") or opf.parent.parent.name
    body = "\n\n".join(
        part
        for part in (
            f"by {author}" if author else "",
            fields.get("description", ""),
            f"Published {fields['date']}" if fields.get("date") else "",
            f"Language {fields['language']}" if fields.get("language") else "",
        )
        if part
    )
    captured_at = time.strftime(
        "%Y-%m-%dT%H:%M:%SZ", time.gmtime(opf.stat().st_mtime)
    )
    return _Book(
        title=title,
        author=author,
        body=body or title,
        revision=hashlib.sha256(data).hexdigest(),
        captured_at=captured_at,
    )


def tree_adapters_for(
    deployment: Visibility,
    roots: Mapping[str, str | os.PathLike[str]],
) -> Mapping[str, sources.SourceAdapter]:
    """The live adapters a deployment's table can bind, keyed by source name.

    The contract comes from the deployment's own table, so a personal facade
    naming a repo or books root is refused at construction: the visibility is
    the table's, not the flag's.
    """

    table = sources.SOURCES_BY_DEPLOYMENT[deployment]
    builders = {"repos": RepoTreeAdapter, "books": BooksTreeAdapter}
    built: dict[str, sources.SourceAdapter] = {}
    for name, root in roots.items():
        # The table holds the fixture adapter; its contract is what a live
        # adapter has to satisfy, visibility included.
        base = table.get(name)
        contract = None if base is None else base.contract
        if contract is None:
            raise ContractError(
                f"source {name!r} is not reachable from the {deployment.value} "
                f"deployment; it serves {', '.join(sorted(table))}"
            )
        builder = builders.get(name)
        if builder is None:
            raise ContractError(f"no live tree adapter answers for {name!r}")
        built[name] = builder(contract, root)
    return MappingProxyType(built)
