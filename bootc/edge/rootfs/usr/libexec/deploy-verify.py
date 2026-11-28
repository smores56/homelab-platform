#!/usr/bin/env python3
"""Verify a proposed deploy on the edge before anything changes (design #939, T6).

The edge runs the server's wire contract with a smaller repo allowlist and no
apps tenant, so the questions themselves -- the allowlist, the tag name, the
digest and label shapes, descendancy, the state and denylist records -- are the
server's pure functions in bootc/lib/deploy/decisions.py. They are consumed, not
copied: this file is the edge role's I/O and the two answers that are the edge's
own.

The artifact is `smores56/homelab-platform/edge:sha-<c12>`, and the publish
workflow builds it only for the commits that touch the edge's tree. So a tag that
is absent is not the verdict it is on the server (where a docs-only main commit
never gets a server image either, and never will): the edge image may be midway
through its publish, the next request for this repository supersedes the entry
rather than waiting behind it, and popping the entry would mean the merge that
does touch the edge tree is the only one it ever deploys. The answer is
`no-artifact` and the entry is held -- exit 4, the retry stamp, the same hold the
drain already gives a failure to verify.

The signature verdict is bootc's and no one else's. `bootc switch
--enforce-container-sigpolicy` is the only thing in the system that answers it
(docs/core/server-image.md, "Signature enforcement"; deploy-platform.sh is the
server's use of the same call), so the switch runs here, names the digest this
verification just resolved -- never the tag, which could move between the label
read and the switch -- and its exit code is the answer. That is the one place
this verifier is not read-only: a switch stages a boot entry and never applies
it, because the reboot is the deploy and the drain owns it. Exit 0 means exactly
the verified digest was staged, so the edge's role hook must not switch again.

Exit 0 verified (one JSON object on stdout, byte-identical to the server's for the
same document so the drain and the fixtures read one verdict), 3 rejected, 4
infrastructure -- the shared vocabulary. Nothing here writes a file: the server's
120 s cache protects an API budget a quarter-hour poll spends steadily, and a
verifier that writes nothing is one fewer writer under a lock it does not hold.

Stdlib only, like the receiver: the image installs no distribution package, and
this program ships in it beside the decisions it calls.
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import subprocess
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any


# The policy tables and the pure checks are shared with the server
# (bootc/lib/deploy/decisions.py). The image installs them at /usr/libexec/deploy
# and a checkout has them under bootc/lib; the program's own directory is
# searched first, so a suite run on a host that carries an image never tests the
# installed copy of the shared code.
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
        "deploy-verify: no decisions.py beside this program, in the checkout or in "
        "/usr/libexec/deploy"
    )


sys.path.insert(0, _decisions_dir())
import decisions  # noqa: E402  # the path above is what makes it importable

STATE_DIR = os.environ.get("DEPLOY_STATE_DIR", "/var/lib/homelab/deploy")
GITHUB_API = os.environ.get("DEPLOY_GITHUB_API", "https://api.github.com").rstrip("/")
REGISTRY = os.environ.get("DEPLOY_REGISTRY", "https://ghcr.io").rstrip("/")
# One deadline per call, not per run: a wedged TLS read on one request must not
# spend the time the remaining checks need, and the drain bounds the whole call.
TIMEOUT = float(os.environ.get("DEPLOY_VERIFY_TIMEOUT", "30"))
# The switch is the one call here that pulls an image, so it gets its own
# deadline. The drain bounds the verifier as a whole (`DEPLOY_VERIFY_DEADLINE`);
# the edge sets that above this, or a slow pull is killed mid-stage.
BOOTC_BIN = os.environ.get("BOOTC_BIN", "bootc")
SWITCH_TIMEOUT = float(os.environ.get("DEPLOY_SWITCH_TIMEOUT", "600"))

STATE_FILE = os.path.join(STATE_DIR, "state.json")
DENYLIST_FILE = os.path.join(STATE_DIR, "denylist.json")

# The edge role's policy table: one repository, and the image repository its
# tags, digests and revision label are resolved out of. It is the same table the
# receiver enforces at the door, so an apps request cannot reach here.
ROLE = decisions.role(decisions.EDGE)
REPOS = tuple(sorted(ROLE.repos))
IMAGE_REPO = ROLE.image_repo
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
    rather than only the words.
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


class Infrastructure(Failure):
    """No verdict at all: exit 4, the entry keeps its place and is retried."""


class NoArtifact(Failure):
    """The edge image for this commit is not published: hold, never pop.

    Exit 4 like any other failure to verify, because that is what the shared
    drain already does with one: the entry keeps its slot, carries a `retry_at`
    and is superseded by the next request for this repository. The edge has no
    not-deployable verdict at all -- the one document the server calls that is
    this role's hold, and replaying the fixtures is what holds the two roles to
    that difference being the only one.
    """


def _check(answer: decisions.Decision) -> decisions.Decision:
    """The one place a shared answer becomes this role's exception.

    Only the two outcomes reach the edge: a refusal, and a failure to verify.
    `not-deployable` is the server's -- see `NoArtifact` for why.
    """
    if answer.ok:
        return answer
    if answer.kind == decisions.REFUSE:
        raise Refused(answer.reason, answer.detail)
    raise Infrastructure(answer.reason, answer.detail)


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

    A 4xx is returned rather than raised: a missing tag is a fact about the
    image and only the caller knows what a status means there. Transport trouble
    is not a verdict about anything and becomes an infrastructure failure.
    """
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "smoresnet-deploy-verify", **(headers or {})},
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


