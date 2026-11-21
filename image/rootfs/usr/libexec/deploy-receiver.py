#!/usr/bin/env python3
"""The deploy receiver: the only way a deploy event reaches smortress.

A final publish job posts one signed request and gets an id back; everything
after that is host-side. The listener therefore does the cheapest possible
thing correctly: authenticate the exact bytes, bound the timestamp, refuse a
replay, allowlist the repository, refuse a denylisted commit, and put one file
in the queue atomically. It resolves no tag, checks no signature and writes no
state -- a request that fails any check changes nothing.

Two files are written here and nowhere else: `nonces.json` and `listener.lock`.
The drain writes `state.json` while the listener may be running, so a second
writer on that file would lose either the deployed commit or a nonce. The
listener never opens it for writing.

Stdlib only, like the webhook service: the image installs no distribution
package, and the tailnet is bounded by Serve rather than by this process.
"""

from __future__ import annotations

import fcntl
import hashlib
import hmac
import json
import os
import re
import signal
import sys
import threading
import time
import uuid
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

STATE_DIR = os.environ.get("DEPLOY_STATE_DIR", "/var/lib/homelab/deploy")
SECRETS_DIR = os.environ.get("DEPLOY_SECRETS_DIR", "/run/smortress/secrets")
# Loopback only: Serve terminates the tailnet side and forwards here, so a
# wildcard bind would add reach and no benefit.
HOST = os.environ.get("DEPLOY_LISTEN_HOST", "127.0.0.1")
PORT = int(os.environ.get("DEPLOY_LISTEN_PORT", "8484"))

CURRENT_SECRET = "webhook-secret.yaml"
NEXT_SECRET = "webhook-secret-next.yaml"

QUEUE_DIR = os.path.join(STATE_DIR, "queue")
JOURNAL_FILE = os.path.join(STATE_DIR, "journal.jsonl")
STATE_FILE = os.path.join(STATE_DIR, "state.json")
DENYLIST_FILE = os.path.join(STATE_DIR, "denylist.json")
NONCE_FILE = os.path.join(STATE_DIR, "nonces.json")
NONCE_LOCK = os.path.join(STATE_DIR, "listener.lock")

MAX_BODY_BYTES = 64 * 1024
READ_TIMEOUT = 10
SKEW_SECONDS = 300
QUEUE_CAP = 32
# The ring only has to outlive the skew window; a wider TTL keeps two clocks
# that disagree by minutes from reopening a replay.
NONCE_TTL = 3600
NONCE_CAP = 4096
REPOS = frozenset({"homelab-platform", "homelab-apps"})
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
NONCE_RE = re.compile(r"^[0-9a-f]{32}$")
SIGNATURE_PREFIX = "sha256="
HEX = frozenset("0123456789abcdef")


def log(message: str) -> None:
    sys.stderr.write(f"deploy-receiver: {message}\n")
    sys.stderr.flush()


def utc_now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def read_json(path: str) -> Any:
    """Parse a state document; a missing or unreadable one is not a crash."""
    try:
        with open(path, "rb") as handle:
            return json.loads(handle.read())
    except (OSError, ValueError):
        return None


def write_all(fd: int, data: bytes) -> None:
    """One write is not guaranteed to consume the buffer, even on a local fs."""
    view = memoryview(data)
    while view:
        written = os.write(fd, view)
        view = view[written:]


