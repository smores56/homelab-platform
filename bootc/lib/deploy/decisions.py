"""The deploy decision, shared by every role that receives a deploy request.

The host answers one question -- may this commit deploy -- and answers it in two
places: the receiver refuses a request at the door, and the verifier refuses a
commit after asking GitHub and the registry. The edge image (#939) receives the
same wire contract with a smaller repo allowlist, so the answers that are policy
-- the allowlist, the tag name, the digest and label shapes, descendancy, the
journal vocabulary, the coalesce key, the state and denylist records -- live
here once, as pure functions over data, and each role keeps only its I/O.

Two rules keep this file shareable:

- nothing here does I/O, reads the clock, or raises. Every step answers with a
  `Decision`, and the caller turns that into its own exit code, exception or
  journal line. That is what lets a golden fixture (bootc/lib/deploy/fixtures/)
  assert the outcome without a host, a network or a token;
- every reason string is the one the journal already carries, so moving a check
  here changes no record an operator reads.

Stdlib only, and it ships in both bootc images.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from typing import Any

# -- roles and the policy tables --------------------------------------------

SERVER = "server"
EDGE = "edge"

PLATFORM = "homelab-platform"
APPS = "homelab-apps"
OWNER = "smores56"

# Must match IMAGE_REPO in bootc/lib/pins.env: the tag, both digests and the
# revision label are all resolved out of this one repository.
IMAGE_REPO = "smores56/homelab-platform/server"
EDGE_IMAGE_REPO = "smores56/homelab-platform/edge"
REVISION_LABEL = "org.opencontainers.image.revision"


@dataclass(frozen=True)
class Role:
    """What one host is allowed to deploy, and the image it deploys from."""

    name: str
    repos: frozenset[str]
    image_repo: str


# The allowlist is the receiver's, not the drain's: an entry for a repository a
# host does not run would occupy a queue slot and lock out the ones it does. The
# edge runs the platform plane only -- it has no apps tenant, so an apps request
# is refused at the door rather than queued and then failed downstream.
ROLES = {
    SERVER: Role(SERVER, frozenset({PLATFORM, APPS}), IMAGE_REPO),
    EDGE: Role(EDGE, frozenset({PLATFORM}), EDGE_IMAGE_REPO),
}


def role(name: str) -> Role:
    """The policy table for a role name; an unknown role is a programming error."""
    try:
        return ROLES[name]
    except KeyError:
        raise ValueError(f"unknown deploy role {name!r}") from None


def allows(role_name: str, repo: Any) -> bool:
    """Does this role accept a request for this repository?"""
    return isinstance(repo, str) and repo in role(role_name).repos


# -- shapes -----------------------------------------------------------------

COMMIT_PATTERN = r"^[0-9a-f]{40}$"
DIGEST_PATTERN = r"^sha256:[0-9a-f]{64}$"
NONCE_PATTERN = r"^[0-9a-f]{32}$"

COMMIT_RE = re.compile(COMMIT_PATTERN)
DIGEST_RE = re.compile(DIGEST_PATTERN)
NONCE_RE = re.compile(NONCE_PATTERN)

HEX = frozenset("0123456789abcdef")


def is_commit(value: Any) -> bool:
    return isinstance(value, str) and COMMIT_RE.match(value) is not None


def is_digest(value: Any) -> bool:
    return isinstance(value, str) and DIGEST_RE.match(value) is not None


def is_nonce(value: Any) -> bool:
    return isinstance(value, str) and NONCE_RE.match(value) is not None



# -- the tag -----------------------------------------------------------------

TAG_PREFIX = "sha-"
TAG_LENGTH = 12


def tag_for(commit: str) -> str:
    """The publish workflow's tag for a commit: `sha-<first 12>`, nothing else."""
    return f"{TAG_PREFIX}{commit[:TAG_LENGTH]}"


def parse_tag(tag: Any) -> str | None:
    """The 12-character commit prefix a tag names, or None when it is not ours.

    The reverse direction exists for the receiver and the gate, which see a tag
    that arrived from outside and must refuse one that is not this shape rather
    than slice it and hope.
    """
    if not isinstance(tag, str) or not tag.startswith(TAG_PREFIX):
        return None
    prefix = tag[len(TAG_PREFIX) :]
    if len(prefix) != TAG_LENGTH or any(char not in HEX for char in prefix):
        return None
    return prefix


