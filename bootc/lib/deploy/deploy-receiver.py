#!/usr/bin/env python3
"""The deploy receiver: the only way a deploy event reaches smortress.

A final publish job posts one signed request and gets an id back; everything
after that is host-side. The listener therefore does the cheapest possible
thing correctly: authenticate the exact bytes, bound the timestamp of those
bytes, refuse a replay, allowlist the repository, refuse a denylisted commit,
and put one file in the queue atomically. It resolves no tag, checks no
signature and writes no state -- a request that fails any check changes nothing.

Nothing an unauthenticated caller can trigger may cost the listener disk I/O or
the lock a valid request needs: every check that does not need the secret runs
before the lock, and a refusal is counted in memory (`/healthz` reports it)
instead of appended to the journal.

Two files are written here and nowhere else: `nonces.json` and `listener.lock`.
The drain writes `state.json` while the listener may be running, so a second
writer on that file would lose either the deployed commit or a nonce. The
listener never opens it for writing.

Stdlib only, like the webhook service: the image installs no distribution
package, and the tailnet is bounded by Serve rather than by this process.

The receiver is the same program on every role -- the server and the edge differ
only in what they run -- so it lives in bootc/lib beside the decisions it
enforces (bootc/lib/deploy/decisions.py, design #939): the repo allowlist, the
request shapes, the journal line and the two records it reads are pure functions
there, and each role passes its own name.
"""

from __future__ import annotations

import fcntl
import hashlib
import hmac
import json
import os
import signal
import sys
import threading
import time
import uuid
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any


# The policy tables and the pure checks are shared with the verifier and the
# drain loop. The image installs them at /usr/libexec/deploy; this file sits in
# that directory in a checkout. The program's own directory is searched first so
# a test run never picks up an installed copy of the shared code.
def _decisions_dir() -> str:
    here = os.path.dirname(os.path.abspath(__file__))
    for candidate in (
        os.environ.get("DEPLOY_LIB_DIR", ""),
        here,
        os.path.join(here, os.pardir, os.pardir, os.pardir, os.pardir, "lib", "deploy"),
        "/usr/libexec/deploy",
    ):
        if candidate and os.path.isfile(os.path.join(candidate, "decisions.py")):
            return os.path.abspath(candidate)
    raise SystemExit(
        "deploy-receiver: no decisions.py beside this program, in the checkout or in "
        "/usr/libexec/deploy"
    )


sys.path.insert(0, _decisions_dir())
import decisions  # noqa: E402  # the path above is what makes it importable

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
# Requests being read at once. A slot is taken before the first body byte, so a
# caller that connects and stalls (or a flood of them) costs a slot for at most
# READ_TIMEOUT; past the cap the answer is immediate rather than queued, because
# a listener that buffers unbounded request bodies is the one that dies first.
MAX_CONCURRENCY = int(os.environ.get("DEPLOY_MAX_CONCURRENCY", "32"))
# The ring only has to outlive the skew window; a wider TTL keeps two clocks
# that disagree by minutes from reopening a replay.
NONCE_TTL = 3600
NONCE_CAP = 4096


def role_from_env() -> decisions.Role:
    """This host's policy table: the repos it accepts, and nothing else.

    `DEPLOY_ROLE` is the image's choice, because the listener is the same program
    on every role and the allowlist is the one thing it must not guess. The
    default is the server -- the host this program shipped on first -- and an
    unknown name is a refusal to start rather than a fallback to it: a listener
    whose policy table is not the host's is a listener that has to be stopped by
    hand, and refusing here means the unit fails instead.

    It is enforced *here*, before the nonce ring and before a queue file: an apps
    entry on the edge would occupy one of the 32 slots and lock out a platform
    deploy the host does run.
    """
    name = os.environ.get("DEPLOY_ROLE", decisions.SERVER)
    try:
        return decisions.role(name)
    except ValueError:
        raise SystemExit(
            "deploy-receiver: refusing to start: DEPLOY_ROLE="
            f"{name!r} is not one of {', '.join(sorted(decisions.ROLES))}"
        ) from None


