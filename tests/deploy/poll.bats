#!/usr/bin/env bats
# bats file_tags=deploy
# Offline checks for the quarter-hour deploy poll (SDLC #798, T6; cadence per #1014).
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
#   bats tests/deploy/poll.bats
load ../helpers

poll=scripts/deploy-poll.sh
lib=scripts/deploy-state.sh
verify=bootc/server/rootfs/usr/libexec/deploy-verify.py
timer=units/systemd/smortress-deploy-poll.timer
service=units/systemd/smortress-deploy-poll.service
ping_url=http://ping.test/deploy

sha_current=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
sha_ahead=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
cache_url=http://api.test/repos/smores56/homelab-apps/git/ref/heads/main

# The fake curl answers the API from the fixture directory, keyed by the request
# path, and records every Healthchecks ping instead of sending it. A 403 and a
# connect failure are kept apart (`network` is exit 7, as the real curl reports
# it) because only one of the two is worth a page.
setup_file() {
    bin=$BATS_FILE_TMPDIR/bin
    mkdir -p "$bin"
    cat >"$bin/curl" <<'CURL'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >>"$FAKE_CURL_LOG"
out=/dev/stdout
write_out=
url=
while (($#)); do
  case $1 in
    --output | -o) out=$2; shift 2 ;;
    --write-out) write_out=$2; shift 2 ;;
    --data-binary | -d | -H | --header | --max-time | --config) shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
if [[ -z $url ]]; then
  url=$(sed -n 's/^url = "\(.*\)"$/\1/p' | head -n 1)
