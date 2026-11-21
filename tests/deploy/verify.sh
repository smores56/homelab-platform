#!/usr/bin/env bash
# Offline checks for deploy-verify and the drain's verification action
# (SDLC #798, T2).
#
# The host re-derives every deploy decision, so the checks themselves are driven
# here against a loopback server that answers as both the GitHub API and the
# ghcr registry: the tip, the commit graph, the tag-to-digest resolution through
# an index to the amd64 manifest, the revision label, the denylist, the 120 s
# cache and the request deadline. No root, no network, no bootc, no token.
#
#   tests/deploy/verify.sh
set -uo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root" || exit 1

verify=image/rootfs/usr/libexec/deploy-verify.py
lib=scripts/deploy-state.sh
drain=scripts/deploy-drain.sh
for file in "$verify" "$lib" "$drain"; do
  [[ -r $file ]] || {
    printf 'FAIL %s is missing\n' "$file" >&2
    exit 1
  }
done
for tool in jq python3 timeout; do
  command -v "$tool" >/dev/null || {
    printf 'FAIL %s is required\n' "$tool" >&2
    exit 1
  }
done

pass=0
fail=0
ok() {
  pass=$((pass + 1))
  printf 'ok   %s\n' "$1"
}
bad() {
  fail=$((fail + 1))
  printf 'FAIL %s\n' "$1" >&2
  [[ -n ${2:-} ]] && printf '     %s\n' "${2//$'\n'/$'\n'     }" >&2
  return 0
}
check_eq() { # got want label
  if [[ $1 == "$2" ]]; then ok "$3"; else bad "$3" "want '$2', got '$1'"; fi
}
check_json() { # doc filter want label
  local got
  got=$(jq -r "$2" <<<"$1" 2>/dev/null)
  check_eq "$got" "$3" "$4"
}

