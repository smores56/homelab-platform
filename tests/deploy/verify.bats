#!/usr/bin/env bats
# bats file_tags=deploy
# Offline checks for deploy-verify and the drain's verification action
# (SDLC #798, T2).
#
# The host re-derives every deploy decision, so the checks themselves are driven
# here against a loopback server that answers as both the GitHub API and the
# ghcr registry: the tip, the commit graph, the tag-to-digest resolution through
# an index to the amd64 manifest, the revision label, the denylist, the 120 s
# cache and the request deadline. No root, no network, no bootc, no token.
#
#   bats tests/deploy/verify.bats
#
# The shell suite this replaced ran every check in one process against one
# growing fixture; here each check is its own test with its own state directory
# and its own server under $BATS_TEST_TMPDIR, and the fixture a check needs is
# rebuilt by a helper named for it.
#
# Two kinds of check the shell suite carried are not repeated here. The state
# library's own internals -- `denylist_has_digest` before and after an entry, and
# `cache_clear` -- are tests/deploy/state.bats's, which owns that file; and a
# fixture the server never answered is a failing setup, which reports the
# server's log, not a passing check.
load ../helpers

verify=image/rootfs/usr/libexec/deploy-verify.py
lib=scripts/deploy-state.sh
drain=scripts/deploy-drain.sh

commit=0123456789abcdef0123456789abcdef01234567
deployed=fedcba9876543210fedcba9876543210fedcba98
tag=sha-${commit:0:12}
index_digest="sha256:$(printf '1%.0s' {1..64})"
manifest_digest="sha256:$(printf '2%.0s' {1..64})"
arm64_digest="sha256:$(printf '3%.0s' {1..64})"
config_digest="sha256:$(printf '4%.0s' {1..64})"

id_a=11111111-1111-4111-8111-111111111111
id_b=22222222-2222-4222-8222-222222222222
id_c=33333333-3333-4333-8333-333333333333
id_d=44444444-4444-4444-8444-444444444444
id_e=55555555-5555-4555-8555-555555555555
id_g=77777777-7777-4777-8777-777777777777

