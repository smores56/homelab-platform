#!/usr/bin/env python3
"""Assert the OpenTofu config fetches only reviewed providers and no module.

`tofu init` downloads every provider a config names and runs it at plan time,
where the plan's credentials are in the environment (design #841). What gets
fetched therefore has to be closed before `init` runs, not reviewed after: an
added `required_providers` entry or a remote `module` source fetches and executes
code no review in this repository saw.

The allowlist is the committed lock file. A provider named in
`.terraform.lock.hcl` is one the repository fetched and hashed on purpose, and
`tests/tofu/check.sh` pins both of them, so the lock file is the reviewed set.
Every `module` source must be a local path: there are none today, and a remote
module is code from outside the repository.

usage:
  scripts/check-tofu-providers.py [DIR]    # DIR defaults to tofu
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

LOCK = re.compile(r'^provider[ \t]+"([^"]+)"', re.MULTILINE)
# A string, a comment, an identifier, a brace, `=`, or a comma. Strings come
# first so a `//` inside one ("https://...") is not read as a comment.
TOKEN = re.compile(
    r'"(?:[^"\\]|\\.)*"|#[^\n]*|//[^\n]*|/\*(?:[^*]|\*(?!/))*\*/'
    r'|[A-Za-z_][A-Za-z0-9_-]*|\{|\}|=',
    re.DOTALL,
)
IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_-]*")
LOCAL = re.compile(r"\.\.?/")


def fail(message: str) -> None:
    print(message)


def tokenize(text: str) -> list[tuple[int, str]]:
    """Tokens with their offset, comments dropped: bodies are read by position."""
    out = []
    for match in TOKEN.finditer(text):
        token = match.group(0)
        if token[0] in "#/" and not token.startswith('"'):
            continue
        out.append((match.start(), token))
    return out


def unquote(token: str) -> str:
    return token[1:-1]


def blocks(tokens: list[tuple[int, str]]):
    """Yield (kind, labels, body) for each block that starts at depth zero."""
    i = 0
    depth = 0
    while i < len(tokens):
        _, token = tokens[i]
        if token == "{":
            depth += 1
        elif token == "}":
            depth -= 1
        elif depth == 0 and IDENT.fullmatch(token):
            labels = []
            j = i + 1
            while j < len(tokens) and tokens[j][1].startswith('"'):
                labels.append(unquote(tokens[j][1]))
                j += 1
            if j < len(tokens) and tokens[j][1] == "{":
                nested = 1
                k = j + 1
                while k < len(tokens) and nested:
                    if tokens[k][1] == "{":
                        nested += 1
                    elif tokens[k][1] == "}":
                        nested -= 1
                    k += 1
                yield token, labels, tokens[j + 1 : k - 1], tokens[i][0]
                i = k
                continue
        i += 1


def assignments(body: list[tuple[int, str]]):
    """Yield (name, value, offset) for every `name = <string|block>` at depth 0."""
    i = 0
    depth = 0
    while i < len(body):
        _, token = body[i]
        if token == "{":
            depth += 1
        elif token == "}":
            depth -= 1
        elif depth == 0 and IDENT.fullmatch(token) and i + 1 < len(body):
            if body[i + 1][1] == "=":
                value = body[i + 2] if i + 2 < len(body) else ("", "")
                yield token, value[1], body[i][0]
                i += 3
                continue
        i += 1


def locked_sources(config: Path) -> list[str]:
    lock = config / ".terraform.lock.hcl"
    if not lock.is_file():
        sys.exit(f"FAIL {lock} is missing; the provider allowlist is the lock file")
    sources = []
    for address in LOCK.findall(lock.read_text()):
        # `registry.opentofu.org/cloudflare/cloudflare` is `cloudflare/cloudflare`.
        sources.append("/".join(address.split("/")[-2:]))
    if not sources:
        sys.exit(f"FAIL {lock} names no provider")
    return sources


def provider_entries(body: list[tuple[int, str]]):
    """Yield (name, source, offset) for each `required_providers` entry."""
    i = 0
    depth = 0
    while i < len(body):
        _, token = body[i]
        if token == "{":
            depth += 1
        elif token == "}":
            depth -= 1
        elif depth == 0 and IDENT.fullmatch(token) and i + 1 < len(body) and body[i + 1][1] == "=":
            name = token
            j = i + 2
            if j < len(body) and body[j][1] == "{":
                nested = 1
                k = j + 1
                while k < len(body) and nested:
                    if body[k][1] == "{":
                        nested += 1
                    elif body[k][1] == "}":
                        nested -= 1
                    k += 1
                source = None
                for key, value, _ in assignments(body[j + 1 : k - 1]):
                    if key == "source" and value.startswith('"'):
                        source = unquote(value)
                yield name, source if source is not None else f"hashicorp/{name}", body[i][0]
                i = k
                continue
            if j < len(body) and body[j][1].startswith('"'):
                # A bare constraint string carries the implied hashicorp source.
                yield name, f"hashicorp/{name}", body[i][0]
                i = j + 1
                continue
        i += 1


def main(argv: list[str]) -> int:
    if len(argv) > 2:
        sys.exit("usage: scripts/check-tofu-providers.py [DIR]")
    config = Path(argv[1] if len(argv) == 2 else "tofu")
    if not config.is_dir():
        sys.exit(f"FAIL {config} is not a directory")

    allowed = locked_sources(config)
    files = sorted(p for p in config.glob("*.tf") if p.is_file())
    if not files:
        sys.exit(f"FAIL {config} holds no *.tf config")

    bad = 0
    for path in files:
        text = path.read_text()

        def line_at(offset: int) -> int:
            return text.count("\n", 0, offset) + 1

        tokens = tokenize(text)
        for kind, labels, body, offset in blocks(tokens):
            line = line_at(offset)
            if kind == "terraform":
                # `required_providers` is the one nested block with no label;
                # `backend "s3"` and the test blocks carry one.
                for _, nested_labels, nested, _ in blocks(body):
                    if nested_labels:
                        continue
                    for name, source, entry_offset in provider_entries(nested):
                        if source not in allowed:
                            fail(
                                f"{path}:{line_at(entry_offset)} required_providers names "
                                f"{name} ({source}); the lock file allows {', '.join(allowed)}"
                            )
                            bad = 1
            elif kind == "module":
                name = labels[0] if labels else "<unnamed>"
                source = None
                for key, value, _ in assignments(body):
                    if key == "source" and value.startswith('"'):
                        source = unquote(value)
                if source is None:
                    fail(f"{path}:{line} module {name} declares no source")
                    bad = 1
                elif not LOCAL.match(source):
                    fail(
                        f"{path}:{line} module {name} has source {source}; "
                        "only a local ./ or ../ path is allowed"
                    )
                    bad = 1

    if bad:
        fail("tofu init would fetch a provider or module this repository did not review")
        return 1
    print(f"ok   required_providers names only {', '.join(allowed)}; every module source is local")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
