"""Live tree adapters: a file at HEAD, a book's OPF, and their bounds.

Each case builds a real bare clone and a real OPDShelf entry in a temporary
directory and asks the adapter the two questions the facade tool surface asks.
No network, no container: ``git`` is the same binary the runtime image carries,
and the OPF is written by the test.
"""

from __future__ import annotations

import hashlib
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from agent_facade import sources, tree_sources
from data_plane.model import Visibility

GIT = "git"


def _git(*arguments: str, cwd: Path) -> str:
    environment = {
        "PATH": "/usr/bin:/bin",
        "LC_ALL": "C",
        "GIT_AUTHOR_NAME": "Test",
        "GIT_AUTHOR_EMAIL": "test@example.com",
        "GIT_COMMITTER_NAME": "Test",
        "GIT_COMMITTER_EMAIL": "test@example.com",
        "GIT_CONFIG_GLOBAL": "/dev/null",
    }
    return subprocess.run(
        [GIT, *arguments],
        cwd=cwd,
        capture_output=True,
        text=True,
        env=environment,
        check=True,
    ).stdout


def publish_repo(root: Path, name: str = "github.com/smores56/homelab-platform") -> Path:
    """A clean-bare clone at ``root/<name>/.git`` with a few committed files."""

    work = root / "work"
    work.mkdir(parents=True, exist_ok=True)
    _git("init", "-q", "-b", "main", cwd=work)
    (work / "README.md").write_text(
        "# Homelab\n\nFlux manifests and the boiler maintenance runbook.\n", encoding="utf-8"
    )
    (work / "justfile").write_text("test:\n\thome-ops check\n", encoding="utf-8")
    (work / "big.txt").write_text("x" * (tree_sources.MAX_FILE_BYTES + 1024), encoding="utf-8")
    (work / "logo.png").write_bytes(b"\x89PNG\r\n\x1a\n\x00\x00binary")
    _git("add", "-A", cwd=work)
    _git("commit", "-q", "-m", "first", cwd=work)

    bare = root / name / ".git"
    bare.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [GIT, "clone", "-q", "--bare", str(work), str(bare)],
        capture_output=True,
        check=True,
        env={"PATH": "/usr/bin:/bin", "LC_ALL": "C", "GIT_CONFIG_GLOBAL": "/dev/null"},
    )
    return bare


def publish_book(
    root: Path,
    author: str = "Ursula K. Le Guin",
    title: str = "The Dispossessed",
    description: str = "A physicist leaves a moon for its mother planet.",
) -> Path:
    entry = root / author / title
    entry.mkdir(parents=True, exist_ok=True)
    (entry / "metadata.opf").write_text(
        f"""<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>{title}</dc:title>
    <dc:creator>{author}</dc:creator>
    <dc:description>{description}</dc:description>
    <dc:date>1974</dc:date>
    <dc:language>en</dc:language>
  </metadata>
</package>
""",
        encoding="utf-8",
    )
    (entry / f"{title} - {author}.epub").write_bytes(b"PK\x03\x04not-a-real-epub")
    return entry


def _contract(name: str):
    return sources.SOURCES_BY_DEPLOYMENT[Visibility.GENERAL][name].contract


def _head(bare: Path) -> str:
    return _git("rev-parse", "HEAD", cwd=bare.parent).strip()


