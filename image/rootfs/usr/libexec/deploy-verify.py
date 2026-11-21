#!/usr/bin/env python3
"""Verify a proposed deploy on the host before anything changes (SDLC #798, T2).

A deploy request proposes a commit and carries no authority of its own, so every
fact is re-derived here: is that commit the tip *now*, does it descend from what
the host is running, and does the image published for it name that commit. The
checks are ordered and fail closed, and none of them writes deployment state --
a rejected commit changes nothing and leaves the last good deployment running.

The only file written is the 120 s API cache, because GitHub calls are anonymous
and budgeted: a burst of events, or one event followed by a poll, must spend one
call rather than one each. The drain is the only writer of the state tree, so
the cache needs no lock of its own.

Exit 0 verified (one JSON object on stdout), 3 rejected, 4 infrastructure. The
split is the contract: a rejection is a verdict about the commit and must never
be retried, while an exhausted budget or a dead network says nothing about the
commit and has to keep looking like a retryable failure, or the host would
record a rate limit as a bad deploy for ever.

Stdlib only, and it ships in the image rootfs beside the receiver for the same
reason: the build's `smortress-src` loop installs `.sh` files only.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import socket
import sys
import time
import urllib.error
import urllib.request
import uuid
from dataclasses import dataclass
from typing import Any

STATE_DIR = os.environ.get("DEPLOY_STATE_DIR", "/var/lib/homelab/deploy")
GITHUB_API = os.environ.get("DEPLOY_GITHUB_API", "https://api.github.com").rstrip("/")
REGISTRY = os.environ.get("DEPLOY_REGISTRY", "https://ghcr.io").rstrip("/")
# One deadline per call, not per run: a wedged TLS read on one request must not
# spend the time the remaining checks need, and the drain bounds the whole call.
TIMEOUT = float(os.environ.get("DEPLOY_VERIFY_TIMEOUT", "30"))

STATE_FILE = os.path.join(STATE_DIR, "state.json")
DENYLIST_FILE = os.path.join(STATE_DIR, "denylist.json")
CACHE_FILE = os.path.join(STATE_DIR, "cache.json")

OWNER = "smores56"
PLATFORM = "homelab-platform"
REPOS = ("homelab-platform", "homelab-apps")
# Must match IMAGE_REPO in image/pins.env: the tag, both digests and the
# revision label are all resolved out of this one repository.
IMAGE_REPO = "smores56/homelab-platform/server"
REVISION_LABEL = "org.opencontainers.image.revision"
CACHE_TTL = 120
# A manifest or a config blob is a few KiB; a read that is not bounded is a
# response that can hold the drain open.
MAX_BODY = 8 * 1024 * 1024

COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")

INDEX_ACCEPT = ", ".join(
    (
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
        "application/vnd.oci.image.manifest.v1+json",
        "application/vnd.docker.distribution.manifest.v2+json",
    )
)


def log(message: str) -> None:
    sys.stderr.write(f"deploy-verify: {message}\n")
    sys.stderr.flush()


# -- outcomes ---------------------------------------------------------------


class Failure(Exception):
    """A named outcome, with a reason the journal can hold verbatim."""

    def __init__(self, reason: str, detail: str = "") -> None:
        super().__init__(reason)
        self.reason = reason
        self.detail = detail


class NotDeployable(Failure):
    """The commit has no image yet: a test-only or docs-only main commit.

    The registry tag is derived from the commit, and the publish workflow only
    runs when an image-bearing path changes, so most commits on main have no
    image. That is not a failure: it is refused without a denylist entry, without
    a page, and without a retry, because nothing will change until the next
    image-bearing commit.
    """


class Refused(Failure):
    """A verdict about the commit: exit 3. No later attempt changes it."""


class Infrastructure(Failure):
    """No verdict at all: exit 4, the entry stays queued and is retried."""


# -- HTTP -------------------------------------------------------------------


@dataclass(frozen=True)
class Reply:
    status: int
    headers: dict[str, str]
    body: bytes

    def json(self) -> Any:
        try:
            return json.loads(self.body)
        except ValueError:
            return None


def _timed_out(error: BaseException) -> bool:
    """A deadline and a refused connection both arrive as URLError."""
    seen: set[int] = set()
    candidate: BaseException | None = error
    while candidate is not None and id(candidate) not in seen:
        seen.add(id(candidate))
        if isinstance(candidate, TimeoutError):
            return True
        cause = getattr(candidate, "reason", None)
        candidate = cause if isinstance(cause, BaseException) else candidate.__cause__
    return "timed out" in str(error)


def http_get(url: str, headers: dict[str, str] | None = None) -> Reply:
    """One GET, one deadline, no retry loop.

    A 4xx is returned rather than raised: a missing tag is a verdict about the
    image and only the caller knows what a status means there. Transport trouble
    is not a verdict about anything and becomes an infrastructure failure.
    """
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "smortress-deploy-verify", **(headers or {})},
        method="GET",
    )
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            return Reply(
                response.status,
                {key.lower(): value for key, value in response.headers.items()},
                response.read(MAX_BODY),
            )
    except urllib.error.HTTPError as error:
        try:
            body = error.read(MAX_BODY)
        except OSError:
            body = b""
        return Reply(
            error.code,
            {key.lower(): value for key, value in (error.headers or {}).items()},
            body,
        )
    except (urllib.error.URLError, OSError, socket.timeout) as error:
        raise Infrastructure(
            "timeout" if _timed_out(error) else "network", f"{url}: {error}"
        ) from error


# -- the 120 s cache --------------------------------------------------------


def write_atomic(path: str, data: bytes) -> None:
    """temp + fsync + rename + directory fsync, matching the state library."""
    directory = os.path.dirname(path) or "."
    tmp = os.path.join(directory, f".{os.path.basename(path)}.{uuid.uuid4().hex}.tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        view = memoryview(data)
        while view:
            written = os.write(fd, view)
            view = view[written:]
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
    fd = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


class Cache:
    """The anonymous API answers from the last two minutes, on disk.

    Disk, not memory: the verifier is one short-lived process per request. A
    corrupt or absent cache is a cold cache, never a failure -- it is derived
    data -- but a cache that cannot be *written* is an infrastructure failure,
    because running without it spends the budget this file exists to protect.
    """

    def __init__(self, path: str = CACHE_FILE, ttl: int = CACHE_TTL) -> None:
        self._path = path
        self._ttl = ttl
        self._entries = self._load()

    def _load(self) -> dict[str, Any]:
        try:
            with open(self._path, "rb") as handle:
                document = json.loads(handle.read())
        except (OSError, ValueError):
            return {}
        entries = document.get("entries") if isinstance(document, dict) else None
        return dict(entries) if isinstance(entries, dict) else {}

    def get(self, key: str) -> Any:
        entry = self._entries.get(key)
        if not isinstance(entry, dict):
            return None
        try:
            if time.time() - int(entry["at"]) > self._ttl:
                return None
        except (KeyError, TypeError, ValueError):
            return None
        return entry.get("value")

    def put(self, key: str, value: Any) -> None:
        now = int(time.time())
        fresh = {name: entry for name, entry in self._entries.items() if self._fresh(entry, now)}
        fresh[key] = {"at": now, "value": value}
        self._entries = fresh
        try:
            write_atomic(
                self._path,
                json.dumps({"schema": 1, "entries": fresh}, separators=(",", ":")).encode(),
            )
        except OSError as error:
            raise Infrastructure("cache-unwritable", f"{self._path}: {error}") from error

    def _fresh(self, entry: Any, now: int) -> bool:
        if not isinstance(entry, dict):
            return False
        try:
            return now - int(entry.get("at", 0)) <= self._ttl
        except (TypeError, ValueError):
            return False


# -- GitHub: the tip and the commit graph -----------------------------------


def github_get(path: str) -> Reply:
    url = f"{GITHUB_API}{path}"
    reply = http_get(url, {"Accept": "application/vnd.github+json"})
    # An exhausted anonymous budget is about the API, not about the commit.
    if reply.status in (403, 429):
        raise Infrastructure("rate-limited", f"{url} answered {reply.status}")
    return reply


def _document(reply: Reply, url: str) -> dict[str, Any]:
    document = reply.json()
    if not isinstance(document, dict):
        raise Infrastructure("bad-response", f"{url} is not a JSON object")
    return document


def tip(repo: str, cache: Cache) -> str:
    """What `main` points at now, not what the caller claimed."""
    path = f"/repos/{OWNER}/{repo}/git/ref/heads/main"
    url = f"{GITHUB_API}{path}"
    document = cache.get(url)
    if not isinstance(document, dict):
        reply = github_get(path)
        if reply.status != 200:
            raise Infrastructure(f"http-{reply.status}", url)
        document = _document(reply, url)
        cache.put(url, document)
    pointer = document.get("object")
    sha = pointer.get("sha") if isinstance(pointer, dict) else None
    if not isinstance(sha, str) or not COMMIT_RE.match(sha):
        raise Infrastructure("bad-response", f"{url} carries no commit sha")
    return sha


def descendancy(repo: str, deployed: str, commit: str, cache: Cache) -> None:
    """One request answers "does the deployed commit come first?"."""
    path = f"/repos/{OWNER}/{repo}/compare/{deployed}...{commit}"
    url = f"{GITHUB_API}{path}"
    document = cache.get(url)
    if not isinstance(document, dict):
        reply = github_get(path)
        if reply.status == 404:
            # A commit GitHub has never seen: nothing about it can be trusted,
            # and no later call would answer differently.
            raise Refused("descendancy-unknown", f"{url} answered 404")
        if reply.status != 200:
            raise Infrastructure(f"http-{reply.status}", url)
        document = _document(reply, url)
        cache.put(url, document)
    status = document.get("status")
    if status == "ahead":
        return
    if status in ("behind", "diverged"):
        raise Refused(status, f"{url} answered {status}")
    # `identical` lands here, and so does anything GitHub adds later: the
    # deployed commit already being the proposed one is the drain's no-op, not a
    # descendance.
    raise Refused("descendancy-unknown", f"compare status {status!r}")


# -- the registry: tag -> digests -> revision label -------------------------


def _digest(value: Any, what: str) -> str:
    if not isinstance(value, str) or not DIGEST_RE.match(value):
        raise Infrastructure("registry-response", f"{what}: {value!r}")
    return value


def registry_token() -> str:
    url = f"{REGISTRY}/token?service=ghcr.io&scope=repository:{IMAGE_REPO}:pull"
    reply = http_get(url, {"Accept": "application/json"})
    if reply.status in (403, 429):
        raise Infrastructure("rate-limited", f"{url} answered {reply.status}")
    if reply.status != 200:
        raise Infrastructure(f"http-{reply.status}", url)
    document = reply.json()
    token = None
    if isinstance(document, dict):
        token = document.get("token") or document.get("access_token")
    if not isinstance(token, str) or not token:
        raise Infrastructure("registry-auth", f"{url} returned no token")
    return token


def registry_get(path: str, token: str, accept: str) -> Reply:
    url = f"{REGISTRY}{path}"
    reply = http_get(url, {"Accept": accept, "Authorization": f"Bearer {token}"})
    if reply.status == 401:
        # An anonymous token is short-lived; one refresh, never a loop.
        reply = http_get(
            url, {"Accept": accept, "Authorization": f"Bearer {registry_token()}"}
        )
        if reply.status == 401:
            raise Infrastructure("registry-auth", f"{url} refused an anonymous token")
    if reply.status in (403, 429):
        raise Infrastructure("rate-limited", f"{url} answered {reply.status}")
    return reply


@dataclass(frozen=True)
class Resolved:
    token: str
    tag: str
    index: str
    manifest: str
    document: dict[str, Any]


def resolve_digests(commit: str) -> Resolved:
    """The digest pair for `sha-<commit[:12]>`, from the tag alone.

    The caller supplies a commit and never a digest, so the tag name plus the
    image's own revision label is what binds the two. Both forms are recorded
    because bootc reports either the index digest or the platform manifest
    digest, and the boot gate has to accept whichever it reports.
    """
    tag = f"sha-{commit[:12]}"
    token = registry_token()
    base = f"/v2/{IMAGE_REPO}"
    reply = registry_get(f"{base}/manifests/{tag}", token, INDEX_ACCEPT)
    if reply.status == 404:
        raise NotDeployable("tag-missing", f"{IMAGE_REPO}:{tag} is not published")
    if reply.status != 200:
        raise Infrastructure(f"http-{reply.status}", f"{base}/manifests/{tag}")
    document = _document(reply, f"{base}/manifests/{tag}")
    index_digest = _digest(reply.headers.get("docker-content-digest"), "Docker-Content-Digest")
    children = document.get("manifests")
    if children is None:
        # A tag that points straight at the platform manifest: the two forms are
        # the same digest, which is what the boot gate will see.
        return Resolved(token, tag, index_digest, index_digest, document)
    manifest_digest = _amd64_digest(children, f"{IMAGE_REPO}:{tag}")
    reply = registry_get(f"{base}/manifests/{manifest_digest}", token, INDEX_ACCEPT)
    if reply.status != 200:
        raise Infrastructure(f"http-{reply.status}", f"{base}/manifests/{manifest_digest}")
    manifest = _document(reply, f"{base}/manifests/{manifest_digest}")
    if _digest(reply.headers.get("docker-content-digest"), "Docker-Content-Digest") != manifest_digest:
        # The registry answered with something other than what the index named;
        # recording either digest would be recording a guess.
        raise Infrastructure("registry-response", f"{base}/manifests/{manifest_digest} is not that digest")
    return Resolved(token, tag, index_digest, manifest_digest, manifest)


def _amd64_digest(children: Any, what: str) -> str:
    if not isinstance(children, list):
        raise Refused("no-amd64-manifest", f"{what} carries no manifest list")
    for child in children:
        if not isinstance(child, dict):
            continue
        platform = child.get("platform")
        if not isinstance(platform, dict):
            continue
        if platform.get("os") == "linux" and platform.get("architecture") == "amd64":
            return _digest(child.get("digest"), "an index entry")
    raise Refused("no-amd64-manifest", f"{what} has no linux/amd64 manifest")


def revision_label(resolved: Resolved) -> str:
    """The commit the image itself says it was built from."""
    config = resolved.document.get("config")
    digest = _digest(config.get("digest") if isinstance(config, dict) else None, "config digest")
    path = f"/v2/{IMAGE_REPO}/blobs/{digest}"
    reply = registry_get(path, resolved.token, "*/*")
    if reply.status != 200:
        raise Infrastructure(f"http-{reply.status}", path)
    document = _document(reply, path)
    section = document.get("config")
    labels = section.get("Labels") if isinstance(section, dict) else None
    revision = labels.get(REVISION_LABEL) if isinstance(labels, dict) else None
    if not isinstance(revision, str) or not COMMIT_RE.match(revision):
        raise Refused("label-missing", f"{IMAGE_REPO}:{resolved.tag} carries no {REVISION_LABEL}")
    return revision


# -- the host's own records -------------------------------------------------


def _read_json(path: str) -> Any:
    try:
        with open(path, "rb") as handle:
            return json.loads(handle.read())
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as error:
        raise Infrastructure("state-unreadable", f"{path}: {error}") from error


def deployed_commit(repo: str) -> str:
    """What is running for this repository, or an explicit bootstrap.

    Never inferred: without a recorded ancestor there is no descendancy to
    check, and guessing one is how an older image gets staged over a newer host.
    """
    if not os.path.exists(STATE_FILE):
        raise Refused("bootstrap-required", f"{STATE_FILE} is absent")
    document = _read_json(STATE_FILE)
    if not isinstance(document, dict):
        # A record that will not parse cannot be trusted as an ancestor either.
        raise Refused("bootstrap-required", f"{STATE_FILE} is unreadable")
    repos = document.get("repos")
    entry = repos.get(repo) if isinstance(repos, dict) else None
    commit = entry.get("commit") if isinstance(entry, dict) else None
    if not isinstance(commit, str) or not COMMIT_RE.match(commit):
        raise Refused("bootstrap-required", f"no deployed commit for {repo}")
    return commit


def denylisted(kind: str, value: str) -> bool:
    """The host's own refusal list: apps commits, platform digests, either form."""
    if not os.path.exists(DENYLIST_FILE):
        return False
    document = _read_json(DENYLIST_FILE)
    if not isinstance(document, dict):
        # Fail closed: a list that will not parse is not an empty list.
        raise Infrastructure("denylist-unreadable", DENYLIST_FILE)
    table = document.get(kind)
    return isinstance(table, dict) and value in table


