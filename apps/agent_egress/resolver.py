"""Allowlist-only DNS responder, one listener per source label.

A query is answered only when its qname is in that label's allowlist and its qtype
is A or AAAA; every other name is REFUSED, as is every other qtype. Allowed names
are resolved by the host's own upstream through `getaddrinfo`, and private,
loopback, link-local and reserved answers are dropped, so a compromised
allowlisted name cannot point a container at the LAN or at the bridge itself.

As with the proxy, the source label is the listener's, not the client's: nftables
decides which container reaches this port, and the allowlist decides what it may
learn from it. The proxy does not
need this responder to work -- it resolves upstream names itself -- so a resolver
outage costs cache hits, not egress.

Ported from smores56/nix-config, `modules/lib/ingest/resolver.py`, and adapted: the
per-tap host address and guest-address peer check are the microVM plane's, where
one listener belonged to exactly one guest.
"""

from __future__ import annotations

import argparse
import ipaddress
import json
import select
import socket
import sys
from collections.abc import Callable
from datetime import datetime, timezone

from . import policy

RCODE_REFUSED = 5
SUPPORTED_TYPES = (1, 28)  # A, AAAA

Sink = Callable[..., None]


def log(event: str, **fields: object) -> None:
    record = {"ts": datetime.now(timezone.utc).isoformat(timespec="seconds"), "unit": "agent-egress-resolver", "event": event}
    record.update(fields)
    print(json.dumps(record, sort_keys=True), flush=True)


class Resolver:
    """One UDP listener, one source label, one allowlist."""

    def __init__(self, policy_data: policy.Policy, source: str, resolve: Callable[[str], list[str]] | None = None, emit: Sink = log):
        self.allowlist = policy_data.hostnames(source)
        self.source = source
        self._resolve = resolve or self._resolve_upstream
        self._emit = emit

    def handle(self, sock: socket.socket, data: bytes, peer: tuple[str, int]) -> None:
        try:
            ident, qname, qtype, qclass, question = policy.parse_dns_question(data)
        except policy.PolicyError as exc:
            self._emit("drop", reason=str(exc), peer=peer[0], source=self.source)
            return
        if qclass != 1 or qtype not in SUPPORTED_TYPES:
            self._emit("refuse", source=self.source, qname=qname, qtype=qtype, reason="unsupported_type")
            sock.sendto(policy.build_dns_response(ident, question, qtype, [], rcode=RCODE_REFUSED), peer)
            return
        if qname not in self.allowlist:
            self._emit("refuse", source=self.source, qname=qname, qtype=qtype, reason="not_allowlisted")
            sock.sendto(policy.build_dns_response(ident, question, qtype, [], rcode=RCODE_REFUSED), peer)
            return
        addresses = self._public(qname, self._resolve(qname))
        self._emit("answer", source=self.source, qname=qname, qtype=qtype, addresses=len(addresses))
        sock.sendto(policy.build_dns_response(ident, question, qtype, addresses), peer)

    def _public(self, qname: str, addresses: list[str]) -> list[str]:
        """Drop answers that would point a collector at the LAN or the bridge.

        Applied here rather than inside the lookup so an injected or future
        resolver cannot route around it: a compromised allowlisted name must not be
        able to hand out a private address.
        """
        kept: list[str] = []
        for address in addresses:
            if address in kept:
                continue
            ip = ipaddress.ip_address(address)
            if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_reserved:
                self._emit("refuse", source=self.source, qname=qname, address=address, reason="non_public_answer")
                continue
            kept.append(address)
        return kept[:8]

    def _resolve_upstream(self, qname: str) -> list[str]:
        try:
            infos = socket.getaddrinfo(qname, None, type=socket.SOCK_STREAM)
        except OSError as exc:
            self._emit("resolve-failed", source=self.source, qname=qname, reason=str(exc))
            return []
        return [info[4][0] for info in infos]

    def listen(self, bind: tuple[str, int]) -> socket.socket:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind(bind)
        log("listen", source=self.source, address=f"{bind[0]}:{bind[1]}")
        return sock

    def serve(self, listener: socket.socket) -> None:
        while True:
            try:
                readable, _, _ = select.select([listener], [], [], 30)
            except OSError:
                return
            if not readable:
                continue
            try:
                data, peer = listener.recvfrom(4096)
            except OSError as exc:
                self._emit("drop", source=self.source, reason=str(exc))
                continue
            self.handle(listener, data, peer)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="agent-egress resolver")
    parser.add_argument("--policy", required=True, help="policy document (JSON)")
    parser.add_argument("--source", required=True, help="the label whose allowlist this listener answers from")
    parser.add_argument("--listen", required=True, metavar="HOST:PORT")
    args = parser.parse_args(argv)

    try:
        data = policy.Policy.load(args.policy)
        resolver = Resolver(data, args.source)
        listener = resolver.listen(policy.parse_bind(args.listen))
    except policy.PolicyError as exc:
        print(f"agent-egress resolver: {exc}", file=sys.stderr)
        return 1
    except OSError as exc:
        log("bind-failed", source=args.source, listen=args.listen, reason=str(exc))
        return 1
    try:
        resolver.serve(listener)
    except KeyboardInterrupt:
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
