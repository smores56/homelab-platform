#!/usr/bin/env python3
"""Consolidate the one-file-per-secret set into lifecycle bundles.

The spec maps each current output to a bundle and a dotted key. `--apply`
decrypts every current ciphertext with the operator identity, writes the nested
JSON bundles, encrypts them to the repository policy, verifies every value, and
optionally writes the target index. It never deletes the old ciphertext: the
operator reviews the diff, swaps `index.json`, and removes `secrets/server/` by
hand.

usage:
  scripts/secrets-bundle.py --check
  scripts/secrets-bundle.py --apply --write-index
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def err(message: str) -> None:
    print(f"secrets-bundle: {message}", file=sys.stderr)


def json_path(key: str) -> str:
    return "".join(f'["{part}"]' for part in key.split("."))


def decrypt(path: Path, key: str, sops: str, env: dict) -> object:
    input_type = "json" if path.suffix == ".json" else "yaml"
    args = [sops, "--decrypt", "--input-type", input_type, "--output-type", "json"]
    if key != "*":
        args += ["--extract", json_path(key)]
    args.append(str(path))
    text = subprocess.check_output(args, text=True, env=env).strip()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return text


def assign(data: dict, key: str, value: object) -> None:
    parts = key.split(".")
    cur = data
    for part in parts[:-1]:
        nxt = cur.setdefault(part, {})
        if not isinstance(nxt, dict):
            raise ValueError(f"{part} is already a scalar")
        cur = nxt
    if parts[-1] in cur:
        raise ValueError(f"{key} is declared twice")
    cur[parts[-1]] = value


def encrypt(path: Path, data: dict, config: Path, sops: str, env: dict) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        plain = Path(tmp) / "plain.json"
        plain.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
        result = subprocess.run(
            [
                sops,
                "--config",
                str(config),
                "--encrypt",
                "--input-type",
                "json",
                "--output-type",
                "json",
                "--filename-override",
                str(config.parent / "secrets" / path.name),
                str(plain),
            ],
            capture_output=True,
            text=True,
            env=env,
        )
        if result.returncode != 0:
            raise RuntimeError(result.stderr.strip() or "sops encrypt failed")
        path.write_text(result.stdout, encoding="utf-8")


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=".")
    parser.add_argument("--index")
    parser.add_argument("--spec")
    parser.add_argument("--out-index")
    parser.add_argument("--check", action="store_true", help="validate the spec and exit")
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--write-index", action="store_true")
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()

    repo = Path(args.repo).resolve()
    index_path = Path(args.index).resolve() if args.index else repo / "secrets" / "index.json"
    spec_path = Path(args.spec).resolve() if args.spec else repo / "scripts" / "secrets-bundles.json"
    out_index = Path(args.out_index).resolve() if args.out_index else repo / "secrets" / "index.bundles.json"
    config = repo / ".sops.yaml"
    sops = "sops"
    env = os.environ.copy()
    keycmd = Path.home() / ".local" / "bin" / "sops-age-key"
    if (
        not env.get("SOPS_AGE_KEY_CMD")
        and not env.get("SOPS_AGE_KEY_FILE")
        and not env.get("SOPS_AGE_KEY")
        and keycmd.is_file()
    ):
        env["SOPS_AGE_KEY_CMD"] = str(keycmd)
        print(f"using {keycmd} as SOPS_AGE_KEY_CMD", file=sys.stderr)
    canonical = Path.home() / ".config" / "sops" / "sops.yaml"
    if not env.get("SOPS_CONFIG") and canonical.is_file():
        env["SOPS_CONFIG"] = str(canonical)

    index = load(index_path)
    spec = load(spec_path)
    outputs = {output["name"]: output for output in index.get("outputs", [])}
    mapped = {name for entries in spec.values() for name in entries}

    if mapped != set(outputs):
        err(f"spec covers {sorted(mapped)}, index has {sorted(outputs)}")
        return 1

    target = {
        "note": "Generated from the bundle spec; each output names its bundle and dotted key.",
        "bundles": {},
        "operator": index.get("operator", []),
        "outputs": [],
    }
    for bundle, entries in spec.items():
        for name, key in entries.items():
            source = outputs[name]
            target["bundles"][name] = bundle
            target["outputs"].append(
                {
                    "name": name,
                    "bundle": bundle,
                    "key": key,
                    "uid": source["uid"],
                    "gid": source["gid"],
                    "mode": source["mode"],
                    "format": source.get("format", "yaml"),
                    "consumer": source.get("consumer", ""),
                    **({"staged": True} if source.get("staged") else {}),
                    **({"indirect": True} if source.get("indirect") else {}),
                }
            )

    if not args.apply:
        if args.write_index:
            out_index.write_text(json.dumps(target, indent=2) + "\n", encoding="utf-8")
            print(f"ok   wrote {out_index}")
        print(f"ok   spec covers {len(outputs)} output(s) in {len(spec)} bundle(s)")
        return 0

    if any(output.get("bundle", "").endswith(".json") for output in outputs.values()):
        err("index.json already points at bundles; nothing to migrate")
        return 1
    missing = [name for name in outputs if not (repo / "secrets" / "server" / name).exists()]
    if missing:
        err(f"{len(missing)} source ciphertext(s) are missing; restore the set first:")
        err("  git checkout HEAD -- secrets/server")
        for name in missing[:5]:
            err(f"  {name}")
        return 1

    if not config.exists():
        err(f"{config} is missing")
        return 1

    data: dict[str, dict] = {}
    values: dict[str, object] = {}
    for name, key in ((n, k) for entries in spec.values() for n, k in entries.items()):
        old = repo / "secrets" / "server" / name
        value = decrypt(old, outputs[name].get("key", "*"), sops, env)
        values[name] = value
        bundle = target["bundles"][name]
        assign(data.setdefault(bundle, {}), key, value)

    written: list[Path] = []
    try:
        for bundle, payload in data.items():
            path = repo / "secrets" / bundle
            if path.exists() and not args.force:
                err(f"{path} exists; pass --force to replace it")
                return 1
            encrypt(path, payload, config, sops, env)
            written.append(path)
            print(f"ok   wrote {path}")

        for output in target["outputs"]:
            path = repo / "secrets" / output["bundle"]
            got = decrypt(path, output["key"], sops, env)
            if got != values[output["name"]]:
                err(f"{output['name']} does not round-trip through {output['bundle']}")
                return 1
    except (RuntimeError, subprocess.CalledProcessError) as exc:
        for path in written:
            path.unlink(missing_ok=True)
        err(str(exc))
        return 1

    if args.write_index:
        out_index.write_text(json.dumps(target, indent=2) + "\n", encoding="utf-8")
        print(f"ok   wrote {out_index}")
    print(f"ok   verified {len(values)} output(s); review, then swap index.json and remove secrets/server/")
    return 0


if __name__ == "__main__":
    sys.exit(main())
