#!/usr/bin/env python3
"""Read-only guard in front of Backrest (design #725, T2).

Backrest has no read-only role: its admin API can reconfigure the repository,
run arbitrary restic, and it returns the repository password and the R2 key
pair in GetConfig. The Cloudflare Worker refuses those calls; this is the same
guard for a host that has no Worker in front of it.

The guard owns the public port and starts Backrest itself on loopback, so no
configuration can expose an unguarded Backrest.

    BACKREST_GUARD_ADDR    what to bind (default 127.0.0.1:9898)
    BACKREST_UPSTREAM_ADDR what Backrest listens on (default 127.0.0.1:9899)
    BACKREST_BIN           the Backrest binary (default /backrest; empty starts
                           nothing, which is how the tests drive a stub)
"""

import http.client
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

GUARD_ADDR = os.environ.get("BACKREST_GUARD_ADDR", "127.0.0.1:9898")
UPSTREAM_ADDR = os.environ.get("BACKREST_UPSTREAM_ADDR", "127.0.0.1:9899")
BACKREST_BIN = os.environ.get("BACKREST_BIN", "/backrest")
REPO_ID = os.environ.get("BACKREST_REPO_ID", "")

UPSTREAM_HOST, UPSTREAM_PORT = UPSTREAM_ADDR.rsplit(":", 1)
UPSTREAM_PORT = int(UPSTREAM_PORT)
BIND_HOST, BIND_PORT = GUARD_ADDR.rsplit(":", 1)
BIND_PORT = int(BIND_PORT)

# Everything else — SetConfig, AddRepo, RemoveRepo, Backup, Forget, DoRepoTask,
# Restore, RunCommand, Cancel, ClearHistory, PathAutocomplete, SetupSftp,
# GeneratePairingToken, HashPassword — is refused here.
ALLOWED_RPCS = {
    "GetConfig",
    "GetOperations",
    "GetOperationEvents",
    "GetLogs",
    "GetSummaryDashboard",
    "GetDownloadURL",
    "ListSnapshots",
    "ListSnapshotFiles",
}

RPC_PATH = re.compile(r"^/v1\.([A-Za-z]+)/([A-Za-z]+)$")
HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
    "host",
    "content-length",
    # Responses are parsed here, so an encoded body would defeat redaction.
    "accept-encoding",
}


def error_body(code, message):
    return json.dumps({"code": code, "message": message}).encode()


# --- protobuf wire handling -------------------------------------------------
# Config.repos = 3, Repo.password = 3, Repo.env = 4. Backrest's Web UI asks in
# protobuf, so a JSON-only redaction would leave the credentials readable.


def read_varint(buf, at):
    shift = 0
    value = 0
    while True:
        if at >= len(buf):
            raise ValueError("truncated varint")
        byte = buf[at]
        at += 1
        value |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return value, at
        shift += 7
        if shift > 63:
            raise ValueError("varint is too long")


def read_fields(buf):
    fields = []
    at = 0
    while at < len(buf):
        start = at
        tag, at = read_varint(buf, at)
        number, wire = tag >> 3, tag & 7
        payload = None
        if wire == 0:
            _, at = read_varint(buf, at)
        elif wire == 1:
            at += 8
        elif wire == 2:
            length, at = read_varint(buf, at)
            payload = buf[at : at + length]
            at += length
        elif wire == 5:
            at += 4
        else:
            raise ValueError("unsupported wire type %d" % wire)
        if at > len(buf):
            raise ValueError("truncated field")
        fields.append((number, wire, buf[start:at], payload))
    return fields


def varint_bytes(value):
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def length_delimited(field, payload):
    return varint_bytes((field << 3) | 2) + varint_bytes(len(payload)) + payload


def redact_config_proto(body):
    parts = []
    for number, wire, raw, payload in read_fields(body):
        if number != 3 or wire != 2 or payload is None:
            parts.append(raw)
            continue
        kept = [inner for inner in read_fields(payload) if inner[0] not in (3, 4)]
        parts.append(length_delimited(3, b"".join(inner[2] for inner in kept)))
    return b"".join(parts)


def read_uint64_field(body, wanted):
    try:
        for number, wire, _, _ in read_fields(body):
            if number == wanted and wire == 0:
                at = 0
                _, at = read_varint(body, at)
                value, _ = read_varint(body, at)
                return str(value & ((1 << 64) - 1))
    except ValueError:
        return None
    return None


# --- response transforms ----------------------------------------------------


def redact_config_json(body):
    try:
        parsed = json.loads(body)
    except ValueError:
        return body
    if not isinstance(parsed, dict):
        return body
    repos = parsed.get("repos")
    if isinstance(repos, list):
        for repo in repos:
            if isinstance(repo, dict):
                repo.pop("password", None)
                repo.pop("env", None)
    auth = parsed.get("auth")
    if isinstance(auth, dict) and isinstance(auth.get("users"), list):
        for user in auth["users"]:
            if isinstance(user, dict) and "passwordBcrypt" in user:
                user["passwordBcrypt"] = "********"
    return json.dumps(parsed).encode()