fi
case ${url:-} in
  *api.test*)
    status=$(cat "$FAKE_API_STATUS" 2>/dev/null) || status=200
    [[ $status == network ]] && exit 7
    answer='{}'
    rel=${url#*api.test/}
    file=$FAKE_API_BODIES/${rel//\//_}.json
    [[ -s $file ]] && answer=$(cat -- "$file")
    [[ -n $write_out ]] && printf '%s' "$status"
    if [[ $out == /dev/stdout ]]; then printf '%s' "$answer"; else printf '%s' "$answer" >"$out"; fi
    exit 0
    ;;
esac
printf '%s\n' "${url:-}" >>"$FAKE_PING_LOG"
exit 0
CURL
    chmod 0755 "$bin/curl"
}

# Every test starts from the same fixture -- the API's tip ahead of the deployed
# commit -- and changes only the part it is about. bats runs a file's tests in
# parallel, so the state, the queue, the cache and the logs are per test.
setup() {
    api=$BATS_TEST_TMPDIR/api
    state=$BATS_TEST_TMPDIR/state
    queue=$state/queue
    log=$BATS_TEST_TMPDIR/log
    pings=$BATS_TEST_TMPDIR/pings
    mkdir -p "$api" "$queue"
    : >"$log"
    : >"$pings"
    export PATH="$BATS_FILE_TMPDIR/bin:$PATH"
    export FAKE_CURL_LOG=$log
    export FAKE_PING_LOG=$pings
    export FAKE_API_STATUS=$BATS_TEST_TMPDIR/api-status
    export FAKE_API_BODIES=$api
    export DEPLOY_STATE_DIR=$state
    export DEPLOY_LOCK_FILE=$BATS_TEST_TMPDIR/deploy.lock
    export DEPLOY_PING_SECRET=$BATS_TEST_TMPDIR/deploy-ping-url.yaml
    export DEPLOY_GITHUB_API=http://api.test
    export DEPLOY_POLL_CACHE=$state/poll-cache.json
    export DEPLOY_POLL_REPOS=homelab-apps
    printf '%s\n' "$ping_url" >"$DEPLOY_PING_SECRET"
    # shellcheck source=/dev/null
    source "$lib"
    api_tip homelab-apps "$sha_ahead"
    seed_state homelab-apps "$sha_current"
}

# The API answer for `main` of one repository, named the way the fake curl looks
# it up: the request path with its slashes turned into underscores.
api_tip() { # <repo> <sha>
    jq -cn --arg sha "$2" '{object: {sha: $sha, type: "commit"}}' \
        >"$api/repos_smores56_${1}_git_ref_heads_main.json"
}

# seed_state <repo> <commit>: merges, so both repositories can be seeded.
seed_state() {
    local current
    current=$(cat "$state/state.json" 2>/dev/null) || current='{"schema":1,"apps":{}}'
    jq --arg repo "$1" --arg commit "$2" \
        '.repos = ((.repos // {}) | .[$repo] = {commit: $commit})' <<<"$current" \
        >"$state/state.json"
}

# entry_count: the requests waiting in the queue, one file each as the drain
# reads them.
entry_count() {
    find "$queue" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' '
}

last_entry() { # <jq-filter>
    local file
    file=$(find "$queue" -maxdepth 1 -type f -name '*.json' | head -n1)
    [[ -n $file ]] || return 1
    jq -r "$1" "$file" 2>/dev/null
}

api_calls() { # calls the poll made to the anonymous API
    grep -c 'api.test' "$log" || true
}

journal_events() { # <event> -> count
    grep -c "\"event\":\"$1\"" "$state/journal.jsonl" 2>/dev/null || true
}

# poll_once: one run of the poll, its status in `rc` and its streams beside the
# fixture. bats owns `run`, so the shell suite's name is not reused.
poll_once() {
    rc=0
    bash "$poll" >"$BATS_TEST_TMPDIR/stdout" 2>"$BATS_TEST_TMPDIR/stderr" || rc=$?
}

expect_failure() {
    ((rc != 0)) && return 0
    cat "$BATS_TEST_TMPDIR/stderr" >&2 || true
    return 1
}

# A denylisted tip: the receiver refused this commit, so the poll must leave the
# queue alone and page.
denylist_tip() {
    jq -cn --arg commit "$sha_ahead" \
        '{schema: 1, commits: {($commit): {reason: "boot-gate", at: "2026-01-01T00:00:00Z"}}, digests: {}}' \
        >"$state/denylist.json"
}

# Two repositories polled at once, both with a new tip and both seeded.
poll_both_repos() {
    export DEPLOY_POLL_REPOS='homelab-platform homelab-apps'
    api_tip homelab-platform "$sha_ahead"
    seed_state homelab-platform "$sha_current"
    seed_state homelab-apps "$sha_current"
}

# The verifier's own reader of the same 120 s cache rule, from its module.
verify_cache_get() { # <url> -> hit|miss
    python3 - "$verify" "$state/cache.json" "$1" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("deploy_verify", sys.argv[1])
module = importlib.util.module_from_spec(spec)
sys.modules["deploy_verify"] = module
spec.loader.exec_module(module)
print("miss" if module.Cache(sys.argv[2]).get(sys.argv[3]) is None else "hit")
PY
}

# One API reset, the way the drain does it when it forgets a tip.
cache_clear_deploy_state() {
    bash -c 'source "$1"; cache_clear' _ "$lib"
}

# --- the tip ahead of the deployed commit is enqueued once -------------------

@test "a poll against a newer tip succeeds" {
    poll_once
    assert_equal "$rc" 0
}

@test "a newer tip enqueues one request" {
    poll_once
    assert_equal "$(entry_count)" 1
}

@test "the request names the repository" {
    poll_once
    assert_equal "$(last_entry '.repo')" homelab-apps
}

@test "the request names the tip" {
    poll_once
    assert_equal "$(last_entry '.commit')" "$sha_ahead"
}

@test "the request records that the poll raised it" {
    poll_once
    assert_equal "$(last_entry '.source')" poll
}

@test "the request id is a uuid the drain accepts" {
    poll_once
    assert_equal "$(last_entry '.id | test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")')" true
}

@test "the request carries a queue time" {
    poll_once
    assert_equal "$(last_entry '.queued_at | type')" number
}

@test "the enqueue is journaled" {
    poll_once
    assert_equal "$(journal_events poll-enqueued)" 1
}

# The listener's entries carry a nonce it spent; a poll has none to replay, so
# its entry is the same shape without one.
@test "the entry is the listener's shape, without a nonce" {
    poll_once
    assert_equal "$(last_entry 'keys_unsorted | join(",")')" 'schema,id,repo,commit,queued_at,source'
}

# A second poll before the drain ran must not add a second request for the same
# commit: the queue is one decision, and a duplicate would drain it twice.
@test "a tip already queued is not enqueued again" {
    poll_once
    poll_once
    assert_equal "$(entry_count)" 1
}

@test "the repeat is journaled as already queued" {
    poll_once
    poll_once
    assert_equal "$(journal_events poll-queued)" 1
}