def _document(reply: Reply, url: str) -> dict[str, Any]:
    document = reply.json()
    if not isinstance(document, dict):
        raise Infrastructure("bad-response", f"{url} is not a JSON object")
    return document


# -- GitHub: the tip and the commit graph -----------------------------------


def github_get(path: str) -> Reply:
    url = f"{GITHUB_API}{path}"
    reply = http_get(url, {"Accept": "application/vnd.github+json"})
    # An exhausted anonymous budget is about the API, not about the commit.
    if reply.status in (403, 429):
        _check(decisions.rate_limited(reply.status, url))
    return reply


def tip(repo: str) -> str:
    """What `main` points at now, not what the caller claimed."""
    path = f"/repos/{decisions.OWNER}/{repo}/git/ref/heads/main"
    url = f"{GITHUB_API}{path}"
    reply = github_get(path)
    if reply.status != 200:
        _check(decisions.http_failure(reply.status, url))
    answer = decisions.tip_from(_document(reply, url), url)
    _check(answer)
    return answer.value


def descendancy(repo: str, deployed: str, commit: str) -> None:
    """One request answers "does the deployed commit come first?"."""
    path = f"/repos/{decisions.OWNER}/{repo}/compare/{deployed}...{commit}"
    url = f"{GITHUB_API}{path}"
    reply = github_get(path)
    _check(decisions.compare(reply.status, reply.json(), url))


# -- the registry: tag -> digests -> revision label -------------------------


