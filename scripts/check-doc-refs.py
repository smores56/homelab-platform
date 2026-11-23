#!/usr/bin/env python3
"""Check that documentation references point at live paths and anchors.

Paths are checked from Markdown inline code, Markdown links, and `docs/...`
references in code and units. An absolute host path (`/etc/...`), an example
with a placeholder (`<name>`), and an external URL are not repository paths and
are skipped.

The baseline is a ratchet, not an allowlist: an entry is only accepted while it
still fails, so fixing a reference forces its removal from the baseline.

usage:
  scripts/check-doc-refs.py [--write-baseline]
"""
from __future__ import annotations

import argparse
import glob
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BASELINE = ROOT / "scripts" / "doc-refs-baseline.txt"
EXTENSIONS = {
    ".bu",
    ".cil",
    ".conf",
    ".container",
    ".env",
    ".json",
    ".lock",
    ".md",
    ".py",
    ".service",
    ".sh",
    ".tf",
    ".timer",
    ".toml",
    ".ts",
    ".txt",
    ".yaml",
    ".yml",
}
CODE_SPAN = re.compile(r"`([^`\n]+)`")
LINK = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")
DOC_REF = re.compile(r"docs/[A-Za-z0-9_./-]+\.md(?:#[A-Za-z0-9_-]+)?")
FENCE = re.compile(r"^\s*```")


