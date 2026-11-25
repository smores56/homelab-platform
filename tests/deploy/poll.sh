#!/usr/bin/env bash
# Offline checks for the hourly deploy poll (SDLC #798, T6).
#
# The poll is the backstop, not a decider: it resolves `main` for each repository
# through the anonymous GitHub API, and it enqueues a request only when the tip
# differs from the deployed commit. Everything after that -- the tip check, the
# commit graph, the digests, the gates -- is the receiver's, so this suite asserts
# what the poll must not do as much as what it must: no deploy of its own, no
# enqueue for a denylisted tip, no second entry for a tip already queued, no
# inference of a bootstrap.
#
# The API is a fixture directory behind a fake `curl`, the state and the queue are
# throwaway paths, and the journal, the queue entries and the command line are
# real. No network, no root, no image.
#
#   tests/deploy/poll.sh
set -uo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root" || exit 1

poll=scripts/deploy-poll.sh
lib=scripts/deploy-state.sh
verify=image/rootfs/usr/libexec/deploy-verify.py
for file in "$poll" "$lib" "$verify"; do
  [[ -r $file ]] || {
    printf 'FAIL %s is missing\n' "$file" >&2
    exit 1
  }
done
for tool in jq curl python3; do
  command -v "$tool" >/dev/null || {
    printf 'FAIL %s is required\n' "$tool" >&2
    exit 1
  }
done

# shellcheck source=tests/deploy/lib.sh
source "$root/tests/deploy/lib.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

bin=$work/bin
api=$work/api
state=$work/state
queue=$state/queue
log=$work/log
pings=$work/pings
mkdir -p "$bin" "$api" "$queue"

# The API is answered from the fixture directory, keyed by the request path,
# and every Healthchecks ping is recorded instead of sent.
install_fake_curl "$bin"
export FAKE_CURL_LOG=$log
export FAKE_ENDPOINT_MATCH='*api.test*'
export FAKE_ENDPOINT_STATUS_FILE=$work/api-status
export FAKE_ENDPOINT_BASE='api.test/'
export FAKE_ENDPOINT_BODY_DIR=$api
export FAKE_PING_LOG=$pings

export PATH="$bin:$PATH"
export FAKE_API_STATUS=$work/api-status
export DEPLOY_STATE_DIR=$state
export DEPLOY_LOCK_FILE=$work/deploy.lock
export DEPLOY_PING_SECRET=$work/deploy-ping-url.yaml
export DEPLOY_GITHUB_API=http://api.test
export DEPLOY_POLL_CACHE=$state/poll-cache.json
export DEPLOY_POLL_REPOS=homelab-apps
printf 'http://ping.test/deploy\n' >"$DEPLOY_PING_SECRET"

sha_current=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
sha_ahead=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

api_tip() { # repo sha
  jq -cn --arg sha "$2" '{object: {sha: $sha, type: "commit"}}' \
    >"$api/repos_smores56_${1}_git_ref_heads_main.json"
}
seed_state() { # repo commit -- merges, so both repositories can be seeded
  local current
  current=$(cat "$state/state.json" 2>/dev/null) || current='{"schema":1,"apps":{}}'
  jq --arg repo "$1" --arg commit "$2" \
    '.repos = ((.repos // {}) | .[$repo] = {commit: $commit})' <<<"$current" \
    >"$state/state.json"
}
queue_entries() {
  find "$queue" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' '
}
last_entry() { # jq filter
  local file
  file=$(find "$queue" -maxdepth 1 -type f -name '*.json' | head -n1)
  [[ -n $file ]] || return 1
  jq -r "$1" "$file" 2>/dev/null
}

reset_case() {
  : >"$log"
  : >"$pings"
  rm -f "$FAKE_API_STATUS" "$DEPLOY_POLL_CACHE" "$state/state.json" "$state/journal.jsonl" \
    "$state/denylist.json"
  find "$queue" -maxdepth 1 -type f -name '*.json' -delete
  api_tip homelab-apps "$sha_ahead"
  seed_state homelab-apps "$sha_current"
}