ROLE = role_from_env()
SIGNATURE_PREFIX = "sha256="
HEX = decisions.HEX


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

    The line's shape is shared (`decisions.journal_line`), because the drain and
    the shell readers grep the same file: timestamp and event first, details
    after. Opened per write: the drain rotates this file, and a held descriptor
    would keep appending to the rotated inode. A journal failure must not turn an
    answer into a different answer -- the request is still queued or refused on
    its own merits -- so the error is logged and not raised.
    """
    line = decisions.journal_line(utc_now(), event, fields)
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
    """Read the one scalar sops-decrypt wrote.

    Both `value` spellings are accepted: sops-decrypt writes the scalar alone (the
    manifest says `value`, so the key is stripped), while a hand-staged file may
    spell out `value: <scalar>`. A bare line is taken whole and a line with a colon
    must be `value:`, so a YAML document with other keys is still not a secret.
    There is no YAML parser here on purpose: an empty scalar is a failed decrypt
    and therefore no secret, never a wildcard.
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
        if sep:
            if key.strip() != "value":
                continue
            value = value.strip()
        else:
            value = line
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


@dataclass(frozen=True)
class Request:
    """What a signed body asks for, once every check that needs no lock passed."""

    repo: str
    commit: str
    nonce: str


class RejectionTally:
    """A bounded, in-memory count of everything the listener refused.

    A journal line is an fsync, and every refusal below the signature check is
    reachable by anyone who can open the port: writing one per attempt lets an
    unauthenticated caller drive disk I/O at will and is the cheap half of a
    denial of service. The tally is capped both in keys and in total so a flood
    of distinct reasons cannot grow the process either; `/healthz` reports it,
    which is what the operator needs (a listener answering nothing but 401s
    looks healthy otherwise).
    """

    MAX_KEYS = 32
    MAX_TOTAL = 100_000

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._counts: dict[str, int] = {}
        self._total = 0
        self._dropped = 0

    def add(self, reason: str) -> None:
        with self._lock:
            if self._total >= self.MAX_TOTAL:
                self._dropped += 1
                return
            self._total += 1
            if reason in self._counts or len(self._counts) < self.MAX_KEYS:
                self._counts[reason] = self._counts.get(reason, 0) + 1
            else:
                self._counts["other"] = self._counts.get("other", 0) + 1

    def snapshot(self) -> dict[str, int]:
        with self._lock:
            counts = dict(self._counts)
            if self._dropped:
                counts["dropped"] = self._dropped
            return counts