# -- the ordered verification -----------------------------------------------


def verify(repo: str, commit: str) -> dict[str, Any]:
    deployed = deployed_commit(repo)
    # Cheapest check first: a denied commit spends no API budget at all.
    if denylisted("commits", commit):
        raise Refused("denylisted", f"{commit} is on the denylist")
    cache = Cache()
    current = tip(repo, cache)
    if current != commit:
        raise Refused("tip-mismatch", f"main is at {current}")
    if deployed == commit:
        # Reachable only through a race with a poll; the drain treats an
        # already-deployed entry as a no-op before it gets here.
        raise Refused("already-deployed", commit)
    descendancy(repo, deployed, commit, cache)
    verdict: dict[str, Any] = {
        "verdict": "verified",
        "repo": repo,
        "commit": commit,
        "deployed": deployed,
        "tip": current,
        "descendancy": "ahead",
        "digests": None,
    }
    if repo != PLATFORM:
        return verdict
    resolved = resolve_digests(commit)
    for digest in (resolved.index, resolved.manifest):
        if denylisted("digests", digest):
            # Refused before the config blob is fetched: a denied image's label
            # does not matter, and this is one request saved per denial.
            raise Refused("denylisted", f"{digest} is on the denylist")
    revision = revision_label(resolved)
    if revision != commit:
        raise Refused("revision-mismatch", f"{resolved.tag} claims {revision}")
    verdict["digests"] = {"index": resolved.index, "manifest": resolved.manifest}
    verdict["revision"] = revision
    return verdict