def only_verified_json(body):
    try:
        parsed = json.loads(body)
    except ValueError:
        return body
    if not isinstance(parsed, dict) or not isinstance(parsed.get("snapshots"), list):
        return body
    parsed["snapshots"] = [
        snapshot
        for snapshot in parsed["snapshots"]
        if isinstance(snapshot, dict) and "verified" in (snapshot.get("tags") or [])
    ]
    return json.dumps(parsed).encode()


def api_call(method, payload, headers):
    """One internal RPC, with the caller's own session."""
    body = json.dumps(payload).encode()
    request = {"Content-Type": "application/json", "Content-Length": str(len(body))}
    request.update(headers)
    conn = http.client.HTTPConnection(UPSTREAM_HOST, UPSTREAM_PORT, timeout=120)
    try:
        conn.request("POST", "/v1.Backrest/" + method, body=body, headers=request)
        return as_json(conn.getresponse().read())
    finally:
        conn.close()


def indexed_ids(headers):
    operations = api_call("GetOperations", {"lastN": 1000}, headers).get("operations") or []
    return {
        operation.get("snapshotId")
        for operation in operations
        if operation.get("operationIndexSnapshot") is not None and operation.get("snapshotId")
    }


# Every restart starts from an empty index, and GetDownloadURL cannot mint a URL
# without an index operation for the snapshot. Backrest schedules none on its
# own with no plans configured, so listing snapshots has to ask for one, exactly
# as the Worker does.
def reindex(headers):
    live = [
        snapshot.get("id")
        for snapshot in (api_call("ListSnapshots", {"repoId": REPO_ID}, headers).get("snapshots") or [])
        if snapshot.get("id")
    ]
    if not live:
        return
    if all(snapshot in indexed_ids(headers) for snapshot in live):
        return
    api_call("DoRepoTask", {"repoId": REPO_ID, "task": "TASK_INDEX_SNAPSHOTS"}, headers)
    deadline = time.monotonic() + 600
    while time.monotonic() < deadline:
        if all(snapshot in indexed_ids(headers) for snapshot in live):
            return
        time.sleep(1)


_reindex_lock = threading.Lock()
_reindex_running = False


def schedule_reindex(headers):
    global _reindex_running
    with _reindex_lock:
        if _reindex_running:
            return
        _reindex_running = True

    def run():
        global _reindex_running
        try:
            reindex(headers)
        except Exception as error:  # noqa: BLE001 - a refresh must never kill a request
            sys.stderr.write("backrest-guard: reindex failed: %s\n" % error)
        finally:
            with _reindex_lock:
                _reindex_running = False

    threading.Thread(target=run, daemon=True).start()