class Receiver:
    """The contract as a function of the signed body."""

    def __init__(self, secrets: list[bytes]) -> None:
        self._secrets = secrets
        # ThreadingHTTPServer would otherwise let two requests race in the
        # "nonce unseen -> queue it" window. It is taken only after the request
        # is authenticated and shaped: a refusal must never wait on, or hold up,
        # the lock a valid request needs.
        self._lock = threading.Lock()
        self._slots = threading.BoundedSemaphore(MAX_CONCURRENCY)
        self._rejections = RejectionTally()

    # -- admission ----------------------------------------------------------
    def admit(self) -> bool:
        """One of the bounded read slots, or False when the cap is reached."""
        return self._slots.acquire(blocking=False)

    def release(self) -> None:
        self._slots.release()

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
    # The queue-directory contract documented in scripts/deploy-state.sh: one
    # regular file directly inside QUEUE_DIR whose name ends in `.json`. A
    # subdirectory called `x.json` is not an entry, so the cap here counts what
    # the drain's `queue_entries` sees. tests/deploy/receiver.sh compares this
    # reader with the bash one on a fixture.
    @staticmethod
    def _queue_count() -> int:
        try:
            with os.scandir(QUEUE_DIR) as entries:
                return sum(
                    1
                    for entry in entries
                    if entry.name.endswith(".json") and entry.is_file(follow_symlinks=False)
                )
        except OSError:
            return 0

    @staticmethod
    def _queue_writable() -> bool:
        return os.path.isdir(QUEUE_DIR) and os.access(QUEUE_DIR, os.W_OK | os.X_OK)

    @staticmethod
    def _deployed_commit(repo: str) -> str | None:
        return decisions.recorded_commit(read_json(STATE_FILE), repo)

    @staticmethod
    def _denylisted(commit: str) -> bool:
        return decisions.denylisted(read_json(DENYLIST_FILE), decisions.COMMITS, commit)

    # -- answers ------------------------------------------------------------
    def health(self) -> Response:
        # The queue is the health signal: a listener that answers 200 while it
        # cannot accept a request is the one failure nobody notices. The tally
        # rides beside it, because a listener whose traffic is all refusals
        # would otherwise look like a healthy receiver nobody is deploying to.
        rejected = self._rejections.snapshot()
        if self._secrets and self._queue_writable():
            return Response(200, {"status": "ok", "rejected": rejected})
        return Response(
            503, {"status": "unhealthy", "reason": "queue-unavailable", "rejected": rejected}
        )

    def busy(self) -> Response:
        """The answer when every read slot is taken (the caller should retry)."""
        self._rejections.add("listener-busy")
        log(f"listener-busy ({MAX_CONCURRENCY} slots taken)")
        return Response(503, {"status": "rejected", "reason": "listener-busy"})

    def bad_body(self, status: int) -> Response:
        self._rejections.add("bad-body")
        log(f"bad-body ({status})")
        return Response(status, {"status": "rejected", "reason": "bad-body"})

    def _refuse(self, status: int, reason: str, **fields: Any) -> Response:
        """A refusal the caller's own request caused, counted and not journaled.

        Reachable without the secret, so the record is the in-memory tally that
        `/healthz` reports: an fsynced journal line per attempt is disk I/O an
        unauthenticated caller could ask for, at whatever rate it likes.
        """
        self._rejections.add(reason)
        log(f"{reason} ({status}) {' '.join(f'{k}={v}' for k, v in fields.items())}".strip())
        return Response(status, {"status": "rejected", "reason": reason})

    def _reject(self, status: int, reason: str, **fields: Any) -> Response:
        """A refusal only a caller holding the secret can reach: journaled.

        Nothing here is attacker-reachable at will -- a denylisted commit and a
        full queue both take a valid HMAC -- so the durable record stays.
        """
        journal("deploy-rejected", status=status, reason=reason, **fields)
        log(f"{reason} ({status}) {' '.join(f'{k}={v}' for k, v in fields.items())}".strip())
        return Response(status, {"status": "rejected", "reason": reason})

    def _parse(self, body: bytes) -> Request | Response:
        """Shape, signed timestamp and nonce, or the refusal naming what is wrong.

        `ts` comes from the body and nowhere else: it is the value the HMAC
        covers, so a header that disagreed with it could only be a request to
        read one clock and verify another.
        """
        try:
            payload = json.loads(body)
        except ValueError:
            return self._refuse(400, "malformed-json")
        if not isinstance(payload, dict):
            return self._refuse(400, "malformed-json")

        repo = payload.get("repo")
        commit = payload.get("commit")
        nonce = payload.get("nonce")
        if not decisions.allows(ROLE.name, repo):
            return self._refuse(400, "unsupported-repo", repo=str(repo))
        if not decisions.is_commit(commit):
            return self._refuse(400, "invalid-commit", repo=repo)
        if not decisions.is_nonce(nonce):
            return self._refuse(400, "invalid-nonce", repo=repo)
        try:
            ts = int(payload["ts"])
        except (KeyError, TypeError, ValueError):
            return self._refuse(400, "invalid-timestamp", repo=repo)
        skew = int(time.time()) - ts
        if abs(skew) > SKEW_SECONDS:
            return self._refuse(401, "stale-timestamp", repo=repo, skew=skew)
        return Request(repo=repo, commit=commit, nonce=nonce)

    def deploy(self, body: bytes, signature: str | None) -> Response:
        """The contract, with every lock-free check ahead of the lock."""
        if not self._signed(body, signature):
            return self._refuse(401, "bad-signature")
        parsed = self._parse(body)
        if isinstance(parsed, Response):
            return parsed
        repo, commit, nonce = parsed.repo, parsed.commit, parsed.nonce

        with self._lock:
            try:
                replayed = self._nonce_seen(nonce)
            except OSError as exc:
                # No ring means no replay protection: refuse rather than accept
                # a request that could be replayed for ever.
                log(f"cannot read the nonce ring: {exc}")
                journal("queue-failed", repo=repo, commit=commit, error=str(exc))
                return Response(503, {"status": "error", "reason": "nonce-ring-unavailable"})
            if replayed:
                return self._refuse(401, "replayed-nonce", repo=repo)
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
        # The slot comes before the first body byte: over the cap the answer is
        # immediate, so a flood costs one short-lived thread per connection
        # instead of one stalled read per request. `/healthz` takes no slot --
        # the dead-man has to be able to ask while the listener is saturated.
        if not RECEIVER.admit():
            self._send(RECEIVER.busy())
            return
        try:
            body, error = self._read_body()
            if body is None:
                self._send(RECEIVER.bad_body(error))
                return
            self._send(RECEIVER.deploy(body, self.headers.get("X-Deploy-Signature")))
        finally:
            RECEIVER.release()

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