def tracked() -> list[str]:
    return subprocess.run(
        ["git", "-C", str(ROOT), "ls-files"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.splitlines()


def slug(heading: str) -> str:
    text = re.sub(r"`([^`]*)`", r"\1", heading.strip())
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = text.lower()
    text = re.sub(r"[^\w\s-]", "", text)
    return text.strip().replace(" ", "-")


def anchors(path: Path) -> set[str]:
    if not path.exists() or path.suffix != ".md":
        return set()
    found = set()
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        match = re.match(r"^(#{1,6})\s+(.*?)\s*$", line)
        if match:
            found.add(slug(match.group(2)))
    return found


def ignored(candidate: str) -> bool:
    """A gitignored path is operator-local state, not repository content."""
    result = subprocess.run(
        ["git", "-C", str(ROOT), "check-ignore", "-q", "--", candidate],
        capture_output=True,
    )
    return result.returncode == 0


def token_like_skip(target: str) -> bool:
    """Tokens that cannot be repository paths: a flag, a URL, a prose elision,
    a hostname, or a path that starts outside this repository."""
    if target.startswith(("-", "~", "/")) or "://" in target or "..." in target:
        return True
    if any(ch in target for ch in "<>{}$|\\"):
        return True
    first = target.partition("#")[0].partition("/")[0]
    if first and first not in {".", ".."} and "." in first:
        return True
    return False


def normalize(target: str, doc: Path) -> tuple[str, str] | None:
    target = target.strip().strip("'\"")
    if not target or target.startswith(("#", "http://", "https://", "mailto:", "~", "/")):
        return None
    if any(ch in target for ch in "<>{}$|\\"):
        return None
    path, _, anchor = target.partition("#")
    path = path.strip().rstrip(".,;:")
    if not path or not repo_path(path):
        return None
    candidates = [path]
    if doc.parent != ROOT:
        candidates.append(str((doc.parent / path).relative_to(ROOT)))
    for candidate in candidates:
        if "*" in candidate:
            if glob.glob(str(ROOT / candidate), recursive=True):
                return None
            return candidate, anchor
        if (ROOT / candidate).exists():
            return (candidate, anchor) if anchor else None
        if ignored(candidate):
            return None
        if candidate.endswith(tuple(EXTENSIONS)) or "/" in candidate:
            return candidate, anchor
    return None


TOP_LEVEL = {entry.name for entry in ROOT.iterdir()}


def repo_path(target: str) -> bool:
    """A relative path is only checkable when it starts in this repository.

    A first segment that is not a top-level entry names runtime state
    (`state/agent-local`, `db-dumps/`), a directory inside one (`webui/`), or a
    path in another repository, and none of those can be checked from here.
    """
    first = target.partition("/")[0]
    return first in TOP_LEVEL or first in {"docs", "README.md"}


def looks_like_path(token: str) -> bool:
    if " " in token or token.startswith(("http://", "https://", "mailto:", "~", "/", "-")):
        return False
    if "://" in token or "..." in token:
        return False
    if any(ch in token for ch in "<>{}$|"):
        return False
    path = token.partition("#")[0]
    if not repo_path(path):
        return False
    if path in {"CODEOWNERS"}:
        return True
    # A bare filename is a unit or key name in prose far more often than a
    # repository path; only a relative path can be checked unambiguously.
    if "/" not in path:
        return False
    return path.endswith(tuple(EXTENSIONS)) or path.endswith("*") or path.endswith("/")


def failures() -> list[tuple[str, str]]:
    bad: set[tuple[str, str]] = set()
    files = tracked()
    for rel in files:
        path = ROOT / rel
        if not path.exists():
            # A deleted-but-not-yet-committed file has nothing to check.
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except (IsADirectoryError, UnicodeDecodeError):
            continue
        if path.suffix == ".md":
            fenced = False
            for number, line in enumerate(text.splitlines(), 1):
                if FENCE.match(line):
                    fenced = not fenced
                    continue
                if fenced:
                    continue
                tokens = [(token, True) for token in CODE_SPAN.findall(line)]
                tokens += [(token, False) for token in LINK.findall(line)]
                for token, is_code in tokens:
                    if is_code and not looks_like_path(token):
                        continue
                    found = normalize(token, path)
                    if not found:
                        continue
                    target, anchor = found
                    base = next(
                        (
                            candidate
                            for candidate in (
                                target,
                                str((path.parent / target).relative_to(ROOT)),
                            )
                            if (ROOT / candidate).exists()
                        ),
                        None,
                    )
                    if anchor and base and anchor not in anchors(ROOT / base):
                        bad.add((rel, f"{target}#{anchor} (missing anchor)"))
                    elif base is None:
                        bad.add((rel, f"{target}#{anchor}" if anchor else target))
        else:
            for match in DOC_REF.finditer(text):
                target = match.group(0)
                found = normalize(target, path)
                if not found:
                    continue
                file, anchor = found
                if anchor:
                    if not (ROOT / file).exists() or anchor not in anchors(ROOT / file):
                        bad.add((rel, f"{target} (missing anchor)"))
                else:
                    bad.add((rel, target))
    return sorted(bad)


def read_baseline() -> set[tuple[str, str]]:
    if not BASELINE.exists():
        return set()
    entries = set()
    for line in BASELINE.read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#"):
            continue
        source, _, target = line.partition("\t")
        if source and target:
            entries.add((source, target))
    return entries


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write-baseline", action="store_true")
    args = parser.parse_args()

    bad = failures()
    if args.write_baseline:
        BASELINE.write_text(
            "# Accepted stale references. Shrink-only: remove a line when fixed.\n"
            + "".join(f"{source}\t{target}\n" for source, target in bad),
            encoding="utf-8",
        )
        print(f"ok   wrote {len(bad)} accepted reference(s) to {BASELINE.name}")
        return 0

    baseline = read_baseline()
    current = set(bad)
    unexpected = current - baseline
    stale = baseline - current
    for source, target in sorted(unexpected):
        print(f"{source}: {target}", file=sys.stderr)
    for source, target in sorted(stale):
        print(f"baseline no longer fails (remove it): {source}: {target}", file=sys.stderr)
    if unexpected or stale:
        print(
            f"doc refs: {len(unexpected)} new, {len(stale)} stale baseline entry(s)",
            file=sys.stderr,
        )
        return 1
    print(f"ok   {len(current)} accepted reference(s), no new drift")
    return 0


if __name__ == "__main__":
    sys.exit(main())
