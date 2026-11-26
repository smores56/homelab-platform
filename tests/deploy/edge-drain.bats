#!/usr/bin/env bats
# bats file_tags=deploy
# Offline checks for the edge's deploy plane (design #939, T8).
#
# The edge runs the server's shared drain loop with three things of its own: a
# no-op where the server's snapshot gate sits, a verifier whose `bootc switch` is
# the proof of the deployment (so the role hook must not switch again), and a
# deadline pair that has to clear the switch's own pull -- T6's review found the
# shared 300 s default under a 600 s switch, which kills a slow pull after bootc
# has already staged the entry. The queue is a throwaway directory, the verifier
# and `systemctl` are fakes, and the listener, the heartbeat and the units are the
# real files. No root, no reboot, no network.
#
#   bats tests/deploy/edge-drain.bats
load ../helpers

drain=bootc/edge/rootfs/usr/libexec/deploy-drain-edge
state_lib=scripts/deploy-state.sh
drain_lib=bootc/lib/deploy/drain.sh
receiver=bootc/lib/deploy/deploy-receiver.py
heartbeat=scripts/deploy-heartbeat.sh
fixtures=bootc/lib/deploy/fixtures
unit_dir=bootc/edge/rootfs/usr/lib/systemd/system
drain_unit=$unit_dir/smoresnet-deploy.service
listener_unit=$unit_dir/smoresnet-deploy-listener.service
heartbeat_unit=$unit_dir/smoresnet-deploy-heartbeat.service
heartbeat_timer=$unit_dir/smoresnet-deploy-heartbeat.timer
containerfile=bootc/edge/Containerfile

commit=0123456789abcdef0123456789abcdef01234567
denied=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
digest_index=sha256:1111111111111111111111111111111111111111111111111111111111111111
digest_manifest=sha256:2222222222222222222222222222222222222222222222222222222222222222
ping_url=https://hc.invalid/ping/edge

# The image tree the units run: the drain, the library it sources, the state
# library and the output helpers, installed under the names the Containerfile
# gives them, so the resolution this suite exercises is the image's.
setup_file() {
    bin=$BATS_FILE_TMPDIR/bin
    image=$BATS_FILE_TMPDIR/image
    mkdir -p "$bin"
    install -D -m 0755 "$drain" "$image/usr/libexec/deploy-drain-edge"
    install -D -m 0644 "$drain_lib" "$image/usr/libexec/deploy/drain.sh"
    install -D -m 0644 "$state_lib" "$image/usr/libexec/deploy-state"
    install -D -m 0644 scripts/lib/log.sh "$image/usr/libexec/lib/log.sh"

    # `systemctl` records what the drain asked it to do: a reboot that happened is
    # the whole of "the deployment was staged", and a rejected entry must not have
    # one.
    cat >"$bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_LOG/systemctl-calls"
exit "${STUB_SYSTEMCTL_EXIT:-0}"
STUB
    # One curl for the two jobs the heartbeat has: the health probe (a status in
    # $FAKE_HEALTH_STATUS, or `network` for a connect failure) and the page, whose
    # URL arrives as a curl config on stdin and never reaches argv.
    cat >"$bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_LOG/curl-calls"
out=/dev/stdout
url=
while (($#)); do
  case $1 in
    --output | -o) out=$2; shift 2 ;;
    --config) shift 2 ;;
    --fail | --fail-with-body) shift ;;
    --write-out | --header | --max-time | --retry) shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
if [[ -z $url ]]; then
  url=$(sed -n 's/^url = "\(.*\)"$/\1/p' | head -n 1)
fi
case ${url:-} in
  *healthz*)
    status=$(cat "$FAKE_HEALTH_STATUS" 2>/dev/null) || status=200
    [[ $status == network ]] && exit 7
    [[ $out == /dev/stdout ]] || printf '{"status":"ok"}' >"$out"
    [[ $status == 200 ]] && exit 0
    exit 22
    ;;