# --- a tip that is already deployed is not enqueued --------------------------

@test "a poll with nothing to do succeeds" {
    seed_state homelab-apps "$sha_ahead"
    poll_once
    assert_equal "$rc" 0
}

@test "a deployed tip enqueues nothing" {
    seed_state homelab-apps "$sha_ahead"
    poll_once
    assert_equal "$(entry_count)" 0
}

@test "the no-op is journaled" {
    seed_state homelab-apps "$sha_ahead"
    poll_once
    assert_equal "$(journal_events poll-current)" 1
}

# --- a denylisted tip pages and enqueues nothing -----------------------------

@test "a denylisted tip is not enqueued" {
    denylist_tip
    poll_once
    assert_equal "$(entry_count)" 0
}

@test "a denylisted tip pings the deploy check's fail endpoint" {
    denylist_tip
    poll_once
    assert grep -qx "$ping_url/fail" "$pings"
}

@test "the refusal is journaled" {
    denylist_tip
    poll_once
    assert_equal "$(journal_events poll-denylisted)" 1
}

# --- an unseeded repository is not inferred ----------------------------------

# Bootstrap is explicit in the design: with no state, the operator runs
# `smortress-deploy bootstrap` once. A poll that enqueued anyway would ask the
# receiver to verify a commit with no ancestor to check it against.
@test "a repository with no recorded commit is not enqueued" {
    rm -f "$state/state.json"
    poll_once
    assert_equal "$(entry_count)" 0
}

@test "the missing bootstrap is journaled" {
    rm -f "$state/state.json"
    poll_once
    assert_equal "$(journal_events poll-unseeded)" 1
}

# --- the API is bounded and its failures are visible -------------------------

@test "a rate-limited poll fails the unit" {
    printf '403\n' >"$FAKE_API_STATUS"
    poll_once
    expect_failure
}

@test "a rate-limited poll enqueues nothing" {
    printf '403\n' >"$FAKE_API_STATUS"
    poll_once
    assert_equal "$(entry_count)" 0
}

@test "a rate-limited poll pages, because an exhausted budget looks like a quiet host" {
    printf '403\n' >"$FAKE_API_STATUS"
    poll_once
    assert grep -qx "$ping_url/fail" "$pings"
}

@test "the poll called the anonymous API" {
    printf '403\n' >"$FAKE_API_STATUS"
    poll_once
    assert grep -q 'api.test' "$log"
}

@test "an unreachable API fails the unit" {
    printf 'network\n' >"$FAKE_API_STATUS"
    poll_once
    expect_failure
}

@test "an unreachable API enqueues nothing" {
    printf 'network\n' >"$FAKE_API_STATUS"
    poll_once
    assert_equal "$(entry_count)" 0
}

@test "an unreachable API does not page: it is not the commit's fault" {
    printf 'network\n' >"$FAKE_API_STATUS"
    poll_once
    assert_equal "$(cat "$pings" 2>/dev/null)" ''
}

@test "the failure is journaled" {
    printf 'network\n' >"$FAKE_API_STATUS"
    poll_once
    assert_equal "$(journal_events poll-failed)" 1
}

@test "a 500 from the API fails the unit" {
    printf '500\n' >"$FAKE_API_STATUS"
    poll_once
    expect_failure
}

@test "a 500 from the API enqueues nothing" {
    printf '500\n' >"$FAKE_API_STATUS"
    poll_once
    assert_equal "$(entry_count)" 0
}

# Every call carries a deadline: a poll that could hang would keep the unit
# active until the timer's next tick and hide the API from the next run.
@test "every API call is bounded" {
    assert grep -qE -- '--max-time' "$poll"
}

# --- the 120 s cache keeps a hand-run from spending the budget ---------------

@test "the first poll calls the API once" {
    poll_once
    assert_equal "$(api_calls)" 1
}

@test "a second poll inside the cache window calls the API not at all" {
    poll_once
    calls_after_first=$(api_calls)
    poll_once
    assert_equal "$(api_calls)" "$calls_after_first"
}

@test "the poll keeps its own cache" {
    poll_once
    assert [ -s "$DEPLOY_POLL_CACHE" ]
}

