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
# and `systemctl` are fakes, and the units are the real files.
# No root, no reboot, no network.
#
#   bats tests/deploy/edge-drain.bats
load ../helpers

drain=bootc/edge/rootfs/usr/libexec/deploy-drain-edge
state_lib=scripts/deploy-state.sh
drain_lib=bootc/lib/deploy/drain.sh
fixtures=bootc/lib/deploy/fixtures
unit_dir=bootc/edge/rootfs/usr/lib/systemd/system
drain_unit=$unit_dir/smoresnet-deploy.service
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
    # One curl for the drain's page, whose URL arrives as a curl config on stdin
    # and never reaches argv.
    cat >"$bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_LOG/curl-calls"
url=
while (($#)); do
  case $1 in
    --output | -o | --config | --write-out | --header | --max-time | --retry) shift 2 ;;
    --fail | --fail-with-body) shift ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
if [[ -z $url ]]; then
  url=$(sed -n 's/^url = "\(.*\)"$/\1/p' | head -n 1)
fi
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
    # The one fake curl, handed to deploy_notify rather than put on PATH.
    export DEPLOY_CURL_BIN=$BATS_FILE_TMPDIR/bin/curl
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
# deployment that was staged until the poll's dead-man pages.
@test "a deadline at or below the switch timeout is refused" {
    queue_seed 11111111-1111-4111-8111-111111111111 "$commit"
    export DEPLOY_SWITCH_TIMEOUT=900 DEPLOY_VERIFY_DEADLINE=900
    run_drain
    assert_not_equal "$rc" 0
    assert grep -q 'does not clear the verifier switch timeout' <<<"$out"
    assert_equal "$(queued)" 1
}

# --- the dead-man is the poll's, on this host too ---------------------------

# The edge ran the shared heartbeat on a five-minute timer until #1019. The poll
# runs the same liveness verdict every fifteen minutes on both hosts, and one check
# with two reporters would flap: the heartbeat's program and its units are gone,
# and the poll's unit is where the edge's ping URL now lives.
@test "the edge keeps no heartbeat to race the poll" {
    refute ls "$unit_dir"/smoresnet-deploy-heartbeat.* 2>/dev/null
    refute grep -q 'smoresnet-deploy-heartbeat' "$containerfile"
}

# --- the image installs what the units run ---------------------------------

@test "the edge image installs and enables the deploy plane's units" {
    contains 'smoresnet-deploy-poll.timer' "$containerfile"
    contains 'COPY bootc/lib/deploy/drain.sh /usr/libexec/deploy/drain.sh' "$containerfile"
}

@test "every program the edge deploy units run is in the image tree" {
    for unit in "$drain_unit" "$unit_dir/smoresnet-deploy-poll.service"; do
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
