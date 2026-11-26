#!/usr/bin/env bats
# bats file_tags=deploy
# Offline checks for staging, the reboot and the post-boot gate (SDLC #798, T4).
#
# A platform deploy ends in a reboot, so the half that decides whether the host
# should keep what it booted lives here: the exact `bootc switch` argv, the
# staged-digest check against what the verifier recorded, `pending.json` before
# the reboot, the booted-versus-pending comparison, the host health gate and its
# budget, the denylist and the rollback argv, and the GRUB flags that let an
# unbootable deployment fall back without userspace. `bootc`, `systemctl`,
# `grub2-editenv`, `tailscale`, `zpool` and `mountpoint` are fakes on PATH and
# the state is a throwaway directory; the records, the journal and the command
# lines are real. No root, no reboot, no image, no network.
#
# The gate judges the host only. The tenant's apps -- unit active, loopback port
# answering, Serve path declared -- belong to tests/deploy/apps-health.bats, and
# the fixtures here keep an app the gate would have found broken, so a gate that
# starts judging the tenant again fails this suite.
#
#   bats tests/deploy/boot.bats
load ../helpers

platform=scripts/deploy-platform.sh
gate=scripts/smortress-boot-gate.sh
lib=scripts/deploy-state.sh
snippet=bootc/server/rootfs/usr/lib/bootupd/grub2-static/configs.d/10-smortress-count.cfg

commit=9f2c0d3b1a4e5f60718293a4b5c6d7e8f9012345
digest_index=sha256:1111111111111111111111111111111111111111111111111111111111111111
digest_manifest=sha256:2222222222222222222222222222222222222222222222222222222222222222
digest_other=sha256:3333333333333333333333333333333333333333333333333333333333333333
digest_prev_index=sha256:4444444444444444444444444444444444444444444444444444444444444444
digest_prev_manifest=sha256:5555555555555555555555555555555555555555555555555555555555555555
prev_commit=abcdef0123456789abcdef0123456789abcdef01
image_ref=ghcr.io/smores56/homelab-platform/server
digests=$(jq -nc --arg i "$digest_index" --arg m "$digest_manifest" '{index:$i,manifest:$m}')
ping_url=https://hc.invalid/ping/abc

# Nothing ever listens on this port. The plan, the tenant's active-unit list and
# the Serve stub keep a healthy-looking app whose port is closed and whose path
# can be removed: the fixtures are exactly the three failures the gate used to
# judge, so a gate that starts judging the tenant again fails this suite instead
# of rolling a host back silently.
app_port=34611

# The fakes are the same for every test and are written once per file; the state,
# the records, the GRUB block and the logs are per test.
setup_file() {
    bin=$BATS_FILE_TMPDIR/bin
    mkdir -p "$bin" "$BATS_FILE_TMPDIR/log"

    # `bootc` reports whatever the test put in its state file, so "staged image is
    # not the one that was verified" and "this boot is not the staged deployment"
    # are one file each and not two code paths.
    cat >"$bin/bootc" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG/bootc-calls"
staged=$(sed -n 's/^staged=//p' "$STUB_BOOTC_STATE" 2>/dev/null)
booted=$(sed -n 's/^booted=//p' "$STUB_BOOTC_STATE" 2>/dev/null)
booted_spec=$(sed -n 's/^booted_spec=//p' "$STUB_BOOTC_STATE" 2>/dev/null)
case ${1-} in
  switch)
    # A real switch stages the image it names. The default is to leave the entry
    # alone so a test can simulate a switch that staged something else; setting
    # STUB_BOOTC_STAGE_ON_SWITCH makes a switch to that digest stage it.
    target=${*: -1}
    if [[ -n ${STUB_BOOTC_STAGE_ON_SWITCH:-} &&
      $target == *"@$STUB_BOOTC_STAGE_ON_SWITCH" ]]; then
      printf 'staged=%s\nbooted=%s\n' "$STUB_BOOTC_STAGE_ON_SWITCH" "$booted" \
        >"$STUB_BOOTC_STATE"
    fi
    exit "${STUB_BOOTC_SWITCH_EXIT:-0}"
    ;;
  upgrade)
    # Moving within the tracked reference stages the same way a switch does.
    if [[ -n ${STUB_BOOTC_UPGRADE_STAGE:-} ]]; then
      printf 'staged=%s\nbooted=%s\nbooted_spec=%s\n' \
        "$STUB_BOOTC_UPGRADE_STAGE" "$booted" "$booted_spec" >"$STUB_BOOTC_STATE"
    fi
    exit "${STUB_BOOTC_UPGRADE_EXIT:-0}"
    ;;
  rollback) exit "${STUB_BOOTC_ROLLBACK_EXIT:-0}" ;;
  status)
    if [[ " $* " == *" --booted "* ]]; then
      jq -nc --arg d "$booted" --arg s "$booted_spec" \
        '{status:{booted:{image:{imageDigest:(if $d == "" then null else $d end),image:(if $s == "" then null else $s end)}}}}'
    elif [[ -n ${STUB_BOOTC_NO_STAGED:-} ]]; then
      jq -nc --arg d "$booted" '{status:{booted:{image:{imageDigest:$d}}}}'
    else
      if [[ -n ${STUB_BOOTC_STAGE_AFTER:-} ]]; then
        n=$(cat "$STUB_LOG/stage-count" 2>/dev/null || printf 0)
        if ((n < STUB_BOOTC_STAGE_AFTER)); then
          printf '%s\n' $((n + 1)) >"$STUB_LOG/stage-count"
          staged=$STUB_BOOTC_STAGE_OLD
        fi
      fi
      jq -nc --arg s "$staged" --arg b "$booted" '
        def img($v): {image:{imageDigest:(if $v == "" then null else $v end)}};
        {status:{staged:img($s),booted:img($b)}}'
    fi
    ;;
  *) exit 0 ;;
esac
STUB

    # `systemctl reboot` records whether `pending.json` was already on disk, which
    # is the only way to prove the order of the two without a real reboot.
    cat >"$bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG/systemctl-calls"
scope=system
rest=()
for a in "$@"; do
  case $a in
    --user | --machine=*) scope=user ;;
    *) rest+=("$a") ;;
  esac
