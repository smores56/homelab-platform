#!/usr/bin/env python3
"""Render the boot manifest and bundle list from secrets/index.json.

The seed runs this on the image copy and replaces /etc/smortress/secrets.manifest
from it, so the index is the only host-owned declaration. It is a separate
program because the boot path must not parse JSON in shell.

usage:
  scripts/secrets-index.py render-manifest [--index PATH] [--out PATH]
  scripts/secrets-index.py bundles [--index PATH]
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

DEFAULT_INDEX = Path(__file__).resolve().parent.parent / "secrets" / "index.json"


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["render-manifest", "bundles"])
    parser.add_argument("--index", default=str(DEFAULT_INDEX))
    parser.add_argument("--out")
    args = parser.parse_args()

    index = load(Path(args.index))
    outputs = index.get("outputs", [])
    if args.command == "bundles":
        for bundle in sorted({output["bundle"] for output in outputs}):
            print(bundle)
        return 0

    lines = []
    for output in outputs:
        lines.append(
            " ".join(
                [
                    output["name"],
                    output["uid"],
                    output["gid"],
                    output["mode"],
                    output.get("format", "yaml"),
                ]
            )
        )
    content = "\n".join(lines) + "\n"
    if args.out:
        Path(args.out).write_text(content, encoding="utf-8")
    else:
        sys.stdout.write(content)
    return 0


if __name__ == "__main__":
    sys.exit(main())
