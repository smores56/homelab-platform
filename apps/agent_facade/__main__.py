"""Entrypoint: ``python -m apps.agent_facade``.

One process is one deployment. The deployment, the memory root, the byte cap and
the one token come from flags or from the matching ``AGENT_FACADE_*``
environment variable; a missing deployment aborts startup rather than serving a
half-configured endpoint, and a missing token starts the process anyway so that
every tool call is refused with a JSON error instead of the child dying on a
client that has no other way to learn why.

The token is read once from the environment or from the file named by
``--token-file`` (``AGENT_FACADE_TOKEN_FILE``, the container form), held in
memory, and never logged: the log line reports only whether one is configured.

Logs go to stderr, so stdout belongs to the stdio transport alone. The app
imports the data-plane libraries from ``libs/``, which is how the other
``apps/`` packages are run:

    PYTHONPATH=libs python3 -m apps.agent_facade --deployment personal
"""

from __future__ import annotations

import argparse
import logging
import os
import sys
from pathlib import Path
from typing import Iterable

from data_plane.errors import DataPlaneError

from . import contracts, memory, replica_sources, server, sources

DEFAULT_TRANSPORT = "stdio"
DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 18004
DEFAULT_MEMORY_ROOT = "state/agent-facade"
TOKEN_ENV = "AGENT_FACADE_TOKEN"
TRANSPORTS = ("stdio", "http")

LOG = logging.getLogger("agent-facade")


class ConfigError(Exception):
    """Startup configuration is missing or invalid."""


def _env(name: str, default: str | None = None) -> str | None:
    value = os.environ.get(name)
    return default if value is None or not value.strip() else value


def _required(value: str | None, name: str) -> str:
    if not value:
        raise ConfigError(f"{name} is required")
    return value


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m apps.agent_facade",
        description="Serve one agent deployment's typed source facades and memory.",
    )
    parser.add_argument(
        "--transport",
        choices=TRANSPORTS,
        default=_env("AGENT_FACADE_TRANSPORT", DEFAULT_TRANSPORT),
        help="stdio (newline JSON-RPC) or http (Streamable HTTP on POST /mcp)",
    )
    parser.add_argument(
        "--deployment",
        default=_env("AGENT_FACADE_DEPLOYMENT"),
        help="personal or general; this process serves exactly one",
    )
    parser.add_argument(
        "--token-file",
        default=_env("AGENT_FACADE_TOKEN_FILE"),
        help="file holding the one deployment token (else AGENT_FACADE_TOKEN)",
    )
    parser.add_argument(
        "--memory-root",
        default=_env("AGENT_FACADE_MEMORY_ROOT", DEFAULT_MEMORY_ROOT),
        help="root of the memory profile this deployment may write",
    )
    parser.add_argument(
        "--host", default=_env("AGENT_FACADE_HOST", DEFAULT_HOST), help="http bind address"
    )
    parser.add_argument(
        "--port",
        type=int,
        default=int(_env("AGENT_FACADE_PORT", str(DEFAULT_PORT)) or DEFAULT_PORT),
        help="http bind port",
    )
    parser.add_argument(
        "--max-body-bytes",
        type=int,
        default=int(
            _env("AGENT_FACADE_MAX_BODY_BYTES", str(contracts.MAX_BODY_BYTES))
            or contracts.MAX_BODY_BYTES
        ),
        help="cap for a returned body and for a written memory value",
    )
    parser.add_argument(
        "--replica",
        action="append",
        default=[],
        metavar="SOURCE=DIR",
        help=(
            "answer one source of this deployment from a published raw generation "
            "at DIR instead of the fixture (mail, calendar, finance, brave)"
        ),
    )
    return parser


def _token(token_file: str | None) -> str | None:
    """The one deployment token: the named file if there is one, else the env.

    A file that exists but reads empty is a startup failure: a service with an
    empty credential is a service that can only refuse, and silently doing so is
    worse than not starting.
    """

    if token_file:
        path = Path(token_file)
        try:
            token = path.read_text(encoding="utf-8").strip()
        except OSError as error:
            raise ConfigError(
                f"cannot read token file {path}: {error.strerror}"
            ) from error
        if not token:
            raise ConfigError(f"token file {path} is empty")
        return token
    return _env(TOKEN_ENV)


def _replicas(specs: Iterable[str]) -> dict[str, Path]:
    """Parse ``SOURCE=DIR`` arguments, refusing a duplicate source."""

    roots: dict[str, Path] = {}
    for spec in specs:
        name, separator, directory = spec.partition("=")
        if not separator or not name.strip() or not directory.strip():
            raise ConfigError(f"--replica wants SOURCE=DIR, got {spec!r}")
        if name in roots:
            raise ConfigError(f"--replica names {name!r} twice")
        roots[name] = Path(directory)
    return roots


def build_facade(args: argparse.Namespace) -> server.Facade:
    """Build one deployment's facade from parsed configuration."""

    if args.max_body_bytes < 1:
        raise ConfigError("--max-body-bytes must be positive")
    deployment = sources.deployment(
        _required(args.deployment, "--deployment (AGENT_FACADE_DEPLOYMENT)")
    )
    token = _token(args.token_file)
    if token is None:
        LOG.warning("no deployment token configured; every tool call will be refused")
    replacements = replica_sources.adapters_for(deployment, _replicas(args.replica))
    return server.Facade(
        deployment=deployment,
        catalog=sources.Catalog.for_deployment(deployment, replacements=replacements),
        store=memory.MemoryIndex(args.memory_root, deployment),
        token=token,
        max_body_bytes=args.max_body_bytes,
    )


def main(argv: Iterable[str] | None = None) -> int:
    args = _parser().parse_args(list(sys.argv[1:] if argv is None else argv))
    logging.basicConfig(
        stream=sys.stderr,
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    try:
        facade = build_facade(args)
    except (ConfigError, DataPlaneError) as error:
        print(f"agent-facade: {error}", file=sys.stderr)
        return 2

    if args.transport == "stdio":
        server.serve_stdio(facade)
        return 0
    server.serve_http(facade, args.host, args.port)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