done
verb=${rest[0]-}
unit=${rest[1]-}
case $verb in
  reboot)
    pending=no
    [[ -s $DEPLOY_STATE_DIR/pending.json ]] && pending=yes
    printf 'reboot pending=%s\n' "$pending" >>"$STUB_LOG/systemctl-calls"
    exit 0
    ;;
  is-active)
    printf 'is-active %s\n' "$unit" >>"$STUB_LOG/gate-order"
    if [[ $scope == user ]]; then file=$STUB_SYSTEMCTL_USER_ACTIVE; else file=$STUB_SYSTEMCTL_ACTIVE; fi
    if grep -qxF -- "$unit" "$file" 2>/dev/null; then
      printf 'active\n'
      exit 0
    fi
    printf 'inactive\n'
    exit 3
    ;;
  is-failed)
    if grep -qxF -- "$unit" "${STUB_SYSTEMCTL_FAILED:-/nonexistent}" 2>/dev/null; then
      printf 'failed\n'
      exit 1
    fi
    printf 'active\n'
    exit 0
    ;;
  *) exit 0 ;;
esac
STUB

    # `grub2-editenv` is a real key=value store here, so the assertions read the
    # same file the GRUB snippet would.
    cat >"$bin/grub2-editenv" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG/grub-calls"
file=${1-}
shift || true
verb=${1-}
shift || true
write() {
  tmp=$file.tmp
  {
    grep -v -F -e "$1=" "$file" 2>/dev/null || true
    [[ -n ${2+x} ]] && printf '%s=%s\n' "$1" "$2"
  } >"$tmp"
  mv "$tmp" "$file"
}
case $verb in
  set)
    for kv in "$@"; do write "${kv%%=*}" "${kv#*=}"; done
    ;;
  unset)
    for k in "$@"; do write "$k"; done
    ;;
esac
exit 0
STUB

    cat >"$bin/tailscale" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG/tailscale-calls"
if [[ $* == "serve status --json" ]]; then
  cat "$STUB_SERVE_JSON"
fi
exit 0
STUB

    cat >"$bin/zpool" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG/zpool-calls"
[[ ${STUB_ZPOOL_OK:-1} == 1 ]] || exit 1
printf '%s\n' "${*: -1}"
STUB

    cat >"$bin/mountpoint" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG/mountpoint-calls"
[[ ${STUB_MOUNTPOINT_OK:-1} == 1 ]] || exit 1
exit 0
STUB

    # deploy_notify hands the URL over as a curl config on stdin, never in argv.
    cat >"$bin/curl" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
