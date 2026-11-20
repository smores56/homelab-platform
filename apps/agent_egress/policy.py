"""Pure policy for the collector egress proxy and its DNS responder.

Nothing here touches the network or the filesystem: the policy document, host
normalisation, the SNI parser and DNS framing are the whole contract, so both
services stay thin and the tests can exercise every rejection path.

The document is JSON, one entry per source label, and an allow entry carries its
port because a bridge network has no per-tap constant to derive it from:

    {
      "version": 1,
      "sources": {
        "brave": {"allow": ["sync-v2.brave.com:443"]}
      }
    }

Every refusal here is a startup refusal: a malformed document, an unknown key, a
version this build does not speak, a source with no grants, or a grant that is
not `host:port` with a real DNS name. A proxy that started on a document it only
half understood would be an open proxy with extra steps.

Ported from smores56/nix-config, `modules/lib/ingest/policy.py`, and adapted: the
tap index, guest CID, host address, batch framing, age recipients and heartbeat
envelope are the microVM plane's and are not part of this contract.
"""

from __future__ import annotations

import ipaddress
import json
import re
import struct
from collections.abc import Iterable, Mapping

POLICY_VERSION = 1

# Exact, lowercase DNS names only: no wildcard, no port, no scheme, no trailing dot.
HOST_RE = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$")
# A source label names a listener and appears in every log line, so it stays short
# and boring: no path separators, no whitespace, nothing that could pass for a host.
SOURCE_RE = re.compile(r"^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$")

POLICY_KEYS = {"version", "sources"}
SOURCE_KEYS = {"allow"}

Grant = tuple[str, int]


class PolicyError(ValueError):
    """A document, name or request that the plane refuses."""


class NeedMoreData(PolicyError):
    """A TLS ClientHello (or DNS message) that is not complete yet."""


def _is_ip_literal(name: str) -> bool:
    try:
        ipaddress.ip_address(name)
        return True
    except ValueError:
        return False


def normalize_host(host: object) -> str:
    if not isinstance(host, str):
        raise PolicyError("host is not a string")
    h = host.strip().rstrip(".").lower()
    if not h:
        raise PolicyError("empty host")
    if any(c in h for c in "/:@[] \\"):
        raise PolicyError(f"host contains a scheme, port, userinfo or brackets: {host!r}")
    if _is_ip_literal(h):
        raise PolicyError(f"IP literal refused: {host}")
    if not HOST_RE.match(h):
        raise PolicyError(f"not a DNS hostname: {host!r}")
    return h


def parse_authority(authority: str, default_port: int = 443) -> tuple[str, int]:
    """Parse an HTTP CONNECT authority (`host:port`) and refuse IP literals."""
    if not isinstance(authority, str) or not authority:
        raise PolicyError("empty authority")
    if "@" in authority:
        raise PolicyError("userinfo refused")
    host, _, port_text = authority.rpartition(":")
    if not host:
        host, port_text = authority, ""
    if port_text:
        if not port_text.isdigit():
            raise PolicyError(f"non-numeric port: {authority!r}")
        port = int(port_text)
        if not 1 <= port <= 65535:
            raise PolicyError(f"port out of range: {authority!r}")
    else:
        port = default_port
    return normalize_host(host), port


def parse_absolute_form(target: str) -> tuple[str, int, str]:
    """Parse `http://host[:port]/path` into (host, port, origin-form path).

    The port is not restricted here. The original plane accepted only 80 and 443
    because its document carried hostnames and nothing else; this one carries the
    port in each grant, and the proxy refuses any (host, port) the label does not
    hold. An `https://` target is refused because a client that already speaks TLS
    has CONNECT, and the forwarded request would be plaintext to that port.
    """
    if not isinstance(target, str) or "://" not in target:
        raise PolicyError("not an absolute-form request target")
    scheme, _, rest = target.partition("://")
    if scheme.lower() != "http":
        raise PolicyError(f"absolute-form scheme {scheme!r} refused")
    authority, slash, path = rest.partition("/")
    host, port = parse_authority(authority, default_port=80)
    return host, port, "/" + path if slash else "/"


def parse_host_header(value: str) -> tuple[str, int]:
    if not isinstance(value, str) or not value.strip():
        raise PolicyError("empty Host header")
    return parse_authority(value.strip(), default_port=80)