def fsync_dir(path: str) -> None:
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def atomic_write(path: str, data: bytes) -> None:
    """temp + fsync + rename + directory fsync: a reader sees one whole version.

    The drain writes the same directory, so the temp name is unique per process
    and per call; the rename is what makes the visible name change atomically.
    """
    directory = os.path.dirname(path) or "."
    tmp = os.path.join(directory, f".{os.path.basename(path)}.{uuid.uuid4().hex}.tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        write_all(fd, data)
        os.fsync(fd)
    except OSError:
        os.close(fd)
        os.unlink(tmp)
        raise
    os.close(fd)
    try:
        os.replace(tmp, path)
    except OSError:
        os.unlink(tmp)
        raise
    fsync_dir(directory)


def journal(event: str, **fields: Any) -> None:
    """One fsynced line before the action it describes.

    Opened per write: the drain rotates this file, and a held descriptor would
    keep appending to the rotated inode. A journal failure must not turn an
    answer into a different answer -- the request is still queued or refused on
    its own merits -- so the error is logged and not raised.
    """
    line = json.dumps({"ts": utc_now(), "event": event, **fields}, separators=(",", ":"))
    try:
        fd = os.open(JOURNAL_FILE, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    except OSError as exc:
        log(f"cannot journal {event}: {exc}")
        return
    try:
        os.write(fd, (line + "\n").encode())
        os.fsync(fd)
    except OSError as exc:
        log(f"cannot journal {event}: {exc}")
    finally:
        os.close(fd)


def parse_secret(path: str) -> bytes | None:
    """Read the one `value:` scalar sops-decrypt wrote.

    `value`, not a nested document, so this needs no YAML parser and cannot be
    confused by one: an empty or unquoted-empty scalar is a failed decrypt and
    therefore no secret, never a wildcard.
    """
    try:
        with open(path, "rb") as handle:
            text = handle.read().decode("utf-8", "replace")
    except OSError:
        return None
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        key, sep, value = line.partition(":")
        if not sep or key.strip() != "value":
            continue
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
            value = value[1:-1]
        return value.encode() if value else None
    return None


def load_secrets() -> list[bytes]:
    """Both rotation slots, or a refusal to start.

    The current secret is not optional: a listener that started with none would
    answer 202 to a request it never authenticated, and every caller would
    believe a deploy had been queued.
    """
    current = parse_secret(os.path.join(SECRETS_DIR, CURRENT_SECRET))
    if not current:
        raise SystemExit(
            f"deploy-receiver: refusing to start: {os.path.join(SECRETS_DIR, CURRENT_SECRET)} "
            "is missing or empty; a listener with no secret would accept anything"
        )
    secrets = [current]
    following = parse_secret(os.path.join(SECRETS_DIR, NEXT_SECRET))
    if following:
        secrets.append(following)
    return secrets


class NonceRing:
    """The replay ring under the listener's own flock.

    `listener.lock` is the listener's alone: the drain holds `deploy.lock` and
    never opens this file, so the two writers cannot interleave here even if a
    drain runs while a request arrives. The whole ring is rewritten on exit --
    it is a few hundred entries, and a partial in-place edit would be the one
    way to corrupt it.
    """

    def __init__(self) -> None:
        self._fd = -1
        self._ring: dict[str, int] = {}

    def __enter__(self) -> dict[str, int]:
        self._fd = os.open(NONCE_LOCK, os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(self._fd, fcntl.LOCK_EX)
        document = read_json(NONCE_FILE)
        nonces = document.get("nonces") if isinstance(document, dict) else None
        self._ring = dict(nonces) if isinstance(nonces, dict) else {}
        return self._ring

    def __exit__(self, *_exc: object) -> None:
        try:
            self._prune()
            atomic_write(
                NONCE_FILE,
                json.dumps({"schema": 1, "nonces": self._ring}, separators=(",", ":")).encode(),
            )
        finally:
            fcntl.flock(self._fd, fcntl.LOCK_UN)
            os.close(self._fd)

    def _prune(self) -> None:
        cutoff = int(time.time()) - NONCE_TTL
        fresh = {nonce: int(ts) for nonce, ts in self._ring.items() if int(ts) >= cutoff}
        # A clock jump forward could otherwise leave the ring over its cap;
        # dropping the oldest entries is safe because they are outside the skew
        # window anyway.
        if len(fresh) > NONCE_CAP:
            fresh = dict(sorted(fresh.items(), key=lambda item: item[1])[-NONCE_CAP:])
        self._ring = fresh


@dataclass(frozen=True)
class Response:
    status: int
    payload: dict[str, Any] = field(default_factory=dict)


class Receiver:
    """The contract as a function of (body, signature, timestamp)."""

    def __init__(self, secrets: list[bytes]) -> None:
        self._secrets = secrets
        # ThreadingHTTPServer would otherwise let two requests race in the
        # "nonce unseen -> queue it" window.
        self._lock = threading.Lock()

    # -- authentication -----------------------------------------------------
    def _signed(self, body: bytes, signature: str | None) -> bool:
        if not signature or not signature.startswith(SIGNATURE_PREFIX):
            return False
        digest = signature[len(SIGNATURE_PREFIX) :].strip().lower()
        if len(digest) != 64 or any(char not in HEX for char in digest):
            return False
        return any(
            hmac.compare_digest(hmac.new(secret, body, hashlib.sha256).hexdigest(), digest)
            for secret in self._secrets
        )

    # -- the nonce ring -----------------------------------------------------
    def _nonce_seen(self, nonce: str) -> bool:
        with NonceRing() as ring:
            return nonce in ring

    def _nonce_record(self, nonce: str) -> None:
        with NonceRing() as ring:
            ring[nonce] = int(time.time())

    # -- reads --------------------------------------------------------------
    @staticmethod
    def _queue_count() -> int:
        try:
            return len([name for name in os.listdir(QUEUE_DIR) if name.endswith(".json")])
        except OSError:
            return 0

    @staticmethod
    def _queue_writable() -> bool:
        return os.path.isdir(QUEUE_DIR) and os.access(QUEUE_DIR, os.W_OK | os.X_OK)

    @staticmethod
    def _deployed_commit(repo: str) -> str | None:
        document = read_json(STATE_FILE)
        if not isinstance(document, dict):
            return None
        repos = document.get("repos")
        if not isinstance(repos, dict):
            return None
        entry = repos.get(repo)
        if not isinstance(entry, dict):
            return None
        commit = entry.get("commit")
        return commit if isinstance(commit, str) and commit else None

    @staticmethod
    def _denylisted(commit: str) -> bool:
        document = read_json(DENYLIST_FILE)
        if not isinstance(document, dict):
            return False
        commits = document.get("commits")
        return isinstance(commits, dict) and commit in commits

    # -- answers ------------------------------------------------------------
    def health(self) -> Response:
        # The queue is the health signal: a listener that answers 200 while it
        # cannot accept a request is the one failure nobody notices.
        if self._secrets and self._queue_writable():
            return Response(200, {"status": "ok"})
        return Response(503, {"status": "unhealthy", "reason": "queue-unavailable"})

    def _reject(self, status: int, reason: str, **fields: Any) -> Response:
        journal("deploy-rejected", status=status, reason=reason, **fields)
        log(f"{reason} ({status}) {' '.join(f'{k}={v}' for k, v in fields.items())}".strip())
        return Response(status, {"status": "rejected", "reason": reason})

    def deploy(self, body: bytes, signature: str | None, timestamp: str | None) -> Response:
        with self._lock:
            if not self._signed(body, signature):
                return self._reject(401, "bad-signature")
            try:
                payload = json.loads(body)
            except ValueError:
                return self._reject(400, "malformed-json")
            if not isinstance(payload, dict):
                return self._reject(400, "malformed-json")

            repo = payload.get("repo")
            commit = payload.get("commit")
            nonce = payload.get("nonce")
            if not isinstance(repo, str) or repo not in REPOS:
                return self._reject(400, "unsupported-repo", repo=str(repo))
            if not isinstance(commit, str) or not COMMIT_RE.match(commit):
                return self._reject(400, "invalid-commit", repo=repo)
            if not isinstance(nonce, str) or not NONCE_RE.match(nonce):
                return self._reject(400, "invalid-nonce", repo=repo)

            raw_ts: Any = timestamp if timestamp not in (None, "") else payload.get("ts")
            try:
                ts = int(raw_ts)
            except (TypeError, ValueError):
                return self._reject(400, "invalid-timestamp", repo=repo)
            skew = int(time.time()) - ts
            if abs(skew) > SKEW_SECONDS:
                return self._reject(401, "stale-timestamp", repo=repo, skew=skew)

            try:
                replayed = self._nonce_seen(nonce)
            except OSError as exc:
                # No ring means no replay protection: refuse rather than accept
                # a request that could be replayed for ever.
                log(f"cannot read the nonce ring: {exc}")
                journal("queue-failed", repo=repo, commit=commit, error=str(exc))
                return Response(503, {"status": "error", "reason": "nonce-ring-unavailable"})
            if replayed:
                return self._reject(401, "replayed-nonce", repo=repo)
            if self._denylisted(commit):
                return self._reject(409, "denylisted-commit", repo=repo, commit=commit)
            if self._deployed_commit(repo) == commit:
                journal("already-deployed", repo=repo, commit=commit)
                return Response(200, {"status": "already-deployed", "repo": repo, "commit": commit})
            if self._queue_count() >= QUEUE_CAP:
                return self._reject(429, "queue-full", repo=repo)

            # Spent before the queue write, and only by a request that passed
            # every check: a nonce is a property of the authorized attempt, not
            # of a successful queue write, and the caller mints a new one per
            # attempt, so a queue failure costs one retry and reopens nothing.
            try:
                self._nonce_record(nonce)
            except OSError as exc:
                log(f"cannot record the nonce: {exc}")
                journal("queue-failed", repo=repo, commit=commit, error=str(exc))
                return Response(503, {"status": "error", "reason": "nonce-ring-unavailable"})

            entry_id = str(uuid.uuid4())
            entry = {
                "schema": 1,
                "id": entry_id,
                "repo": repo,
                "commit": commit,
                "queued_at": int(time.time()),
                "nonce": nonce,
                "source": "event",
            }
            try:
                atomic_write(
                    os.path.join(QUEUE_DIR, f"{entry_id}.json"),
                    json.dumps(entry, separators=(",", ":")).encode(),
                )
            except OSError as exc:
                log(f"cannot queue {entry_id}: {exc}")
                journal("queue-failed", repo=repo, commit=commit, error=str(exc))
                return Response(503, {"status": "error", "reason": "queue-unavailable"})
            journal("queue-enqueued", id=entry_id, repo=repo, commit=commit)
            return Response(202, {"status": "queued", "id": entry_id})


RECEIVER: Receiver


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "smortress-deploy/1"
    sys_version = ""

    def setup(self) -> None:
        super().setup()
        # Bounds the whole body read: a caller that opens a connection and stops
        # sending must not hold a worker for ever.
        self.connection.settimeout(READ_TIMEOUT)

    def log_message(self, fmt: str, *args: Any) -> None:
        log(fmt % args)

    def _send(self, response: Response) -> None:
        body = (json.dumps(response.payload, separators=(",", ":")) + "\n").encode()
        self.send_response(response.status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        try:
            self.wfile.write(body)
        except OSError:
            # The caller hung up mid-answer; that is not a listener failure and
            # must not print a traceback that reads like one.
            pass

    def do_GET(self) -> None:
        if self.path.split("?", 1)[0] == "/healthz":
            self._send(RECEIVER.health())
            return
        self._send(Response(404, {"status": "error", "reason": "not-found"}))

    def do_POST(self) -> None:
        if self.path.split("?", 1)[0] != "/v1/deploy":
            self._send(Response(404, {"status": "error", "reason": "not-found"}))
            return
        body, error = self._read_body()
        if body is None:
            self._send(Response(error, {"status": "rejected", "reason": "bad-body"}))
            return
        self._send(
            RECEIVER.deploy(
                body,
                self.headers.get("X-Deploy-Signature"),
                self.headers.get("X-Deploy-Timestamp"),
            )
        )

    def _read_body(self) -> tuple[bytes | None, int]:
        raw = self.headers.get("Content-Length")
        if raw is None:
            # No boundary means no way to bound the read; a chunked body is not
            # what the publish job sends.
            return None, 411
        try:
            length = int(raw)
        except ValueError:
            return None, 400
        if length < 0:
            return None, 400
        if length > MAX_BODY_BYTES:
            return None, 413
        chunks: list[bytes] = []
        remaining = length
        try:
            while remaining > 0:
                chunk = self.rfile.read(min(remaining, 65536))
                if not chunk:
                    return None, 400
                chunks.append(chunk)
                remaining -= len(chunk)
        except OSError:
            return None, 408
        return b"".join(chunks), 0


def main() -> int:
    global RECEIVER
    RECEIVER = Receiver(load_secrets())
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    server.daemon_threads = True

    def stop(_signum: int, _frame: object) -> None:
        # shutdown() waits for serve_forever, so it cannot run on this thread.
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    log(f"listening on {HOST}:{PORT} state={STATE_DIR} secrets={SECRETS_DIR}")
    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