url=
while (($#)); do
  case $1 in
    --config | --max-time | --retry | --connect-timeout | --write-out) shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
if [[ -z $url ]]; then
  url=$(sed -n 's/^url = "\(.*\)"$/\1/p' | head -n 1)
fi
printf '%s\n' "${url:-}" >>"$FAKE_PING_LOG"
exit 0
STUB

    # The apps revert is a separate program with its own suite (tests/deploy/apps.bats);
    # here it stands in for the gate's call, removes the record the way a successful
    # revert does, and shares one ordering log with the health checks.
    cat >"$bin/deploy-apps" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG/apps-calls"
printf 'deploy-apps %s\n' "$*" >>"$STUB_LOG/gate-order"
if [[ ${1:-} == revert && ${STUB_APPS_KEEP_APPLY:-0} != 1 && ${STUB_APPS_EXIT:-0} == 0 ]]; then
  rm -f "$DEPLOY_STATE_DIR/apply.json"
fi
exit "${STUB_APPS_EXIT:-0}"
STUB
    chmod 0755 "$bin"/*
}

# Every test starts from the healthy host and the two-second gate budget; bats
# runs a file's tests in parallel, so the state, the records, the GRUB block and
# the logs are per test.
setup() {
    work=$BATS_TEST_TMPDIR
    log=$work/log
    state_dir=$work/state
    mkdir -p "$log"
    export PATH="$BATS_FILE_TMPDIR/bin:$PATH"
    export DEPLOY_STATE_DIR=$state_dir
    export DEPLOY_LOCK_FILE=$work/deploy.lock
    export DEPLOY_PING_SECRET=$work/deploy-ping-url.yaml
    export DEPLOY_UNITS_FILE=$work/deploy-units.txt
    export APPS_PLAN=$work/plan.json
    export GRUB_ENV=$work/grubenv
    # The gate only writes the flags when grub.cfg reads the counter; a fixture
    # with the snippet's variable stands in for a host where boot counting was
    # installed.
    export GRUB_CFG=$work/grub.cfg
    export STUB_LOG=$log
    export FAKE_PING_LOG=$log/curl-urls
    export STUB_BOOTC_STATE=$work/bootc-state
    export STUB_SYSTEMCTL_ACTIVE=$work/active-units
    export STUB_SYSTEMCTL_USER_ACTIVE=$work/active-user-units
    export STUB_SYSTEMCTL_FAILED=$work/failed-units
    export STUB_SERVE_JSON=$work/serve.json
    export DEPLOY_APPS_BIN=$BATS_FILE_TMPDIR/bin/deploy-apps
    # Keep the finalize poll short in tests; production uses the one-second default.
    export DEPLOY_STAGE_POLL_INTERVAL=0.1 DEPLOY_STAGE_POLL_ATTEMPTS=3
    # shellcheck source=/dev/null
    source "$lib"
    deploy_state_init
    reset_case
}

journal_field() { # <event> <jq-path>
    jq -r "select(.event==\"$1\") | $2" "$state_dir/journal.jsonl" 2>/dev/null
}

# The GRUB environment block is a flat key=value file; this reads it the same way
# in every assertion so a missing key is a null rather than an empty string.
grub_flags() { # <jq path>
    sed 's/^\([^=]*\)=\(.*\)$/{"\1":"\2"}/' "$GRUB_ENV" 2>/dev/null | jq -sc 'add // {}' |
        jq -r "$1" 2>/dev/null
}

serve_healthy() {
    jq -nc --argjson port "$app_port" \
        '{"Web":{":443":{"Handlers":{"/apps/demo":{Proxy:("http://127.0.0.1:" + ($port | tostring))}}}}}' \
        >"$STUB_SERVE_JSON"
}

seed_pending() { # <index> <manifest> <commit> [<booted>] [<booted spec>]
    jq -nc --arg i "$1" --arg m "$2" --arg c "$3" \
        '{schema:1,phase:"staged",commit:$c,digest:$i,digests:{index:$i,manifest:$m},
      stagedAt:"2026-11-20T00:00:00Z"}' | pending_write || return 1
    printf 'staged=%s\nbooted=%s\nbooted_spec=%s\n' "$2" "$4" "${5:-}" >"$STUB_BOOTC_STATE"
}

reset_case() { # keep the fakes' healthy answers, drop every record
    rm -f "$state_dir/state.json" "$state_dir/pending.json" "$state_dir/apply.json" \
        "$state_dir/held.json" "$state_dir/denylist.json" "$state_dir/journal.jsonl"
    rm -f "$DEPLOY_PING_SECRET" "$GRUB_ENV" "$STUB_BOOTC_STATE" "$log/stage-count"
    : >"$log/bootc-calls"
    : >"$log/systemctl-calls"
    : >"$log/grub-calls"
    : >"$log/curl-urls"
    : >"$log/tailscale-calls"
    : >"$log/zpool-calls"
    : >"$log/mountpoint-calls"
    : >"$log/apps-calls"
    : >"$log/gate-order"
    unset STUB_BOOTC_SWITCH_EXIT STUB_BOOTC_ROLLBACK_EXIT STUB_BOOTC_NO_STAGED \
        STUB_BOOTC_STAGE_ON_SWITCH STUB_BOOTC_STAGE_AFTER STUB_BOOTC_STAGE_OLD \
        STUB_ZPOOL_OK STUB_MOUNTPOINT_OK GRUB_EDITEV STUB_APPS_EXIT \
        STUB_APPS_KEEP_APPLY
    # A two-second budget keeps the failed-health cases short while still proving
    # that the gate retries instead of deciding on the first look.
    export DEPLOY_BOOT_GATE_BUDGET=2 DEPLOY_BOOT_GATE_PAUSE=1
    printf 'core-one.service\ncore-two.service\n' >"$DEPLOY_UNITS_FILE"
    printf 'core-one.service\ncore-two.service\n' >"$STUB_SYSTEMCTL_ACTIVE"
    printf 'demo.service\n' >"$STUB_SYSTEMCTL_USER_ACTIVE"
    : >"$STUB_SYSTEMCTL_FAILED"
    printf '%s\n' "$ping_url" >"$DEPLOY_PING_SECRET"
    printf 'boot_success=0\nboot_counter=2\ndefault=0\n' >"$GRUB_ENV"
    printf 'set boot_counter=3\n' >"$GRUB_CFG"
    jq -nc --argjson port "$app_port" \
        '{version:1,apps:{demo:{basePath:"/apps/demo",containerPort:8080,loopbackPort:$port}}}' \
        >"$APPS_PLAN"
    serve_healthy
}

run_stage() {
    rc=0
    out=$(bash "$platform" stage "$@" 2>&1) || rc=$?
}

run_gate() {
    rc=0
    out=$(bash "$gate" 2>&1) || rc=$?
}

expect_failure() {
    ((rc != 0)) && return 0
    printf '%s\n' "$out" >&2
    return 1
}

state_json() { # the recorded state, or an empty object
    cat "$state_dir/state.json" 2>/dev/null || printf '{}'
}

denylist_json() {
    cat "$state_dir/denylist.json" 2>/dev/null || printf '{}'
}

last_bootc_call() {
    tail -n 1 "$log/bootc-calls"
}

# --- 1. stage: the exact switch argv, then the staged-digest check ----------
# The host is running the previous deployment and bootc staged the new one: if
# booted already equalled the verified digest, stage would (correctly) record an
# already-running image and never reboot.
stage_verified() {
    printf 'staged=%s\nbooted=%s\n' "$digest_manifest" "$digest_prev_manifest" >"$STUB_BOOTC_STATE"
    run_stage --commit "$commit" --digests "$digests"
}

@test "a stage whose digest bootc reports passes" {
    stage_verified
    assert_equal "$rc" 0
}

@test "stage switches to the verified manifest digest and enforces the signature policy" {
    stage_verified
    assert_equal "$(grep '^switch ' "$log/bootc-calls" | head -n 1)" \
        "switch --enforce-container-sigpolicy $image_ref@$digest_manifest"
}

@test "stage never applies the deployment" {
    stage_verified
    refute grep -qF -- '--apply' "$log/bootc-calls"
}

@test "stage reads the staged entry back" {
    stage_verified
    assert grep -qF -- 'status --json' "$log/bootc-calls"
}

@test "pending.json records a staged deploy" {
    stage_verified
    assert_equal "$(jq -r '.phase' <<<"$(cat "$state_dir/pending.json")")" staged
}

@test "pending.json records the commit" {
    stage_verified
    assert_equal "$(jq -r '.commit' <<<"$(cat "$state_dir/pending.json")")" "$commit"
}

@test "pending.json records the index digest" {
    stage_verified
    assert_equal "$(jq -r '.digests.index' <<<"$(cat "$state_dir/pending.json")")" "$digest_index"
}

@test "pending.json records the manifest digest" {
    stage_verified
    assert_equal "$(jq -r '.digests.manifest' <<<"$(cat "$state_dir/pending.json")")" "$digest_manifest"
}

@test "pending.json carries no unused boot budget" {
    stage_verified
    assert_equal "$(jq -r 'has("budget")' <<<"$(cat "$state_dir/pending.json")")" false
}

@test "pending.json is on disk before the reboot is requested" {
    stage_verified
    assert grep -qF -- 'reboot pending=yes' "$log/systemctl-calls"
}

@test "the stage is journaled" {
    stage_verified
    assert_equal "$(journal_field stage-pending '.digest')" "$digest_index"
}

@test "staging records no landed deployment" {
    stage_verified
    assert [ ! -e "$state_dir/state.json" ]
}

@test "a clean stage notifies nothing" {
    stage_verified
    refute grep -qF -- "$ping_url" "$log/curl-urls"
}

# A switch returns before ostree-finalize-staged writes the entry. The poll must
# wait for the verified digest instead of accepting the stale staged entry.
stage_waits_for_finalize() {
    printf 'staged=%s\nbooted=%s\n' "$digest_other" "$digest_prev_manifest" >"$STUB_BOOTC_STATE"
    export STUB_BOOTC_STAGE_ON_SWITCH=$digest_manifest
    export STUB_BOOTC_STAGE_AFTER=2
    export STUB_BOOTC_STAGE_OLD=$digest_other
    run_stage --commit "$commit" --digests "$digests"
    unset STUB_BOOTC_STAGE_ON_SWITCH STUB_BOOTC_STAGE_AFTER STUB_BOOTC_STAGE_OLD
}

@test "a stage waits for the finalize to publish the verified digest" {
    stage_waits_for_finalize
    assert_equal "$rc" 0
}

@test "the waited-for stage writes its pending record" {
    stage_waits_for_finalize
    assert_equal "$(jq -r '.phase' <<<"$(cat "$state_dir/pending.json" 2>/dev/null)")" staged
}

@test "the waited-for stage reaches the reboot" {
    stage_waits_for_finalize
    assert grep -qF -- 'reboot' "$log/systemctl-calls"
}

# A restore that leaves the pre-switch entry unchanged must not claim success:
# the switch may not have overridden a pending finalize.
stage_restore_unchanged() {
    state_record_verified homelab-platform "$prev_commit" "$digest_prev_index" "$digest_prev_manifest"
    printf 'staged=%s\nbooted=%s\n' "$digest_prev_manifest" "$digest_other" >"$STUB_BOOTC_STATE"
    export STUB_BOOTC_STAGE_ON_SWITCH=$digest_prev_manifest
    run_stage --commit "$commit" --digests "$digests"
    unset STUB_BOOTC_STAGE_ON_SWITCH
}

@test "a restore that did not change the staged entry refuses" {
    stage_restore_unchanged
    assert_equal "$rc" 5
}

@test "the unchanged restore is journaled as a failure" {
    stage_restore_unchanged
    assert_equal "$(journal_field stage-restore-failed '.staged')" "$digest_prev_manifest"
}

@test "the unchanged restore writes no pending record" {
    stage_restore_unchanged
    assert [ ! -e "$state_dir/pending.json" ]
}

# bootc may report the index form for the same staged image, and a host that
# reports the form the reference did not use must still pass.
stage_index_form() {
    printf 'staged=%s\nbooted=%s\n' "$digest_index" "$digest_prev_manifest" >"$STUB_BOOTC_STATE"
    run_stage --commit "$commit" --digests "$digests"
}

@test "a staged image reported as the index form passes" {
    stage_index_form
    assert_equal "$rc" 0
}

@test "the index form still reaches the reboot" {
    stage_index_form
    assert grep -qF -- 'reboot' "$log/systemctl-calls"
}

# --- 2. stage: a staged digest nobody verified refuses, records nothing -----
stage_unverified() {
    printf 'staged=%s\nbooted=%s\n' "$digest_other" "$digest_other" >"$STUB_BOOTC_STATE"
    run_stage --commit "$commit" --digests "$digests"
}

@test "a staged digest that is not the verified one is refused with exit 5" {
    stage_unverified
    assert_equal "$rc" 5
}

@test "a refused stage writes no pending record" {
    stage_unverified
    assert [ ! -e "$state_dir/pending.json" ]
}

@test "a refused stage never reboots" {
    stage_unverified
    refute grep -qF -- 'reboot' "$log/systemctl-calls"
}

@test "the refusal journals the digest bootc reported" {
    stage_unverified
    assert_equal "$(journal_field stage-digest-mismatch '.staged')" "$digest_other"
}

@test "the refusal journals the digest that was verified" {
    stage_unverified
    assert_equal "$(journal_field stage-digest-mismatch '.digest')" "$digest_index"
}

@test "a refused stage pages the deploy check" {
    stage_unverified
    assert_equal "$(head -n 1 "$log/curl-urls")" "$ping_url/fail"
}

# A manual `bootc upgrade` leaves the state naming an older commit. When the
# booted image is the verified one there is nothing to stage, and that must
# record the deployment rather than refuse a null staged entry.
stage_already_booted() {
    printf 'staged=\nbooted=%s\n' "$digest_manifest" >"$STUB_BOOTC_STATE"
    run_stage --commit "$commit" --digests "$digests"
}

@test "an already-booted verified image is recorded, not refused" {
    stage_already_booted
    assert_equal "$rc" 6
}

@test "an already-booted image never reboots" {
    stage_already_booted
    refute grep -qF -- 'reboot' "$log/systemctl-calls"
}

@test "the already-booted image is journaled" {
    stage_already_booted
    assert_equal "$(journal_field stage-already-booted '.commit')" "$commit"
}

@test "the already-booted image is recorded in state" {
    stage_already_booted
    assert_equal "$(jq -r '.repos["homelab-platform"].commit' <<<"$(state_json)")" "$commit"
}

# A stage always names the verified digest, so the tag cannot move underneath it.
# The already-booted case above covers a manual `bootc upgrade` that landed the
# same digest without the deploy.
stage_null_staged() {
    export STUB_BOOTC_NO_STAGED=1
    run_stage --commit "$commit" --digests "$digests"
    unset STUB_BOOTC_NO_STAGED
}

@test "a null staged entry is refused with exit 5" {
    stage_null_staged
    assert_equal "$rc" 5
}

@test "a null staged entry writes no pending record" {
    stage_null_staged
    assert [ ! -e "$state_dir/pending.json" ]
}

@test "a null staged entry never reboots" {
    stage_null_staged
    refute grep -qF -- 'reboot' "$log/systemctl-calls"
}

# The switch is already on disk, so a mismatch that is only refused would leave
# the next boot staging an image nobody verified. The other deployment is put back
# and the read-back has to prove it.
stage_restored() {
    state_record_verified homelab-platform "$prev_commit" "$digest_prev_index" "$digest_prev_manifest"
    printf 'staged=%s\nbooted=%s\n' "$digest_other" "$digest_other" >"$STUB_BOOTC_STATE"
    export STUB_BOOTC_STAGE_ON_SWITCH=$digest_prev_manifest
    run_stage --commit "$commit" --digests "$digests"
    unset STUB_BOOTC_STAGE_ON_SWITCH
}

@test "a refused stage still exits 5 after restoring the deployed image" {
    stage_restored
    assert_equal "$rc" 5
}

@test "the refused stage switches back to the recorded deployed digest" {
    stage_restored
    assert_equal "$(grep '^switch ' "$log/bootc-calls" | tail -n 1)" \
        "switch --enforce-container-sigpolicy $image_ref@$digest_prev_manifest"
}

@test "the restored staged entry is journaled with what bootc had staged" {
    stage_restored
    assert_equal "$(journal_field stage-restored '.from')" "$digest_other"
}

@test "a restored stage is not journaled as a failed restore" {
    stage_restored
    assert_equal "$(journal_field stage-restore-failed '.staged')" ''
}

@test "a restored stage writes no pending record" {
    stage_restored
    assert [ ! -e "$state_dir/pending.json" ]
}

@test "a restored stage never reboots" {
    stage_restored
    refute grep -qF -- 'reboot' "$log/systemctl-calls"
}

# A restore that also fails leaves the host one switch away from an unverified
# boot, which the operator has to hear about.
stage_restore_failed() {
    state_record_verified homelab-platform "$prev_commit" "$digest_prev_index" "$digest_prev_manifest"
    printf 'staged=%s\nbooted=%s\n' "$digest_other" "$digest_other" >"$STUB_BOOTC_STATE"
    run_stage --commit "$commit" --digests "$digests"
}

@test "a stage whose restore does not take still refuses" {
    stage_restore_failed
    assert_equal "$rc" 5
}

@test "the failed restore is journaled with the digest still staged" {
    stage_restore_failed
    assert_equal "$(journal_field stage-restore-failed '.staged')" "$digest_other"
}

@test "a failed restore pages the deploy check" {
    stage_restore_failed
    assert_equal "$(tail -n 1 "$log/curl-urls")" "$ping_url/fail"
}

# --- 3. the gate on a boot that is the staged deployment --------------------
gate_on_staged_deployment() {
    seed_pending "$digest_index" "$digest_manifest" "$commit" "$digest_manifest"
    run_gate
}

@test "a healthy host on the staged deployment passes the gate" {
    gate_on_staged_deployment
    assert_equal "$rc" 0
}

@test "the gate journals the landed commit" {
    gate_on_staged_deployment
    assert_equal "$(journal_field boot-gate-green '.commit')" "$commit"
}

@test "the gate records the deployed commit" {
    gate_on_staged_deployment
    assert_equal "$(jq -r '.repos["homelab-platform"].commit' <<<"$(state_json)")" "$commit"
}

@test "the gate records the index digest" {
    gate_on_staged_deployment
    assert_equal "$(jq -r '.repos["homelab-platform"].indexDigest' <<<"$(state_json)")" "$digest_index"
}

@test "the gate records the manifest digest" {
    gate_on_staged_deployment
    assert_equal "$(jq -r '.repos["homelab-platform"].manifestDigest' <<<"$(state_json)")" "$digest_manifest"
}

@test "success sets boot_success" {
    gate_on_staged_deployment
    assert_equal "$(grub_flags '.boot_success')" 1
}

@test "success resets the boot counter" {
    gate_on_staged_deployment
    assert_equal "$(grub_flags '.boot_counter')" 3
}

@test "success clears the pending record" {
    gate_on_staged_deployment
    assert [ ! -e "$state_dir/pending.json" ]
}

@test "success pings the deploy check" {
    gate_on_staged_deployment
    assert_equal "$(cat "$log/curl-urls")" "$ping_url"
}

@test "a healthy boot rolls nothing back" {
    gate_on_staged_deployment
    refute grep -qF -- 'rollback' "$log/bootc-calls"
}

# The gate judges the host, and the plan's app is not part of that: the port
# below nothing listens on and a Serve query it never makes are the prober's
# business (tests/deploy/apps-health.bats).
@test "the gate probes no tenant unit" {
    gate_on_staged_deployment
    refute grep -qF -- 'demo.service' "$log/systemctl-calls"
}

@test "the gate asks no user manager anything" {
    gate_on_staged_deployment
    refute grep -qF -- '--user' "$log/systemctl-calls"
}

@test "the gate reads no Serve status" {
    gate_on_staged_deployment
    assert [ ! -s "$log/tailscale-calls" ]
}

@test "a healthy boot denylists nothing" {
    gate_on_staged_deployment
    assert_equal "$(jq -r '.digests | length' <<<"$(denylist_json)")" 0
}

# A signed release that the operator had held is cleared once it lands, so
# `status` stops reporting a hold that no longer exists.
gate_clears_released_hold() {
    seed_pending "$digest_index" "$digest_manifest" "$commit" "$digest_index"
    jq -nc --arg d "$digest_index" --arg c "$commit" \
        '{schema:1,digest:$d,commit:$c,digests:{index:$d,manifest:$d},missingUnits:[],reason:"x",
        heldAt:"2026-11-20T00:00:00Z",released:true,releasedBy:"alice"}' | held_write
    run_gate
}

@test "a booted index digest matches the pending record and passes" {
    gate_clears_released_hold
    assert_equal "$rc" 0
}

@test "a landed released hold is cleared by the gate" {
    gate_clears_released_hold
    assert [ ! -e "$state_dir/held.json" ]
}

# --- 4. the gate fails closed on an unhealthy host -------------------------
# Each case names one host check, so a check that stops working is visible as the
# one assertion that fails rather than as "the gate is stricter now".
unhealthy() { # <case>
    case $1 in
        unit-inactive) printf 'core-one.service\n' >"$STUB_SYSTEMCTL_ACTIVE" ;;
        unit-failed) printf 'core-two.service\n' >"$STUB_SYSTEMCTL_FAILED" ;;
        zpool-not-imported) export STUB_ZPOOL_OK=0 ;;
        apps-not-mounted) export STUB_MOUNTPOINT_OK=0 ;;
    esac
    seed_pending "$digest_index" "$digest_manifest" "$commit" "$digest_manifest"
    run_gate
}

unhealthy_fails() { # <case>
    unhealthy "$1"
    expect_failure
}

unhealthy_rollback() { # <case>
    unhealthy "$1"
    assert_equal "$(last_bootc_call)" 'rollback --apply'
}

unhealthy_index_denied() { # <case>
    unhealthy "$1"
    assert_equal "$(jq -r --arg d "$digest_index" \
        '.digests[$d].reason // "" | startswith("boot-gate")' <<<"$(denylist_json)")" true
}

unhealthy_manifest_denied() { # <case>
    unhealthy "$1"
    assert_equal "$(jq -r --arg d "$digest_manifest" \
        '.digests[$d].reason // "" | startswith("boot-gate")' <<<"$(denylist_json)")" true
}

unhealthy_pages() { # <case>
    unhealthy "$1"
    assert_equal "$(cat "$log/curl-urls")" "$ping_url/fail"
}

unhealthy_pending_kept() { # <case>
    unhealthy "$1"
    assert [ -s "$state_dir/pending.json" ]
}

unhealthy_no_state() { # <case>
    unhealthy "$1"
    assert [ ! -e "$state_dir/state.json" ]
}

unhealthy_counter() { # <case>
    unhealthy "$1"
    assert_equal "$(grub_flags '.boot_counter')" -1
}

unhealthy_boot_success() { # <case>
    unhealthy "$1"
    assert_equal "$(grub_flags '.boot_success')" 0
}

unhealthy_default() { # <case>
    unhealthy "$1"
    assert_equal "$(grub_flags '.default')" 0
}

unhealthy_journal() { # <case>
    unhealthy "$1"
    assert_contains "$(journal_field boot-gate-failed '.reason')" "$1"
}

for case in unit-inactive unit-failed zpool-not-imported apps-not-mounted; do
    register "$case fails the gate" unhealthy_fails "$case"
    register "$case rolls back with the apply argv" unhealthy_rollback "$case"
    register "the index digest is denylisted after $case" unhealthy_index_denied "$case"
    register "the manifest digest is denylisted after $case" unhealthy_manifest_denied "$case"
    register "$case pages the deploy check" unhealthy_pages "$case"
    register "$case keeps the pending record for the next boot" unhealthy_pending_kept "$case"
    register "$case records no landed deployment" unhealthy_no_state "$case"
    register "the abandon path spends the boot counter after $case" unhealthy_counter "$case"
    register "the abandon path clears boot_success after $case" unhealthy_boot_success "$case"
    register "the abandon path selects entry 0 after $case" unhealthy_default "$case"
    register "the failure is journaled with its reason after $case" unhealthy_journal "$case"
done

# The three tenant failures that used to fail this gate are a pass now: an
# inactive unit, a Serve list without the path, and a port nothing answers (the
# default fixture, since the suite binds no listener at all). A check that comes
# back shows up here as a rollback rather than as a stricter gate nobody noticed.
tenant_unhealthy() { # <case>
    case $1 in
        tenant-unit-inactive) : >"$STUB_SYSTEMCTL_USER_ACTIVE" ;;
        serve-path-missing) printf '{"Web":{":443":{"Handlers":{"/other":{}}}}}' >"$STUB_SERVE_JSON" ;;
        ingress-unreachable)
            jq -nc --argjson port "$app_port" \
                '{version:1,apps:{demo:{basePath:"/apps/demo",containerPort:8080,loopbackPort:$port}}}' \
                >"$APPS_PLAN"
            ;;
        # A plan nobody can read is the tenant's failure too, and it was the one
        # that failed every boot gate while the tenant was mid-apply.
        plan-unreadable) printf 'not a plan\n' >"$APPS_PLAN" ;;
    esac
    seed_pending "$digest_index" "$digest_manifest" "$commit" "$digest_manifest"
    run_gate
}

tenant_passes() { # <case>
    tenant_unhealthy "$1"
    assert_equal "$rc" 0
}

tenant_no_rollback() { # <case>
    tenant_unhealthy "$1"
    refute grep -qF -- 'rollback' "$log/bootc-calls"
}

tenant_records_deployment() { # <case>
    tenant_unhealthy "$1"
    assert_equal "$(journal_field boot-gate-green '.commit')" "$commit"
}

tenant_landed_record() { # <case>
    tenant_unhealthy "$1"
    assert [ -s "$state_dir/state.json" ]
}

tenant_no_denylist() { # <case>
    tenant_unhealthy "$1"
    assert [ ! -e "$state_dir/denylist.json" ]
}

tenant_pages_green() { # <case>
    tenant_unhealthy "$1"
    assert_equal "$(cat "$log/curl-urls")" "$ping_url"
}

for case in tenant-unit-inactive serve-path-missing ingress-unreachable plan-unreadable; do
    register "$case does not fail the gate" tenant_passes "$case"
    register "$case rolls nothing back" tenant_no_rollback "$case"
    register "$case records the deployment" tenant_records_deployment "$case"
    register "$case records a landed deployment" tenant_landed_record "$case"
    register "$case denylists nothing" tenant_no_denylist "$case"
    register "$case pages the deploy check green" tenant_pages_green "$case"
done

# --- 5. the health gate retries inside its budget, then fails closed -------
health_budget_exhausted() {
    seed_pending "$digest_index" "$digest_manifest" "$commit" "$digest_manifest"
    printf 'core-one.service\n' >"$STUB_SYSTEMCTL_ACTIVE"
    started=$(date -u +%s)
    run_gate
    elapsed=$(($(date -u +%s) - started))
    attempts=$(grep -c 'is-active core-two.service' "$log/systemctl-calls")
}

# The parenthetical is the count the shell suite observed under this budget: the
# assertion is the same one it made -- the gate looked more than once -- and the
# text is kept because parity compares it.
@test "the health gate retries inside its budget (3 attempts)" {
    health_budget_exhausted
    ((attempts >= 2)) || printf '%s attempts\n' "$attempts" >&2
    ((attempts >= 2))
}

@test "the retries are spread over the budget (2s)" {
    health_budget_exhausted
    ((elapsed >= 1)) || printf '%ss\n' "$elapsed" >&2
    ((elapsed >= 1))
}

@test "an exhausted health budget fails the gate" {
    health_budget_exhausted
    assert_equal "$rc" 1
}

@test "an exhausted health budget rolls back" {
    health_budget_exhausted
    assert_equal "$(last_bootc_call)" 'rollback --apply'
}

# --- 6. a boot the bootloader already rolled back --------------------------
# The counter fell back (or an operator did): the staged deployment is not
# running, so there is nothing to roll back -- but the digest is refused and the
# stale record is consumed, so a later manual reboot cannot roll a healthy host
# back either.
gate_rolled_back_by_bootloader() {
    seed_pending "$digest_index" "$digest_manifest" "$commit" "$digest_other"
    printf 'boot_success=0\nboot_counter=0\ndefault=1\n' >"$GRUB_ENV"
    run_gate
}

@test "a booted digest that is not the staged one is not a failure" {
    gate_rolled_back_by_bootloader
    assert_equal "$rc" 0
}

@test "the rollback is journaled with the deployment that booted" {
    gate_rolled_back_by_bootloader
    assert_equal "$(journal_field rolled-back-by-bootloader '.booted')" "$digest_other"
}

@test "a rolled-back index digest is denylisted" {
    gate_rolled_back_by_bootloader
    assert_equal "$(jq -r --arg d "$digest_index" '.digests[$d].reason' <<<"$(denylist_json)")" \
        rolled-back-by-bootloader
}

@test "a rolled-back manifest digest is denylisted" {
    gate_rolled_back_by_bootloader
    assert_equal "$(jq -r --arg d "$digest_manifest" '.digests[$d].reason' <<<"$(denylist_json)")" \
        rolled-back-by-bootloader
}

@test "the gate does not roll back a boot the bootloader chose" {
    gate_rolled_back_by_bootloader
    refute grep -qF -- 'rollback' "$log/bootc-calls"
}

@test "a rolled-back deploy consumes the pending record" {
    gate_rolled_back_by_bootloader
    assert [ ! -e "$state_dir/pending.json" ]
}

@test "a rollback pages the deploy check" {
    gate_rolled_back_by_bootloader
    assert_equal "$(cat "$log/curl-urls")" "$ping_url/fail"
}

@test "a rolled-back boot resets the GRUB default" {
    gate_rolled_back_by_bootloader
    assert_equal "$(grub_flags '.default')" null
}

@test "a rolled-back boot resets the boot counter" {
    gate_rolled_back_by_bootloader
    assert_equal "$(grub_flags '.boot_counter')" 3
}

@test "a rolled-back boot marks the boot good" {
    gate_rolled_back_by_bootloader
    assert_equal "$(grub_flags '.boot_success')" 1
}

@test "a rolled-back deployment records nothing" {
    gate_rolled_back_by_bootloader
    assert [ ! -e "$state_dir/state.json" ]
}

@test "a rolled-back boot runs no health checks" {
    gate_rolled_back_by_bootloader
    refute grep -qF -- 'is-active' "$log/systemctl-calls"
}

# --- 7. no pending record: reconcile only ----------------------------------
# An interrupted apps apply is reverted by the gate itself; with no pending
# platform deployment nothing else happens -- no bootc, no health check.
gate_no_pending() {
    jq -nc '{schema:1,phase:"pulling",previousUnits:[],intendedUnits:[]}' | apply_write
    run_gate
}

@test "a boot with no pending deploy passes" {
    gate_no_pending
    assert_equal "$rc" 0
}

@test "an interrupted apps apply is journaled with its phase" {
    gate_no_pending
    assert_equal "$(journal_field apply-interrupted '.phase')" pulling
}

@test "the gate calls the apps revert" {
    gate_no_pending
    assert grep -qF -- 'revert' "$log/apps-calls"
}

@test "the gate journals the reverted apply" {
    gate_no_pending
    assert_equal "$(journal_field apply-reverted '.by')" boot-gate
}

@test "the reverted apply clears the record" {
    gate_no_pending
    assert [ ! -e "$state_dir/apply.json" ]
}

@test "no pending deploy means no rollback" {
    gate_no_pending
    refute grep -qF -- 'rollback' "$log/bootc-calls"
}

@test "a boot with no pending deploy marks the boot good" {
    gate_no_pending
    assert_equal "$(grub_flags '.boot_success')" 1
}

@test "a boot with no pending deploy resets the boot counter" {
    gate_no_pending
    assert_equal "$(grub_flags '.boot_counter')" 3
}

@test "a boot with no pending deploy clears the GRUB default" {
    gate_no_pending
    assert_equal "$(grub_flags '.default')" null
}

# The operator's documented check reads this file, so it has to say what the
# comment in the runbook says: the boot is good and the counter is whole.
@test "the operator's 'boot_success=1 boot_counter=3' check is true after an ordinary boot" {
    gate_no_pending
    assert grep -qx 'boot_success=1' "$GRUB_ENV"
    assert grep -qx 'boot_counter=3' "$GRUB_ENV"
}

@test "a quiet boot notifies nothing" {
    gate_no_pending
    assert [ ! -s "$log/curl-urls" ]
}

@test "a quiet boot runs no health checks" {
    gate_no_pending
    assert [ ! -s "$log/systemctl-calls" ]
}

# With a pending deployment the revert still comes first: the health gate must
# judge the revision the recorded plan names, not a half-applied tenant.
gate_matching_with_interrupted_apply() {
    seed_pending "$digest_index" "$digest_manifest" "$commit" "$digest_manifest"
    jq -nc '{schema:1,phase:"installing",previousUnits:[],intendedUnits:[]}' | apply_write
    run_gate
    revert_line=$(grep -n 'deploy-apps revert' "$log/gate-order" | head -n 1 | cut -d: -f1)
    first_check=$(grep -n 'is-active' "$log/gate-order" | head -n 1 | cut -d: -f1)
}

@test "a matching boot with an interrupted apply passes" {
    gate_matching_with_interrupted_apply
    assert_equal "$rc" 0
}

@test "the apps revert runs before the health checks" {
    gate_matching_with_interrupted_apply
    assert [ -n "$revert_line" ]
    assert [ -n "$first_check" ]
    assert [ "$revert_line" -lt "$first_check" ]
}

@test "a pending boot clears the reverted apply" {
    gate_matching_with_interrupted_apply
    assert [ ! -e "$state_dir/apply.json" ]
}

# An ordinary boot must not spend the counter: the GRUB snippet decrements it on
# every boot before userspace, and a gate that only reset it for a pending deploy
# would fall back to the previous deployment after three quiet reboots.
ordinary_boots() { # <count>: replay the snippet and the gate that many times
    for boot in $(seq 1 "$1"); do
        # What the GRUB snippet does before userspace: the boot is unproven, one
        # attempt is spent, and at zero the previous entry is selected.
        counter=$(grub_flags '.boot_counter')
        [[ -n $counter ]] || counter=3
        {
            printf 'boot_success=0\n'
            if ((counter > 0)); then
                printf 'boot_counter=%s\n' "$((counter - 1))"
                [[ $(grub_flags '.default') == null ]] ||
                    printf 'default=%s\n' "$(grub_flags '.default')"
            else
                printf 'boot_counter=-1\ndefault=1\n'
            fi
        } >"$GRUB_ENV"
        run_gate
    done
}

ordinary_boot_keeps_the_counter() { # <boot the assertion is about>
    ordinary_boots "$1"
    assert_equal "$(grub_flags '.default')" null
    assert_equal "$(grub_flags '.boot_counter')" 3
    assert_equal "$(grub_flags '.boot_success')" 1
}

for boot in 1 2 3; do
    register "ordinary boot $boot keeps the counter reset and the default cleared" \
        ordinary_boot_keeps_the_counter "$boot"
done

# --- 7b. a boot nobody recorded is paged, never rolled back ----------------
# A crash between `bootc switch` and the pending record, or a staged entry a
# refused stage left behind, boots an image state.json does not name. It is the
# operator's image -- a hand-run switch is a choice -- but the state the poll
# compares against is wrong, so it is journaled and paged.
gate_unrecorded_boot() {
    state_record_verified homelab-platform "$commit" "$digest_index" "$digest_manifest"
    printf 'staged=\nbooted=%s\n' "$digest_other" >"$STUB_BOOTC_STATE"
    run_gate
}

@test "an unrecorded booted image is not a failure" {
    gate_unrecorded_boot
    assert_equal "$rc" 0
}

@test "the unrecorded boot is journaled with the digest that booted" {
    gate_unrecorded_boot
    assert_equal "$(journal_field booted-unrecorded '.booted')" "$digest_other"
}

@test "an unrecorded boot pages the deploy check" {
    gate_unrecorded_boot
    assert_equal "$(cat "$log/curl-urls")" "$ping_url/fail"
}

@test "an unrecorded boot is never rolled back" {
    gate_unrecorded_boot
    refute grep -qF -- 'rollback' "$log/bootc-calls"
}

# The recorded form, either way round, is silent.
gate_recorded_boot() {
    state_record_verified homelab-platform "$commit" "$digest_index" "$digest_manifest"
    printf 'staged=\nbooted=%s\n' "$digest_manifest" >"$STUB_BOOTC_STATE"
    run_gate
}

@test "a boot that matches the recorded digest passes" {
    gate_recorded_boot
    assert_equal "$rc" 0
}

@test "a recorded boot notifies nothing" {
    gate_recorded_boot
    assert [ ! -s "$log/curl-urls" ]
}

@test "a recorded boot is not journaled as unrecorded" {
    gate_recorded_boot
    assert_equal "$(journal_field booted-unrecorded '.booted')" ''
}

# --- 7c. a failed apps revert still decides the platform -------------------
# With no pending deploy the boot is fine and there is no platform decision: the
# failure is journaled and paged, and the record stays for the next gate or drain.
gate_failed_revert_no_pending() {
    jq -nc '{schema:1,phase:"installing",previousUnits:[],intendedUnits:[]}' | apply_write
    export STUB_APPS_EXIT=1
    run_gate
    unset STUB_APPS_EXIT
}

@test "a failed revert with no pending deploy leaves the boot alone" {
    gate_failed_revert_no_pending
    assert_equal "$rc" 0
}

@test "a failed revert is journaled" {
    gate_failed_revert_no_pending
    assert_equal "$(journal_field apply-revert-failed '.by')" boot-gate
}

@test "a failed revert keeps the record for the next run" {
    gate_failed_revert_no_pending
    assert [ -s "$state_dir/apply.json" ]
}

@test "a failed revert with no pending deploy pages the deploy check" {
    gate_failed_revert_no_pending
    assert_equal "$(cat "$log/curl-urls")" "$ping_url/fail"
}

# With a pending deployment that is what booted, a tenant nobody restored is a
# failed health gate: denylist the digest and roll back.
gate_failed_revert_staged() {
    seed_pending "$digest_index" "$digest_manifest" "$commit" "$digest_manifest"
    jq -nc '{schema:1,phase:"installing",previousUnits:[],intendedUnits:[]}' | apply_write
    export STUB_APPS_EXIT=1
    run_gate
    unset STUB_APPS_EXIT
}

@test "a failed revert on the staged boot fails the gate" {
    gate_failed_revert_staged
    assert_equal "$rc" 1
}

@test "the failed revert names the gate failure" {
    gate_failed_revert_staged
    assert_equal "$(journal_field boot-gate-failed '.reason')" apply-revert-failed
}

@test "a failed revert on the staged boot rolls back" {
    gate_failed_revert_staged
    assert_equal "$(last_bootc_call)" 'rollback --apply'
}

@test "a failed revert on the staged boot pages the deploy check" {
    gate_failed_revert_staged
    assert_equal "$(cat "$log/curl-urls")" "$ping_url/fail"
}

@test "a failed revert on the staged boot denylists the digest" {
    gate_failed_revert_staged
    assert_equal "$(jq -r --arg d "$digest_index" '.digests[$d].reason' <<<"$(denylist_json)")" \
        boot-gate:apply-revert-failed
}

@test "a failed gate keeps the pending record" {
    gate_failed_revert_staged
    assert [ -s "$state_dir/pending.json" ]
}

# --- 8. a host without grub2-editenv says so instead of doing nothing ------
# The counter is the only pre-userspace rollback; a host that cannot reset it
# must journal the gap rather than leave it invisible.
gate_missing_grub_tool() {
    seed_pending "$digest_index" "$digest_manifest" "$commit" "$digest_manifest"
    export GRUB_EDITEV=$work/no-such-grub-tool
    run_gate
    unset GRUB_EDITEV
}

@test "a missing GRUB tool does not undo a healthy boot" {
    gate_missing_grub_tool
    assert_equal "$rc" 0
}

@test "a missing GRUB tool is journaled" {
    gate_missing_grub_tool
    assert_equal "$(journal_field grub-tool-missing '.tool')" "$work/no-such-grub-tool"
}

@test "the deployment is still recorded without the GRUB tool" {
    gate_missing_grub_tool
    assert [ -s "$state_dir/state.json" ]
}

@test "no GRUB write is attempted without the tool" {
    gate_missing_grub_tool
    assert [ ! -s "$log/grub-calls" ]
}

# --- 9. a failed rollback is never silent ---------------------------------
gate_failed_rollback() {
    seed_pending "$digest_index" "$digest_manifest" "$commit" "$digest_manifest"
    printf 'core-one.service\n' >"$STUB_SYSTEMCTL_ACTIVE"
    export STUB_BOOTC_ROLLBACK_EXIT=1
    run_gate
    unset STUB_BOOTC_ROLLBACK_EXIT
}

@test "a rollback that fails fails the gate" {
    gate_failed_rollback
    assert_equal "$rc" 1
}

@test "the failed rollback is journaled" {
    gate_failed_rollback
    assert_equal "$(journal_field rollback-failed '.exit')" 1
}

# --- 10. the boot counter ships with the image ----------------------------

@test "the GRUB snippet clears boot_success on every boot" {
    assert grep -qF -- 'set boot_success=0' "$snippet"
}

@test "the GRUB snippet counts the attempts" {
    assert grep -qF -- 'boot_counter=' "$snippet"
}

@test "the GRUB snippet falls back to the previous deployment" {
    assert grep -qF -- 'set default=1' "$snippet"
}

@test "a hung PID 1 becomes a reboot the counter can act on" {
    assert grep -qF -- 'RuntimeWatchdogSec=1min' bootc/server/rootfs/etc/systemd/system.conf.d/10-watchdog.conf
}

# A panic reboot without a bootloader counter loops the same image forever, so
# the image must not ship one until counting is installed on the host.
@test "no panic reboot ships without a counter" {
    assert [ ! -e bootc/server/rootfs/etc/sysctl.d/10-panic.conf ]
}

# --- 11. a host whose GRUB does not read the counter says so ----------------
# bootupd reports every component current and never regenerates grub.cfg, so the
# variables are written nowhere it would be read: the gate must journal that and
# still decide the deployment.
gate_without_boot_counting() {
    printf 'menuentry nothing\n' >"$GRUB_CFG"
    printf 'boot_success=0\nboot_counter=0\ndefault=1\n' >"$GRUB_ENV"
    # A clean boot: no deployment record, nothing to revert, and the units a
    # healthy host has. The previous cases deliberately broke both.
    rm -f "$state_dir/pending.json" "$state_dir/apply.json"
    printf 'core-one.service\ncore-two.service\n' >"$STUB_SYSTEMCTL_ACTIVE"
    : >"$STUB_SYSTEMCTL_FAILED"
    run_gate
}

@test "a host without boot counting still finishes the gate" {
    gate_without_boot_counting
    assert_equal "$rc" 0
}

@test "the counter is left untouched without counting" {
    gate_without_boot_counting
    assert_equal "$(grub_flags '.boot_counter')" 0
}

@test "the missing counter is journaled" {
    gate_without_boot_counting
    assert_equal "$(journal_field boot-counting-absent '.reason' | tail -1)" \
        "grub.cfg does not read boot_counter"
}