work=$(mktemp -d)
server_pid=
cleanup() {
  [[ -n $server_pid ]] && kill "$server_pid" 2>/dev/null
  wait 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

state_dir=$work/state
export DEPLOY_STATE_DIR=$state_dir
export DEPLOY_LOCK_FILE=$work/deploy.lock
mkdir -p "$state_dir/queue" "$state_dir/work"
chmod 0700 "$state_dir" "$state_dir/queue"
# shellcheck source=/dev/null
source "$lib"

# --- the fake GitHub API and registry ----------------------------------------
scenario_file=$work/scenario.json
requests=$work/requests.log
: >"$requests"

cat >"$work/server.py" <<'PY'
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

free_port() {
  python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()'
}

port=$(free_port)
base=http://127.0.0.1:$port
python3 "$work/server.py" "$scenario_file" "$requests" "$port" >"$work/server.log" 2>&1 &
server_pid=$!
ready=0
for _ in $(seq 1 100); do
  if python3 -c 'import socket, sys
s = socket.socket()
s.settimeout(0.2)
sys.exit(0 if s.connect_ex(("127.0.0.1", int(sys.argv[1]))) == 0 else 1)' "$port"; then
    ready=1
    break
  fi
  sleep 0.1
done
if ((ready)); then
  ok "the fake GitHub and registry answer on loopback"
else
  bad "the fake GitHub and registry answer on loopback" "$(cat "$work/server.log")"
  exit 1
fi

commit=0123456789abcdef0123456789abcdef01234567
deployed=fedcba9876543210fedcba9876543210fedcba98
tag=sha-${commit:0:12}
index_digest="sha256:$(printf '1%.0s' {1..64})"
manifest_digest="sha256:$(printf '2%.0s' {1..64})"
arm64_digest="sha256:$(printf '3%.0s' {1..64})"
config_digest="sha256:$(printf '4%.0s' {1..64})"

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

out=
rc=
run_verify() { # <repo> <commit> [<timeout-seconds>]
  local repo=$1 sha=$2 limit=${3:-30}
  out=$(DEPLOY_STATE_DIR="$state_dir" DEPLOY_GITHUB_API="$base" DEPLOY_REGISTRY="$base" \
    DEPLOY_VERIFY_TIMEOUT="$limit" python3 "$verify" --repo "$repo" --commit "$sha" \
    2>"$work/verify.err")
  rc=$?
}

requests_matching() { # <pattern> -> count in the server's log
  grep -c -- "$1" "$requests" 2>/dev/null || true
}

# --- the state helpers T2 adds ----------------------------------------------
scenario .
: >"$requests"
deploy_state_init || bad "deploy_state_init creates the tree"

if state_record_verified homelab-platform "$deployed" "$index_digest" "$manifest_digest"; then
  ok "state_record_verified writes the record"
else
  bad "state_record_verified writes the record"
fi
check_eq "$(deployed_commit homelab-platform)" "$deployed" "deployed_commit reads the platform commit"
check_eq "$(state_field repos.homelab-platform.indexDigest)" "$index_digest" \
  "state_record_verified keeps the index digest"
check_eq "$(state_field repos.homelab-platform.manifestDigest)" "$manifest_digest" \
  "state_record_verified keeps the manifest digest"
check_eq "$(jq -r 'select(.event=="state-verified") | .commit' "$state_dir/journal.jsonl")" "$deployed" \
  "state_record_verified journals before it writes"
state_record_verified homelab-apps "$deployed" || bad "state_record_verified writes an apps record"
check_eq "$(state_field repos.homelab-platform.commit)" "$deployed" \
  "a second repository keeps the first one's entry"
if state_record_verified nonesuch "$deployed" >/dev/null 2>&1; then
  bad "state_record_verified refuses an unknown repository"
else
  ok "state_record_verified refuses an unknown repository"
fi
if denylist_has_digest "$index_digest"; then
  bad "denylist_has_digest is false before any entry"
else
  ok "denylist_has_digest is false before any entry"
fi
denylist_add digest "$manifest_digest" 'failed the boot gate'
if denylist_has_digest "$manifest_digest"; then
  ok "denylist_has_digest finds a denied digest"
else
  bad "denylist_has_digest finds a denied digest"
fi
denylist_clear() { rm -f "$state_dir/denylist.json"; }
denylist_clear
if touch "$state_dir/cache.json" && cache_clear && [[ ! -e $state_dir/cache.json ]]; then
  ok "cache_clear drops the API cache"
else
  bad "cache_clear drops the API cache"
fi

# --- tip, descendancy and the accept path -----------------------------------
seed_state "$deployed" >/dev/null

scenario '.tip["homelab-platform"] = "89abcdef0123456789abcdef0123456789abcdef"'
run_verify homelab-platform "$commit"
check_eq "$rc" 3 "a commit that is not the tip is rejected"
check_json "$out" .verdict rejected "the rejection is a verdict"
check_json "$out" .reason tip-mismatch "a non-tip commit names the tip"

scenario '.compare = "behind"'
run_verify homelab-platform "$commit"
check_eq "$rc" 3 "a commit behind the deployed one is rejected"
check_json "$out" .reason behind "the behind status is its own reason"

scenario '.compare = "diverged"'
run_verify homelab-platform "$commit"
check_eq "$rc" 3 "a diverged commit is rejected"
check_json "$out" .reason diverged "the diverged status is its own reason"

scenario '.compare = "weird"'
run_verify homelab-platform "$commit"
check_eq "$rc" 3 "an unknown compare status is rejected"
check_json "$out" .reason descendancy-unknown "an unknown status is its own reason"

scenario .
: >"$requests"
cache_clear
run_verify homelab-platform "$commit"
check_eq "$rc" 0 "an ahead commit on the tip is verified"
check_json "$out" .verdict verified "the accept path prints a verdict"
check_json "$out" .descendancy ahead "the accept path records the descendancy"
check_json "$out" .digests.index "$index_digest" "the index digest is recorded"
check_json "$out" .digests.manifest "$manifest_digest" "the amd64 manifest digest is recorded"
check_eq "$(requests_matching "/compare/$deployed\.\.\.$commit")" 1 \
  "the compare is asked for the deployed commit...the proposed one"
check_eq "$(requests_matching "/manifests/$tag")" 1 "the tag is resolved by commit prefix"
check_eq "$(requests_matching "/manifests/$manifest_digest")" 1 "an index is followed to the amd64 manifest"
check_eq "$(requests_matching "/manifests/$arm64_digest")" 0 "the arm64 manifest is never fetched"
check_eq "$(requests_matching "/blobs/$config_digest")" 1 "the config blob is read for the label"

# --- bootstrap is never inferred --------------------------------------------
rm -f "$state_dir/state.json"
scenario .
run_verify homelab-platform "$commit"
check_eq "$rc" 3 "a host with no state requires bootstrap"
check_json "$out" .reason bootstrap-required "no deployed commit is a bootstrap-required rejection"

printf '{"schema":1,"repos":{"homelab-platform":{}},"apps":{}}\n' |
  atomic_write "$state_dir/state.json"
run_verify homelab-platform "$commit"
check_json "$out" .reason bootstrap-required "a repository with no deployable commit requires bootstrap"
seed_state "$deployed" >/dev/null

# --- the revision label -----------------------------------------------------
scenario '.tag.label = "89abcdef0123456789abcdef0123456789abcdef"'
run_verify homelab-platform "$commit"
check_eq "$rc" 3 "an image whose revision label is another commit is rejected"
check_json "$out" .reason revision-mismatch "a mismatched revision label is its own reason"

scenario '.tag.label = null'
run_verify homelab-platform "$commit"
check_eq "$rc" 3 "an image with no revision label is rejected"
check_json "$out" .reason label-missing "a missing revision label is its own reason"

# --- the tag ------------------------------------------------------------------
scenario '.tag.found = false'
run_verify homelab-platform "$commit"
check_eq "$rc" 3 "a commit with no published image is rejected"
check_json "$out" .reason tag-missing "a missing tag is its own reason"

# A tag that is a plain amd64 manifest records both forms as that one digest.
scenario '.tag.index = false'
run_verify homelab-platform "$commit"
check_eq "$rc" 0 "a single-manifest tag is verified"
check_json "$out" .digests.index "$manifest_digest" "a plain manifest's index form is its digest"
check_json "$out" .digests.manifest "$manifest_digest" "a plain manifest's manifest form is its digest"

# An anonymous token that the registry stops honouring is refreshed once: a
# retry loop here would spend the same budget as an unbounded one.
scenario '.registry_401 = true'
: >"$requests"
run_verify homelab-platform "$commit"
check_eq "$rc" 0 "an expired anonymous token is refreshed and the run continues"
check_eq "$(requests_matching "^/token")" 2 "the token is fetched again after a 401"
check_eq "$(requests_matching "/manifests/$tag")" 2 "the manifest is retried exactly once"

# --- the denylist ------------------------------------------------------------
denylist_add digest "$index_digest" 'failed the boot gate'
: >"$requests"
scenario .
run_verify homelab-platform "$commit"
check_eq "$rc" 3 "a denylisted index digest is rejected"
check_json "$out" .reason denylisted "the denied digest is its own reason"
check_eq "$(requests_matching "/blobs/")" 0 "a denied digest is refused before its config is fetched"
denylist_clear

denylist_add digest "$manifest_digest" 'failed the boot gate'
run_verify homelab-platform "$commit"
check_eq "$rc" 3 "a denylisted amd64 manifest digest is rejected"
check_json "$out" .reason denylisted "either digest form is denied"
denylist_clear

denylist_add commit "$commit" 'denied by the gate'
run_verify homelab-platform "$commit"
check_eq "$rc" 3 "a denylisted commit is rejected"
check_json "$out" .reason denylisted "the denied commit is its own reason"
denylist_clear

# --- the cache ---------------------------------------------------------------
scenario .
cache_clear
: >"$requests"
run_verify homelab-platform "$commit"
check_eq "$rc" 0 "the first run verifies against the API"
first=$(grep -cE '/git/ref/|/compare/' "$requests")
check_eq "$first" 2 "the first run asks for the tip and the compare"
run_verify homelab-platform "$commit"
check_eq "$rc" 0 "the second run verifies too"
check_eq "$(grep -cE '/git/ref/|/compare/' "$requests")" "$first" \
  "a cache hit issues no HTTP request"
if [[ -s $state_dir/cache.json ]]; then
  ok "the cache lives in the state tree"
else
  bad "the cache lives in the state tree"
fi

# --- infrastructure failures are not verdicts -------------------------------
scenario '.github_status = 403'
cache_clear
run_verify homelab-platform "$commit"
check_eq "$rc" 4 "a rate-limited API is an infrastructure failure"
check_json "$out" .reason rate-limited "an exhausted budget is named rate-limited"

scenario '.github_status = 429'
cache_clear
run_verify homelab-platform "$commit"
check_eq "$rc" 4 "an HTTP 429 is an infrastructure failure"

scenario '.stall = true | .stall_seconds = 5'
run_verify homelab-platform "$commit" 1
check_eq "$rc" 4 "a stalled server hits the request deadline"
check_json "$out" .reason timeout "the deadline is named timeout"

scenario .
cache_clear
if state_record_verified homelab-platform "$deployed" "$index_digest" "$manifest_digest" &&
  chmod 0500 "$state_dir"; then
  run_verify homelab-platform "$commit"
  check_eq "$rc" 4 "an unwritable cache is an infrastructure failure"
  check_json "$out" .reason cache-unwritable "an unwritable cache is named"
  chmod 0700 "$state_dir"
else
  bad "an unwritable cache is an infrastructure failure" "cannot make the state tree read-only"
fi

# --- usage --------------------------------------------------------------------
run_verify homelab-platform 0123456789abcdef
check_eq "$rc" 2 "a short commit is a usage error"
run_verify other-repo "$commit"
check_eq "$rc" 2 "a repository outside the allowlist is a usage error"

# --- apps: no registry, no digests -------------------------------------------
scenario .
seed_state "$deployed" "$deployed" >/dev/null
: >"$requests"
cache_clear
run_verify homelab-apps "$commit"
check_eq "$rc" 0 "an ahead apps commit is verified"
check_json "$out" .digests null "an apps deploy carries no digest"
check_eq "$(requests_matching "/v2/")" 0 "an apps deploy never touches the registry"

# --- the drain's verification action ---------------------------------------
export DEPLOY_VERIFY_BIN=$root/$verify
export DEPLOY_JOURNAL_MAX_BYTES=5242880
# The platform snapshot gate is T3 and has its own suite (tests/deploy/platform.sh);
# what this suite proves is that a verified platform entry reaches it with the
# digests the verdict resolved.
cat >"$work/fake-platform" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_PLATFORM_LOG"
exit "${FAKE_PLATFORM_EXIT:-0}"
STUB
chmod 0755 "$work/fake-platform"
export DEPLOY_PLATFORM_BIN=$work/fake-platform
export FAKE_PLATFORM_LOG=$work/platform-calls
: >"$work/platform-calls"
# The apps apply is T5 and has its own suite; what this suite proves is that the
# drain hands a verified apps entry to it and acts on its exit code.
cat >"$work/fake-apps" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_APPS_LOG"
exit "${FAKE_APPS_EXIT:-0}"
STUB
chmod 0755 "$work/fake-apps"
export DEPLOY_APPS_BIN=$work/fake-apps
export FAKE_APPS_LOG=$work/apps-calls
: >"$work/apps-calls"

queue_seed() { # <id> <repo> <commit>
  jq -nc --arg id "$1" --arg repo "$2" --arg commit "$3" --argjson at "$(date +%s)" \
    '{schema:1,id:$id,repo:$repo,commit:$commit,queued_at:$at,source:"event"}' |
    atomic_write "$state_dir/queue/$1.json"
}

drain_run() {
  DEPLOY_STATE_DIR="$state_dir" DEPLOY_LOCK_FILE="$work/deploy.lock" \
    DEPLOY_VERIFY_BIN="$root/$verify" DEPLOY_GITHUB_API="$base" DEPLOY_REGISTRY="$base" \
    DEPLOY_VERIFY_TIMEOUT=30 DEPLOY_DRAIN_RESCAN_PAUSE=0 \
    timeout 60 bash "$drain" >"$work/drain.out" 2>&1
}

id_a=11111111-1111-4111-8111-111111111111
id_b=22222222-2222-4222-8222-222222222222
id_c=33333333-3333-4333-8333-333333333333

scenario .
seed_state "$deployed" "$deployed" >/dev/null
queue_seed "$id_a" homelab-platform "$commit"
if drain_run; then
  ok "the drain exits 0 after verifying an entry"
else
  bad "the drain exits 0 after verifying an entry" "$(cat "$work/drain.out")"
fi
check_eq "$(queue_count)" 0 "a verified entry is removed from the queue"
check_eq "$(jq -r 'select(.event=="verified") | .verdict.digests.manifest' "$state_dir/journal.jsonl")" \
  "$manifest_digest" "the verified entry journals the resolved manifest digest"
check_eq "$(jq -r 'select(.event=="verified") | .commit' "$state_dir/journal.jsonl")" "$commit" \
  "the verified entry journals its commit"
if grep -q "^prepare --commit $commit --digests " "$work/platform-calls"; then
  ok "a verified platform entry is handed to the snapshot gate"
else
  bad "a verified platform entry is handed to the snapshot gate" "$(cat "$work/platform-calls")"
fi
gate_digests=$(sed -n 's/.*--digests \(.*\)$/\1/p' "$work/platform-calls" | head -n1)
check_json "$gate_digests" .index "$index_digest" "the gate receives the resolved index digest"
check_json "$gate_digests" .manifest "$manifest_digest" "the gate receives the resolved manifest digest"

# A rejection is final for that entry: the same commit is popped, not retried.
scenario '.tip["homelab-platform"] = "89abcdef0123456789abcdef0123456789abcdef"'
cache_clear
queue_seed "$id_b" homelab-platform "$commit"
if drain_run; then
  ok "a rejected entry does not fail the drain"
else
  bad "a rejected entry does not fail the drain" "$(cat "$work/drain.out")"
fi
check_eq "$(queue_count)" 0 "a rejected entry is removed from the queue"
check_eq "$(jq -r 'select(.event=="verify-rejected") | .reason' "$state_dir/journal.jsonl")" tip-mismatch \
  "the rejected entry journals the reason"

# A commit the state already records is a no-op: no verification, no API call.
scenario .
seed_state "$commit" "$deployed" >/dev/null
: >"$requests"
id_d=44444444-4444-4444-8444-444444444444
queue_seed "$id_d" homelab-platform "$commit"
if drain_run; then
  ok "the drain exits 0 on an already-deployed entry"
else
  bad "the drain exits 0 on an already-deployed entry" "$(cat "$work/drain.out")"
fi
check_eq "$(queue_count)" 0 "an already-deployed entry is removed from the queue"
check_eq "$(jq -r 'select(.event=="already-deployed") | .commit' "$state_dir/journal.jsonl")" "$commit" \
  "the already-deployed entry is journaled"
check_eq "$(wc -l <"$requests" | tr -d ' ')" 0 "an already-deployed entry spends no API call"

# An infrastructure failure leaves the work queued for the next trigger.
scenario '.github_status = 403'
# Back to a commit that is not the deployed one, or the drain would no-op.
seed_state "$deployed" >/dev/null
queue_seed "$id_c" homelab-platform "$commit"
if drain_run; then
  bad "an infrastructure failure fails the drain"
else
  ok "an infrastructure failure fails the drain"
fi
check_eq "$(queue_count)" 1 "an entry that could not be verified stays queued"
check_eq "$(jq -r 'select(.event=="verify-infra-failure") | .reason' "$state_dir/journal.jsonl")" \
  rate-limited "the infrastructure failure journals the reason"

# The snapshot gate's own outcome decides the entry: a hold is a decision about
# the deploy and is popped, a gate that could not run leaves the request queued
# so the next trigger retries it.
clear_queue() {
  for entry in "$state_dir"/queue/*.json; do rm -f "$entry"; done
}
clear_queue
scenario .
seed_state "$deployed" >/dev/null
: >"$work/platform-calls"
id_e=55555555-5555-4555-8555-555555555555
queue_seed "$id_e" homelab-platform "$commit"
export FAKE_PLATFORM_EXIT=5
if drain_run; then
  ok "a held deploy does not fail the drain"
else
  bad "a held deploy does not fail the drain" "$(cat "$work/drain.out")"
fi
check_eq "$(queue_count)" 0 "a held deploy is removed from the queue"
check_eq "$(jq -r 'select(.event=="drain-finish") | .held' "$state_dir/journal.jsonl" | tail -n1)" 1 \
  "the drain counts the held deploy"
export FAKE_PLATFORM_EXIT=4
queue_seed "$id_e" homelab-platform "$commit"
if drain_run; then
  bad "a gate that cannot run fails the drain"
else
  ok "a gate that cannot run fails the drain"
fi
check_eq "$(queue_count)" 1 "an entry the gate could not clear stays queued"
unset FAKE_PLATFORM_EXIT

# An apps commit has no reboot: it goes straight to the apps apply, and that
# program's exit code is the whole verdict.
clear_queue
seed_state "$deployed" "$deployed" >/dev/null
: >"$work/platform-calls"
: >"$work/apps-calls"
id_g=77777777-7777-4777-8777-777777777777
queue_seed "$id_g" homelab-apps "$commit"
if drain_run; then
  ok "a verified apps commit does not fail the drain"
else
  bad "a verified apps commit does not fail the drain" "$(cat "$work/drain.out")"
fi
check_eq "$(queue_count)" 0 "the applied apps entry is removed from the queue"
check_eq "$(cat "$work/apps-calls")" "apply --commit $commit" \
  "the drain hands the apps entry to the apps apply"
check_eq "$(jq -r 'select(.event=="apps-deferred") | .commit' "$state_dir/journal.jsonl" | tail -n1)" \
  "" "the drain no longer defers the apps apply"
if [[ -s $work/platform-calls ]]; then
  bad "an apps commit never reaches the snapshot gate" "$(cat "$work/platform-calls")"
else
  ok "an apps commit never reaches the snapshot gate"
fi

# A commit the schema refused is final: the apply denylisted it, so the entry is
# popped and counted, and the same commit is not retried forever.
clear_queue
queue_seed "$id_g" homelab-apps "$commit"
if FAKE_APPS_EXIT=3 drain_run; then
  ok "a rejected apps commit does not fail the drain"
else
  bad "a rejected apps commit does not fail the drain" "$(cat "$work/drain.out")"
fi
check_eq "$(queue_count)" 0 "a rejected apps entry is removed from the queue"
check_eq "$(jq -r 'select(.event=="drain-finish") | .rejected' "$state_dir/journal.jsonl" | tail -n1)" 1 \
  "the drain counts the rejected apps commit"

# A retryable or reverted failure leaves the entry queued so the next trigger
# tries again; the apply changed nothing or put the previous revision back.
clear_queue
queue_seed "$id_g" homelab-apps "$commit"
if FAKE_APPS_EXIT=5 drain_run; then
  bad "a reverted apps apply fails the drain"
else
  ok "a reverted apps apply fails the drain"
fi
check_eq "$(queue_count)" 1 "an apps entry that changed nothing stays queued"
printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