# -- the decision vocabulary -------------------------------------------------

OK = "ok"
REFUSE = "refuse"
NOT_DEPLOYABLE = "not-deployable"
INFRASTRUCTURE = "infrastructure"

# The verdict words the verifier prints and the drain reads back out of the
# verdict document, each with the exit code that carries it. The split is the
# contract: a refusal is a verdict about the commit and is never retried, while a
# failure to verify says nothing about the commit and must stay retryable.
VERDICT_VERIFIED = "verified"
VERDICT_REJECTED = "rejected"
VERDICT_NOT_DEPLOYABLE = "not-deployable"
VERDICT_INFRA = "infra-failure"

EXIT_CODES = {
    VERDICT_VERIFIED: 0,
    VERDICT_REJECTED: 3,
    VERDICT_INFRA: 4,
    VERDICT_NOT_DEPLOYABLE: 5,
}


@dataclass(frozen=True)
class Decision:
    """One step's answer: what it decided, why, and the value it accepted.

    `reason` and `detail` are the strings that already reach the journal, so a
    caller that translates this into an exception keeps every record it wrote
    before the check lived here.
    """

    kind: str = OK
    reason: str = ""
    detail: str = ""
    value: str = ""

    @property
    def ok(self) -> bool:
        return self.kind == OK

    def verdict(self) -> str:
        """The verdict word for a step that ended the verification."""
        return {
            REFUSE: VERDICT_REJECTED,
            NOT_DEPLOYABLE: VERDICT_NOT_DEPLOYABLE,
            INFRASTRUCTURE: VERDICT_INFRA,
        }.get(self.kind, VERDICT_VERIFIED)

    def document(self, repo: str, commit: str) -> dict[str, Any]:
        """The one-line answer the drain reads with jq, for a non-ok decision.

        Byte-identical to what the verifier printed before the decision moved:
        one object, key order `verdict, reason, repo, commit, detail`.
        """
        answer: dict[str, Any] = {
            "verdict": self.verdict(),
            "reason": self.reason,
            "repo": repo,
            "commit": commit,
        }
        if self.detail:
            answer["detail"] = self.detail
        return answer


def ok(value: str = "") -> Decision:
    return Decision(OK, value=value)


def refuse(reason: str, detail: str = "") -> Decision:
    return Decision(REFUSE, reason=reason, detail=detail)


def not_deployable(reason: str, detail: str = "") -> Decision:
    return Decision(NOT_DEPLOYABLE, reason=reason, detail=detail)


def infrastructure(reason: str, detail: str = "") -> Decision:
    return Decision(INFRASTRUCTURE, reason=reason, detail=detail)


# -- the journal -------------------------------------------------------------

# Every event this end of the wire writes. The names are read by operators and by
# `smortress-deploy status`, so they are data here: a new event is a vocabulary
# change, and the tests hold the Python and the shell to this list.
JOURNAL_EVENTS = frozenset(
    {
        # the listener, before anything else looks at the request
        "deploy-rejected",
        "queue-enqueued",
        "queue-failed",
        "already-deployed",
        # the drain's own progress
        "drain-start",
        "drain-parked",
        "drain-finish",
        "queue-superseded",
        "queue-invalid",
        # the verdict
        "verified",
        "verify-rejected",
        "verify-infra-failure",
        "verify-not-deployable",
        "deferred",
        # the action the verdict authorized
        "stage-already-booted",
        "apply-reverted",
        # the records this end writes about itself (scripts/deploy-state.sh)
        "state-verified",
        "state-reconciled",
        "notify-sent",
        "notify-failed",
        "notify-skipped",
    }
)


def journal_line(timestamp: str, event: str, fields: dict[str, Any] | None = None) -> str:
    """One journal line: the timestamp and the event first, the details after.

    Compact separators, because the listener fsyncs one line per request and a
    shell reader greps it; the drain and the listener have to write the same
    bytes or `jq .event` would need two readers.
    """
    line = {"ts": timestamp, "event": event}
    line.update(fields or {})
    return json.dumps(line, separators=(",", ":"))