def emit(document: dict[str, Any]) -> None:
    """One line: the drain reads it with jq and journals it verbatim."""
    sys.stdout.write(json.dumps(document, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def _detail(failure: Failure) -> dict[str, str]:
    return {"detail": failure.detail} if failure.detail else {}


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="deploy-verify",
        description="Verify a proposed deploy's commit, digests and revision label.",
    )
    parser.add_argument("--repo", required=True, choices=REPOS)
    parser.add_argument("--commit", required=True)
    args = parser.parse_args(argv)
    if not COMMIT_RE.match(args.commit):
        log("--commit must be a 40-character lowercase hex sha")
        return 2
    base = {"repo": args.repo, "commit": args.commit}
    try:
        verdict = verify(args.repo, args.commit)
    except NotDeployable as failure:
        emit({"verdict": "not-deployable", "reason": failure.reason, **base, **_detail(failure)})
        log(f"{args.repo} {args.commit}: not deployable ({failure.reason})")
        return 5
    except Refused as failure:
        emit({"verdict": "rejected", "reason": failure.reason, **base, **_detail(failure)})
        log(f"{args.repo} {args.commit}: rejected ({failure.reason}) {failure.detail}".rstrip())
        return 3
    except Infrastructure as failure:
        emit({"verdict": "infra-failure", "reason": failure.reason, **base, **_detail(failure)})
        log(f"{args.repo} {args.commit}: could not verify ({failure.reason}) {failure.detail}".rstrip())
        return 4
    emit(verdict)
    log(f"{args.repo} {args.commit}: verified")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