# Each repository's write rewrites the file from what it just read, so a prune
# that dropped the other repository's entry would make the next run pay for it
# again -- and a filter that raised would empty the file outright.
@test "both repositories' entries survive a refresh" {
    poll_both_repos
    poll_once
    cached=$(jq -r '(.entries // {}) | keys | length' "$DEPLOY_POLL_CACHE" 2>/dev/null) || cached=0
    assert_equal "$cached" 2
}

@test "both surviving entries are fresh" {
    poll_both_repos
    poll_once
    assert_equal "$(jq -r --argjson now "$(date +%s)" \
        '[.entries[] | select($now - .at <= 120)] | length' "$DEPLOY_POLL_CACHE" 2>/dev/null)" 2
}

# A stamp that is not a number is one entry to drop, not a reason to lose the
# cache: the poll would otherwise re-spend its whole budget on every run.
@test "an unreadable entry does not empty the cache around it" {
    poll_both_repos
    poll_once
    jq -c --argjson now "$(date +%s)" \
        '.entries["http://api.test/repos/smores56/homelab-platform/git/ref/heads/main"].at = "nonsense"' \
        "$DEPLOY_POLL_CACHE" >"$BATS_TEST_TMPDIR/cache.tmp" && mv "$BATS_TEST_TMPDIR/cache.tmp" "$DEPLOY_POLL_CACHE"
    : >"$log"
    poll_once
    assert_equal "$(jq -r '.entries | has("http://api.test/repos/smores56/homelab-apps/git/ref/heads/main")' \
        "$DEPLOY_POLL_CACHE" 2>/dev/null)" true
}

@test "the dropped entry is the only one fetched again" {
    poll_both_repos
    poll_once
    jq -c --argjson now "$(date +%s)" \
        '.entries["http://api.test/repos/smores56/homelab-platform/git/ref/heads/main"].at = "nonsense"' \
        "$DEPLOY_POLL_CACHE" >"$BATS_TEST_TMPDIR/cache.tmp" && mv "$BATS_TEST_TMPDIR/cache.tmp" "$DEPLOY_POLL_CACHE"
    : >"$log"
    poll_once
    assert_equal "$(grep -c 'homelab-platform/git/ref' "$log" || true)" 1
}

# --- one reset invalidates both readers --------------------------------------
# The verifier and the poll keep the same 120 s cache schema in two files, one
# per writer (the poll runs outside the deploy lock, so a shared file would lose
# one of the two). A reset that cleared only one would leave the other serving
# the stale tip the caller tried to forget, so cache_clear drops both and both
# readers observe it.
@test "the verifier reader starts cold" {
    poll_once
    assert_equal "$(verify_cache_get "$cache_url")" miss
}

@test "the verifier reader sees a fresh entry" {
    poll_once
    python3 - "$state/cache.json" "$cache_url" "$sha_ahead" <<'PY'
import json, sys, time
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump({"schema": 1, "entries": {sys.argv[2]: {
        "at": int(time.time()), "value": {"object": {"sha": sys.argv[3]}}}}}, handle)
PY
    assert_equal "$(verify_cache_get "$cache_url")" hit
}

@test "the poll reader sees the same fresh entry" {
    poll_once
    calls_before=$(api_calls)
    poll_once
    assert_equal "$(api_calls)" "$calls_before"
}

@test "a reset invalidates the verifier reader" {
    poll_once
    python3 - "$state/cache.json" "$cache_url" "$sha_ahead" <<'PY'
import json, sys, time
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump({"schema": 1, "entries": {sys.argv[2]: {
        "at": int(time.time()), "value": {"object": {"sha": sys.argv[3]}}}}}, handle)
PY
    cache_clear_deploy_state
    assert_equal "$(verify_cache_get "$cache_url")" miss
}

@test "a reset invalidates the poll reader" {
    poll_once
    cache_clear_deploy_state
    : >"$log"
    poll_once
    assert_equal "$(grep -c 'homelab-apps/git/ref' "$log" || true)" 1
}

# --- the poll decides nothing ------------------------------------------------

@test "the poll never writes the deployed state" {
    before=$(cat "$state/state.json")
    poll_once
    assert_equal "$(cat "$state/state.json")" "$before"
}

@test "the poll runs no verifier, no drain and no bootc" {
    poll_once
    assert_equal "$(grep -c 'deploy-verify\|deploy-drain\|bootc' "$log" || true)" 0
}