esac
printf '%s\n' "${url:-}" >>"$FAKE_LOG/pings"
exit 0
STUB
    chmod 0755 "$bin"/*
}

setup() {
    work=$BATS_TEST_TMPDIR
    log=$work/log
    state=$work/state
    image=$BATS_FILE_TMPDIR/image
    mkdir -p "$log" "$state/queue"
    export FAKE_LOG=$log
    # The one fake curl, handed to the programs that page (deploy_notify and the
    # heartbeat's health probe) rather than put on PATH: the listener's own
    # readiness probe below is the real one.
    export DEPLOY_CURL_BIN=$BATS_FILE_TMPDIR/bin/curl
    export FAKE_HEALTH_STATUS=$work/health-status
    export DEPLOY_STATE_DIR=$state
    export DEPLOY_LOCK_FILE=$work/deploy.lock
    export DEPLOY_PING_SECRET=$work/deploy-ping-url
    # The drain's own parking pause: the rescan exists for a burst of requests and
    # costs one second per idle drain, which is 16 seconds here for nothing.
    export DEPLOY_DRAIN_RESCAN_PAUSE=0
    export DEPLOY_RETRY_DELAY=300
    export DEPLOY_SYSTEMCTL=$BATS_FILE_TMPDIR/bin/systemctl
    export DEPLOY_VERIFY_BIN=$work/verify
    export STUB_SYSTEMCTL_EXIT=0
    printf '%s\n' "$ping_url" >"$DEPLOY_PING_SECRET"
    chmod 0600 "$DEPLOY_PING_SECRET"
    # The fake verifier answers whatever the test put in $work/verdict-exit and
    # $work/verdict, and records the argv the shared loop gave it.
    cat >"$work/verify" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_LOG/verify-calls"
cat "$FAKE_VERDICT" 2>/dev/null || true
exit "$(cat "$FAKE_VERDICT_EXIT" 2>/dev/null || printf 0)"
STUB
    chmod 0755 "$work/verify"
    export FAKE_VERDICT=$work/verdict
    export FAKE_VERDICT_EXIT=$work/verdict-exit
    printf '0\n' >"$FAKE_VERDICT_EXIT"
    jq -r '.expect.stdout' "$fixtures/platform-verified.json" >"$work/verdict"
    : >"$log/systemctl-calls"
    : >"$log/verify-calls"
    : >"$log/curl-calls"
    : >"$log/pings"
    # shellcheck source=/dev/null
    source "$state_lib"
    deploy_state_init
}

queue_seed() { # <id> <commit> [<repo>]
    jq -cn --arg id "$1" --arg commit "$2" --arg repo "${3:-homelab-platform}" \
        --argjson at "$(date +%s)" \
        '{schema:1,id:$id,repo:$repo,commit:$commit,queued_at:$at,source:"event"}' \
        >"$state/queue/$1.json"
}

queued() {
    find "$state/queue" -maxdepth 1 -name '*.json' -type f 2>/dev/null | wc -l | tr -d ' '
}

run_drain() {
    rc=0
    out=$(bash "$image/usr/libexec/deploy-drain-edge" 2>&1) || rc=$?
}

journal_count() { # <event>
    jq -r "select(.event==\"$1\") | .event" "$state/journal.jsonl" 2>/dev/null |
        wc -l | tr -d ' '
}

journal_field() { # <event> <jq-path>
    jq -r "select(.event==\"$1\") | $2" "$state/journal.jsonl" 2>/dev/null
}

pending_json() {
    cat "$state/pending.json" 2>/dev/null || printf '{}'
}

rebooted() {
    grep -q '^reboot' "$log/systemctl-calls"
}

# contains <text> <file>: a failure names the line that went missing instead of a
# bare status, because these assertions read files rather than run commands.
contains() {
    grep -qF -- "$1" "$2" || fail "missing '$1' in $2"
}

# unit_env: one Environment= line out of a unit, which is how this suite drives the
# edge's own knobs instead of a copy of them.
unit_env() { # <unit> <VAR>
    sed -n "s/^Environment=$2=//p" "$1" | head -n 1
}

# --- the queue is consumed and popped ---------------------------------------

@test "the edge consumes and pops a verified entry" {
    queue_seed 11111111-1111-4111-8111-111111111111 "$commit"
    run_drain
    assert_equal "$rc" 0
    assert_equal "$(queued)" 0
    assert_equal "$(journal_field drain-finish .drained)" 1
}

@test "the edge drain verifies the entry it was given" {
    queue_seed 11111111-1111-4111-8111-111111111111 "$commit"
    run_drain
    assert grep -qx -- "--repo homelab-platform --commit $commit" "$log/verify-calls"
}

# The verifier's switch already staged the boot entry, so the record it leaves is
# the whole of what the edge's hook has to add before the reboot.
@test "the edge writes the pending record the boot gate resumes from" {
    queue_seed 11111111-1111-4111-8111-111111111111 "$commit"
    run_drain
    assert_equal "$(jq -r '.commit' <<<"$(pending_json)")" "$commit"
    assert_equal "$(jq -r '.digests.index' <<<"$(pending_json)")" "$digest_index"
    assert_equal "$(jq -r '.digests.manifest' <<<"$(pending_json)")" "$digest_manifest"
    assert_equal "$(jq -r '.phase' <<<"$(pending_json)")" staged
}

@test "the edge reboots into the staged image" {
    queue_seed 11111111-1111-4111-8111-111111111111 "$commit"
    run_drain
    rebooted
}

# The one thing that must never happen on this host: the hook switching a second
# time. The verifier's switch is the signature verdict, and a second one would name
# an image nothing checked.
@test "the edge hook never runs bootc: the verifier's switch is the verdict" {
    run grep -nE '^[[:space:]]*[^#[:space:]].*\bbootc\b' "$drain"
    assert_failure
}

@test "the drain journals the no-op snapshot gate" {
    queue_seed 11111111-1111-4111-8111-111111111111 "$commit"
    run_drain
    assert_equal "$(journal_field snapshot-gate-skipped .role)" edge
}

# A rejection is final: the same commit fails identically next trigger, so the
# entry is popped and nothing is rebooted.
@test "a rejected entry is popped and never rebooted" {
    queue_seed 22222222-2222-4222-8222-222222222222 "$denied"
    printf '3\n' >"$FAKE_VERDICT_EXIT"
    jq -nc --arg c "$denied" '{verdict:"rejected",repo:"homelab-platform",
      commit:$c,reason:"denylisted"}' >"$work/verdict"
    run_drain
    assert_equal "$rc" 0
    assert_equal "$(queued)" 0
    assert_equal "$(journal_field drain-finish .rejected)" 1
    run rebooted
    assert_failure
}

# --- the deadline pair clears the verifier's switch --------------------------

@test "the drain's verification deadline sits above the verifier's switch timeout" {
    queue_seed 11111111-1111-4111-8111-111111111111 "$commit"
    run_drain
    verify=$(journal_field edge-drain-limits .verifyDeadline)
    switch=$(journal_field edge-drain-limits .switchTimeout)
    assert_equal "$switch" 600
    ((verify > switch))
}

@test "the two deadlines are derived from one knob, not two" {
    queue_seed 11111111-1111-4111-8111-111111111111 "$commit"
    export DEPLOY_SWITCH_TIMEOUT=900
    unset DEPLOY_VERIFY_DEADLINE
    run_drain
    assert_equal "$(journal_field edge-drain-limits .switchTimeout)" 900
    verify=$(journal_field edge-drain-limits .verifyDeadline)
    ((verify > 900))
}

# The bug T6's review found, as a refusal: a deadline under the switch kills a
# slow pull after bootc has written the entry, and the host then retries a
# deployment that was staged until the heartbeat pages.
@test "a deadline at or below the switch timeout is refused" {
    queue_seed 11111111-1111-4111-8111-111111111111 "$commit"
    export DEPLOY_SWITCH_TIMEOUT=900 DEPLOY_VERIFY_DEADLINE=900
    run_drain
    assert_not_equal "$rc" 0
    assert grep -q 'does not clear the verifier switch timeout' <<<"$out"
    assert_equal "$(queued)" 1
}

# --- the listener starts with no sops unit and answers /healthz -------------

@test "the edge listener names no sops unit" {
    run grep -E '^(Requires|Wants|After|Before)=.*sops-decrypt' "$listener_unit"
    assert_failure
}

@test "the edge listener reads its secret from /etc/smoresnet as the edge role" {
    assert_equal "$(unit_env "$listener_unit" DEPLOY_SECRETS_DIR)" /etc/smoresnet
    assert_equal "$(unit_env "$listener_unit" DEPLOY_ROLE)" edge
}

free_port() {
    python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()'
}

# start_listener: the receiver as the unit runs it. The two Environment= values
# are the unit's own; the secrets directory is the only thing overridden, because
# /etc/smoresnet is the host's.
start_listener() { # <secrets-dir> <log>
    local port _
    port=$(free_port)
    listener_base=http://127.0.0.1:$port
    env DEPLOY_ROLE="$(unit_env "$listener_unit" DEPLOY_ROLE)" \
        DEPLOY_SECRETS_DIR="$1" DEPLOY_STATE_DIR=$state \
        DEPLOY_LISTEN_PORT="$port" DEPLOY_LISTEN_HOST=127.0.0.1 \
        python3 "$receiver" >>"$2" 2>&1 &
    listener_pid=$!
    for _ in $(seq 1 100); do
        if [[ $(curl -s -o /dev/null -w '%{http_code}' --max-time 1 \
            "$listener_base/healthz" 2>/dev/null) == 200 ]]; then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

teardown() {
    kill "${listener_pid:-}" 2>/dev/null || true
    wait 2>/dev/null || true
}

secrets_fixture() { # <dir> <mode>
    mkdir -p "$1"
    chmod 0700 "$1"
    printf 'value: edge-%04d\n' "$RANDOM" >"$1/webhook-secret.yaml"
    chmod "$2" "$1/webhook-secret.yaml"
}

@test "the listener answers /healthz with no sops-decrypt anywhere on the host" {
    secrets_fixture "$work/secrets" 0600
    start_listener "$work/secrets" "$work/listener.log" ||
        fail "the listener never answered: $(tail -n 5 "$work/listener.log")"
    assert_equal "$(curl -s -o /dev/null -w '%{http_code}' "$listener_base/healthz")" 200
}

@test "a missing secret exits non-zero naming the file" {
    mkdir -p "$work/empty"
    rc=0
    DEPLOY_ROLE=edge DEPLOY_STATE_DIR=$state DEPLOY_SECRETS_DIR=$work/empty \
        DEPLOY_LISTEN_PORT="$(free_port)" timeout 20 python3 "$receiver" \
        >"$work/missing.log" 2>&1 || rc=$?
    assert_equal "$rc" 1
    assert grep -qF "$work/empty/webhook-secret.yaml" "$work/missing.log"
}

# Plaintext at rest is only 0600 if something refuses the alternative: a group- or
# world-readable HMAC key is the box's second factor published.
@test "a secret readable by group or other is refused, naming the file and its mode" {
    secrets_fixture "$work/loose" 0640
    rc=0
    DEPLOY_ROLE=edge DEPLOY_STATE_DIR=$state DEPLOY_SECRETS_DIR=$work/loose \
        DEPLOY_LISTEN_PORT="$(free_port)" timeout 20 python3 "$receiver" \
        >"$work/loose.log" 2>&1 || rc=$?
    assert_not_equal "$rc" 0
    assert grep -qF "$work/loose/webhook-secret.yaml is mode 0640" "$work/loose.log"
}

# --- the heartbeat pages a wedged queue ------------------------------------

# beat: one run of the shared dead-man under the edge unit's own limits, which is
# what makes this the edge's heartbeat rather than the server's. The unit's ping
# path is /etc/smoresnet's operator file, so the test's own is substituted for it.
edge_beat() {
    rc=0
    env DEPLOY_QUEUE_MAX_AGE="$(unit_env "$heartbeat_unit" DEPLOY_QUEUE_MAX_AGE)" \
        DEPLOY_PING_SECRET=$DEPLOY_PING_SECRET DEPLOY_STATE_DIR=$state \
        bash "$heartbeat" >"$work/stdout" 2>"$work/stderr" || rc=$?
}

@test "the edge heartbeat pages through the operator's file under /etc/smoresnet" {
    assert_equal "$(unit_env "$heartbeat_unit" DEPLOY_PING_SECRET)" \
        /etc/smoresnet/deploy-ping-url
    contains 'After=smoresnet-deploy-listener.service' "$heartbeat_unit"
    contains 'OnCalendar=*-*-* *:0/5:00' "$heartbeat_timer"
}

@test "the edge heartbeat's queue limit is above the verifier's deadline" {
    limit=$(unit_env "$heartbeat_unit" DEPLOY_QUEUE_MAX_AGE)
    [[ $limit =~ ^[0-9]+$ ]] || fail "no DEPLOY_QUEUE_MAX_AGE in $heartbeat_unit"
    # The edge's slowest honest wait: the drain's own verification deadline plus
    # one reboot. Two hours (the server's limit) would let a wedged edge queue sit
    # through 24 missed beats on the host with the least rollback.
    ((limit > 1200))
    ((limit < 7200))
}

@test "a fresh queue entry keeps the edge check green" {
    queue_seed 33333333-3333-4333-8333-333333333333 "$commit"
    edge_beat
    assert_equal "$rc" 0
    assert grep -qx "$ping_url" "$log/pings"
}

@test "a wedged queue pings /fail" {
    queue_seed 44444444-4444-4444-8444-444444444444 "$commit"
    jq -c --argjson at "$(($(date +%s) - 2000))" '.queued_at = $at' \
        "$state/queue/44444444-4444-4444-8444-444444444444.json" |
        atomic_write "$state/queue/44444444-4444-4444-8444-444444444444.json"
    edge_beat
    assert_equal "$rc" 1
    assert grep -qx "$ping_url/fail" "$log/pings"
}

@test "a silent listener pings /fail on the edge too" {
    printf 'network\n' >"$FAKE_HEALTH_STATUS"
    edge_beat
    assert_equal "$rc" 1
    assert grep -qx "$ping_url/fail" "$log/pings"
}

# --- the image installs what the units run ---------------------------------

@test "the edge image installs and enables the deploy plane's units" {
    contains 'smoresnet-deploy-listener.service' "$containerfile"
    contains 'smoresnet-deploy-heartbeat.timer' "$containerfile"
    contains 'COPY bootc/lib/deploy/deploy-receiver.py /usr/libexec/deploy-receiver.py' \
        "$containerfile"
    contains 'COPY bootc/lib/deploy/drain.sh /usr/libexec/deploy/drain.sh' "$containerfile"
    contains 'COPY scripts/deploy-heartbeat.sh /usr/libexec/deploy-heartbeat' "$containerfile"
}

@test "every program the edge deploy units run is in the image tree" {
    for unit in "$drain_unit" "$listener_unit" "$heartbeat_unit"; do
        program=$(sed -n 's/^ExecStart=//p' "$unit" | awk '{ print $NF }')
        [[ -n $program ]] || fail "$unit has no ExecStart"
        # Either the rootfs ships it (executable in git) or the Containerfile
        # copies it in under that name.
        rootfs=bootc/edge/rootfs$program
        if [[ -e $rootfs ]]; then
            [[ -x $rootfs ]] || fail "$rootfs is committed non-executable"
        else
            grep -qF " /usr/libexec/$(basename "$program")" "$containerfile" ||
                fail "$program is run by $(basename "$unit") and nothing installs it"
        fi
    done
}

@test "the edge drain unit is started by the queue, not by boot" {
    # The trigger is the queue: smoresnet-deploy.path fires on the first request a
    # notify or the poll enqueued (design #939, T11). The drain itself must exist
    # and be startable, and must not claim an [Install] that would boot it, which
    # would drain a queue nobody had filled.
    run grep -q '^\[Install\]' "$drain_unit"
    assert_failure
    contains 'ExecStart=/usr/libexec/deploy-drain-edge' "$drain_unit"
}
