#!/usr/bin/env bats
# bats file_tags=deploy
# Offline checks for the deploy heartbeat (SDLC #798, T6).
#
# The heartbeat is the dead-man for the deploy queue. It pings the deploy check
# green only when no queue entry has been waiting for two hours, and it pings /fail
# with the reason otherwise. A poll-driven ping could not see a wedged drain: the
# poll's own request would sit in the queue and the poll would report nothing
# wrong. That is why the two are separate programs. There is no listener to probe
# any more (#1018), and #1019 replaces this program with a poll-side ping.
#
# `curl` is a fake and the queue is a throwaway directory; the ping URL, the
# journal and the exit codes are real. No network, no root, no image.
#
#   bats tests/deploy/heartbeat.bats
load ../helpers

heartbeat=scripts/deploy-heartbeat.sh
lib=scripts/deploy-state.sh
timer=units/systemd/smortress-deploy-heartbeat.timer
service=units/systemd/smortress-deploy-heartbeat.service
ping_url=http://ping.test/deploy

# The fake curl is the same for every test, so it is written once per file: every
# Healthchecks ping is recorded instead of sent. deploy_notify hands its URL over
# as a curl config on stdin, never in argv, so a URL-less call reads the
# `url = "..."` line.
setup_file() {
    bin=$BATS_FILE_TMPDIR/bin
    mkdir -p "$bin"
    cat >"$bin/curl" <<'CURL'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >>"$FAKE_CURL_LOG"
url=
while (($#)); do
  case $1 in
    --output | -o | --write-out | --config | -H | --header | --max-time | --retry) shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
if [[ -z $url ]]; then
  url=$(sed -n 's/^url = "\(.*\)"$/\1/p' | head -n 1)
fi
printf '%s\n' "${url:-}" >>"$FAKE_PING_LOG"
exit 0
CURL
    chmod 0755 "$bin/curl"
}

# Everything the beat reads and writes is per test: bats runs a file's tests in
# parallel, so one state directory, one log and one ping file per test is what
# keeps them independent.
setup() {
    state=$BATS_TEST_TMPDIR/state
    log=$BATS_TEST_TMPDIR/log
    pings=$BATS_TEST_TMPDIR/pings
    mkdir -p "$state/queue"
    : >"$log"
    : >"$pings"
    export PATH="$BATS_FILE_TMPDIR/bin:$PATH"
    export FAKE_CURL_LOG=$log
    export FAKE_PING_LOG=$pings
    export DEPLOY_STATE_DIR=$state
    export DEPLOY_LOCK_FILE=$BATS_TEST_TMPDIR/deploy.lock
    export DEPLOY_PING_SECRET=$BATS_TEST_TMPDIR/deploy-ping-url.yaml
    printf '%s\n' "$ping_url" >"$DEPLOY_PING_SECRET"
    # shellcheck source=/dev/null
    source "$lib"
}

journal_events() { # <event> -> count
    grep -c "\"event\":\"$1\"" "$state/journal.jsonl" 2>/dev/null || true
}

queue_seed() { # <id> <queued_at>
    jq -cn --arg id "$1" --argjson at "$2" \
        '{schema: 1, id: $id, repo: "homelab-apps", commit: "dddddddddddddddddddddddddddddddddddddddd",
          queued_at: $at, source: "event"}' >"$state/queue/$1.json"
}

# beat: one run of the heartbeat, its status in `rc` and its streams beside the
# fixture. A failure report carries the beat's own stderr, so the reason it failed
# is on the report rather than only its exit code.
beat() {
    rc=0
    bash "$heartbeat" >"$BATS_TEST_TMPDIR/stdout" 2>"$BATS_TEST_TMPDIR/stderr" || rc=$?
}

expect_failure() {
    ((rc != 0)) && return 0
    cat "$BATS_TEST_TMPDIR/stderr" >&2 || true
    return 1
}