run() {
  bash "$poll" >"$work/stdout" 2>"$work/stderr"
}

# --- the tip ahead of the deployed commit is enqueued once -------------------

reset_case
if run; then ok "a poll against a newer tip succeeds"; else bad "a poll against a newer tip succeeds" "$(cat "$work/stderr")"; fi
check_eq "$(queue_entries)" 1 "a newer tip enqueues one request"
check_eq "$(last_entry '.repo')" homelab-apps "the request names the repository"
check_eq "$(last_entry '.commit')" "$sha_ahead" "the request names the tip"
check_eq "$(last_entry '.source')" poll "the request records that the poll raised it"
check_eq "$(last_entry '.id | test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")')" true \
  "the request id is a uuid the drain accepts"
check_eq "$(last_entry '.queued_at | type')" number "the request carries a queue time"
check_eq "$(journal_events poll-enqueued)" 1 "the enqueue is journaled"
# The listener's entries carry a nonce it spent; a poll has none to replay, so
# its entry is the same shape without one.
check_eq "$(last_entry 'keys_unsorted | join(",")')" 'schema,id,repo,commit,queued_at,source' \
  "the entry is the listener's shape, without a nonce"

# A second poll before the drain ran must not add a second request for the same
# commit: the queue is one decision, and a duplicate would drain it twice.
reset_case
run
run
check_eq "$(queue_entries)" 1 "a tip already queued is not enqueued again"
check_eq "$(journal_events poll-queued)" 1 "the repeat is journaled as already queued"

# --- a tip that is already deployed is not enqueued --------------------------

reset_case
seed_state homelab-apps "$sha_ahead"
if run; then ok "a poll with nothing to do succeeds"; else bad "a poll with nothing to do succeeds" "$(cat "$work/stderr")"; fi
check_eq "$(queue_entries)" 0 "a deployed tip enqueues nothing"
check_eq "$(journal_events poll-current)" 1 "the no-op is journaled"

# --- a denylisted tip pages and enqueues nothing -----------------------------

reset_case
jq -cn --arg commit "$sha_ahead" \
  '{schema: 1, commits: {($commit): {reason: "boot-gate", at: "2026-01-01T00:00:00Z"}}, digests: {}}' \
  >"$state/denylist.json"
run
check_eq "$(queue_entries)" 0 "a denylisted tip is not enqueued"
if grep -qx 'http://ping.test/deploy/fail' "$pings"; then
  ok "a denylisted tip pings the deploy check's fail endpoint"
else
  bad "a denylisted tip pings the deploy check's fail endpoint" "$(cat "$pings")"
fi
check_eq "$(journal_events poll-denylisted)" 1 "the refusal is journaled"

# --- an unseeded repository is not inferred ----------------------------------

# Bootstrap is explicit in the design: with no state, the operator runs
# `smortress-deploy bootstrap` once. A poll that enqueued anyway would ask the
# receiver to verify a commit with no ancestor to check it against.
reset_case
rm -f "$state/state.json"
run
check_eq "$(queue_entries)" 0 "a repository with no recorded commit is not enqueued"
check_eq "$(journal_events poll-unseeded)" 1 "the missing bootstrap is journaled"

# --- the API is bounded and its failures are visible -------------------------

reset_case
printf '403\n' >"$FAKE_API_STATUS"
if run; then bad "a rate-limited poll fails the unit"; else ok "a rate-limited poll fails the unit"; fi
check_eq "$(queue_entries)" 0 "a rate-limited poll enqueues nothing"
if grep -qx 'http://ping.test/deploy/fail' "$pings"; then
  ok "a rate-limited poll pages, because an exhausted budget looks like a quiet host"
else
  bad "a rate-limited poll pages, because an exhausted budget looks like a quiet host" "$(cat "$pings")"
fi
if grep -q 'api.test' "$log"; then ok "the poll called the anonymous API"; else bad "the poll called the anonymous API"; fi

