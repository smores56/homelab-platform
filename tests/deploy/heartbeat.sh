#!/usr/bin/env bash
# Offline checks for the deploy heartbeat (SDLC #798, T6).
#
# The heartbeat is the dead-man for the receiver itself. It pings the deploy check
# green only when the listener answers /healthz inside five seconds *and* no queue
# entry has been waiting for half an hour, and it pings /fail with the reason
# otherwise. A poll-driven ping could not see a wedged drain: the poll's own
# request would sit in the queue and the poll would report nothing wrong. That is
# why the two are separate programs and why this suite drives the health endpoint
# and the queue independently.
#
# The health endpoint is a fake `curl` and the queue is a throwaway directory; the
# ping URL, the journal and the exit codes are real. No network, no root, no image.
#
#   tests/deploy/heartbeat.sh
set -uo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root" || exit 1

heartbeat=scripts/deploy-heartbeat.sh
lib=scripts/deploy-state.sh
for file in "$heartbeat" "$lib"; do
  [[ -r $file ]] || {
    printf 'FAIL %s is missing\n' "$file" >&2
    exit 1
  }
done
for tool in jq curl; do
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
state=$work/state
queue=$state/queue
log=$work/log
pings=$work/pings
mkdir -p "$bin" "$queue"

# Stand-in for curl: the health URL answers the status in $FAKE_HEALTH_STATUS
# (`network` is a connect failure, exit 7) and every Healthchecks ping is recorded
# instead of sent.
cat >"$bin/curl" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >>"${FAKE_LOG:?}"
fail=0
out=/dev/stdout
write_out=
url=
while (($#)); do
  case $1 in
    --output) out=$2; shift 2 ;;
    --write-out) write_out=$2; shift 2 ;;
    --fail | --fail-with-body) fail=1; shift ;;
    --config) shift 2 ;;
    -H | --header | --max-time | --data-binary | -d | --retry) shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
# deploy_notify hands the ping URL over as a config on stdin, never in argv.
if [[ -z $url ]]; then
  url=$(sed -n 's/^url = "\(.*\)"$/\1/p' | head -n 1)
fi
status=200
case $url in
  *healthz*)
    status=$(cat "$FAKE_HEALTH_STATUS" 2>/dev/null) || status=200
    [[ $status == network ]] && exit 7 ;;
  *) printf '%s\n' "$url" >>"${FAKE_PING_LOG:?}" ;;
esac
[[ -n $write_out ]] && printf '%s' "$status"
if [[ $out == /dev/stdout ]]; then printf '{"status":"ok"}'; else printf '{"status":"ok"}' >"$out"; fi
if ((fail)) && ((status >= 400)); then exit 22; fi
exit 0
EOF
chmod +x "$bin/curl"

export PATH="$bin:$PATH"
export FAKE_LOG=$log
export FAKE_HEALTH_STATUS=$work/health-status
export FAKE_PING_LOG=$pings
export DEPLOY_STATE_DIR=$state
export DEPLOY_LOCK_FILE=$work/deploy.lock
export DEPLOY_PING_SECRET=$work/deploy-ping-url.yaml
printf 'http://ping.test/deploy\n' >"$DEPLOY_PING_SECRET"

queue_seed() { # id queued_at
  jq -cn --arg id "$1" --argjson at "$2" \
    '{schema: 1, id: $id, repo: "homelab-apps", commit: "dddddddddddddddddddddddddddddddddddddddd",
      queued_at: $at, source: "event"}' >"$queue/$1.json"
}
reset_case() {
  : >"$log"
  : >"$pings"
  rm -f "$FAKE_HEALTH_STATUS" "$state/journal.jsonl"
  find "$queue" -maxdepth 1 -type f -name '*.json' -delete
}
run() {
  bash "$heartbeat" >"$work/stdout" 2>"$work/stderr"
}

# --- a healthy, idle receiver is reported green ------------------------------

reset_case
if run; then ok "a healthy receiver exits 0"; else bad "a healthy receiver exits 0" "$(cat "$work/stderr")"; fi
check_eq "$(cat "$pings")" 'http://ping.test/deploy' "a healthy receiver pings the check itself, not /fail"
check_eq "$(journal_events heartbeat-ok)" 1 "the healthy beat is journaled"
if grep -qE -- '--max-time 5' "$log"; then ok "the health probe is bounded to five seconds"; else bad "the health probe is bounded to five seconds"; fi
if grep -qE 'healthz' "$log"; then ok "the probe targets the listener's own /healthz"; else bad "the probe targets the listener's own /healthz"; fi

