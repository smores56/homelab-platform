#!/usr/bin/env python3
"""Validate secrets/index.json against the ciphertext, the manifest, and consumers.

The index is the single declaration of a secret output. This checker proves the
three copies of that fact agree: the ciphertext exists and has the named key,
the manifest is exactly the outputs rendered in five columns, and every
consumer reference names an output. It does not decrypt anything.

usage:
  scripts/secrets-check.py [--shadow]
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
INDEX = ROOT / "secrets" / "index.json"
MANIFEST = ROOT / "image" / "rootfs" / "usr" / "share" / "smortress" / "secrets.manifest"
SECRETS = ROOT / "secrets"
RUN_REF = re.compile(r"/run/smortress/secrets/([A-Za-z0-9._-]+\.yaml)")
UNIT_REF = re.compile(r"^Secret=([A-Za-z0-9._-]+)(?:,|$)", re.MULTILINE)
KEY = re.compile(r"^([A-Za-z0-9_.-]+):", re.MULTILINE)


def tracked() -> list[str]:
    return subprocess.run(
        ["git", "-C", str(ROOT), "ls-files"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.splitlines()


def top_keys(path: Path) -> list[str]:
    text = path.read_text(encoding="utf-8", errors="replace")
    if path.suffix == ".json":
        try:
            return [key for key in json.loads(text) if key != "sops"]
        except json.JSONDecodeError:
            return []
    return [key for key in KEY.findall(text) if key != "sops"]


def bundle_path(name: str) -> Path | None:
    for candidate in (SECRETS / "server" / name, SECRETS / name):
        if candidate.exists():
            return candidate
    return None


def manifest_rows() -> list[tuple[str, str, str, str, str, str, str]]:
    rows = []
    for line in MANIFEST.read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        parts = line.split()
        if len(parts) >= 7:
            rows.append(tuple(parts[:7]))
        elif len(parts) >= 4:
            fmt = parts[4] if len(parts) > 4 else "yaml"
            rows.append((parts[0], parts[0], "*", parts[1], parts[2], parts[3], fmt))
    return rows


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shadow", action="store_true", help="compare the rendered manifest and exit")
    args = parser.parse_args()

    if not INDEX.exists():
        print(f"secrets-check: {INDEX} is missing", file=sys.stderr)
        return 1
    index = json.loads(INDEX.read_text(encoding="utf-8"))
    outputs = index.get("outputs", [])
    bundles = index.get("bundles", {})
    operators = index.get("operator", [])
    problems = 0

    def bad(message: str) -> None:
        nonlocal problems
        print(f"secrets-check: {message}", file=sys.stderr)
        problems += 1

    names: set[str] = set()
    for output in outputs:
        name = output.get("name", "")
        if not re.fullmatch(r"[A-Za-z0-9._-]+\.yaml", name):
            bad(f"bad output name {name!r}")
            continue
        if name in names:
            bad(f"duplicate output {name}")
        names.add(name)
        if bundles.get(name) != output.get("bundle"):
            bad(f"{name}: bundles[{name}] does not match output.bundle")
        mode = output.get("mode", "")
        if not re.fullmatch(r"0?[46]00", mode):
            bad(f"{name}: mode must be 0400 or 0600, got {mode!r}")
        fmt = output.get("format", "yaml")
        if fmt not in {"value", "yaml"}:
            bad(f"{name}: unknown format {fmt!r}")
        bundle = bundle_path(output.get("bundle", ""))
        if bundle is None:
            bad(f"{name}: bundle {output.get('bundle')!r} is missing under secrets/")
            continue
        keys = top_keys(bundle)
        key = output.get("key", "")
        first = key.split(".", 1)[0]
        if fmt == "value":
            if key == "*" or first not in keys:
                bad(f"{name}: value output needs a key under {keys}, got {key!r}")
        elif not key:
            bad(f"{name}: yaml output has no key")

        consumer = output.get("consumer", "")
        if output.get("staged"):
            continue
        if not consumer:
            bad(f"{name}: has no consumer")
            continue
        consumer_path = ROOT / consumer
        if not consumer_path.exists():
            bad(f"{name}: consumer {consumer} does not exist")
        elif not output.get("indirect"):
            text = consumer_path.read_text(encoding="utf-8", errors="replace")
            if name not in text and name.removesuffix(".yaml") not in text:
                bad(f"{name}: {consumer} does not name it")

    for name in sorted(set(bundles) - names):
        bad(f"bundles has {name} with no output")
    for pattern in ("server/*.yaml", "*.json"):
        for path in sorted(SECRETS.glob(pattern)):
            if path.name in {"index.json", "index.bundles.json"}:
                continue
            if path.name not in set(bundles.values()):
                bad(f"{path.relative_to(ROOT)} is ciphertext but not a declared bundle")
    for name in operators:
        path = SECRETS / name
        if not path.exists():
            bad(f"operator bundle {name} is missing")
        elif not top_keys(path):
            bad(f"operator bundle {name} has no SOPS metadata")

    expected = sorted(
        (o["name"], o["bundle"], o["key"], o["uid"], o["gid"], o["mode"], o.get("format", "yaml"))
        for o in outputs
    )
    actual = sorted(manifest_rows())
    if args.shadow:
        if expected != actual:
            print("secrets-check: rendered manifest differs from the committed manifest", file=sys.stderr)
            for row in sorted(set(expected) - set(actual)):
                print(f"  missing from manifest: {row}", file=sys.stderr)
            for row in sorted(set(actual) - set(expected)):
                print(f"  only in manifest: {row}", file=sys.stderr)
            return 1
        print(f"ok   {len(outputs)} output(s) render the committed manifest")
        return 0
    if expected != actual:
        bad("manifest and index disagree; run scripts/secrets-check.py --shadow for the diff")

    for rel in tracked():
        if not (
            rel.startswith(("units/", "scripts/", "image/rootfs/", "tests/"))
            and rel.endswith((".sh", ".py", ".container", ".service", ".timer"))
        ):
            continue
        text = (ROOT / rel).read_text(encoding="utf-8", errors="replace")
        for ref in RUN_REF.findall(text):
            if ref not in names:
                bad(f"{rel}: /run reference {ref} has no index output")
        for ref in UNIT_REF.findall(text):
            if f"{ref}.yaml" not in names:
                bad(f"{rel}: Podman secret {ref} has no index output")

    if problems:
        print(f"secrets-check: {problems} problem(s)", file=sys.stderr)
        return 1
    print(f"ok   {len(outputs)} output(s), {len(set(bundles.values()))} bundle(s), {len(operators)} operator file(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