@test "the poll neither records a deployment nor removes a queue entry" {
    refute grep -qE 'state_record_verified|queue_pop' "$poll"
}

# --- a full queue does not grow ----------------------------------------------

# The queue the poll meets at its limit, one entry per file as the drain reads it.
seed_full_queue() {
    for i in $(seq 1 32); do
        jq -cn --arg id "00000000-0000-4000-8000-$(printf '%012d' "$i")" --arg repo homelab-platform \
            '{schema: 1, id: $id, repo: $repo, commit: "cccccccccccccccccccccccccccccccccccccccc",
              queued_at: 1, source: "event"}' >"$queue/00000000-0000-4000-8000-$(printf '%012d' "$i").json"
    done
}

@test "a full queue does not grow" {
    seed_full_queue
    poll_once
    assert_equal "$(entry_count)" 32
}

@test "the full queue is journaled" {
    seed_full_queue
    poll_once
    assert_equal "$(journal_events poll-queue-full)" 1
}

# --- both repositories are polled --------------------------------------------

@test "each repository with a new tip gets one request" {
    poll_both_repos
    poll_once
    assert_equal "$(entry_count)" 2
}

@test "both repositories are enqueued" {
    poll_both_repos
    poll_once
    assert_equal "$(jq -r '.repo' "$queue"/*.json | sort | tr '\n' ' ')" 'homelab-apps homelab-platform '
}

# --- the unit runs it every fifteen minutes ----------------------------------

@test "the poll timer ships" {
    assert [ -s "$timer" ]
}

@test "the poll service ships" {
    assert [ -s "$service" ]
}

# The poll is the only trigger once the receiver retires (design #1010), so the
# cadence is the whole of the delay between a merge and its deployment: any
# interval but the fifteen minutes is either a stale host or a hot API budget.
@test "the poll runs every fifteen minutes" {
    assert grep -qxF 'OnCalendar=*-*-* *:0/15:00' "$timer"
    assert grep -qxF 'AccuracySec=1min' "$timer"
}

@test "the description claims a cadence, not one window a day" {
    refute grep -qiE '^Description=.*(daily|nightly|window)' "$timer"
}

# Not persistent: a missed tick must not turn into a deploy on the way up.
@test "a missed tick is not owed at boot" {
    assert grep -qxF 'Persistent=false' "$timer"
}

@test "the timer starts the poll service and is enabled at boot" {
    assert grep -qxF 'Unit=smortress-deploy-poll.service' "$timer"
    assert grep -qxF 'WantedBy=timers.target' "$timer"
}

# The receiver, the listener, the forward and the heartbeat are the units #1018
# deletes: a dependency on any of them would retire the poll with them, or wait
# for a unit that no longer exists. The poll's own ordering (the decrypt it reads
# the ping URL from, the boot gate that writes the state it reads) is the whole
# list.
@test "the poll depends on none of the receiver's units" {
    refute grep -qE '^(Wants|Requires|BindsTo|PartOf|Upholds|Requisite|After|Before)=.*(deploy-receiver|deploy-listener|deploy-forward|deploy-heartbeat)' "$service"
}

@test "the poll's ordering is the decrypt, the network and the boot gate" {
    assert_equal "$(grep -E '^After=' "$service" | sort | tr '\n' ' ')" \
        'After=network-online.target After=smortress-boot-gate.service After=sops-decrypt.service After=systemd-tmpfiles-setup.service '
}

# The heartbeat suite asserts the same thing of its own service
# (tests/deploy/heartbeat.bats): the label is shared, the unit is not, so each
# suite keeps the check for the unit it runs.
@test "the service runs the installed script" {
    assert grep -qE '^ExecStart=/usr/libexec/deploy-poll$' "$service"
}

@test "the poll is bounded" {
    assert grep -qE '^TimeoutStartSec=' "$service"
}

# Enablement is the image's to state, and it has to be the enable list, not a
# mention: the host's /etc carries a disabled override that only a window deploy
# clears (#1014), so a name anywhere else in the file would prove nothing.
@test "the image enables the poll timer" {
    assert grep -qE '^[[:space:]]+smortress-deploy-poll\.timer \\$' bootc/server/Containerfile
}

@test "the build fails if the poll timer is not enabled" {
    assert grep -qF 'test -e /etc/systemd/system/timers.target.wants/smortress-deploy-poll.timer' \
        bootc/server/Containerfile
}