reset_case
queue_seed 11111111-1111-4111-8111-111111111111 "$(($(date +%s) - 60))"
if run; then ok "a queue entry younger than the limit is still healthy"; else bad "a queue entry younger than the limit is still healthy" "$(cat "$work/stderr")"; fi
check_eq "$(cat "$pings")" 'http://ping.test/deploy' "a fresh queue entry keeps the check green"

# --- a wedged drain is paged -------------------------------------------------

reset_case
queue_seed 22222222-2222-4222-8222-222222222222 "$(($(date +%s) - 7300))"
if run; then bad "a queue entry older than two hours fails the unit"; else ok "a queue entry older than two hours fails the unit"; fi
if grep -qx 'http://ping.test/deploy/fail' "$pings"; then
  ok "an old queue entry pings /fail"
else
  bad "an old queue entry pings /fail" "$(cat "$pings")"
fi
if grep -E 'old|stale|minute' "$work/stderr" >/dev/null; then
  ok "the failure names the reason"
else
  bad "the failure names the reason" "$(cat "$work/stderr")"
fi
check_eq "$(journal_events heartbeat-failed)" 1 "the failure is journaled"

# A slow but honest deploy is not a wedged one: the snapshot gate runs for an hour
# and an apps apply behind it for ninety minutes, so the limit sits above both. A
# host that paged on its own rollout would page on every healthy deploy.
reset_case
queue_seed 33333333-3333-4333-8333-333333333333 "$(($(date +%s) - 5400))"
if run; then ok "a 90-minute-old queue entry is still inside the window"; else bad "a 90-minute-old queue entry is still inside the window" "$(cat "$work/stderr")"; fi
check_eq "$(cat "$pings")" 'http://ping.test/deploy' "a 90-minute-old queue entry keeps the check green"

# --- a silent listener is paged ----------------------------------------------

reset_case
printf 'network\n' >"$FAKE_HEALTH_STATUS"
if run; then bad "a listener that does not answer fails the unit"; else ok "a listener that does not answer fails the unit"; fi
if grep -qx 'http://ping.test/deploy/fail' "$pings"; then
  ok "a silent listener pings /fail"
else
  bad "a silent listener pings /fail" "$(cat "$pings")"
fi

reset_case
printf '503\n' >"$FAKE_HEALTH_STATUS"
if run; then bad "a listener answering 503 fails the unit"; else ok "a listener answering 503 fails the unit"; fi
if grep -qx 'http://ping.test/deploy/fail' "$pings"; then
  ok "a non-200 health answer pings /fail"
else
  bad "a non-200 health answer pings /fail" "$(cat "$pings")"
fi

# The dead-man must never report both: a green ping alongside a /fail makes the
# check's state depend on the order Healthchecks received them.
reset_case
printf 'network\n' >"$FAKE_HEALTH_STATUS"
run
check_eq "$(grep -c 'ping.test/deploy$' "$pings" || true)" 0 "an unhealthy beat sends no green ping"

# --- a host without the ping URL is not a broken deploy ----------------------

# The decrypt step writes the URL; a host mid-bootstrap has none, and the
# heartbeat must journal the skip rather than page or fail.
reset_case
rm -f "$DEPLOY_PING_SECRET"
if run; then ok "a missing ping URL is a journaled skip, not a failure"; else bad "a missing ping URL is a journaled skip, not a failure" "$(cat "$work/stderr")"; fi
check_eq "$(journal_events notify-skipped)" 1 "the missing ping URL is journaled"

# --- the unit runs it every five minutes -------------------------------------

timer=units/systemd/smortress-deploy-heartbeat.timer
service=units/systemd/smortress-deploy-heartbeat.service
if [[ -s $timer ]]; then ok "the heartbeat timer ships"; else bad "the heartbeat timer ships"; fi
if [[ -s $service ]]; then ok "the heartbeat service ships"; else bad "the heartbeat service ships"; fi
if grep -qE '^OnCalendar=.*\*:0/5' "$timer" 2>/dev/null; then
  ok "the heartbeat runs every five minutes"
else
  bad "the heartbeat runs every five minutes" "$(cat "$timer" 2>/dev/null)"
fi
if grep -qE '^ExecStart=/usr/libexec/deploy-heartbeat$' "$service" 2>/dev/null; then
  ok "the service runs the installed script"
else
  bad "the service runs the installed script" "$(cat "$service" 2>/dev/null)"
fi
if grep -qE '^TimeoutStartSec=' "$service" 2>/dev/null; then
  ok "the heartbeat is bounded"
else
  bad "the heartbeat is bounded"
fi
if grep -qF 'smortress-deploy-heartbeat.timer' image/Containerfile; then
  ok "the image enables the heartbeat timer"
else
  bad "the image enables the heartbeat timer"
fi

finish
