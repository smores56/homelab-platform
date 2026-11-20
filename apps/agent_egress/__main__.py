"""Entry point: ``python3 -m apps.agent_egress {proxy,resolver}``.

One image serves both halves of the collector egress gate: the allowlist proxy and
the allowlist DNS responder. Each command takes the policy document, the source
label its listener enforces, and the address to listen on.
"""

from __future__ import annotations

import argparse
import sys

from . import proxy, resolver


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="agent-egress")
    commands = parser.add_subparsers(dest="command", required=True)
    for name, help_text in (("proxy", "allowlist forward proxy"), ("resolver", "allowlist DNS responder")):
        command = commands.add_parser(name, help=help_text)
        command.add_argument("--policy", required=True, help="policy document (JSON)")
        command.add_argument("--source", required=True, help="the label whose allowlist this listener enforces")
        command.add_argument("--listen", required=True, metavar="HOST:PORT")
    args = parser.parse_args(argv)

    rest = ["--policy", args.policy, "--source", args.source, "--listen", args.listen]
    if args.command == "proxy":
        return proxy.main(rest)
    return resolver.main(rest)


if __name__ == "__main__":
    sys.exit(main())