def parse_bind(text: object) -> tuple[str, int]:
    """Parse `HOST:PORT` for `--listen`; the port is never a default here."""
    if not isinstance(text, str):
        raise PolicyError("listen address is not a string")
    host, _, port_text = text.strip().rpartition(":")
    if not host or not port_text.isdigit():
        raise PolicyError(f"listen address is not HOST:PORT: {text!r}")
    port = int(port_text)
    if not 1 <= port <= 65535:
        raise PolicyError(f"listen port is out of range: {text!r}")
    return host, port


def parse_grant(text: object) -> Grant:
    """Parse one allow entry: `host:port`, with the port always written out."""
    if not isinstance(text, str):
        raise PolicyError("allow entry is not a string")
    entry = text.strip()
    host, _, port_text = entry.rpartition(":")
    if not host or not port_text:
        raise PolicyError(f"allow entry is not host:port: {text!r}")
    if not port_text.isdigit():
        raise PolicyError(f"allow entry has a non-numeric port: {text!r}")
    port = int(port_text)
    if not 1 <= port <= 65535:
        raise PolicyError(f"allow entry port is out of range: {text!r}")
    return normalize_host(host), port


def parse_client_hello_sni(data: bytes) -> str:
    """Return the SNI from a TLS ClientHello, raising NeedMoreData while truncated."""
    if len(data) < 5:
        raise NeedMoreData("tls record header")
    content_type, version, record_len = struct.unpack(">BHH", data[:5])
    if content_type != 22:
        raise PolicyError("not a TLS handshake record")
    if version >> 8 != 3:
        raise PolicyError("not a TLS record")
    end = 5 + record_len
    if len(data) < end:
        raise NeedMoreData("tls record body")
    body = data[5:end]
    if len(body) < 4:
        raise NeedMoreData("handshake header")
    handshake_type = body[0]
    if handshake_type != 1:
        raise PolicyError("not a ClientHello")
    hs_len = int.from_bytes(body[1:4], "big")
    if len(body) < 4 + hs_len:
        raise NeedMoreData("client hello body")
    hs = body[4 : 4 + hs_len]
    if len(hs) < 34:
        raise NeedMoreData("client hello prefix")
    off = 2 + 32  # legacy_version + random

    if len(hs) < off + 1:
        raise NeedMoreData("session id length")
    session_len = hs[off]
    off += 1 + session_len
    if len(hs) < off + 2:
        raise NeedMoreData("cipher suites length")
    cipher_len = int.from_bytes(hs[off : off + 2], "big")
    off += 2 + cipher_len
    if len(hs) < off + 1:
        raise NeedMoreData("compression length")
    comp_len = hs[off]
    off += 1 + comp_len
    if len(hs) < off + 2:
        raise NeedMoreData("extensions length")
    ext_len = int.from_bytes(hs[off : off + 2], "big")
    off += 2
    ext_end = off + ext_len
    if len(hs) < ext_end:
        raise NeedMoreData("extensions body")
    while off + 4 <= ext_end:
        ext_type = int.from_bytes(hs[off : off + 2], "big")
        length = int.from_bytes(hs[off + 2 : off + 4], "big")
        off += 4
        if off + length > ext_end:
            raise NeedMoreData("extension body")
        if ext_type == 0:  # server_name
            ext = hs[off : off + length]
            if len(ext) < 2:
                raise PolicyError("malformed server_name extension")
            list_len = int.from_bytes(ext[:2], "big")
            if len(ext) < 2 + list_len:
                raise PolicyError("malformed server_name list")
            pos = 2
            list_end = 2 + list_len
            while pos + 3 <= list_end:
                name_type = ext[pos]
                name_len = int.from_bytes(ext[pos + 1 : pos + 3], "big")
                pos += 3
                if pos + name_len > list_end:
                    raise PolicyError("malformed server_name entry")
                if name_type == 0:
                    try:
                        name = ext[pos : pos + name_len].decode("ascii")
                    except UnicodeDecodeError as exc:
                        raise PolicyError("non-ASCII SNI") from exc
                    return normalize_host(name)
                pos += name_len
            raise PolicyError("no host_name entry")
        off += length
    raise PolicyError("ClientHello has no SNI")


