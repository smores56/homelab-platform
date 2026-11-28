# The shared half of the boot gate suite (SDLC #798, T4): the preamble variables,
# the fakes, the per-test fixture, the drivers and the assertions (§1-§11 of the
# suite that was tests/deploy/boot.bats, split by section for parallel files),
# including the §4 unhealthy and tenant drivers that two section files share.
#
# Sourced by tests/deploy/boot-*.bats through `load ./boot_lib`; bats sources it
# afresh for every test, so it only defines functions and the paths they read.
# The drivers hand on fixtures the section files read, so a check of this file
# alone sees them unassigned or unused.
# shellcheck disable=SC2154,SC2034

platform=scripts/deploy-platform.sh
gate=scripts/smortress-boot-gate.sh
lib=scripts/deploy-state.sh
containerfile=bootc/server/Containerfile

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
bt_setup_file() {
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
bt_setup() {
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
    # The gate only writes the flags when the file GRUB actually sources reads
    # the counter: /boot/grub2/custom.cfg, where smortress-boot-counter.service
    # installs greenboot's snippet. The fixture stands in for a host where that
    # install ran, and GRUB_CFG is the decoy a host with the snippet in bootupd's
    # directory would have had -- a test proves the gate does not read it.
    export GRUB_CUSTOM_CFG=$work/grub2/custom.cfg
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
    mkdir -p "$(dirname "$GRUB_CUSTOM_CFG")"
    printf 'set boot_counter=3\n' >"$GRUB_CFG"
    printf 'set boot_counter=3\n' >"$GRUB_CUSTOM_CFG"
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