# --- a healthy, idle queue is reported green ---------------------------------

@test "an idle host exits 0" {
    beat
    assert_equal "$rc" 0
}

@test "an idle host pings the check itself, not /fail" {
    beat
    assert_equal "$(cat "$pings")" "$ping_url"
}

@test "the healthy beat is journaled" {
    beat
    assert_equal "$(journal_events heartbeat-ok)" 1
}

@test "a queue entry younger than the limit is still healthy" {
    queue_seed 11111111-1111-4111-8111-111111111111 "$(($(date +%s) - 60))"
    beat
    assert_equal "$rc" 0
}

@test "a fresh queue entry keeps the check green" {
    queue_seed 11111111-1111-4111-8111-111111111111 "$(($(date +%s) - 60))"
    beat
    assert_equal "$(cat "$pings")" "$ping_url"
}

# --- a wedged drain is paged -------------------------------------------------

@test "a queue entry older than two hours fails the unit" {
    queue_seed 22222222-2222-4222-8222-222222222222 "$(($(date +%s) - 7300))"
    beat
    expect_failure
}

@test "an old queue entry pings /fail" {
    queue_seed 22222222-2222-4222-8222-222222222222 "$(($(date +%s) - 7300))"
    beat
    assert grep -qx "$ping_url/fail" "$pings"
}

@test "the failure names the reason" {
    queue_seed 22222222-2222-4222-8222-222222222222 "$(($(date +%s) - 7300))"
    beat
    assert grep -E 'old|stale|minute' "$BATS_TEST_TMPDIR/stderr"
}

@test "the failure is journaled" {
    queue_seed 22222222-2222-4222-8222-222222222222 "$(($(date +%s) - 7300))"
    beat
    assert_equal "$(journal_events heartbeat-failed)" 1
}

# A slow but honest deploy is not a wedged one: the snapshot gate runs for an hour
# and an apps apply behind it for ninety minutes, so the limit sits above both. A
# host that paged on its own rollout would page on every healthy deploy.
@test "a 90-minute-old queue entry is still inside the window" {
    queue_seed 33333333-3333-4333-8333-333333333333 "$(($(date +%s) - 5400))"
    beat
    assert_equal "$rc" 0
}

@test "a 90-minute-old queue entry keeps the check green" {
    queue_seed 33333333-3333-4333-8333-333333333333 "$(($(date +%s) - 5400))"
    beat
    assert_equal "$(cat "$pings")" "$ping_url"
}

# --- a host without the ping URL is not a broken deploy ----------------------

# The decrypt step writes the URL; a host mid-bootstrap has none, and the
# heartbeat must journal the skip rather than page or fail.
@test "a missing ping URL is a journaled skip, not a failure" {
    rm -f "$DEPLOY_PING_SECRET"
    beat
    assert_equal "$rc" 0
}

@test "the missing ping URL is journaled" {
    rm -f "$DEPLOY_PING_SECRET"
    beat
    assert_equal "$(journal_events notify-skipped)" 1
}

# --- the unit runs it every five minutes -------------------------------------

@test "the heartbeat timer ships" {
    assert [ -s "$timer" ]
}

@test "the heartbeat service ships" {
    assert [ -s "$service" ]
}

@test "the heartbeat runs every five minutes" {
    assert grep -qE '^OnCalendar=.*\*:0/5' "$timer"
}

# The poll suite asserts the same thing of its own service (tests/deploy/poll.bats):
# the label is shared, the unit is not, so each suite keeps the check for the unit
# it runs.
@test "the service runs the installed script" {
    assert grep -qE '^ExecStart=/usr/libexec/deploy-heartbeat$' "$service"
}

@test "the heartbeat is bounded" {
    assert grep -qE '^TimeoutStartSec=' "$service"
}

@test "the image enables the heartbeat timer" {
    assert grep -qF 'smortress-deploy-heartbeat.timer' bootc/server/Containerfile
}