def parse_dns_question(data: bytes) -> tuple[int, str, int, int, bytes]:
    """Parse one standard query; returns (id, qname, qtype, qclass, question_bytes)."""
    if len(data) < 12:
        raise PolicyError("short DNS message")
    ident, flags, qdcount, _an, _ns, _ar = struct.unpack(">HHHHHH", data[:12])
    if flags & 0x8000:
        raise PolicyError("DNS response, not a query")
    if qdcount != 1:
        raise PolicyError("exactly one question is supported")
    off = 12
    labels: list[str] = []
    while True:
        if off >= len(data):
            raise PolicyError("truncated qname")
        length = data[off]
        off += 1
        if length == 0:
            break
        if length & 0xC0:
            raise PolicyError("compression in the question is refused")
        if length > 63 or off + length > len(data):
            raise PolicyError("bad label")
        try:
            labels.append(data[off : off + length].decode("ascii").lower())
        except UnicodeDecodeError as exc:
            raise PolicyError("non-ASCII qname") from exc
        off += length
        if len(labels) > 127:
            raise PolicyError("qname too long")
    if off + 4 > len(data):
        raise PolicyError("truncated question")
    qtype, qclass = struct.unpack(">HH", data[off : off + 4])
    off += 4
    qname = ".".join(labels)
    if not qname:
        raise PolicyError("empty qname")
    normalize_host(qname)
    return ident, qname, qtype, qclass, data[12:off]


def build_dns_response(ident: int, question: bytes, qtype: int, addresses: list[str], rcode: int = 0) -> bytes:
    flags = 0x8180 | (rcode & 0xF)  # QR, RD, RA
    answers: list[bytes] = []
    if rcode == 0 and addresses:
        for address in addresses:
            ip = ipaddress.ip_address(address)
            if qtype == 1 and ip.version == 4:
                rdata = ip.packed
                rtype = 1
            elif qtype == 28 and ip.version == 6:
                rdata = ip.packed
                rtype = 28
            else:
                continue
            answers.append(
                b"\xc0\x0c"  # pointer to the question name
                + struct.pack(">HHIH", rtype, 1, 60, len(rdata))
                + rdata
            )
    header = struct.pack(">HHHHHH", ident, flags, 1, len(answers), 0, 0)
    return header + question + b"".join(answers)


class Policy:
    """An immutable map from source label to the `host:port` grants it holds."""

    def __init__(self, sources: Mapping[str, Iterable[Grant]]):
        self._grants = {name: frozenset(grants) for name, grants in sources.items()}
        self._hosts = {name: frozenset(host for host, _port in grants) for name, grants in self._grants.items()}

    @classmethod
    def from_document(cls, document: object) -> Policy:
        if not isinstance(document, dict):
            raise PolicyError("policy document is not a JSON object")
        unknown = set(document) - POLICY_KEYS
        if unknown:
            raise PolicyError(f"policy document has unknown keys: {sorted(unknown)}")
        if document.get("version") != POLICY_VERSION:
            raise PolicyError(f"unsupported policy version {document.get('version')!r}")
        entries = document.get("sources")
        if not isinstance(entries, dict) or not entries:
            raise PolicyError("policy document has no sources")
        sources: dict[str, frozenset[Grant]] = {}
        for name, entry in entries.items():
            if not isinstance(name, str) or not SOURCE_RE.match(name):
                raise PolicyError(f"not a source label: {name!r}")
            if not isinstance(entry, dict):
                raise PolicyError(f"source {name} is not an object")
            unknown = set(entry) - SOURCE_KEYS
            if unknown:
                raise PolicyError(f"source {name} has unknown keys: {sorted(unknown)}")
            allow = entry.get("allow")
            if not isinstance(allow, list) or not allow:
                raise PolicyError(f"source {name} has an empty allowlist")
            grants = [parse_grant(item) for item in allow]
            if len(set(grants)) != len(grants):
                raise PolicyError(f"source {name} repeats a grant")
            sources[name] = frozenset(grants)
        return cls(sources)

    @classmethod
    def load(cls, path: str) -> Policy:
        try:
            with open(path, encoding="utf-8") as handle:
                document = json.load(handle)
        except json.JSONDecodeError as exc:
            raise PolicyError(f"policy document is not JSON: {exc}") from exc
        except OSError as exc:
            raise PolicyError(f"policy document {path} is unreadable: {exc}") from exc
        return cls.from_document(document)

    @property
    def source_names(self) -> tuple[str, ...]:
        return tuple(sorted(self._grants))

    def allowlist(self, source: str) -> frozenset[Grant]:
        try:
            return self._grants[source]
        except KeyError as exc:
            raise PolicyError(f"unknown source: {source!r}") from exc

    def hostnames(self, source: str) -> frozenset[str]:
        self.allowlist(source)
        return self._hosts[source]

    def permits(self, source: str, host: str, port: int) -> bool:
        return (host, port) in self.allowlist(source)
