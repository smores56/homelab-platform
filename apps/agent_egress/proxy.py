"""Allowlist HTTP/HTTPS forward proxy, one listener per source label.

A listener is started with `--source <label>` and enforces that label's grants
only. There is no per-client address to check here, so identity is the network's
job and the allowlist is the second gate: nftables decides which container may
reach the listener's port at all (`docs/core/applications.md`, "Collector
egress"), and this process decides which hostnames and ports that container may
reach once it is there.

The rules are the microVM plane's, unchanged:

* CONNECT is accepted only for a `(host, port)` the label holds, and is
  additionally gated on the TLS SNI inside the first ClientHello, so a client
  cannot tunnel to a different name through a permitted CONNECT. The mismatch is
  refused before any upstream connection exists.
* Absolute-form HTTP is checked on the request target and on the Host header, and
  refused when they disagree.
* Unknown host, wrong port, missing SNI, SNI/host mismatch and a malformed
  request are all refusals, never a pass-through.

Logs are metadata only: time, source, target host/port, decision, byte counts.
Paths, queries and payload bytes never reach a log line.

Ported from smores56/nix-config, `modules/lib/ingest/proxy.py`, and adapted: the
per-tap gateway/client address maps and the bind-retry loop belong to the microVM
plane, where a tap appears after its guest boots.
"""

from __future__ import annotations

import argparse
import json
import select
import socket
import sys
import threading
import time
from collections.abc import Callable
from datetime import datetime, timezone

from . import policy

MAX_HEADER_BYTES = 16384
MAX_HELLO_BYTES = 16384
MAX_PENDING_BYTES = 8 << 20

Sink = Callable[..., None]


def log(event: str, **fields: object) -> None:
    record = {"ts": datetime.now(timezone.utc).isoformat(timespec="seconds"), "unit": "agent-egress-proxy", "event": event}
    record.update(fields)
    print(json.dumps(record, sort_keys=True), flush=True)


def response(code: int, reason: str) -> bytes:
    return f"HTTP/1.1 {code} {reason}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".encode()