class RepoTreeTests(unittest.TestCase):
    def setUp(self) -> None:
        self._work = tempfile.TemporaryDirectory()
        self.root = Path(self._work.name)
        self.bare = publish_repo(self.root)
        self.repos = tree_sources.RepoTreeAdapter(_contract("repos"), self.root)

    def tearDown(self) -> None:
        self._work.cleanup()

    def test_reads_a_file_at_head_with_the_commit_as_its_revision(self) -> None:
        record_id = "repos::github.com/smores56/homelab-platform::README.md"
        record = self.repos.read(record_id)
        self.assertEqual(record.id, record_id)
        self.assertIn("boiler maintenance", record.body)
        self.assertEqual(record.title, "github.com/smores56/homelab-platform:README.md")
        self.assertEqual(record.revision, _head(self.bare))
        self.assertEqual(record.provenance["revision"], record.revision)
        self.assertNotIn("truncated", record.provenance)

    def test_a_missing_path_is_not_found(self) -> None:
        with self.assertRaises(sources.SourceNotFound):
            self.repos.read("repos::github.com/smores56/homelab-platform::no/such/file.md")

    def test_a_path_that_steps_out_of_the_clone_is_refused(self) -> None:
        for bad in (
            "repos::github.com/smores56/homelab-platform::../etc/passwd",
            "repos::github.com/smores56/homelab-platform::/etc/passwd",
            "repos::github.com/smores56/../homelab-platform::README.md",
        ):
            with self.subTest(record=bad), self.assertRaises(tree_sources.InvalidRecordId):
                self.repos.read(bad)

    def test_a_binary_file_is_refused_rather_than_mangled(self) -> None:
        with self.assertRaises(sources.SourceUnsupported):
            self.repos.read("repos::github.com/smores56/homelab-platform::logo.png")

    def test_a_large_file_is_cut_and_says_so(self) -> None:
        record = self.repos.read("repos::github.com/smores56/homelab-platform::big.txt")
        self.assertEqual(len(record.body), tree_sources.MAX_FILE_BYTES)
        self.assertEqual(record.provenance["truncated"], "true")

    def test_search_matches_content_with_every_word(self) -> None:
        hits = self.repos.search("boiler runbook", 5)
        self.assertEqual(
            [hit.id for hit in hits],
            ["repos::github.com/smores56/homelab-platform::README.md"],
        )
        self.assertIn("boiler", hits[0].snippet.casefold())
        self.assertEqual(self.repos.search("boiler flux", 5), ())

    def test_search_matches_a_path_the_content_does_not_hold(self) -> None:
        hits = self.repos.search("justfile", 5)
        self.assertEqual(
            [hit.id for hit in hits],
            ["repos::github.com/smores56/homelab-platform::justfile"],
        )

    def test_search_respects_the_limit(self) -> None:
        self.assertEqual(len(self.repos.search("e", 1)), 1)

    def test_an_unmounted_root_is_unavailable(self) -> None:
        adapter = tree_sources.RepoTreeAdapter(_contract("repos"), self.root / "absent")
        with self.assertRaises(sources.SourceUnavailable):
            adapter.search("boiler", 5)


class BooksTreeTests(unittest.TestCase):
    def setUp(self) -> None:
        self._work = tempfile.TemporaryDirectory()
        self.root = Path(self._work.name)
        self.entry = publish_book(self.root)
        self.books = tree_sources.BooksTreeAdapter(_contract("books"), self.root)

    def tearDown(self) -> None:
        self._work.cleanup()

    def test_reads_the_opf_metadata_not_the_epub(self) -> None:
        record = self.books.read("books::Ursula K. Le Guin/The Dispossessed")
        self.assertEqual(record.title, "The Dispossessed")
        self.assertIn("Ursula K. Le Guin", record.body)
        self.assertIn("physicist", record.body)
        opf = self.entry / "metadata.opf"
        self.assertEqual(record.revision, hashlib.sha256(opf.read_bytes()).hexdigest())
        self.assertEqual(record.provenance["revision"], record.revision)

    def test_a_missing_book_is_not_found(self) -> None:
        with self.assertRaises(sources.SourceNotFound):
            self.books.read("books::Nobody/No Book")

    def test_an_id_that_is_not_two_components_is_refused(self) -> None:
        for bad in ("books::Dune", "books::a/b/c", "books::../secrets/x"):
            with self.subTest(record=bad), self.assertRaises(tree_sources.InvalidRecordId):
                self.books.read(bad)

    def test_search_matches_title_author_and_description(self) -> None:
        for query in ("dispossessed", "guin", "physicist moon"):
            with self.subTest(query=query):
                hits = self.books.search(query, 5)
                self.assertEqual(
                    [hit.id for hit in hits],
                    ["books::Ursula K. Le Guin/The Dispossessed"],
                )
        self.assertEqual(self.books.search("le guin dune", 5), ())

    def test_an_unparseable_opf_is_skipped_by_search_and_unavailable_on_read(self) -> None:
        broken = self.root / "Broken" / "Author"
        broken.mkdir(parents=True)
        (broken / "metadata.opf").write_text("<package>", encoding="utf-8")
        self.assertEqual(
            [hit.id for hit in self.books.search("dispossessed", 5)],
            ["books::Ursula K. Le Guin/The Dispossessed"],
        )
        with self.assertRaises(sources.SourceUnavailable):
            self.books.read("books::Broken/Author")


class BindingTests(unittest.TestCase):
    def test_the_general_table_binds_both_live_adapters(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            adapters = tree_sources.tree_adapters_for(
                Visibility.GENERAL, {"repos": work, "books": work}
            )
            self.assertEqual(sorted(adapters), ["books", "repos"])

    def test_the_personal_table_refuses_both(self) -> None:
        for name in ("repos", "books"):
            with self.subTest(source=name), self.assertRaises(Exception):
                tree_sources.tree_adapters_for(Visibility.PERSONAL, {name: "/"})

    def test_an_unknown_source_is_refused(self) -> None:
        with self.assertRaises(Exception):
            tree_sources.tree_adapters_for(Visibility.GENERAL, {"mail": "/"})


if __name__ == "__main__":
    unittest.main()
