"""Entrypoint: `python -m broker <enrollment.json>`.

Credentials are files under `BROKER_SECRETS_DIR` (default `/run/secrets`, the
projected Secret mount); a missing file aborts startup unless its host declares
`optional_secret`, in which case that host answers 503 until the file appears.
"""

from __future__ import annotations

import logging
import os
import sys

from .config import ConfigError, load_config, load_secrets
from .credentials import StaticCredentials
from .server import main


def run(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 1:
        print("usage: python -m broker <enrollment.json>", file=sys.stderr)
        return 2
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    directory = os.environ.get("BROKER_SECRETS_DIR", "/run/secrets")
    try:
        config = load_config(argv[0])
        secrets = load_secrets(config.hosts, directory)
        credentials = StaticCredentials(secrets)
    except ConfigError as exc:
        print(f"broker: {exc}", file=sys.stderr)
        return 2
    return main(config, credentials)


if __name__ == "__main__":
    sys.exit(run())