class Proxy:
    """One listener, one source label, one allowlist."""

    def __init__(self, policy_data: policy.Policy, source: str, dial: Callable[[str, int], socket.socket] | None = None, emit: Sink = log):
        # Resolved once, at startup: a label the document does not name is a
        # deployment mistake, and refusing here is what keeps it out of service.
        self.allowlist = policy_data.allowlist(source)
        self.source = source
        self._dial_upstream = dial or self._dial
        self._emit = emit

    def handle(self, conn: socket.socket, peer: tuple[str, int]) -> None:
        started = time.monotonic()
        try:
            header, rest = self._read_header(conn)
            request_line, headers = self._parse(header)
            method, target, version = request_line
            if method.upper() == "CONNECT":
                self._connect(conn, target, rest, started)
            else:
                self._absolute(conn, method, target, version, headers, rest, started)
        except (policy.PolicyError, socket.timeout, OSError) as exc:
            self._emit("deny", source=self.source, reason=str(exc), peer=peer[0])
            try:
                conn.sendall(response(403, "Forbidden"))
            except OSError:
                pass
            conn.close()

    @staticmethod
    def _read_header(conn: socket.socket) -> tuple[bytes, bytes]:
        conn.settimeout(15)
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = conn.recv(4096)
            if not chunk:
                raise policy.PolicyError("client closed before headers")
            buf += chunk
            if len(buf) > MAX_HEADER_BYTES:
                raise policy.PolicyError("header too large")
        head, _, rest = buf.partition(b"\r\n\r\n")
        return head, rest

    @staticmethod
    def _parse(header: bytes) -> tuple[tuple[str, str, str], dict[str, str]]:
        lines = header.decode("iso-8859-1").split("\r\n")
        parts = lines[0].split(" ")
        if len(parts) != 3 or not parts[2].startswith("HTTP/"):
            raise policy.PolicyError("malformed request line")
        headers: dict[str, str] = {}
        for line in lines[1:]:
            name, sep, value = line.partition(":")
            if not sep:
                raise policy.PolicyError("malformed header")
            headers[name.strip().lower()] = value.strip()
        return (parts[0], parts[1], parts[2]), headers

    def _connect(self, conn: socket.socket, target: str, rest: bytes, started: float) -> None:
        host, port = policy.parse_authority(target, default_port=443)
        if (host, port) not in self.allowlist:
            self._emit("deny", source=self.source, action="connect", host=host, port=port, reason="not_allowlisted")
            raise policy.PolicyError(f"{host}:{port} is not allowlisted for {self.source}")
        # A client starts TLS only after this reply, so it must come before the
        # ClientHello is read. Waiting for the hello first deadlocks until the read
        # times out, and the client then reports the 403 as a failed tunnel.
        conn.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
        try:
            hello = self._read_client_hello(conn, rest)
            sni = policy.parse_client_hello_sni(hello)
            if sni != host:
                self._emit("deny", source=self.source, action="connect", host=host, sni=sni, reason="sni_mismatch")
                conn.close()
                return
            # Still before any upstream connection exists, so a mismatched hello never
            # reaches the internet.
            upstream = self._dial_upstream(host, port)
        except (policy.PolicyError, socket.timeout, OSError) as exc:
            # The 200 is already on the wire, so close rather than send a second response.
            self._emit("deny", source=self.source, action="connect", host=host, port=port, reason=str(exc))
            conn.close()
            return
        self._emit("allow", source=self.source, action="connect", host=host, port=port, sni=sni)
        upstream.sendall(hello)
        self._splice(conn, upstream, host, port, started)

    def _absolute(
        self,
        conn: socket.socket,
        method: str,
        target: str,
        version: str,
        headers: dict[str, str],
        rest: bytes,
        started: float,
    ) -> None:
        host, port, path = policy.parse_absolute_form(target)
        if (host, port) not in self.allowlist:
            self._emit("deny", source=self.source, action="http", host=host, port=port, reason="not_allowlisted")
            raise policy.PolicyError(f"{host}:{port} is not allowlisted for {self.source}")
        header_host = headers.get("host")
        if header_host is not None:
            header_hostname, _ = policy.parse_host_header(header_host)
            if header_hostname != host:
                self._emit("deny", source=self.source, action="http", host=host, header_host=header_hostname, reason="host_mismatch")
                raise policy.PolicyError("Host header does not match the absolute-form target")
        upstream = self._dial_upstream(host, port)
        forwarded = [
            f"{method} {path} {version}",
            f"Host: {host}",
        ]
        for name, value in headers.items():
            if name in {"host", "proxy-connection", "proxy-authorization"}:
                continue
            forwarded.append(f"{name}: {value}")
        upstream.sendall(("\r\n".join(forwarded) + "\r\n\r\n").encode("iso-8859-1") + rest)
        self._emit("allow", source=self.source, action="http", host=host, port=port)
        self._splice(conn, upstream, host, port, started)

    @staticmethod
    def _dial(host: str, port: int) -> socket.socket:
        infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
        last: OSError | None = None
        for family, socktype, proto, _canon, addr in infos:
            sock = socket.socket(family, socktype, proto)
            sock.settimeout(15)
            try:
                sock.connect(addr)
                return sock
            except OSError as exc:
                last = exc
                sock.close()
        raise policy.PolicyError(f"upstream {host}:{port} unreachable: {last}")

    @staticmethod
    def _read_client_hello(conn: socket.socket, first: bytes) -> bytes:
        buf = first
        conn.settimeout(10)
        while True:
            try:
                policy.parse_client_hello_sni(buf)
                return buf
            except policy.NeedMoreData:
                pass
            chunk = conn.recv(4096)
            if not chunk:
                raise policy.PolicyError("client closed before ClientHello")
            buf += chunk
            if len(buf) > MAX_HELLO_BYTES:
                raise policy.PolicyError("ClientHello too large")

    def _splice(self, client: socket.socket, upstream: socket.socket, host: str, port: int, started: float) -> None:
        client.setblocking(False)
        upstream.setblocking(False)
        sent = received = 0
        # Bytes read from a side but not yet accepted by the other side. A single
        # sendall on a non-blocking socket raises BlockingIOError as soon as the
        # peer's receive window fills — treating that as a dead peer truncated every
        # response bigger than one socket buffer (a 1 MiB album page arrived as
        # 64 KiB and `IncompleteRead`).
        pending: dict[socket.socket, bytearray] = {client: bytearray(), upstream: bytearray()}
        peer = {client: upstream, upstream: client}
        reading = [client, upstream]
        reason = "eof"
        while reading or any(pending.values()):
            # Watch the destinations, not the sources: buffered bytes wait on the
            # peer's window, and a source that already hit EOF is gone from `reading`
            # while its tail is still owed to the other side.
            writing = [peer[sock] for sock, buffer in pending.items() if buffer]
            try:
                ready, can_write, errored = select.select(reading, writing, reading, 30)
            except OSError:
                reason = "select"
                break
            if errored:
                reason = "error"
                break
            if not ready and not can_write:
                reason = "idle"
                break
            for sock in ready:
                try:
                    data = sock.recv(65536)
                except BlockingIOError:
                    continue
                except OSError:
                    reason = "reset"
                    data = b""
                if not data:
                    reading.remove(sock)
                    continue
                if sock is client:
                    sent += len(data)
                else:
                    received += len(data)
                pending[sock] += data
            for sock, buffer in pending.items():
                if not buffer:
                    continue
                try:
                    written = peer[sock].send(buffer)
                except BlockingIOError:
                    continue
                except OSError:
                    reason = "reset"
                    reading = []
                    pending[sock].clear()
                    continue
                del buffer[:written]
                # Unbounded buffering would let a peer that never reads grow the
                # proxy without limit; every response is size-capped upstream.
                if len(buffer) > MAX_PENDING_BYTES:
                    reason = "backlog"
                    reading = []
                    pending[sock].clear()
        for sock in (client, upstream):
            try:
                sock.close()
            except OSError:
                pass
        self._emit(
            "close",
            source=self.source,
            host=host,
            port=port,
            bytes_in=sent,
            bytes_out=received,
            ms=int((time.monotonic() - started) * 1000),
            reason=reason,
        )

    def listen(self, bind: tuple[str, int]) -> socket.socket:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind(bind)
        sock.listen(16)
        self._emit("listen", source=self.source, address=f"{bind[0]}:{bind[1]}")
        return sock

    def serve(self, listener: socket.socket) -> None:
        while True:
            try:
                conn, peer = listener.accept()
            except OSError:
                # The listener was closed, which is how a test stops the loop; a
                # live deployment has no reason to leave this call.
                return
            threading.Thread(target=self.handle, args=(conn, peer), daemon=True).start()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="agent-egress proxy")
    parser.add_argument("--policy", required=True, help="policy document (JSON)")
    parser.add_argument("--source", required=True, help="the label whose allowlist this listener enforces")
    parser.add_argument("--listen", required=True, metavar="HOST:PORT")
    args = parser.parse_args(argv)

    try:
        data = policy.Policy.load(args.policy)
        proxy = Proxy(data, args.source)
        listener = proxy.listen(policy.parse_bind(args.listen))
    except policy.PolicyError as exc:
        print(f"agent-egress proxy: {exc}", file=sys.stderr)
        return 1
    except OSError as exc:
        log("bind-failed", source=args.source, listen=args.listen, reason=str(exc))
        return 1
    try:
        proxy.serve(listener)
    except KeyboardInterrupt:
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