reset_case
printf 'network\n' >"$FAKE_API_STATUS"
if run; then bad "an unreachable API fails the unit"; else ok "an unreachable API fails the unit"; fi
check_eq "$(queue_entries)" 0 "an unreachable API enqueues nothing"
check_eq "$(cat "$pings" 2>/dev/null)" '' "an unreachable API does not page: it is not the commit's fault"
check_eq "$(journal_events poll-failed)" 1 "the failure is journaled"

reset_case
printf '500\n' >"$FAKE_API_STATUS"
if run; then bad "a 500 from the API fails the unit"; else ok "a 500 from the API fails the unit"; fi
check_eq "$(queue_entries)" 0 "a 500 from the API enqueues nothing"

# Every call carries a deadline: a poll that could hang would keep the unit
# active until the timer's next tick and hide the API from the next run.
reset_case
if grep -qE -- '--max-time' "$poll"; then ok "every API call is bounded"; else bad "every API call is bounded"; fi

# --- the 120 s cache keeps a hand-run from spending the budget ---------------

reset_case
run
calls_after_first=$(grep -c 'api.test' "$log" || true)
run
calls_after_second=$(grep -c 'api.test' "$log" || true)
check_eq "$calls_after_first" 1 "the first poll calls the API once"
check_eq "$calls_after_second" "$calls_after_first" "a second poll inside the cache window calls the API not at all"
check_file "$DEPLOY_POLL_CACHE" "the poll keeps its own cache"

# Each repository's write rewrites the file from what it just read, so a prune
# that dropped the other repository's entry would make the next run pay for it
# again -- and a filter that raised would empty the file outright.
reset_case
export DEPLOY_POLL_REPOS='homelab-platform homelab-apps'
api_tip homelab-platform "$sha_ahead"
seed_state homelab-platform "$sha_current"
seed_state homelab-apps "$sha_current"
run
cached=$(jq -r '(.entries // {}) | keys | length' "$DEPLOY_POLL_CACHE" 2>/dev/null) || cached=0
check_eq "$cached" 2 "both repositories' entries survive a refresh"
check_eq "$(jq -r --argjson now "$(date +%s)" \
  '[.entries[] | select($now - .at <= 120)] | length' "$DEPLOY_POLL_CACHE" 2>/dev/null)" 2 \
  "both surviving entries are fresh"
# A stamp that is not a number is one entry to drop, not a reason to lose the
# cache: the poll would otherwise re-spend its whole budget on every run.
jq -c --argjson now "$(date +%s)" \
  '.entries["http://api.test/repos/smores56/homelab-platform/git/ref/heads/main"].at = "nonsense"' \
  "$DEPLOY_POLL_CACHE" >"$work/cache.tmp" && mv "$work/cache.tmp" "$DEPLOY_POLL_CACHE"
: >"$log"
run
check_eq "$(jq -r '.entries | has("http://api.test/repos/smores56/homelab-apps/git/ref/heads/main")' \
  "$DEPLOY_POLL_CACHE" 2>/dev/null)" true \
  "an unreadable entry does not empty the cache around it"
check_eq "$(grep -c 'homelab-platform/git/ref' "$log" || true)" 1 \
  "the dropped entry is the only one fetched again"
export DEPLOY_POLL_REPOS=homelab-apps

# --- one reset invalidates both readers --------------------------------------
# The verifier and the poll keep the same 120 s cache schema in two files, one
# per writer (the poll runs outside the deploy lock, so a shared file would lose
# one of the two). A reset that cleared only one would leave the other serving
# the stale tip the caller tried to forget, so cache_clear drops both and both
# readers observe it.
verify_cache_get() { # <url>
  python3 - "$verify" "$state/cache.json" "$1" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("deploy_verify", sys.argv[1])
module = importlib.util.module_from_spec(spec)
sys.modules["deploy_verify"] = module
spec.loader.exec_module(module)
print("miss" if module.Cache(sys.argv[2]).get(sys.argv[3]) is None else "hit")
PY
}

reset_case
rm -f "$state/cache.json"
cache_url=http://api.test/repos/smores56/homelab-apps/git/ref/heads/main
run
check_eq "$(verify_cache_get "$cache_url")" miss "the verifier reader starts cold"
python3 - "$state/cache.json" "$cache_url" "$sha_ahead" <<'PY'
import json, sys, time
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump({"schema": 1, "entries": {sys.argv[2]: {
        "at": int(time.time()), "value": {"object": {"sha": sys.argv[3]}}}}}, handle)