# -- the host's own records --------------------------------------------------


def deployed_commit(state: Any, repo: str) -> str | None:
    """`.repos.<repo>.commit` when it is a commit, and None otherwise.

    Never inferred: without a recorded ancestor there is no descendancy to
    check, and guessing one is how an older image gets staged over a newer host.
    A caller that needs the absence to be a refusal raises on the None; the
    listener, which only answers "already deployed", treats it as "no".
    """
    repos = state.get("repos") if isinstance(state, dict) else None
    entry = repos.get(repo) if isinstance(repos, dict) else None
    commit = entry.get("commit") if isinstance(entry, dict) else None
    return commit if is_commit(commit) else None


def recorded_commit(state: Any, repo: str) -> str | None:
    """The listener's read: a non-empty string, so a legacy record still counts."""
    repos = state.get("repos") if isinstance(state, dict) else None
    entry = repos.get(repo) if isinstance(repos, dict) else None
    commit = entry.get("commit") if isinstance(entry, dict) else None
    return commit if isinstance(commit, str) and commit else None


COMMITS = "commits"
DIGESTS = "digests"


def denylisted(denylist: Any, table: str, value: Any) -> bool:
    """Is this commit, or this digest, on the host's own refusal list?

    Both digest forms are recorded for one boot, so a caller that checks one form
    lets a denied image through; that is the caller's job (`for digest in ...`),
    not this function's.
    """
    entries = denylist.get(table) if isinstance(denylist, dict) else None
    return isinstance(entries, dict) and value in entries


def entry_valid(entry: Any, role_name: str) -> bool:
    """The queued shape a drain acts on.

    `drain_entry_valid` in scripts/deploy-drain.sh is the shell spelling of the
    same rule over one queue file; the fixtures assert the two agree, because an
    entry one reader accepts and the other drops is a request nothing deploys.
    """
    return (
        isinstance(entry, dict)
        and allows(role_name, entry.get("repo"))
        and is_commit(entry.get("commit"))
        and isinstance(entry.get("id"), str)
    )


def coalesce_key(repo: Any, entry_id: str) -> str:
    """What two pending requests must share to be one deploy.

    One repository has one deployable revision at a time, so the key is the
    repository. An entry whose repo cannot be read still has a place in the
    ordering, and it must not collide with a real repository name, which is why
    the id becomes part of it.
    """
    return repo if isinstance(repo, str) and repo else f"unreadable/{entry_id}"


# -- GitHub: the tip and the commit graph ------------------------------------


def tip_from(document: Any, url: str) -> Decision:
    """The sha `main` points at, from the ref document."""
    pointer = document.get("object") if isinstance(document, dict) else None
    sha = pointer.get("sha") if isinstance(pointer, dict) else None
    if not is_commit(sha):
        return infrastructure("bad-response", f"{url} carries no commit sha")
    return ok(sha)


def compare(reply_status: int, document: Any, url: str) -> Decision:
    """Does the deployed commit come first?

    One request answers it, and only `ahead` is a yes. `identical` is the drain's
    no-op and never reaches here, so it is a refusal like any status GitHub adds
    later: an unknown answer to "is this newer" is not a permission to deploy.
    """
    if reply_status == 404:
        # A commit GitHub has never seen: nothing about it can be trusted, and no
        # later call would answer differently.
        return refuse("descendancy-unknown", f"{url} answered 404")
    if reply_status != 200:
        return infrastructure(f"http-{reply_status}", url)
    if not isinstance(document, dict):
        return infrastructure("bad-response", f"{url} is not a JSON object")
    status = document.get("status")
    if status == "ahead":
        return ok("ahead")
    if status in ("behind", "diverged"):
        return refuse(status, f"{url} answered {status}")
    return refuse("descendancy-unknown", f"compare status {status!r}")


def rate_limited(reply_status: int, url: str) -> Decision:
    """An exhausted anonymous budget is about the API, not about the commit."""
    return infrastructure("rate-limited", f"{url} answered {reply_status}")


