#!/usr/bin/env python3
"""Verify a proposed deploy on the host before anything changes (SDLC #798, #939).

A deploy request proposes a commit and carries no authority of its own, so every
fact is re-derived here: is that commit the tip *now*, does it descend from what
the host is running, does the image published for it name that commit, and --
where this host has one -- does that image pass the deploy gate. The checks are
ordered and fail closed, and none of them writes deployment state: a rejected
commit changes nothing and leaves the last good deployment running.

Exit 0 verified (one JSON object on stdout), 3 rejected, 4 infrastructure, and 5
not-deployable where the policy names that verdict. The split is the contract: a
rejection is a verdict about the commit and must never be retried, while an
exhausted budget or a dead network says nothing about the commit and has to keep
looking like a retryable failure, or the host would record a rate limit as a bad
deploy for ever.

Two hosts run this program and they differ in inputs, not in behaviour, so the
difference is a table. `lib/deploy/policy.d/<host>.json` states which
repositories this host deploys, the image repository each one publishes to, what
an absent image means on this host, whether the anonymous API answers are cached,
and which gate has the last word; the image installs the host's table as
/usr/libexec/deploy/policy.json. The program carries no host name, no repository
name and no image name of its own -- `scripts/check-lib-drift.sh` fails the tree
if one appears -- because two copies of this file drifting apart is the thing
that split exists to stop.

The questions themselves -- the tag name, the digest and label shapes,
descendancy, the journal vocabulary, the state and denylist records -- are pure
functions in bootc/lib/deploy/decisions.py, installed beside this program as
/usr/libexec/deploy/decisions.py, and the golden fixtures under
bootc/lib/deploy/fixtures/ pin both policies' answers.

Stdlib only: the image installs no distribution package, and the build writes
this file into the image itself rather than through a shell install loop.
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
from dataclasses import dataclass
from typing import Any


# -- the shared decisions ---------------------------------------------------


def _shared_dir() -> str:
    """Where decisions.py is: beside this program, in the checkout, or installed.

    The program's own directory is searched first, so a suite run on a host that
    carries an image never tests the installed copy of the shared code.
    """
    here = os.path.dirname(os.path.abspath(__file__))
    for candidate in (
        os.environ.get("DEPLOY_LIB_DIR", ""),
        here,
        os.path.join(here, os.pardir, os.pardir, "bootc", "lib", "deploy"),
        "/usr/libexec/deploy",
    ):
        if candidate and os.path.isfile(os.path.join(candidate, "decisions.py")):
            return os.path.abspath(candidate)
    raise SystemExit(
        "deploy-verify: no decisions.py beside this program, in the checkout or in "
        "/usr/libexec/deploy"
    )


sys.path.insert(0, _shared_dir())
import decisions  # noqa: E402  # the path above is what makes it importable

STATE_DIR = os.environ.get("DEPLOY_STATE_DIR", "/var/lib/homelab/deploy")
GITHUB_API = os.environ.get("DEPLOY_GITHUB_API", "https://api.github.com").rstrip("/")
REGISTRY = os.environ.get("DEPLOY_REGISTRY", "https://ghcr.io").rstrip("/")
# One deadline per call, not per run: a wedged TLS read on one request must not
# spend the time the remaining checks need, and the drain bounds the whole call.
TIMEOUT = float(os.environ.get("DEPLOY_VERIFY_TIMEOUT", "30"))
# The gate's call is the one that pulls an image, so it has its own deadline. The
# drain bounds the verifier as a whole (`DEPLOY_VERIFY_DEADLINE`) and sets that
# above this, or a slow pull is killed mid-stage.
BOOTC_BIN = os.environ.get("BOOTC_BIN", "bootc")
SWITCH_TIMEOUT = float(os.environ.get("DEPLOY_SWITCH_TIMEOUT", "600"))

STATE_FILE = os.path.join(STATE_DIR, "state.json")
DENYLIST_FILE = os.path.join(STATE_DIR, "denylist.json")
CACHE_FILE = os.path.join(STATE_DIR, "cache.json")
# Where both images install this host's table. A checkout names one of the two
# with DEPLOY_VERIFY_POLICY rather than pretending to be a host.
INSTALLED_POLICY = "/usr/libexec/deploy/policy.json"
# A manifest or a config blob is a few KiB; a read that is not bounded is a
# response that can hold the drain open.
MAX_BODY = 8 * 1024 * 1024

INDEX_ACCEPT = ", ".join(
    (
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
        "application/vnd.oci.image.manifest.v1+json",
        "application/vnd.docker.distribution.manifest.v2+json",
    )
)

# What containers/image prints when the signature policy refuses an image. These
# are bootc's own words, matched to tell its verdicts apart from its failures --
# never to re-derive the verdict, which is the exit code. Anything unrecognised
# stays an infrastructure failure, because a wrong signature does not become a
# good one on the next attempt and a flaky registry is not a bad image.
SIGNATURE_REFUSALS = (
    "source image rejected",
    "signature verification failed",
    "no signatures found",
    "none of the signatures were accepted",
)


def log(message: str) -> None:
    sys.stderr.write(f"deploy-verify: {message}\n")
    sys.stderr.flush()


# -- outcomes ---------------------------------------------------------------


class Failure(Exception):
    """A named outcome, with a reason the journal can hold verbatim.

    `kind` is the shared decision vocabulary and `code` this role's exit code:
    the pair is the contract the drain reads, so the golden fixtures assert both
    rather than only the words. Which kind an answer carries is the policy's --
    an absent image is final on the host that publishes one for every
    image-bearing commit, and a hold on the host that publishes only when its own
    tree moves.
    """

    kind = decisions.INFRASTRUCTURE
    code = decisions.EXIT_CODES[decisions.VERDICT_INFRA]

    def __init__(self, reason: str, detail: str = "") -> None:
        super().__init__(reason)
        self.reason = reason
        self.detail = detail

    def document(self, repo: str, commit: str) -> dict[str, Any]:
        """The one line the drain reads: the verdict, the reason and the base."""
        return decisions.Decision(self.kind, self.reason, self.detail).document(repo, commit)


class Refused(Failure):
    """A verdict about the commit or its image: exit 3. Never retried."""

    kind = decisions.REFUSE
    code = decisions.EXIT_CODES[decisions.VERDICT_REJECTED]


class NotDeployable(Failure):
    """The commit will never have an image: exit 5, and no retry will change it."""

    kind = decisions.NOT_DEPLOYABLE
    code = decisions.EXIT_CODES[decisions.VERDICT_NOT_DEPLOYABLE]


class Infrastructure(Failure):
    """No verdict at all: exit 4, the entry keeps its place and is retried."""


FAILURES = {
    decisions.REFUSE: Refused,
    decisions.NOT_DEPLOYABLE: NotDeployable,
    decisions.INFRASTRUCTURE: Infrastructure,
}

# The journal word for each kind. The three are one sentence each, in the order
# the three outcomes reach an operator.
MESSAGES = {
    decisions.REFUSE: "rejected",
    decisions.NOT_DEPLOYABLE: "not deployable",
    decisions.INFRASTRUCTURE: "could not verify",
}


def check(answer: decisions.Decision) -> decisions.Decision:
    """The one place a shared answer becomes this role's exception."""
    if not answer.ok:
        raise FAILURES[answer.kind](answer.reason, answer.detail)
    return answer


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


