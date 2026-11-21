"""Plant one Brave Sync seed into a headless profile's ``Preferences``.

Brave's join UI is the only supported way to make a profile part of a Sync chain,
and it needs a human to type a 25-word code. Everything it writes is a
preference, so the unattended path is the same thing one step later: write those
preferences before the browser starts, and the engine starts joined.

Three things are planted, because the join UI writes all three and any one of them
missing gives a profile that looks joined and yields nothing:

* ``brave_sync_v2.seed`` -- the OSCrypt blob. Brave stores it as base64 of the raw
  ``v10`` + IV + ciphertext bytes, while every other tool here carries the same
  blob as the ``v10<base64>`` contract string the desktop export produces, so this
  module converts one form to the other and nothing else. The blob decrypts with
  Chromium's fixed "peanuts" key, which is why ``--password-store=basic`` is part
  of the browser's arguments: with any other keyring the planted seed would be
  undecryptable, silently.
* ``sync.requested`` and ``sync.keep_everything_synced`` -- Chromium's SyncService
  only starts for a profile whose prefs ask for it.
* ``sync.has_setup_completed`` -- without it the engine registers, gets a
  ``gaia_id`` and transport state, and never runs the initial download.

The seed is a secret: it is the key to the chain, so it is read from a file this
process does not log, never printed, never put in argv, and the file that carries
it is written ``0600``. Existing keys are preserved -- the browser rewrites
``Preferences`` constantly and the seeder runs before every start, so a run that
replaced the document would drop everything else the profile had.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import copy
import json
import os
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Mapping

#: A refusal is exit 3, the same code the raw collectors use: the unit is failed
#: and the journal names the reason, and nothing is written.
EXIT_REFUSED = 3

UNIT = "agent-brave-seed"
SEED_PATH: tuple[str, str] = ("brave_sync_v2", "seed")
SYNC_PREFS = {
    "requested": True,
    "keep_everything_synced": True,
    "has_setup_completed": True,
}
#: The contract string is `v10` + base64(IV + ciphertext), a few hundred bytes; the
#: cap is what a file that is not a seed at all trips before it is decoded.
MAX_SEED_BYTES = 65536
#: `v10` is OSCrypt's version prefix; the payload is a 16-byte IV followed by
#: AES-128-CBC ciphertext, so it is a non-zero multiple of the block size.
_OSCRYPT_PREFIX = "v10"
_BLOCK = 16


class SeedError(RuntimeError):
    """A refused seed, Preferences document or write."""


def log(event: str, **fields: object) -> None:
    """One JSON line, and never the seed: callers pass presence, not value."""

    record = {
        "ts": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "unit": UNIT,
        "event": event,
    }
    record.update(fields)
    print(json.dumps(record, sort_keys=True), flush=True)


def oscrypt_blob(seed: str) -> bytes:
    """Decode the contract's ``v10<base64>`` string to the raw OSCrypt blob."""

    text = seed.strip()
    if not text:
        raise SeedError("the seed is empty")
    if len(text.encode("utf-8")) > MAX_SEED_BYTES:
        raise SeedError("the seed exceeds the size cap")
    if not text.startswith(_OSCRYPT_PREFIX):
        raise SeedError("the seed does not start with v10")
    payload = text[len(_OSCRYPT_PREFIX) :]
    try:
        decoded = base64.b64decode(payload, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise SeedError(f"the seed is not base64 after v10: {exc}") from None
    if len(decoded) < 2 * _BLOCK or len(decoded) % _BLOCK:
        raise SeedError(
            "the seed is not an OSCrypt blob: expected a 16-byte IV and CBC ciphertext"
        )
    return _OSCRYPT_PREFIX.encode("ascii") + decoded


def stored_seed(seed: str) -> str:
    """The form Brave writes: base64 of the raw blob, ``v10`` included."""

    return base64.b64encode(oscrypt_blob(seed)).decode("ascii")


def read_seed(path: str | Path) -> str:
    """The seed as the secret file carries it, which is the contract form."""

    source = Path(path)
    if source.is_symlink():
        raise SeedError(f"{source} is a symlink; refusing to follow it")
    try:
        raw = source.read_bytes()
    except FileNotFoundError:
        raise SeedError(f"{source} is missing") from None
    except OSError as exc:
        raise SeedError(f"{source} is unreadable: {exc.strerror}") from None
    if len(raw) > MAX_SEED_BYTES:
        raise SeedError(f"{source} is larger than a seed")
    # A Podman secret mounted as a file ends with the newline the ciphertext was
    # written with; no valid seed contains one, so stripping the ends is exact.
    text = raw.decode("utf-8", "replace").strip()
    if not text:
        raise SeedError(f"{source} is empty")
    return text


def load_preferences(path: str | Path) -> dict[str, Any]:
    """The profile's Preferences, or an empty document when it does not exist."""

    target = Path(path)
    try:
        document = json.loads(target.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {}
    except (OSError, UnicodeDecodeError):
        raise SeedError(f"{target} is unreadable") from None
    except json.JSONDecodeError:
        raise SeedError(f"{target} is not JSON") from None
    if not isinstance(document, dict):
        raise SeedError(f"{target} is not a JSON object")
    return document


def write_preferences(path: str | Path, document: Mapping[str, Any]) -> None:
    """Replace Preferences in one rename, at mode 0600."""

    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    handle_fd, temporary = tempfile.mkstemp(
        dir=str(target.parent), prefix=".Preferences-", suffix=".tmp"
    )
    try:
        with os.fdopen(handle_fd, "w", encoding="utf-8") as handle:
            json.dump(document, handle, sort_keys=True)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, target)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def plant(document: Mapping[str, Any], seed: str) -> dict[str, Any]:
    """Return a copy of ``document`` with the seed and the three sync prefs set."""

    planted: dict[str, Any] = copy.deepcopy(dict(document))
    node = planted
    for part in SEED_PATH[:-1]:
        child = node.get(part)
        if not isinstance(child, dict):
            child = {}
            node[part] = child
        node = child
    node[SEED_PATH[-1]] = stored_seed(seed)
    # The join UI's own keys, merged rather than replaced: the sync engine keeps a
    # device id and transport state under `sync` on a profile that has run once.
    sync = planted.get("sync")
    if not isinstance(sync, dict):
        sync = {}
        planted["sync"] = sync
    for key, value in SYNC_PREFS.items():
        sync[key] = value
    return planted


def seed_profile(prefs_path: str | Path, seed_path: str | Path) -> dict[str, object]:
    """Plant the seed file's value into the profile; report what happened."""

    seed = read_seed(seed_path)
    current = load_preferences(prefs_path)
    planted = plant(current, seed)
    # A run that would write the same document is the normal case from the second
    # boot on: not writing it leaves the profile's mtime and the browser's own
    # concurrent rewrite of unrelated keys alone.
    unchanged = planted == current and Path(prefs_path).exists()
    if not unchanged:
        write_preferences(prefs_path, planted)
    return {
        "prefs": str(prefs_path),
        "planted": not unchanged,
        "unchanged": unchanged,
    }


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="brave-seed",
        description="Plant a Brave Sync seed into a headless profile's Preferences.",
    )
    parser.add_argument(
        "--prefs",
        default="/data/Default/Preferences",
        help="the profile's Preferences (default: /data/Default/Preferences)",
    )
    parser.add_argument(
        "--seed-file",
        default="/run/secrets/brave-sync-seed",
        help="the secret file holding v10<base64> (default: /run/secrets/brave-sync-seed)",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(list(sys.argv[1:] if argv is None else argv))
    try:
        summary = seed_profile(args.prefs, args.seed_file)
    except (SeedError, OSError) as error:
        log("refused", prefs=args.prefs, reason=str(error))
        return EXIT_REFUSED
    log("seed", **summary)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