def registry_token() -> str:
    url = f"{REGISTRY}/token?service=ghcr.io&scope=repository:{IMAGE_REPO}:pull"
    reply = http_get(url, {"Accept": "application/json"})
    if reply.status in (403, 429):
        _check(decisions.rate_limited(reply.status, url))
    if reply.status != 200:
        _check(decisions.http_failure(reply.status, url))
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
        _check(decisions.rate_limited(reply.status, url))
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

    Both forms are resolved because bootc reports either the index digest or the
    platform manifest digest, and the edge's gate has to accept whichever it
    reports; the switch below names the manifest form, the image a host boots.
    """
    tag = decisions.tag_for(commit)
    token = registry_token()
    base = f"/v2/{IMAGE_REPO}"
    reference = f"{base}/manifests/{tag}"
    reply = registry_get(reference, token, INDEX_ACCEPT)
    # A 404 is the edge's hold, not the server's verdict: the switch is the only
    # thing that may act on an absent tag, and it must not. The shared step names
    # the reason for the server's journal (`tag-missing`, final); the edge's word
    # for the same fact is `no-artifact`, because on this host it is not final.
    answer = decisions.tag_reference(reply.status, IMAGE_REPO, tag, reference)
    if answer.kind == decisions.NOT_DEPLOYABLE:
        raise NoArtifact("no-artifact", answer.detail)
    _check(answer)
    document = _document(reply, reference)
    served_index = decisions.checked_digest(
        reply.headers.get("docker-content-digest"), "Docker-Content-Digest"
    )
    index_digest = _check(served_index).value
    children = document.get("manifests")
    if children is None:
        # A tag that points straight at the platform manifest: the two forms are
        # the same digest, which is what bootc will report.
        return Resolved(token, tag, index_digest, index_digest, document)
    manifest_digest = _check(decisions.amd64_digest(children, f"{IMAGE_REPO}:{tag}")).value
    path = f"{base}/manifests/{manifest_digest}"
    reply = registry_get(path, token, INDEX_ACCEPT)
    if reply.status != 200:
        _check(decisions.http_failure(reply.status, path))
    manifest = _document(reply, path)
    served = reply.headers.get("docker-content-digest")
    if served != manifest_digest:
        # The registry answered with something other than what the index named;
        # staging either digest would be staging a guess.
        raise Infrastructure("registry-response", f"{path} is {served!r}, not that digest")
    return Resolved(token, tag, index_digest, manifest_digest, manifest)


def revision_label(resolved: Resolved) -> str:
    """The commit the image itself says it was built from."""
    digest = _check(decisions.config_digest(resolved.document)).value
    path = f"/v2/{IMAGE_REPO}/blobs/{digest}"
    reply = registry_get(path, resolved.token, "*/*")
    if reply.status != 200:
        _check(decisions.http_failure(reply.status, path))
    answer = decisions.revision_label(_document(reply, path), IMAGE_REPO, resolved.tag)
    _check(answer)
    return answer.value


# -- bootc: the signature verdict -------------------------------------------


def last_line(detail: str) -> str:
    """The one line of bootc's output a journal can carry.

    bootc prints a warning or two before the error, and the error is the last
    thing on stderr; the whole of it would be a journal line nobody reads.
    """
    lines = [line.strip() for line in detail.splitlines() if line.strip()]
    return lines[-1][:400] if lines else ""


def signature_refused(output: str) -> bool:
    """Did bootc refuse the image, rather than fail to reach it?"""
    text = output.lower()
    return any(marker in text for marker in SIGNATURE_REFUSALS)


def switch(resolved: Resolved) -> None:
    """Run the one signature check the system has, and read its exit code.

    Pinned by digest, so the image the policy accepts is the image whose revision
    label this run read. `--enforce-container-sigpolicy` is what enforces the
    policy.json the image ships (ghcr.io/smores56/homelab-platform -> the
    repository's cosign key); nothing here inspects a signature, because a second
    implementation of a security property is the likeliest silent weakening in
    the path.

    A refusal is final and is a verdict about the image; every other failure --
    a refused connection, a full image store, the deadline -- says nothing about
    the image and stays retryable, which is why only the text bootc prints for a
    policy rejection may become the refusal.
    """
    reference = f"{IMAGE_REPO}@{resolved.manifest}"
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
    commit = decisions.deployed_commit(document, repo)
    if commit is None:
        raise Refused("bootstrap-required", f"no deployed commit for {repo}")
    return commit


def denylisted(table: str, value: str) -> bool:
    """The host's own refusal list: commits and platform image digests."""
    if not os.path.exists(DENYLIST_FILE):
        return False
    document = _read_json(DENYLIST_FILE)
    if not isinstance(document, dict):
        # Fail closed: a list that will not parse is not an empty list.
        raise Infrastructure("denylist-unreadable", DENYLIST_FILE)
    return decisions.denylisted(document, table, value)


# -- the ordered verification -----------------------------------------------


def verify(repo: str, commit: str) -> dict[str, Any]:
    if not decisions.allows(ROLE.name, repo):
        # argparse already refuses it; a caller that renamed the flag still meets
        # this, and it costs one comparison to keep the allowlist unskippable.
        raise Refused("unsupported-repo", f"{repo} is not a repository the edge deploys")
    deployed = deployed_commit(repo)
    # Cheapest check first: a denied commit spends no API budget at all.
    if denylisted(decisions.COMMITS, commit):
        raise Refused("denylisted", f"{commit} is on the denylist")
    current = tip(repo)
    if current != commit:
        raise Refused("tip-mismatch", f"main is at {current}")
    if deployed == commit:
        # Reachable only through a race with a poll; the drain treats an
        # already-deployed entry as a no-op before it gets here.
        raise Refused("already-deployed", commit)
    descendancy(repo, deployed, commit)
    resolved = resolve_digests(commit)
    for digest in (resolved.index, resolved.manifest):
        if denylisted(decisions.DIGESTS, digest):
            # Refused before the config blob is fetched: a denied image's label
            # does not matter, and this is one request saved per denial.
            raise Refused("denylisted", f"{digest} is on the denylist")
    revision = revision_label(resolved)
    if revision != commit:
        raise Refused("revision-mismatch", f"{resolved.tag} claims {revision}")
    # The server's verification ends at the label; the edge's last question is
    # the signature, and bootc is the only thing allowed to answer it. Its exit 0
    # is also this run's only state change: the verified digest is now the
    # staged boot entry.
    switch(resolved)
    # Key order is the server's verified document, byte for byte: the drain reads
    # one verdict shape from both hosts, and the golden fixture is the same file.
    return {
        "verdict": decisions.VERDICT_VERIFIED,
        "repo": repo,
        "commit": commit,
        "deployed": deployed,
        "tip": current,
        "descendancy": "ahead",
        "digests": {"index": resolved.index, "manifest": resolved.manifest},
        "revision": revision,
    }


def emit(document: dict[str, Any]) -> None:
    """One line: the drain reads it with jq and journals it verbatim."""
    sys.stdout.write(json.dumps(document, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="deploy-verify",
        description="Verify a proposed deploy's edge image, revision label and signature.",
    )
    parser.add_argument("--repo", required=True, choices=REPOS)
    parser.add_argument("--commit", required=True)
    args = parser.parse_args(argv)
    if not decisions.is_commit(args.commit):
        log("--commit must be a 40-character lowercase hex sha")
        return 2
    try:
        verdict = verify(args.repo, args.commit)
    except Refused as failure:
        emit(failure.document(args.repo, args.commit))
        log(f"{args.repo} {args.commit}: rejected ({failure.reason}) {failure.detail}".rstrip())
        return failure.code
    except NoArtifact as failure:
        # The hold, named: no image exists yet, and the entry keeps its place for
        # the retry timer rather than being popped like the server's tag-missing.
        emit(failure.document(args.repo, args.commit))
        log(f"{args.repo} {args.commit}: no artifact yet ({failure.reason}) {failure.detail}".rstrip())
        return failure.code
    except Infrastructure as failure:
        emit(failure.document(args.repo, args.commit))
        log(f"{args.repo} {args.commit}: could not verify ({failure.reason}) {failure.detail}".rstrip())
        return failure.code
    emit(verdict)
    log(f"{args.repo} {args.commit}: verified")
    return decisions.EXIT_CODES[decisions.VERDICT_VERIFIED]


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