def http_get(url: str, headers: dict[str, str] | None, user_agent: str) -> Reply:
    """One GET, one deadline, no retry loop.

    A 4xx is returned rather than raised: a missing tag is a fact about the image
    and only the caller knows what a status means there. Transport trouble is not
    a verdict about anything and becomes an infrastructure failure.
    """
    request = urllib.request.Request(
        url,
        headers={"User-Agent": user_agent, **(headers or {})},
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


# -- the API cache ----------------------------------------------------------


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
    """The anonymous API answers from the last `ttl` seconds, on disk.

    Disk, not memory: the verifier is one short-lived process per request. A
    corrupt or absent cache is a cold cache, never a failure -- it is derived
    data -- but a cache that cannot be *written* is an infrastructure failure,
    because running without it spends the budget this file exists to protect.
    """

    def __init__(self, path: str, ttl: int) -> None:
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


class NoCache:
    """A host whose policy keeps no API answers: nothing stored, nothing served.

    Not a degenerate Cache but the absence of one: a host that spends a handful
    of anonymous calls per poll is protecting no budget, and a verifier that
    writes nothing is one fewer writer in a state tree it does not lock.
    """

    def get(self, _key: str) -> None:
        return None

    def put(self, _key: str, _value: Any) -> None:
        return None


# -- GitHub: the tip and the commit graph -----------------------------------


def github_get(path: str, policy: Policy) -> Reply:
    url = f"{GITHUB_API}{path}"
    reply = http_get(url, {"Accept": "application/vnd.github+json"}, policy.user_agent)
    # An exhausted anonymous budget is about the API, not about the commit.
    if reply.status in (403, 429):
        check(decisions.rate_limited(reply.status, url))
    return reply


def _document(reply: Reply, url: str) -> dict[str, Any]:
    document = reply.json()
    if not isinstance(document, dict):
        raise Infrastructure("bad-response", f"{url} is not a JSON object")
    return document


def tip(repo: str, cache: Cache | NoCache, policy: Policy) -> str:
    """What `main` points at now, not what the caller claimed."""
    path = f"/repos/{decisions.OWNER}/{repo}/git/ref/heads/main"
    url = f"{GITHUB_API}{path}"
    document = cache.get(url)
    if not isinstance(document, dict):
        reply = github_get(path, policy)
        if reply.status != 200:
            check(decisions.http_failure(reply.status, url))
        document = _document(reply, url)
        cache.put(url, document)
    answer = decisions.tip_from(document, url)
    check(answer)
    return answer.value


def descendancy(
    repo: str, deployed: str, commit: str, cache: Cache | NoCache, policy: Policy
) -> None:
    """One request answers "does the deployed commit come first?"."""
    path = f"/repos/{decisions.OWNER}/{repo}/compare/{deployed}...{commit}"
    url = f"{GITHUB_API}{path}"
    document = cache.get(url)
    if not isinstance(document, dict):
        reply = github_get(path, policy)
        answer = decisions.compare(reply.status, reply.json(), url)
        check(answer)
        document = reply.json()
        cache.put(url, document)
        return
    # A cached answer is a 200 this process already stored; the status matters
    # only on the way in, which is why the shared check takes it as an argument.
    check(decisions.compare(200, document, url))


# -- the registry: tag -> digests -> revision label -------------------------


def registry_token(image_repo: str, policy: Policy) -> str:
    url = f"{REGISTRY}/token?service=ghcr.io&scope=repository:{image_repo}:pull"
    reply = http_get(url, {"Accept": "application/json"}, policy.user_agent)
    if reply.status in (403, 429):
        check(decisions.rate_limited(reply.status, url))
    if reply.status != 200:
        check(decisions.http_failure(reply.status, url))
    document = reply.json()
    token = None
    if isinstance(document, dict):
        token = document.get("token") or document.get("access_token")
    if not isinstance(token, str) or not token:
        raise Infrastructure("registry-auth", f"{url} returned no token")
    return token


def registry_get(image_repo: str, path: str, token: str, accept: str, policy: Policy) -> Reply:
    url = f"{REGISTRY}{path}"
    reply = http_get(url, {"Accept": accept, "Authorization": f"Bearer {token}"}, policy.user_agent)
    if reply.status == 401:
        # An anonymous token is short-lived; one refresh, never a loop.
        reply = http_get(
            url,
            {
                "Accept": accept,
                "Authorization": f"Bearer {registry_token(image_repo, policy)}",
            },
            policy.user_agent,
        )
        if reply.status == 401:
            raise Infrastructure("registry-auth", f"{url} refused an anonymous token")
    if reply.status in (403, 429):
        check(decisions.rate_limited(reply.status, url))
    return reply


@dataclass(frozen=True)
class Resolved:
    token: str
    tag: str
    index: str
    manifest: str
    document: dict[str, Any]


def resolve_digests(image_repo: str, commit: str, policy: Policy) -> Resolved:
    """The digest pair for `sha-<commit[:12]>`, from the tag alone.

    The caller supplies a commit and never a digest, so the tag name plus the
    image's own revision label is what binds the two. Both forms are resolved
    because bootc reports either the index digest or the platform manifest
    digest, and the host's gate has to accept whichever it reports.
    """
    tag = decisions.tag_for(commit)
    token = registry_token(image_repo, policy)
    base = f"/v2/{image_repo}"
    reference = f"{base}/manifests/{tag}"
    reply = registry_get(image_repo, reference, token, INDEX_ACCEPT, policy)
    # A missing tag is a fact, and what it means is this host's: the policy names
    # the verdict and the reason, so a host that publishes on every image-bearing
    # commit answers "never deployable" where one that publishes on its own tree's
    # changes answers "not yet".
    answer = decisions.tag_reference(reply.status, image_repo, tag, reference)
    if answer.kind == decisions.NOT_DEPLOYABLE:
        raise FAILURES[policy.missing_kind](policy.missing_reason, answer.detail)
    check(answer)
    document = _document(reply, reference)
    served_index = reply.headers.get("docker-content-digest")
    index_digest = check(decisions.checked_digest(served_index, "Docker-Content-Digest")).value
    children = document.get("manifests")
    if children is None:
        # A tag that points straight at the platform manifest: the two forms are
        # the same digest, which is what the gate will see.
        return Resolved(token, tag, index_digest, index_digest, document)
    manifest_digest = check(decisions.amd64_digest(children, f"{image_repo}:{tag}")).value
    path = f"{base}/manifests/{manifest_digest}"
    reply = registry_get(image_repo, path, token, INDEX_ACCEPT, policy)
    if reply.status != 200:
        check(decisions.http_failure(reply.status, path))
    manifest = _document(reply, path)
    served = reply.headers.get("docker-content-digest")
    if served != manifest_digest:
        # The registry answered with something other than what the index named;
        # recording either digest would be recording a guess.
        raise Infrastructure("registry-response", f"{path} is {served!r}, not that digest")
    return Resolved(token, tag, index_digest, manifest_digest, manifest)


def revision_label(resolved: Resolved, image_repo: str, policy: Policy) -> str:
    """The commit the image itself says it was built from."""
    digest = check(decisions.config_digest(resolved.document)).value
    path = f"/v2/{image_repo}/blobs/{digest}"
    reply = registry_get(image_repo, path, resolved.token, "*/*", policy)
    if reply.status != 200:
        check(decisions.http_failure(reply.status, path))
    answer = decisions.revision_label(_document(reply, path), image_repo, resolved.tag)
    check(answer)
    return answer.value


# -- the deploy gate: bootc's signature verdict ------------------------------


def last_line(detail: str) -> str:
    """The one line of gate output a journal can carry.

    bootc prints a warning or two before the error, and the error is the last
    thing on stderr; the whole of it would be a journal line nobody reads.
    """
    lines = [line.strip() for line in detail.splitlines() if line.strip()]
    return lines[-1][:400] if lines else ""


def signature_refused(output: str) -> bool:
    """Did bootc refuse the image, rather than fail to reach it?"""
    text = output.lower()
    return any(marker in text for marker in SIGNATURE_REFUSALS)


def switch(resolved: Resolved, image_repo: str) -> None:
    """Run the one signature check the system has, and read its exit code.

    Pinned by digest, so the image the policy accepts is the image whose revision
    label this run read. `--enforce-container-sigpolicy` is what enforces the
    policy.json the image ships; nothing here inspects a signature, because a
    second implementation of a security property is the likeliest silent
    weakening in the path.

    A refusal is final and is a verdict about the image; every other failure -- a
    refused connection, a full image store, the deadline -- says nothing about the
    image and stays retryable, which is why only the text bootc prints for a
    policy rejection may become the refusal. A switch stages a boot entry and
    never applies it: the reboot is the deploy, and the drain owns it.
    """
    reference = f"{image_repo}@{resolved.manifest}"
    command = [BOOTC_BIN, "switch", "--enforce-container-sigpolicy", reference]
    try:
        completed = subprocess.run(
            command,
            capture_output=True,
            text=True,
            errors="replace",
            timeout=SWITCH_TIMEOUT,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        raise Infrastructure(
            "timeout", f"{' '.join(command)}: no answer in {SWITCH_TIMEOUT:.0f}s"
        ) from error
    except OSError as error:
        raise Infrastructure("bootc-missing", f"{BOOTC_BIN}: {error}") from error
    if completed.returncode == 0:
        return
    output = f"{completed.stderr}\n{completed.stdout}"
    if signature_refused(output):
        raise Refused("signature-rejected", last_line(output))
    raise Infrastructure(
        "switch-failed", f"{reference}: exit {completed.returncode}: {last_line(output)}"
    )


# The gates a host may put between the verified label and its verdict, keyed by
# the word its policy names. A host whose policy names none verifies the image
# and stages nothing. Adding a host with a different gate is a registration here,
# not a branch in the verification.
GATES = {"bootc-switch": switch}


def stage(policy: Policy, resolved: Resolved, image_repo: str) -> None:
    """Ask this host's deploy gate about the verified image, if it has one."""
    gate = GATES.get(policy.signature_gate or "")
    if gate is not None:
        gate(resolved, image_repo)


# -- the policy table -------------------------------------------------------


@dataclass(frozen=True)
class Policy:
    """This host's half of the verification: the inputs, never the behaviour.

    Every row here was a line one host's copy of this file had and the other's
    did not. Read from `lib/deploy/policy.d/<host>.json`, installed as
    /usr/libexec/deploy/policy.json. The two tables differ in:

    - `repos`: the server deploys the platform and the apps tenant; the edge
      deploys the platform alone, because it has no apps tenant at all.
    - `images`: one platform, two image repositories. A repository absent from
      this map deploys without an image -- its commit is verified for tip and
      descendancy, and nothing is fetched from a registry.
    - `api_cache_ttl`: 120 s on the server, where a burst of events and the poll
      behind it must spend one anonymous call; 0 on the edge, where a
      quarter-hour poll over one repository protects no budget.
    - `missing_artifact`: `not-deployable` on the server, where a docs-only
      commit never gets an image and never will; `infrastructure` on the edge,
      where the image is built only when the edge's tree moves, so an absent tag
      may be a publish still in flight and the entry must keep its place.
    - `signature_gate`: none on the server, whose snapshot gate judges the image
      after the reboot; `bootc-switch` on the edge, where bootc's policy exit
      code is the only signature verdict in the system.

    `user_agent` is the name the registry sees, and `role` is the name this table
    is compared under: scripts/check-lib-drift.sh holds `repos` and `images` to
    the shared role table in bootc/lib/deploy/decisions.py, which is also what the
    drain refuses a queued request by. Both are rows here because naming a host is
    the one thing this program must never do.
    """

    role: str
    repos: tuple[str, ...]
    images: dict[str, str]
    user_agent: str
    api_cache_ttl: int
    missing_kind: str
    missing_reason: str
    signature_gate: str | None

    def image_for(self, repo: str) -> str | None:
        """The image repository this host resolves `repo`'s commits out of.

        None means the repository deploys without an image: its commit is
        verified for tip and descendancy and nothing is fetched from a registry.
        """
        return self.images.get(repo)


def policy_path() -> str:
    """The table to run by: the one a checkout names, else the installed one.

    A named table that is not there is an error rather than a fallback: a suite
    that pointed this at the edge's table and silently ran the server's would
    prove the wrong host.
    """
    explicit = os.environ.get("DEPLOY_VERIFY_POLICY", "")
    if explicit:
        if not os.path.isfile(explicit):
            raise SystemExit(f"deploy-verify: DEPLOY_VERIFY_POLICY names no file: {explicit}")
        return explicit
    if not os.path.isfile(INSTALLED_POLICY):
        raise SystemExit(
            f"deploy-verify: no policy table: DEPLOY_VERIFY_POLICY is unset and "
            f"{INSTALLED_POLICY} does not exist"
        )
    return INSTALLED_POLICY


def _text(document: dict[str, Any], key: str, path: str) -> str:
    value = document.get(key)
    if not isinstance(value, str) or not value:
        raise SystemExit(f"deploy-verify: {path}: {key} must be a non-empty string")
    return value


def load_policy(path: str) -> Policy:
    """Read one host's table, refusing a table this program cannot act on.

    A malformed table is a broken image, not a deploy verdict, so it exits before
    a single check runs: a verifier that guessed at half a policy would answer
    with the other host's allowlist.
    """
    try:
        with open(path, "rb") as handle:
            document = json.loads(handle.read())
    except OSError as error:
        raise SystemExit(f"deploy-verify: no policy table at {path}: {error}") from error
    except ValueError as error:
        raise SystemExit(f"deploy-verify: {path} is not JSON: {error}") from error
    if not isinstance(document, dict):
        raise SystemExit(f"deploy-verify: {path} is not a JSON object")

    repos = document.get("repos")
    if not isinstance(repos, list) or not repos or not all(
        isinstance(repo, str) and repo for repo in repos
    ):
        raise SystemExit(f"deploy-verify: {path}: repos must be a non-empty list of names")
    images = document.get("images", {})
    if not isinstance(images, dict) or not all(
        isinstance(repo, str) and isinstance(image, str) and image
        for repo, image in images.items()
    ):
        raise SystemExit(f"deploy-verify: {path}: images must map a repository to an image")
    foreign = sorted(set(images) - set(repos))
    if foreign:
        raise SystemExit(
            f"deploy-verify: {path}: images names repositories this host does not deploy: "
            f"{' '.join(foreign)}"
        )
    ttl = document.get("api_cache_ttl", 0)
    if not isinstance(ttl, int) or isinstance(ttl, bool) or ttl < 0:
        raise SystemExit(f"deploy-verify: {path}: api_cache_ttl must be whole seconds")
    missing = document.get("missing_artifact")
    if not isinstance(missing, dict):
        raise SystemExit(f"deploy-verify: {path}: missing_artifact must be an object")
    kind = missing.get("kind")
    if kind not in FAILURES:
        raise SystemExit(
            f"deploy-verify: {path}: missing_artifact.kind must be one of "
            f"{' '.join(sorted(FAILURES))}"
        )
    gate = document.get("signature_gate")
    if gate is not None and gate not in GATES:
        raise SystemExit(
            f"deploy-verify: {path}: signature_gate must be null or one of "
            f"{' '.join(sorted(GATES))}"
        )
    return Policy(
        role=_text(document, "role", path),
        repos=tuple(repos),
        images={repo: image for repo, image in images.items()},
        user_agent=_text(document, "user_agent", path),
        api_cache_ttl=ttl,
        missing_kind=kind,
        missing_reason=_text(missing, "reason", path),
        signature_gate=gate,
    )


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

    Never inferred: without a recorded ancestor there is no descendancy to check,
    and guessing one is how an older image gets staged over a newer host.
    """
    if not os.path.exists(STATE_FILE):
        raise Refused("bootstrap-required", f"{STATE_FILE} is absent")
    document = _read_json(STATE_FILE)
    if not isinstance(document, dict):
        # A record that will not parse cannot be trusted as an ancestor either.
        raise Refused("bootstrap-required", f"{STATE_FILE} is unreadable")
    commit = decisions.deployed_commit(document, repo)
    if commit is None:
        raise Refused("bootstrap-required", f"no deployed commit for {repo}")
    return commit


def denylisted(table: str, value: str) -> bool:
    """The host's own refusal list: commits, platform image digests, either form."""
    if not os.path.exists(DENYLIST_FILE):
        return False
    document = _read_json(DENYLIST_FILE)
    if not isinstance(document, dict):
        # Fail closed: a list that will not parse is not an empty list.
        raise Infrastructure("denylist-unreadable", DENYLIST_FILE)
    return decisions.denylisted(document, table, value)


# -- the ordered verification -----------------------------------------------


def verify(policy: Policy, repo: str, commit: str) -> dict[str, Any]:
    if repo not in policy.repos:
        # argparse already refuses it; a caller that renamed the flag still meets
        # this, and it costs one comparison to keep the allowlist unskippable.
        raise Refused("unsupported-repo", f"{repo} is not a repository this host deploys")
    deployed = deployed_commit(repo)
    # Cheapest check first: a denied commit spends no API budget at all.
    if denylisted(decisions.COMMITS, commit):
        raise Refused("denylisted", f"{commit} is on the denylist")
    cache: Cache | NoCache = (
        Cache(CACHE_FILE, policy.api_cache_ttl) if policy.api_cache_ttl else NoCache()
    )
    current = tip(repo, cache, policy)
    if current != commit:
        raise Refused("tip-mismatch", f"main is at {current}")
    if deployed == commit:
        # Reachable only through a race with a poll; the drain treats an
        # already-deployed entry as a no-op before it gets here.
        raise Refused("already-deployed", commit)
    descendancy(repo, deployed, commit, cache, policy)
    # Key order is one document for both hosts: the drain and the golden fixtures
    # read one verdict shape, whichever policy answered.
    verdict: dict[str, Any] = {
        "verdict": decisions.VERDICT_VERIFIED,
        "repo": repo,
        "commit": commit,
        "deployed": deployed,
        "tip": current,
        "descendancy": "ahead",
        "digests": None,
    }
    image_repo = policy.image_for(repo)
    if image_repo is None:
        return verdict
    resolved = resolve_digests(image_repo, commit, policy)
    for digest in (resolved.index, resolved.manifest):
        if denylisted(decisions.DIGESTS, digest):
            # Refused before the config blob is fetched: a denied image's label
            # does not matter, and this is one request saved per denial.
            raise Refused("denylisted", f"{digest} is on the denylist")
    revision = revision_label(resolved, image_repo, policy)
    if revision != commit:
        raise Refused("revision-mismatch", f"{resolved.tag} claims {revision}")
    # The label is the last shared question. What follows is this host's gate,
    # and on the host that has one its exit 0 is the run's only state change: the
    # verified digest is now the staged boot entry.
    stage(policy, resolved, image_repo)
    verdict["digests"] = {"index": resolved.index, "manifest": resolved.manifest}
    verdict["revision"] = revision
    return verdict


def emit(document: dict[str, Any]) -> None:
    """One line: the drain reads it with jq and journals it verbatim."""
    sys.stdout.write(json.dumps(document, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def main(argv: list[str]) -> int:
    policy = load_policy(policy_path())
    parser = argparse.ArgumentParser(
        prog="deploy-verify",
        description="Verify a proposed deploy's commit, image, revision label and gate verdict.",
    )
    parser.add_argument("--repo", required=True, choices=tuple(sorted(policy.repos)))
    parser.add_argument("--commit", required=True)
    args = parser.parse_args(argv)
    if not decisions.is_commit(args.commit):
        log("--commit must be a 40-character lowercase hex sha")
        return 2
    try:
        verdict = verify(policy, args.repo, args.commit)
    except Failure as failure:
        emit(failure.document(args.repo, args.commit))
        message = f"{args.repo} {args.commit}: {MESSAGES[failure.kind]} ({failure.reason})"
        log(f"{message} {failure.detail}".rstrip() if failure.detail else message)
        return failure.code
    emit(verdict)
    log(f"{args.repo} {args.commit}: verified")
    return decisions.EXIT_CODES[decisions.VERDICT_VERIFIED]


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
