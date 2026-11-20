"""Fixtures for the agent-egress suite: policy documents, wire bytes, harnesses.

Nothing here talks to a network. The proxy is driven over a loopback listener the
test creates and its upstream dialer is injected, so "no dial happened" is a fact
the test can assert; the resolver is driven by calling `handle` with a socket
stand-in, so no packet leaves the process.
"""

from __future__ import annotations

import json
import socket
import struct
import threading
from pathlib import Path

from apps.agent_egress.policy import Policy
from apps.agent_egress.proxy import Proxy
from apps.agent_egress.resolver import Resolver

#: The worked example, and only an example: the document is not keyed to it.
BRAVE = {"version": 1, "sources": {"brave": {"allow": ["sync-v2.brave.com:443"]}}}


def policy_of(document: object) -> Policy:
    return Policy.from_document(document)


def brave_policy() -> Policy:
    return policy_of(BRAVE)


def plain_http_policy() -> Policy:
    """The same label with a plain-HTTP grant, which absolute-form needs (port 80)."""
    return policy_of({"version": 1, "sources": {"brave": {"allow": ["sync-v2.brave.com:80", "sync-v2.brave.com:443"]}}})


def write_policy(directory: str | Path, document: object) -> str:
    path = Path(directory) / "policy.json"
    path.write_text(json.dumps(document), encoding="utf-8")
    return str(path)


def client_hello(sni: str | None, *, host_name_entries: bool = True) -> bytes:
    """A minimal TLS ClientHello carrying exactly one server_name entry."""
    extensions = b""
    if sni is not None and host_name_entries:
        name = sni.encode("ascii")
        entry = b"\x00" + len(name).to_bytes(2, "big") + name
        server_names = len(entry).to_bytes(2, "big") + entry
        extensions = b"\x00\x00" + len(server_names).to_bytes(2, "big") + server_names
    body = b"\x03\x03" + bytes(range(32))  # legacy_version + random
    body += b"\x00"  # empty session id
    body += b"\x00\x02\x13\x01"  # one cipher suite
    body += b"\x01\x00"  # one compression method
    body += len(extensions).to_bytes(2, "big") + extensions
    handshake = b"\x01" + len(body).to_bytes(3, "big") + body
    return b"\x16\x03\x01" + len(handshake).to_bytes(2, "big") + handshake


def dns_query(qname: str, qtype: int = 1, ident: int = 0x1234) -> bytes:
    header = struct.pack(">HHHHHH", ident, 0x0100, 1, 0, 0, 0)
    question = b"".join(bytes([len(label)]) + label.encode("ascii") for label in qname.split(".")) + b"\x00"
    return header + question + struct.pack(">HH", qtype, 1)


def dns_rcode(response: bytes) -> int:
    _ident, flags, _qd, _an, _ns, _ar = struct.unpack(">HHHHHH", response[:12])
    return flags & 0xF


def dns_answer_count(response: bytes) -> int:
    _ident, _flags, _qd, ancount, _ns, _ar = struct.unpack(">HHHHHH", response[:12])
    return ancount


class Recorder:
    """A log sink that keeps the fields instead of printing them."""

    def __init__(self) -> None:
        self.records: list[dict[str, object]] = []
        self._lock = threading.Lock()

    def __call__(self, event: str, **fields: object) -> None:
        with self._lock:
            self.records.append({"event": event, **fields})

    def events(self) -> list[str]:
        return [str(record["event"]) for record in self.records]

    def text(self) -> str:
        return json.dumps(self.records)


class Harness:
    """A proxy on a loopback port, with its upstream dialer under the test's control."""

    def __init__(self, policy_data: Policy, source: str, dial=None, emit=None) -> None:
        self.log = Recorder()
        self.dials: list[tuple[str, int]] = []
        self.proxy = Proxy(policy_data, source, dial=dial or self._dial, emit=emit or self.log)
        self.listener = self.proxy.listen(("127.0.0.1", 0))
        self.port = self.listener.getsockname()[1]
        self._thread = threading.Thread(target=self.proxy.serve, args=(self.listener,), daemon=True)
        self._thread.start()

    def _dial(self, host: str, port: int) -> socket.socket:
        self.dials.append((host, port))
        # An OSError, not an assertion: the proxy handles it as a failed dial
        # and the test asserts on `dials` instead of on a thread traceback.
        raise ConnectionError(f"unexpected upstream dial to {host}:{port}")

    def client(self) -> socket.socket:
        sock = socket.create_connection(("127.0.0.1", self.port), timeout=5)
        sock.settimeout(5)
        return sock

    def close(self) -> None:
        self.listener.close()


class Upstream:
    """The far side of an injected dial: the test speaks for the real origin."""

    def __init__(self) -> None:
        self.local, self.peer = socket.socketpair()
        self.local.settimeout(5)
        self.peer.settimeout(5)
        self.dials: list[tuple[str, int]] = []

    def dial(self, host: str, port: int) -> socket.socket:
        self.dials.append((host, port))
        return self.peer

    def read_at_least(self, size: int) -> bytes:
        buf = b""
        while len(buf) < size:
            chunk = self.local.recv(4096)
            if not chunk:
                break
            buf += chunk
        return buf

    def close(self) -> None:
        for sock in (self.local, self.peer):
            try:
                sock.close()
            except OSError:
                pass


def recv_exact(sock: socket.socket, size: int) -> bytes:
    buf = b""
    while len(buf) < size:
        chunk = sock.recv(size - len(buf))
        if not chunk:
            break
        buf += chunk
    return buf


def read_headers(sock: socket.socket) -> bytes:
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(4096)
        if not chunk:
            break
        buf += chunk
    return buf


def resolver_of(policy_data: Policy, source: str, addresses: list[str]) -> tuple[Resolver, Recorder, list[str], FakeSock]:
    log = Recorder()
    asked: list[str] = []

    def resolve(qname: str) -> list[str]:
        asked.append(qname)
        return list(addresses)

    return Resolver(policy_data, source, resolve=resolve, emit=log), log, asked, FakeSock()


class FakeSock:
    """A socket stand-in that records what the resolver would have sent."""

    def __init__(self) -> None:
        self.sent: list[bytes] = []

    def sendto(self, data: bytes, _peer: tuple[str, int]) -> None:
        self.sent.append(data)