def http_failure(reply_status: int, url: str) -> Decision:
    """Any other status: a failure to verify, named after the status it got."""
    return infrastructure(f"http-{reply_status}", url)


# -- the registry: tag -> digests -> revision label -------------------------


def checked_digest(value: Any, what: str) -> Decision:
    if not is_digest(value):
        return infrastructure("registry-response", f"{what}: {value!r}")
    return ok(value)


def tag_reference(reply_status: int, image_repo: str, tag: str, path: str) -> Decision:
    """What a tag's manifest request says about the deployability of a commit.

    A missing tag is not a failure: the publish workflow only runs on an
    image-bearing path, so most commits on main never get one. That is a verdict
    (`not-deployable`), and it is separately named so a poll over a docs-only
    commit is not journaled as a rejection.
    """
    if reply_status == 404:
        return not_deployable("tag-missing", f"{image_repo}:{tag} is not published")
    if reply_status != 200:
        return infrastructure(f"http-{reply_status}", path)
    return ok()


def amd64_digest(children: Any, what: str) -> Decision:
    """The linux/amd64 manifest digest out of a manifest index.

    A digest the index names but the registry would not serve is an
    infrastructure failure, not a refusal: it says nothing about the commit.
    """
    if not isinstance(children, list):
        return refuse("no-amd64-manifest", f"{what} carries no manifest list")
    for child in children:
        if not isinstance(child, dict):
            continue
        platform = child.get("platform")
        if not isinstance(platform, dict):
            continue
        if platform.get("os") == "linux" and platform.get("architecture") == "amd64":
            return checked_digest(child.get("digest"), "an index entry")
    return refuse("no-amd64-manifest", f"{what} has no linux/amd64 manifest")


def config_digest(manifest: Any) -> Decision:
    """The config blob a manifest names: where the revision label lives."""
    config = manifest.get("config") if isinstance(manifest, dict) else None
    return checked_digest(config.get("digest") if isinstance(config, dict) else None, "config digest")


def revision_label(config_document: Any, image_repo: str, tag: str) -> Decision:
    """The commit the image itself says it was built from.

    The caller supplies a commit and never a digest, so the tag name plus this
    label is what binds the two. A label that is absent or names another commit
    is final: no later attempt changes what was published.
    """
    section = config_document.get("config") if isinstance(config_document, dict) else None
    labels = section.get("Labels") if isinstance(section, dict) else None
    revision = labels.get(REVISION_LABEL) if isinstance(labels, dict) else None
    if not is_commit(revision):
        return refuse("label-missing", f"{image_repo}:{tag} carries no {REVISION_LABEL}")
    return ok(revision)


# -- what the drain does with a verified entry ------------------------------

# The role hook's exit codes, as data, so the fixtures can assert that the shell
# loop and this table still agree on what a code means. "defer" is the absence of
# an action: the entry keeps its place and the retry timer brings the attempt.
STAGED = "staged"
DEPLOYED = "deployed"
STAGE_NEXT = "stage"
HELD = "held"
REFUSED = "refused"
REJECTED = "rejected"
ALREADY_BOOTED = "already-booted"
APPLIED = "applied"

DEFER = ""

# server: the snapshot gate answers first, and only a green gate runs the stage.
# A host carrying a drop-in the image does not ship (#152) is deferred under its
# own name: staging would reboot into a host whose apps apply cannot land.
GATE_STEPS = {0: (STAGE_NEXT, ""), 5: (HELD, ""), 6: (DEFER, "host-drift")}
STAGE_STEPS = {0: (STAGED, ""), 5: (REFUSED, ""), 6: (ALREADY_BOOTED, "")}
# apps: the apply is the whole verdict, with no reboot and no snapshot gate.
APPLY_STEPS = {0: (APPLIED, ""), 3: (REJECTED, "")}


def step(table: dict[int, tuple[str, str]], exit_code: int, defer_prefix: str) -> tuple[str, str]:
    """`(action, defer reason)` for a role hook's exit code.

    An unlisted code is not a verdict: it says nothing about the commit, so the
    entry is deferred under `<prefix>-exit-<code>` rather than popped.
    """
    return table.get(exit_code, (DEFER, f"{defer_prefix}-exit-{exit_code}"))