def as_json(body):
    try:
        return json.loads(body)
    except ValueError:
        return {}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "backrest-guard"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    def do_GET(self):
        self.dispatch("GET")

    def do_HEAD(self):
        self.dispatch("HEAD")

    def do_POST(self):
        self.dispatch("POST")

    def do_PUT(self):
        self.dispatch("PUT")

    def do_DELETE(self):
        self.dispatch("DELETE")

    def do_PATCH(self):
        self.dispatch("PATCH")

    def refuse(self, status, code, message):
        body = error_body(code, message)
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)
        self.close_connection = True

    def read_body(self):
        if self.headers.get("Transfer-Encoding"):
            return None
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def guard(self, path, method):
        """Return None to proxy, or (status, code, message) to refuse."""
        match = RPC_PATH.match(path)
        if not match:
            if path == "/metrics":
                return 403, "permission_denied", "read-only reader"
            if method not in ("GET", "HEAD"):
                return 405, "permission_denied", "read-only reader"
            return None
        service, name = match.group(1), match.group(2)
        if service == "Authentication":
            if name == "Login":
                return None
            return 403, "permission_denied", "read-only reader"
        if service != "Backrest":
            return 404, "unimplemented", "not found"
        if name not in ALLOWED_RPCS:
            return 403, "permission_denied", "read-only reader"
        if method != "POST":
            return 405, "permission_denied", "read-only reader"
        return None

    def upstream(self, method, path, body=b"", auth_headers=None):
        conn = http.client.HTTPConnection(UPSTREAM_HOST, UPSTREAM_PORT, timeout=None)
        conn.putrequest(method, path, skip_host=True, skip_accept_encoding=True)
        conn.putheader("Host", UPSTREAM_HOST)
        for name, value in (auth_headers or {}).items():
            conn.putheader(name, value)
        if body:
            conn.putheader("Content-Length", str(len(body)))
        conn.endheaders(body or None)
        response = conn.getresponse()
        return conn, response

    def rpc(self, method, payload, auth_headers):
        conn, response = self.upstream(
            "POST", "/v1.Backrest/%s" % method, json.dumps(payload).encode(), auth_headers
        )
        try:
            return as_json(response.read())
        finally:
            conn.close()

    def auth_headers(self):
        headers = {}
        for name in ("Authorization", "Cookie"):
            if self.headers.get(name):
                headers[name] = self.headers[name]
        return headers

    def download_is_verified(self, body, content_type):
        if "json" in content_type:
            op_id = str(as_json(body).get("opId") or "")
        elif "proto" in content_type:
            op_id = read_uint64_field(body, 1) or ""
        else:
            op_id = ""
        if not op_id:
            return False
        headers = self.auth_headers()
        ops = self.rpc("GetOperations", {"selector": {"ids": [op_id]}, "lastN": 1}, headers)
        operations = ops.get("operations") or []
        if not operations:
            return False
        snapshot_id = operations[0].get("snapshotId")
        if not snapshot_id:
            return False
        listing = self.rpc("ListSnapshots", {"repoId": REPO_ID}, headers)
        return any(
            snapshot.get("id") == snapshot_id and "verified" in (snapshot.get("tags") or [])
            for snapshot in (listing.get("snapshots") or [])
        )

    def dispatch(self, method):
        body = self.read_body()
        if body is None:
            self.refuse(411, "invalid_argument", "chunked request bodies are not supported")
            return
        path = self.path.split("?", 1)[0]
        refused = self.guard(path, method)
        if refused:
            self.refuse(*refused)
            return
        if path == "/v1.Backrest/GetDownloadURL" and not self.download_is_verified(
            body, self.headers.get("Content-Type") or ""
        ):
            self.refuse(409, "failed_precondition", "snapshot is not verified")
            return

        transform = None
        if path == "/v1.Backrest/ListSnapshots":
            transform = ("json", only_verified_json)
        elif path == "/v1.Backrest/GetConfig":
            transform = ("json", redact_config_json)

        forward = {}
        for name, value in self.headers.items():
            if name.lower() not in HOP_BY_HOP:
                forward[name] = value
        try:
            conn, response = self.upstream(method, self.path, body, forward)
        except OSError:
            self.refuse(502, "unavailable", "backrest is not reachable")
            return
        if path == "/v1.Backrest/ListSnapshots" and response.status == 200:
            schedule_reindex(self.auth_headers())
        try:
            content_type = response.getheader("Content-Type") or ""
            rewritten = None
            if transform is not None and response.status == 200:
                payload = response.read()
                if "json" in content_type:
                    rewritten = transform[1](payload)
                elif path == "/v1.Backrest/GetConfig" and "proto" in content_type:
                    try:
                        rewritten = redact_config_proto(payload)
                    except ValueError:
                        self.refuse(500, "internal", "could not redact the configuration")
                        return
                else:
                    rewritten = payload
            if rewritten is not None:
                self.send_response(response.status)
                for name, value in response.getheaders():
                    if name.lower() in HOP_BY_HOP:
                        continue
                    self.send_header(name, value)
                self.send_header("Content-Length", str(len(rewritten)))
                self.send_header("Connection", "close")
                self.end_headers()
                if self.command != "HEAD":
                    self.wfile.write(rewritten)
                self.close_connection = True
                return

            self.send_response(response.status)
            length = response.getheader("Content-Length")
            for name, value in response.getheaders():
                if name.lower() in HOP_BY_HOP:
                    continue
                self.send_header(name, value)
            if length is None:
                self.send_header("Transfer-Encoding", "chunked")
            self.send_header("Connection", "close")
            self.end_headers()
            if self.command != "HEAD":
                while True:
                    chunk = response.read(65536)
                    if not chunk:
                        break
                    if length is None:
                        self.wfile.write(b"%x\r\n" % len(chunk) + chunk + b"\r\n")
                    else:
                        self.wfile.write(chunk)
                if length is None:
                    self.wfile.write(b"0\r\n\r\n")
            self.close_connection = True
        finally:
            conn.close()


def start_backrest():
    if not BACKREST_BIN:
        return None
    return subprocess.Popen(
        [BACKREST_BIN, "-bind-address", UPSTREAM_ADDR],
        stdin=subprocess.DEVNULL,
    )


def main():
    child = start_backrest()
    deadline = time.monotonic() + 180
    while child is not None and time.monotonic() < deadline:
        if child.poll() is not None:
            sys.stderr.write("backrest-guard: backrest exited with %s\n" % child.returncode)
            return 1
        try:
            conn = http.client.HTTPConnection(UPSTREAM_HOST, UPSTREAM_PORT, timeout=2)
            conn.request("GET", "/")
            conn.getresponse().read()
            conn.close()
            break
        except OSError:
            time.sleep(1)

    def stop(signum, _frame):
        if child is not None and child.poll() is None:
            child.terminate()
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    server = ThreadingHTTPServer((BIND_HOST, BIND_PORT), Handler)
    server.daemon_threads = True
    sys.stderr.write("backrest-guard: serving %s, backrest on %s\n" % (GUARD_ADDR, UPSTREAM_ADDR))
    server.serve_forever()


if __name__ == "__main__":
    sys.exit(main() or 0)