PY
check_eq "$(verify_cache_get "$cache_url")" hit "the verifier reader sees a fresh entry"
calls_before=$(grep -c 'api.test' "$log" || true)
run
check_eq "$(grep -c 'api.test' "$log" || true)" "$calls_before" \
  "the poll reader sees the same fresh entry"
DEPLOY_STATE_DIR=$state bash -c 'source "'"$lib"'"; cache_clear'
check_eq "$(verify_cache_get "$cache_url")" miss "a reset invalidates the verifier reader"
: >"$log"
run
check_eq "$(grep -c 'homelab-apps/git/ref' "$log" || true)" 1 \
  "a reset invalidates the poll reader"

# --- the poll decides nothing ------------------------------------------------

reset_case
before=$(cat "$state/state.json")
run
check_eq "$(cat "$state/state.json")" "$before" "the poll never writes the deployed state"
check_eq "$(grep -c 'deploy-verify\|deploy-drain\|bootc' "$log" || true)" 0 \
  "the poll runs no verifier, no drain and no bootc"
if grep -qE 'state_record_verified|queue_pop' "$poll"; then
  bad "the poll neither records a deployment nor removes a queue entry"
else
  ok "the poll neither records a deployment nor removes a queue entry"
fi

# --- a full queue does not grow ----------------------------------------------

reset_case
for i in $(seq 1 32); do
  jq -cn --arg id "00000000-0000-4000-8000-$(printf '%012d' "$i")" --arg repo homelab-platform \
    '{schema: 1, id: $id, repo: $repo, commit: "cccccccccccccccccccccccccccccccccccccccc",
      queued_at: 1, source: "event"}' >"$queue/00000000-0000-4000-8000-$(printf '%012d' "$i").json"
done
run
check_eq "$(queue_entries)" 32 "a full queue does not grow"
check_eq "$(journal_events poll-queue-full)" 1 "the full queue is journaled"

# --- both repositories are polled --------------------------------------------

reset_case
export DEPLOY_POLL_REPOS='homelab-platform homelab-apps'
api_tip homelab-platform "$sha_ahead"
seed_state homelab-platform "$sha_current"
seed_state homelab-apps "$sha_current"
run
check_eq "$(queue_entries)" 2 "each repository with a new tip gets one request"
check_eq "$(jq -r '.repo' "$queue"/*.json | sort | tr '\n' ' ')" 'homelab-apps homelab-platform ' \
  "both repositories are enqueued"

# --- the unit runs it hourly -------------------------------------------------

timer=units/systemd/smortress-deploy-poll.timer
service=units/systemd/smortress-deploy-poll.service
if [[ -s $timer ]]; then ok "the poll timer ships"; else bad "the poll timer ships"; fi
if [[ -s $service ]]; then ok "the poll service ships"; else bad "the poll service ships"; fi
# One window a day, in local time, and not persistent: a missed window must not
# turn into a deploy on the way up.
if grep -qxF 'OnCalendar=*-*-* 03:00:00 America/New_York' "$timer" 2>/dev/null &&
  grep -qxF 'Persistent=false' "$timer" 2>/dev/null; then
  ok "the poll runs its daily window in local time and never on the way up"
else
  bad "the poll runs its daily window in local time and never on the way up" "$(cat "$timer" 2>/dev/null)"
fi
if grep -qE '^ExecStart=/usr/libexec/deploy-poll$' "$service" 2>/dev/null; then
  ok "the service runs the installed script"
else
  bad "the service runs the installed script" "$(cat "$service" 2>/dev/null)"
fi
if grep -qE '^TimeoutStartSec=' "$service" 2>/dev/null; then
  ok "the poll is bounded"
else
  bad "the poll is bounded"
fi
if grep -qF 'smortress-deploy-poll.timer' image/Containerfile; then
  ok "the image enables the poll timer"
else
  bad "the image enables the poll timer"
fi

finish