base_doc=$(jq -nc \
    --arg platform "$commit" --arg apps "$commit" \
    --arg name "$tag" --arg index "$index_digest" --arg manifest "$manifest_digest" \
    --arg arm64 "$arm64_digest" --arg config "$config_digest" --arg label "$commit" '
  {tip: {"homelab-platform": $platform, "homelab-apps": $apps},
   compare: "ahead",
   github_status: null,
   stall: false,
   tag: {found: true, name: $name, index: true, index_digest: $index,
         manifest: $manifest, arm64: $arm64, config: $config, label: $label}}')

# --- the fake GitHub API and registry ----------------------------------------
# The scenario file is re-read on every request, so a test changes the world
# between two verifier runs without restarting the server; the request log is
# what proves a cache hit issued no HTTP call at all. The script is the same for
# every test and is written once; each test starts its own instance, so no world
# or request log crosses between them.
setup_file() {
    local dir=$BATS_FILE_TMPDIR

    cat >"$dir/server.py" <<'PY'
"""One loopback server for the GitHub API and the ghcr registry.

The scenario file is re-read on every request so a test changes the world
between two verifier runs without restarting the server; the request log is what
proves a cache hit issued no HTTP call at all.
"""

import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SCENARIO, REQUESTS, PORT = sys.argv[1], sys.argv[2], int(sys.argv[3])

INDEX_TYPE = "application/vnd.oci.image.index.v1+json"
MANIFEST_TYPE = "application/vnd.oci.image.manifest.v1+json"


STATE = {"mtime": None, "seen": {}}


def scenario():
    """The world, with a per-path request count that restarts when it changes.

    The count is what proves a 401 refreshes the token exactly once: within one
    verifier run the world does not change, so the second attempt sees two.
    """
    stamp = os.stat(SCENARIO).st_mtime_ns
    if stamp != STATE["mtime"]:
        STATE["mtime"] = stamp
        STATE["seen"] = {}
    with open(SCENARIO) as handle:
        return json.load(handle)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def _record(self):
        with open(REQUESTS, "a") as handle:
            handle.write(self.path + "\n")

    def _send(self, status, document=None, headers=None):
        body = b"" if document is None else json.dumps(document).encode()
        try:
            self.send_response(status)
            for key, value in (headers or {}).items():
                self.send_header(key, value)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except OSError:
            # A client that hit its deadline hung up mid-answer; that is the
            # test's point, not a server failure.
            pass

    def do_GET(self):
        self._record()
        world = scenario()
        path = self.path.split("?", 1)[0]
        if world.get("stall"):
            time.sleep(float(world.get("stall_seconds", 10)))
        if path == "/token":
            self._send(200, {"token": "anonymous-test-token"})
            return
        if path.startswith("/repos/"):
            if world.get("github_status"):
                self._send(world["github_status"], {"message": "no"})
                return
            if path.endswith("/git/ref/heads/main"):
                repo = path.split("/")[3]
                self._send(200, {"ref": "refs/heads/main", "object": {"sha": world["tip"][repo]}})
                return
            if "/compare/" in path:
                self._send(200, {"status": world["compare"], "ahead_by": 1})
                return
        image = world["tag"]
        if "/manifests/" in path:
            ref = path.rsplit("/", 1)[1]
            STATE["seen"][path] = STATE["seen"].get(path, 0) + 1
            if world.get("registry_401") and ref == image["name"] and STATE["seen"][path] == 1:
                self._send(401, {"errors": [{"code": "UNAUTHORIZED"}]})
                return
            digest = image["index_digest"] if image["index"] and ref == image["name"] else image["manifest"]
            if not image["found"] or ref not in (image["name"], image["manifest"], image["index_digest"]):
                self._send(404, {"errors": [{"code": "MANIFEST_UNKNOWN"}]})
                return
            if ref == image["name"]:
                if image["index"]:
                    document = {
                        "schemaVersion": 2,
                        "mediaType": INDEX_TYPE,
                        "manifests": [
                            {
                                "mediaType": MANIFEST_TYPE,
                                "digest": image["arm64"],
                                "platform": {"os": "linux", "architecture": "arm64"},
                            },
                            {
                                "mediaType": MANIFEST_TYPE,
                                "digest": image["manifest"],
                                "platform": {"os": "linux", "architecture": "amd64"},
                            },
                        ],
                    }
                else:
                    document = manifest(image)
            else:
                document = manifest(image)
            self._send(
                200,
                document,
                {
                    "Content-Type": INDEX_TYPE if document.get("manifests") else MANIFEST_TYPE,
                    "Docker-Content-Digest": digest,
                },
            )
            return
        if "/blobs/" in path:
            labels = {} if image.get("label") is None else {"org.opencontainers.image.revision": image["label"]}
            self._send(200, {"architecture": "amd64", "os": "linux", "config": {"Labels": labels}})
            return
        self._send(404, {})


def manifest(image):
    return {
        "schemaVersion": 2,
        "mediaType": MANIFEST_TYPE,
        "config": {"mediaType": "application/vnd.oci.image.config.v1+json", "digest": image["config"], "size": 7},
        "layers": [],
    }


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever(poll_interval=0.1)
PY

    # The platform snapshot gate is T3 and has its own suite
    # (tests/deploy/platform.bats); what this suite proves is that a verified
    # platform entry reaches it with the digests the verdict resolved.
    cat >"$dir/fake-platform" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_PLATFORM_LOG"
exit "${FAKE_PLATFORM_EXIT:-0}"
STUB
    # The apps apply is T5 and has its own suite; what this suite proves is that
    # the drain hands a verified apps entry to it and acts on its exit code.
    cat >"$dir/fake-apps" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_APPS_LOG"
exit "${FAKE_APPS_EXIT:-0}"
STUB
    chmod 0755 "$dir/fake-platform" "$dir/fake-apps"
}

setup() {
    local file tool

    work=$BATS_TEST_TMPDIR
    scenario_file=$work/scenario.json
    requests=$work/requests.log
    state_dir=$work/state
    : >"$requests"

    for file in "$verify" "$lib" "$drain"; do
        [[ -r $file ]] || fail "$file is missing"
    done
    for tool in jq python3 timeout; do
        command -v "$tool" >/dev/null || fail "$tool is required"
    done

    mkdir -p "$state_dir/queue" "$state_dir/work"
    chmod 0700 "$state_dir" "$state_dir/queue"

    export DEPLOY_STATE_DIR=$state_dir
    export DEPLOY_LOCK_FILE=$work/deploy.lock
    export DEPLOY_JOURNAL_MAX_BYTES=5242880
    export DEPLOY_VERIFY_BIN=$repo_root/$verify
    export DEPLOY_PLATFORM_BIN=$BATS_FILE_TMPDIR/fake-platform
    export DEPLOY_APPS_BIN=$BATS_FILE_TMPDIR/fake-apps
    export FAKE_PLATFORM_LOG=$work/platform-calls
    export FAKE_APPS_LOG=$work/apps-calls
    : >"$FAKE_PLATFORM_LOG"
    : >"$FAKE_APPS_LOG"
    # shellcheck source=/dev/null
    source "$lib"

    port=$(free_port)
    base=http://127.0.0.1:$port
    start_server
    wait_ready
}

teardown() {
    kill "$server_pid" 2>/dev/null || true
    wait 2>/dev/null || true
}

free_port() {
    python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()'
}

# Assigns `server_pid`: a command substitution would run in a subshell and the
# teardown would then have no pid to kill.
start_server() {
    python3 "$BATS_FILE_TMPDIR/server.py" "$scenario_file" "$requests" "$port" \
        >"$work/server.log" 2>&1 &
    server_pid=$!
}

# The shell suite reported the server's readiness as a check of its own; a server
# that never answers is a broken fixture, so it fails the file with its log
# instead of hanging or reporting a hole in the verifier.
wait_ready() {
    local _
    for _ in $(seq 1 100); do
        if python3 -c 'import socket, sys
s = socket.socket()
s.settimeout(0.2)
sys.exit(0 if s.connect_ex(("127.0.0.1", int(sys.argv[1]))) == 0 else 1)' "$port"; then
            return 0
        fi
        sleep 0.1
    done
    fail "the fake GitHub and registry never answered on $base: $(cat "$work/server.log")"
}

# --- the fixture -------------------------------------------------------------
scenario() { # <jq-filter>; the base world with one thing changed, cache cold
    jq -c "$1" <<<"$base_doc" >"$scenario_file"
    # Keyed by URL, so a new world behind the same URL must not be served from the
    # previous answer.
    cache_clear
}

seed_state() { # <platform-commit> [<apps-commit>]
    state_record_verified homelab-platform "$1" "$index_digest" "$manifest_digest" || return 1
    [[ -n ${2:-} ]] && state_record_verified homelab-apps "$2"
    return 0
}

denylist_clear() { rm -f "$state_dir/denylist.json"; }

queue_seed() { # <id> <repo> <commit>
    jq -nc --arg id "$1" --arg repo "$2" --arg commit "$3" --argjson at "$(date +%s)" \
        '{schema:1,id:$id,repo:$repo,commit:$commit,queued_at:$at,source:"event"}' |
        atomic_write "$state_dir/queue/$1.json"
}

# The event record the appender wrote, read the way the shell suite read it.
journal_field() { # <event> <jq-path>
    jq -r "select(.event==\"$1\") | $2" "$state_dir/journal.jsonl" 2>/dev/null
}

# A file the subject never wrote is zero calls, not a reader error.
count_in() { # <file> <pattern>
    local n
    n=$(grep -c -- "$2" "$1" 2>/dev/null) || n=${n:-0}
    printf '%s\n' "${n:-0}"
}

json_is() { # <doc> <jq-filter> <expected>
    assert_equal "$(jq -r "$2" <<<"$1" 2>/dev/null)" "$3"
}

# One verifier run: its verdict in $out, its exit code in $rc, its stderr in a
# file a usage error can be read from.
run_verify() { # <repo> <commit> [<timeout-seconds>]
    local repo=$1 sha=$2 limit=${3:-30}
    rc=0
    out=$(DEPLOY_STATE_DIR="$state_dir" DEPLOY_GITHUB_API="$base" DEPLOY_REGISTRY="$base" \
        DEPLOY_VERIFY_TIMEOUT="$limit" python3 "$verify" --repo "$repo" --commit "$sha" \
        2>"$work/verify.err") || rc=$?
}

# drain_once [VAR=value ...]: one bounded run of the drain; its exit code in
# $drain_rc, its output in $work/drain.out.
drain_once() {
    drain_rc=0
    env "$@" \
        DEPLOY_STATE_DIR="$state_dir" DEPLOY_LOCK_FILE="$work/deploy.lock" \
        DEPLOY_VERIFY_BIN="$repo_root/$verify" DEPLOY_GITHUB_API="$base" DEPLOY_REGISTRY="$base" \
        DEPLOY_VERIFY_TIMEOUT=30 DEPLOY_DRAIN_RESCAN_PAUSE=0 \
        timeout 60 bash "$drain" >"$work/drain.out" 2>&1 || drain_rc=$?
}

# The old suite's `if drain_run; then ok; else bad "$(cat drain.out)"`: a drain
# that fails prints what it said.
assert_drain_ok() {
    if ((drain_rc != 0)); then fail "$(cat "$work/drain.out")"; fi
}

# A world the verifier must judge: the scenario `$1` over a deployed platform
# commit, then one run against the proposed commit.
gated() { # <jq-filter>
    scenario "$1"
    seed_state "$deployed" >/dev/null
    run_verify homelab-platform "$commit"
}

# --- the state helpers T2 adds ----------------------------------------------
record_platform() {
    state_record_verified homelab-platform "$deployed" "$index_digest" "$manifest_digest" ||
        fail "state_record_verified failed"
}

@test "state_record_verified writes the record" {
    run state_record_verified homelab-platform "$deployed" "$index_digest" "$manifest_digest"
    assert_success
}

@test "deployed_commit reads the platform commit" {
    record_platform
    assert_equal "$(deployed_commit homelab-platform)" "$deployed"
}

@test "state_record_verified keeps the index digest" {
    record_platform
    assert_equal "$(state_field repos.homelab-platform.indexDigest)" "$index_digest"
}

@test "state_record_verified keeps the manifest digest" {
    record_platform
    assert_equal "$(state_field repos.homelab-platform.manifestDigest)" "$manifest_digest"
}

@test "state_record_verified journals before it writes" {
    record_platform
    assert_equal "$(journal_field state-verified '.commit')" "$deployed"
}

@test "a second repository keeps the first one's entry" {
    record_platform
    state_record_verified homelab-apps "$deployed" || fail "state_record_verified writes an apps record"
    assert_equal "$(state_field repos.homelab-platform.commit)" "$deployed"
}

# state.json has three writers and four readers, so a writer must not rebuild the
# document from a fixed field list: a top-level key another writer owns has to
# survive the round trip.
@test "state_record_verified keeps an unknown top-level key" {
    record_platform
    jq -c '.future = {added: "by-a-newer-writer"}' "$state_dir/state.json" |
        atomic_write "$state_dir/state.json"
    state_record_verified homelab-platform "$deployed" "$index_digest" "$manifest_digest" ||
        fail "state_record_verified rewrote the record around the unknown key"
    assert_equal "$(state_field 'future.added' 2>/dev/null)" by-a-newer-writer
}

@test "state_record_verified refuses an unknown repository" {
    run state_record_verified nonesuch "$deployed"
    assert_failure
}

# --- tip, descendancy and the accept path -----------------------------------
@test "a commit that is not the tip is rejected" {
    gated '.tip["homelab-platform"] = "89abcdef0123456789abcdef0123456789abcdef"'
    assert_equal "$rc" 3
}

@test "the rejection is a verdict" {
    gated '.tip["homelab-platform"] = "89abcdef0123456789abcdef0123456789abcdef"'
    json_is "$out" .verdict rejected
}

@test "a non-tip commit names the tip" {
    gated '.tip["homelab-platform"] = "89abcdef0123456789abcdef0123456789abcdef"'
    json_is "$out" .reason tip-mismatch
}

@test "a commit behind the deployed one is rejected" {
    gated '.compare = "behind"'
    assert_equal "$rc" 3
}

@test "the behind status is its own reason" {
    gated '.compare = "behind"'
    json_is "$out" .reason behind
}

@test "a diverged commit is rejected" {
    gated '.compare = "diverged"'
    assert_equal "$rc" 3
}

@test "the diverged status is its own reason" {
    gated '.compare = "diverged"'
    json_is "$out" .reason diverged
}

@test "an unknown compare status is rejected" {
    gated '.compare = "weird"'
    assert_equal "$rc" 3
}

@test "an unknown status is its own reason" {
    gated '.compare = "weird"'
    json_is "$out" .reason descendancy-unknown
}

accepted() {
    scenario .
    seed_state "$deployed" >/dev/null
    : >"$requests"
    run_verify homelab-platform "$commit"
}

@test "an ahead commit on the tip is verified" {
    accepted
    assert_equal "$rc" 0
}

@test "the accept path prints a verdict" {
    accepted
    json_is "$out" .verdict verified
}

@test "the accept path records the descendancy" {
    accepted
    json_is "$out" .descendancy ahead
}

@test "the index digest is recorded" {
    accepted
    json_is "$out" .digests.index "$index_digest"
}

@test "the amd64 manifest digest is recorded" {
    accepted
    json_is "$out" .digests.manifest "$manifest_digest"
}

@test "the compare is asked for the deployed commit...the proposed one" {
    accepted
    assert_equal "$(count_in "$requests" "/compare/$deployed\.\.\.$commit")" 1
}

@test "the tag is resolved by commit prefix" {
    accepted
    assert_equal "$(count_in "$requests" "/manifests/$tag")" 1
}

@test "an index is followed to the amd64 manifest" {
    accepted
    assert_equal "$(count_in "$requests" "/manifests/$manifest_digest")" 1
}

@test "the arm64 manifest is never fetched" {
    accepted
    assert_equal "$(count_in "$requests" "/manifests/$arm64_digest")" 0
}

@test "the config blob is read for the label" {
    accepted
    assert_equal "$(count_in "$requests" "/blobs/$config_digest")" 1
}

# --- bootstrap is never inferred --------------------------------------------
@test "a host with no state requires bootstrap" {
    rm -f "$state_dir/state.json"
    scenario .
    run_verify homelab-platform "$commit"
    assert_equal "$rc" 3
}

@test "no deployed commit is a bootstrap-required rejection" {
    rm -f "$state_dir/state.json"
    scenario .
    run_verify homelab-platform "$commit"
    json_is "$out" .reason bootstrap-required
}

@test "a repository with no deployable commit requires bootstrap" {
    printf '{"schema":1,"repos":{"homelab-platform":{}},"apps":{}}\n' |
        atomic_write "$state_dir/state.json"
    scenario .
    run_verify homelab-platform "$commit"
    json_is "$out" .reason bootstrap-required
}

# --- the revision label -----------------------------------------------------
@test "an image whose revision label is another commit is rejected" {
    gated '.tag.label = "89abcdef0123456789abcdef0123456789abcdef"'
    assert_equal "$rc" 3
}

@test "a mismatched revision label is its own reason" {
    gated '.tag.label = "89abcdef0123456789abcdef0123456789abcdef"'
    json_is "$out" .reason revision-mismatch
}

@test "an image with no revision label is rejected" {
    gated '.tag.label = null'
    assert_equal "$rc" 3
}

@test "a missing revision label is its own reason" {
    gated '.tag.label = null'
    json_is "$out" .reason label-missing
}

# --- the tag ------------------------------------------------------------------
# Most main commits carry no image: the publish workflow only runs for
# image-bearing paths. That is not a failure, so it gets its own exit and is
# neither denylisted nor paged.
@test "a commit with no published image is not deployable" {
    gated '.tag.found = false'
    assert_equal "$rc" 5
}

@test "a missing tag has its own verdict" {
    gated '.tag.found = false'
    json_is "$out" .verdict not-deployable
}

@test "a missing tag is its own reason" {
    gated '.tag.found = false'
    json_is "$out" .reason tag-missing
}

# A tag that is a plain amd64 manifest records both forms as that one digest.
@test "a single-manifest tag is verified" {
    gated '.tag.index = false'
    assert_equal "$rc" 0
}

@test "a plain manifest's index form is its digest" {
    gated '.tag.index = false'
    json_is "$out" .digests.index "$manifest_digest"
}

@test "a plain manifest's manifest form is its digest" {
    gated '.tag.index = false'
    json_is "$out" .digests.manifest "$manifest_digest"
}

# An anonymous token that the registry stops honouring is refreshed once: a retry
# loop here would spend the same budget as an unbounded one.
expired_token() {
    scenario '.registry_401 = true'
    seed_state "$deployed" >/dev/null
    : >"$requests"
    run_verify homelab-platform "$commit"
}

@test "an expired anonymous token is refreshed and the run continues" {
    expired_token
    assert_equal "$rc" 0
}

@test "the token is fetched again after a 401" {
    expired_token
    assert_equal "$(count_in "$requests" '^/token')" 2
}

@test "the manifest is retried exactly once" {
    expired_token
    assert_equal "$(count_in "$requests" "/manifests/$tag")" 2
}

# --- the denylist ------------------------------------------------------------
denied() { # <kind> <value> <message>
    scenario .
    seed_state "$deployed" >/dev/null
    denylist_add "$1" "$2" "$3"
    : >"$requests"
    run_verify homelab-platform "$commit"
}

@test "a denylisted index digest is rejected" {
    denied digest "$index_digest" 'failed the boot gate'
    assert_equal "$rc" 3
}

@test "the denied digest is its own reason" {
    denied digest "$index_digest" 'failed the boot gate'
    json_is "$out" .reason denylisted
}

@test "a denied digest is refused before its config is fetched" {
    denied digest "$index_digest" 'failed the boot gate'
    assert_equal "$(count_in "$requests" '/blobs/')" 0
}

@test "a denylisted amd64 manifest digest is rejected" {
    denied digest "$manifest_digest" 'failed the boot gate'
    assert_equal "$rc" 3
}

@test "either digest form is denied" {
    denied digest "$manifest_digest" 'failed the boot gate'
    json_is "$out" .reason denylisted
}

@test "a denylisted commit is rejected" {
    denied commit "$commit" 'denied by the gate'
    assert_equal "$rc" 3
}

@test "the denied commit is its own reason" {
    denied commit "$commit" 'denied by the gate'
    json_is "$out" .reason denylisted
}

# --- the cache ---------------------------------------------------------------
# Two runs over one world: the first cold, the second answered from the cache.
# `first` is the number of tip and compare requests the cold run made.
cached_run() {
    scenario .
    seed_state "$deployed" >/dev/null
    : >"$requests"
    run_verify homelab-platform "$commit"
    first_rc=$rc
    first=$(grep -cE '/git/ref/|/compare/' "$requests" || true)
    run_verify homelab-platform "$commit"
    again_rc=$rc
}

@test "the first run verifies against the API" {
    cached_run
    assert_equal "$first_rc" 0
}

@test "the first run asks for the tip and the compare" {
    cached_run
    assert_equal "$first" 2
}

@test "the second run verifies too" {
    cached_run
    assert_equal "$again_rc" 0
}

@test "a cache hit issues no HTTP request" {
    cached_run
    assert_equal "$(grep -cE '/git/ref/|/compare/' "$requests" || true)" "$first"
}

@test "the cache lives in the state tree" {
    cached_run
    assert [ -s "$state_dir/cache.json" ]
}

# --- infrastructure failures are not verdicts -------------------------------
@test "a rate-limited API is an infrastructure failure" {
    gated '.github_status = 403'
    assert_equal "$rc" 4
}

@test "an exhausted budget is named rate-limited" {
    gated '.github_status = 403'
    json_is "$out" .reason rate-limited
}

@test "an HTTP 429 is an infrastructure failure" {
    gated '.github_status = 429'
    assert_equal "$rc" 4
}

stalled() {
    scenario '.stall = true | .stall_seconds = 5'
    seed_state "$deployed" >/dev/null
    run_verify homelab-platform "$commit" 1
}

@test "a stalled server hits the request deadline" {
    stalled
    assert_equal "$rc" 4
}

@test "the deadline is named timeout" {
    stalled
    json_is "$out" .reason timeout
}

# A cache the verifier cannot write is an infrastructure failure, not a verdict.
unwritable_cache() {
    scenario .
    seed_state "$deployed" >/dev/null
    chmod 0500 "$state_dir" || fail "cannot make the state tree read-only"
    run_verify homelab-platform "$commit"
    chmod 0700 "$state_dir"
}

@test "an unwritable cache is an infrastructure failure" {
    unwritable_cache
    assert_equal "$rc" 4
}

@test "an unwritable cache is named" {
    unwritable_cache
    json_is "$out" .reason cache-unwritable
}

# --- usage --------------------------------------------------------------------
@test "a short commit is a usage error" {
    run_verify homelab-platform 0123456789abcdef
    assert_equal "$rc" 2
}

@test "a repository outside the allowlist is a usage error" {
    run_verify other-repo "$commit"
    assert_equal "$rc" 2
}

# --- apps: no registry, no digests -------------------------------------------
apps_verified() {
    scenario .
    seed_state "$deployed" "$deployed" >/dev/null
    : >"$requests"
    cache_clear
    run_verify homelab-apps "$commit"
}

@test "an ahead apps commit is verified" {
    apps_verified
    assert_equal "$rc" 0
}

@test "an apps deploy carries no digest" {
    apps_verified
    json_is "$out" .digests null
}

@test "an apps deploy never touches the registry" {
    apps_verified
    assert_equal "$(count_in "$requests" '/v2/')" 0
}

# --- the drain's verification action ---------------------------------------
verified_platform_entry() {
    scenario .
    seed_state "$deployed" "$deployed" >/dev/null
    queue_seed "$id_a" homelab-platform "$commit"
    drain_once
    gate_digests=$(sed -n 's/.*--digests \(.*\)$/\1/p' "$work/platform-calls" | head -n1)
}

@test "the drain exits 0 after verifying an entry" {
    verified_platform_entry
    assert_drain_ok
}

@test "a verified entry is removed from the queue" {
    verified_platform_entry
    assert_equal "$(queue_count)" 0
}

@test "the verified entry journals the resolved manifest digest" {
    verified_platform_entry
    assert_equal "$(journal_field verified '.verdict.digests.manifest')" "$manifest_digest"
}

@test "the verified entry journals its commit" {
    verified_platform_entry
    assert_equal "$(journal_field verified '.commit')" "$commit"
}

@test "a verified platform entry is handed to the snapshot gate" {
    verified_platform_entry
    assert_contains "$(cat "$work/platform-calls")" "prepare --commit $commit --digests "
}

@test "the gate receives the resolved index digest" {
    verified_platform_entry
    json_is "$gate_digests" .index "$index_digest"
}

@test "the gate receives the resolved manifest digest" {
    verified_platform_entry
    json_is "$gate_digests" .manifest "$manifest_digest"
}

# A rejection is final for that entry: the same commit is popped, not retried.
rejected_entry() {
    scenario '.tip["homelab-platform"] = "89abcdef0123456789abcdef0123456789abcdef"'
    seed_state "$deployed" >/dev/null
    queue_seed "$id_b" homelab-platform "$commit"
    drain_once
}

@test "a rejected entry does not fail the drain" {
    rejected_entry
    assert_drain_ok
}

@test "a rejected entry is removed from the queue" {
    rejected_entry
    assert_equal "$(queue_count)" 0
}

@test "the rejected entry journals the reason" {
    rejected_entry
    assert_equal "$(journal_field verify-rejected '.reason')" tip-mismatch
}

# A commit the state already records is a no-op: no verification, no API call.
already_deployed_entry() {
    scenario .
    seed_state "$commit" "$deployed" >/dev/null
    : >"$requests"
    queue_seed "$id_d" homelab-platform "$commit"
    drain_once
}

@test "the drain exits 0 on an already-deployed entry" {
    already_deployed_entry
    assert_drain_ok
}

@test "an already-deployed entry is removed from the queue" {
    already_deployed_entry
    assert_equal "$(queue_count)" 0
}

@test "the already-deployed entry is journaled" {
    already_deployed_entry
    assert_equal "$(journal_field already-deployed '.commit')" "$commit"
}

@test "an already-deployed entry spends no API call" {
    already_deployed_entry
    assert_equal "$(wc -l <"$requests" | tr -d ' ')" 0
}

# An infrastructure failure leaves the work queued, deferred: the path unit re-fires
# the drain the moment it exits, so retrying now would spin the 403 into a loop. The
# entry carries when it may be tried again and the retry timer brings that attempt.
deferred_entry() {
    scenario '.github_status = 403'
    # Back to a commit that is not the deployed one, or the drain would no-op.
    seed_state "$deployed" >/dev/null
    queue_seed "$id_c" homelab-platform "$commit"
    drain_once
    retry_at=$(queue_field "$id_c" retry_at 2>/dev/null) || retry_at=0
}

@test "an infrastructure failure defers the entry instead of failing the drain" {
    deferred_entry
    assert_drain_ok
}

@test "an entry that could not be verified stays queued" {
    deferred_entry
    assert_equal "$(queue_count)" 1
}

@test "the infrastructure failure journals the reason" {
    deferred_entry
    assert_equal "$(journal_field verify-infra-failure '.reason')" rate-limited
}

@test "the deferral journals the reason" {
    deferred_entry
    assert_equal "$(journal_field deferred '.reason')" rate-limited
}

@test "the deferral counts the attempt" {
    deferred_entry
    assert_equal "$(queue_field "$id_c" attempts 2>/dev/null)" 1
}

@test "the deferral stamps a retry five minutes out" {
    deferred_entry
    if ((retry_at >= $(date +%s) + 250)); then
        :
    else
        fail "retry_at=$retry_at"
    fi
}

# The snapshot gate's own outcome decides the entry: a hold is a decision about
# the deploy and is popped, a gate that could not run leaves the request queued
# so the next trigger retries it.
held_deploy_entry() {
    scenario .
    seed_state "$deployed" >/dev/null
    queue_seed "$id_e" homelab-platform "$commit"
    drain_once FAKE_PLATFORM_EXIT=5
}

@test "a held deploy does not fail the drain" {
    held_deploy_entry
    assert_drain_ok
}

@test "a held deploy is removed from the queue" {
    held_deploy_entry
    assert_equal "$(queue_count)" 0
}

@test "the drain counts the held deploy" {
    held_deploy_entry
    assert_equal "$(journal_field drain-finish '.held')" 1
}

unclearable_gate_entry() {
    scenario .
    seed_state "$deployed" >/dev/null
    queue_seed "$id_e" homelab-platform "$commit"
    drain_once FAKE_PLATFORM_EXIT=4
}

@test "a gate that cannot run defers the entry instead of failing the drain" {
    unclearable_gate_entry
    assert_drain_ok
}

@test "an entry the gate could not clear stays queued" {
    unclearable_gate_entry
    assert_equal "$(queue_count)" 1
}

@test "the gate failure is journaled as a deferral" {
    unclearable_gate_entry
    assert_equal "$(journal_field deferred '.reason')" snapshot-gate-exit-4
}

drifted_host_entry() {
    scenario .
    seed_state "$deployed" >/dev/null
    queue_seed "$id_e" homelab-platform "$commit"
    drain_once FAKE_PLATFORM_EXIT=6
}

@test "a host manager drop-in defers the entry under its own name" {
    drifted_host_entry
    assert_drain_ok
    assert_equal "$(journal_field deferred '.reason')" host-drift
}

@test "a drift-deferred entry stays queued" {
    drifted_host_entry
    assert_equal "$(queue_count)" 1
}

# An apps commit has no reboot: it goes straight to the apps apply, and that
# program's exit code is the whole verdict.
applied_apps_entry() {
    scenario .
    seed_state "$deployed" "$deployed" >/dev/null
    queue_seed "$id_g" homelab-apps "$commit"
    drain_once
}

@test "a verified apps commit does not fail the drain" {
    applied_apps_entry
    assert_drain_ok
}

@test "the applied apps entry is removed from the queue" {
    applied_apps_entry
    assert_equal "$(queue_count)" 0
}

@test "the drain hands the apps entry to the apps apply" {
    applied_apps_entry
    assert_equal "$(count_in "$work/apps-calls" '^apply --commit')" 1
}

@test "the drain no longer defers the apps apply" {
    applied_apps_entry
    assert_equal "$(journal_field apps-deferred '.commit')" ""
}

@test "an apps commit never reaches the snapshot gate" {
    applied_apps_entry
    assert_equal "$(cat "$work/platform-calls")" ""
}

# A commit the schema refused is final: the apply denylisted it, so the entry is
# popped and counted, and the same commit is not retried forever.
rejected_apps_entry() {
    scenario .
    seed_state "$deployed" "$deployed" >/dev/null
    queue_seed "$id_g" homelab-apps "$commit"
    drain_once FAKE_APPS_EXIT=3
}

@test "a rejected apps commit does not fail the drain" {
    rejected_apps_entry
    assert_drain_ok
}

@test "a rejected apps entry is removed from the queue" {
    rejected_apps_entry
    assert_equal "$(queue_count)" 0
}

@test "the drain counts the rejected apps commit" {
    rejected_apps_entry
    assert_equal "$(journal_field drain-finish '.rejected')" 1
}

# A retryable or reverted failure leaves the entry queued and deferred so the retry
# timer tries again; the apply changed nothing or put the previous revision back.
reverted_apps_entry() {
    scenario .
    seed_state "$deployed" "$deployed" >/dev/null
    queue_seed "$id_g" homelab-apps "$commit"
    drain_once FAKE_APPS_EXIT=5
}

@test "a reverted apps apply defers the entry instead of failing the drain" {
    reverted_apps_entry
    assert_drain_ok
}

@test "an apps entry that changed nothing stays queued" {
    reverted_apps_entry
    assert_equal "$(queue_count)" 1
}

@test "the apps failure is journaled as a deferral" {
    reverted_apps_entry
    assert_equal "$(journal_field deferred '.reason')" apps-apply-exit-5
}
