#!/usr/bin/env bash
# Offline checks for staging, the reboot and the post-boot gate (SDLC #798, T4).
#
# A platform deploy ends in a reboot, so the half that decides whether the host
# should keep what it booted lives here: the exact `bootc switch` argv, the
# staged-digest check against what the verifier recorded, `pending.json` before
# the reboot, the booted-versus-pending comparison, the health gate and its
# budget, the denylist and the rollback argv, and the GRUB flags that let an
# unbootable deployment fall back without userspace. `bootc`, `systemctl`,
# `grub2-editenv`, `tailscale`, `zpool` and `mountpoint` are fakes on PATH and
# the state is a throwaway directory; the records, the journal and the command
# lines are real. The ingress check is a real TCP connect to a throwaway
# listener, because a fake would prove nothing about it. No root, no reboot, no
# image, no network.
#
#   tests/deploy/boot.sh
# shellcheck disable=SC2154  # deploy-state.sh assigns these at source time
set -uo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root" || exit 1

platform=scripts/deploy-platform.sh
gate=scripts/smortress-boot-gate.sh
lib=scripts/deploy-state.sh
for file in "$platform" "$gate" "$lib"; do
  [[ -r $file ]] || {
    printf 'FAIL %s is missing\n' "$file" >&2
    exit 1
  }
done
for tool in jq timeout python3; do
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
check_file() { # path label
  if [[ -s $1 ]]; then ok "$2"; else bad "$2" "missing or empty: $1"; fi
}
check_no_file() { # path label
  if [[ -e $1 ]]; then bad "$2" "$(cat "$1" 2>/dev/null)"; else ok "$2"; fi
}
check_grep() { # file pattern label
  if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3" "no '$2' in $1"; fi
}
check_no_grep() { # file pattern label
  if grep -qF -- "$2" "$1" 2>/dev/null; then bad "$3" "$(grep -F -- "$2" "$1")"; else ok "$3"; fi
}

work=$(mktemp -d)
listener=
cleanup() {
  [[ -n $listener ]] && kill "$listener" 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

bin=$work/bin
log=$work/log
state_dir=$work/state
install -d -m 0755 "$bin" "$log"

ping_url=https://hc.invalid/ping/abc
export DEPLOY_STATE_DIR=$state_dir
export DEPLOY_LOCK_FILE=$work/deploy.lock
export DEPLOY_PING_SECRET=$work/deploy-ping-url.yaml
export DEPLOY_UNITS_FILE=$work/deploy-units.txt
export APPS_PLAN=$work/plan.json
export GRUB_ENV=$work/grubenv
# The gate only writes the flags when grub.cfg reads the counter; a fixture with
# the snippet's variable stands in for a host where boot counting was installed.
export GRUB_CFG=$work/grub.cfg
export STUB_LOG=$log
export PATH="$bin:$PATH"
# shellcheck source=/dev/null
source "$lib"
deploy_state_init || exit 1

commit=9f2c0d3b1a4e5f60718293a4b5c6d7e8f9012345
digest_index=sha256:1111111111111111111111111111111111111111111111111111111111111111
digest_manifest=sha256:2222222222222222222222222222222222222222222222222222222222222222
digest_other=sha256:3333333333333333333333333333333333333333333333333333333333333333
digest_prev_index=sha256:4444444444444444444444444444444444444444444444444444444444444444
digest_prev_manifest=sha256:5555555555555555555555555555555555555555555555555555555555555555
prev_commit=abcdef0123456789abcdef0123456789abcdef01
image_ref=ghcr.io/smores56/homelab-platform/server
digests=$(jq -nc --arg i "$digest_index" --arg m "$digest_manifest" '{index:$i,manifest:$m}')

app_port=34611

# --- the fakes ---------------------------------------------------------------
# `bootc` reports whatever the test put in its state file, so "staged image is
# not the one that was verified" and "this boot is not the staged deployment"
# are one file each and not two code paths.
cat >"$bin/bootc" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG/bootc-calls"
staged=$(sed -n 's/^staged=//p' "$STUB_BOOTC_STATE" 2>/dev/null)
booted=$(sed -n 's/^booted=//p' "$STUB_BOOTC_STATE" 2>/dev/null)
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
  rollback) exit "${STUB_BOOTC_ROLLBACK_EXIT:-0}" ;;
  status)
    if [[ " $* " == *" --booted "* ]]; then
      jq -nc --arg d "$booted" \
        '{status:{booted:{image:{imageDigest:(if $d == "" then null else $d end)}}}}'
    elif [[ -n ${STUB_BOOTC_NO_STAGED:-} ]]; then
      jq -nc --arg d "$booted" '{status:{booted:{image:{imageDigest:$d}}}}'
    else
      jq -nc --arg s "$staged" --arg b "$booted" '
        def img($v): {image:{imageDigest:(if $v == "" then null else $v end)}};
        {status:{staged:img($s),booted:img($b)}}'
    fi
    ;;
  *) exit 0 ;;
esac
EOF

# `systemctl reboot` records whether `pending.json` was already on disk, which is
# the only way to prove the order of the two without a real reboot.
cat >"$bin/systemctl" <<'EOF'
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
EOF

# `grub2-editenv` is a real key=value store here, so the assertions read the same
# file the GRUB snippet would.
cat >"$bin/grub2-editenv" <<'EOF'
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
EOF

cat >"$bin/tailscale" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG/tailscale-calls"
if [[ $* == "serve status --json" ]]; then
  cat "$STUB_SERVE_JSON"
fi
exit 0
EOF

cat >"$bin/zpool" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG/zpool-calls"
[[ ${STUB_ZPOOL_OK:-1} == 1 ]] || exit 1
printf '%s\n' "${*: -1}"
EOF

cat >"$bin/mountpoint" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG/mountpoint-calls"
[[ ${STUB_MOUNTPOINT_OK:-1} == 1 ]] || exit 1
exit 0
EOF

# deploy_notify hands the URL over as a curl config on stdin, never in argv.
cat >"$bin/curl" <<'EOF'
#!/usr/bin/env bash
url=
while (($#)); do
  case $1 in
    --config) shift 2 ;;
    --max-time | --retry | --connect-timeout) shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
if [[ -z $url ]]; then
  url=$(sed -n 's/^url = "\(.*\)"$/\1/p' | head -n 1)
fi
printf '%s\n' "$url" >>"$STUB_LOG/curl-urls"
exit 0
EOF

# The apps revert is a separate program with its own suite (tests/deploy/apps.sh);
# here it stands in for the gate's call, removes the record the way a successful
# revert does, and shares one ordering log with the health checks.
cat >"$bin/deploy-apps" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG/apps-calls"
printf 'deploy-apps %s\n' "$*" >>"$STUB_LOG/gate-order"
if [[ ${1:-} == revert && ${STUB_APPS_KEEP_APPLY:-0} != 1 && ${STUB_APPS_EXIT:-0} == 0 ]]; then
  rm -f "$DEPLOY_STATE_DIR/apply.json"
fi
exit "${STUB_APPS_EXIT:-0}"
EOF
chmod 0755 "$bin"/*

export STUB_BOOTC_STATE=$work/bootc-state
export STUB_SYSTEMCTL_ACTIVE=$work/active-units
export STUB_SYSTEMCTL_USER_ACTIVE=$work/active-user-units
export STUB_SYSTEMCTL_FAILED=$work/failed-units
export STUB_SERVE_JSON=$work/serve.json
export DEPLOY_APPS_BIN=$bin/deploy-apps

# The listener is a real socket: the gate's ingress check must fail on a closed
# port and pass on a bound one, and a stub could only ever say what it was told.
python3 - "$app_port" <<'PY' &
import socket, sys
listener = socket.socket()
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(("127.0.0.1", int(sys.argv[1])))
listener.listen(16)
while True:
    try:
        conn, _ = listener.accept()
    except OSError:
        break
    conn.close()
PY
listener=$!
port_up=false
for _ in $(seq 1 50); do
  # The single quotes are the point: the child bash expands the port.
  # shellcheck disable=SC2016
  if timeout 1 bash -c 'exec 3<>"/dev/tcp/127.0.0.1/$1"' _ "$app_port" 2>/dev/null; then
    port_up=true
    break
  fi
  sleep 0.1
done
if $port_up; then
  ok "the ingress stand-in accepts connections on 127.0.0.1:$app_port"
else
  bad "the ingress stand-in accepts connections on 127.0.0.1:$app_port"
fi

# --- the healthy host --------------------------------------------------------
printf 'core-one.service\ncore-two.service\n' >"$DEPLOY_UNITS_FILE"
printf 'core-one.service\ncore-two.service\n' >"$STUB_SYSTEMCTL_ACTIVE"
printf 'demo.container\n' >"$STUB_SYSTEMCTL_USER_ACTIVE"
: >"$STUB_SYSTEMCTL_FAILED"
jq -nc --argjson port "$app_port" \
  '{version:1,apps:{demo:{basePath:"/apps/demo",containerPort:8080,loopbackPort:$port}}}' \
  >"$APPS_PLAN"
serve_healthy() {
  jq -nc --argjson port "$app_port" \
    '{"Web":{":443":{"Handlers":{"/apps/demo":{Proxy:("http://127.0.0.1:" + ($port | tostring))}}}}}' \
    >"$STUB_SERVE_JSON"
}

journal_field() { # <event> <jq path>
  jq -r "select(.event==\"$1\") | $2" "$state_dir/journal.jsonl" 2>/dev/null
}

# The GRUB environment block is a flat key=value file; this reads it the same way
# in every assertion so a missing key is a null rather than an empty string.
grub_flags() { # <jq path>
  sed 's/^\([^=]*\)=\(.*\)$/{"\1":"\2"}/' "$GRUB_ENV" 2>/dev/null | jq -sc 'add // {}' |
    jq -r "$1" 2>/dev/null
}

seed_pending() { # <index> <manifest> <commit> [<booted>]
  jq -nc --arg i "$1" --arg m "$2" --arg c "$3" \
    '{schema:1,phase:"staged",commit:$c,digest:$i,digests:{index:$i,manifest:$m},
      stagedAt:"2026-11-20T00:00:00Z"}' | pending_write || return 1
  printf 'staged=%s\nbooted=%s\n' "$2" "$4" >"$STUB_BOOTC_STATE"
}

reset_case() { # keep the fakes' healthy answers, drop every record
  rm -f "$state_dir/state.json" "$state_dir/pending.json" "$state_dir/apply.json" \
    "$state_dir/held.json" "$state_dir/denylist.json" "$state_dir/journal.jsonl"
  rm -f "$DEPLOY_PING_SECRET" "$GRUB_ENV" "$STUB_BOOTC_STATE"
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
    STUB_BOOTC_STAGE_ON_SWITCH STUB_ZPOOL_OK STUB_MOUNTPOINT_OK GRUB_EDITEV STUB_APPS_EXIT \
    STUB_APPS_KEEP_APPLY
  # A two-second budget keeps the failed-health cases short while still proving
  # that the gate retries instead of deciding on the first look.
  export DEPLOY_BOOT_GATE_BUDGET=2 DEPLOY_BOOT_GATE_PAUSE=1
  printf 'core-one.service\ncore-two.service\n' >"$STUB_SYSTEMCTL_ACTIVE"
  printf 'demo.container\n' >"$STUB_SYSTEMCTL_USER_ACTIVE"
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
  out=$(bash "$platform" stage "$@" 2>&1)
  rc=$?
}

run_gate() {
  out=$(bash "$gate" 2>&1)
  rc=$?
}

# --- 1. stage: the exact switch argv, then the staged-digest check ----------
reset_case
printf 'staged=%s\nbooted=%s\n' "$digest_manifest" "$digest_manifest" >"$STUB_BOOTC_STATE"
run_stage --commit "$commit" --digests "$digests"
check_eq "$rc" 0 "a stage whose digest bootc reports passes"
check_eq "$(head -n 1 "$log/bootc-calls")" \
  "switch --enforce-container-sigpolicy $image_ref@$digest_manifest" \
  "stage pins the manifest digest and enforces the signature policy"
check_no_grep "$log/bootc-calls" '--apply' "stage never applies the deployment"
check_grep "$log/bootc-calls" 'status --json' "stage reads the staged entry back"
pending=$(cat "$state_dir/pending.json" 2>/dev/null) || pending='{}'
check_json "$pending" .phase staged "pending.json records a staged deploy"
check_json "$pending" .commit "$commit" "pending.json records the commit"
check_json "$pending" ".digests.index" "$digest_index" "pending.json records the index digest"
check_json "$pending" ".digests.manifest" "$digest_manifest" "pending.json records the manifest digest"
if [[ $(jq -r 'has("budget")' <<<"$pending" 2>/dev/null) == false ]]; then
  ok "pending.json carries no unused boot budget"
else
  bad "pending.json carries no unused boot budget" "$pending"
fi
check_grep "$log/systemctl-calls" 'reboot pending=yes' \
  "pending.json is on disk before the reboot is requested"
check_eq "$(journal_field stage-pending '.digest')" "$digest_index" "the stage is journaled"
if [[ -e $state_dir/state.json ]]; then
  bad "staging records no landed deployment" "$(cat "$state_dir/state.json")"
else
  ok "staging records no landed deployment"
fi
if grep -qF "$ping_url" "$log/curl-urls" 2>/dev/null; then
  bad "a clean stage notifies nothing" "$(cat "$log/curl-urls")"
else
  ok "a clean stage notifies nothing"
fi

# bootc may report the index form for the same staged image, and a host that
# reports the form the reference did not use must still pass.
reset_case
printf 'staged=%s\nbooted=%s\n' "$digest_index" "$digest_index" >"$STUB_BOOTC_STATE"
run_stage --commit "$commit" --digests "$digests"
check_eq "$rc" 0 "a staged image reported as the index form passes"
check_grep "$log/systemctl-calls" 'reboot' "the index form still reaches the reboot"

# --- 2. stage: a staged digest nobody verified refuses, records nothing -----
reset_case
printf 'staged=%s\nbooted=%s\n' "$digest_other" "$digest_other" >"$STUB_BOOTC_STATE"
run_stage --commit "$commit" --digests "$digests"
check_eq "$rc" 5 "a staged digest that is not the verified one is refused with exit 5"
check_no_file "$state_dir/pending.json" "a refused stage writes no pending record"
check_no_grep "$log/systemctl-calls" 'reboot' "a refused stage never reboots"
check_eq "$(journal_field stage-digest-mismatch '.staged')" "$digest_other" \
  "the refusal journals the digest bootc reported"
check_eq "$(journal_field stage-digest-mismatch '.digest')" "$digest_index" \
  "the refusal journals the digest that was verified"
check_eq "$(head -n 1 "$log/curl-urls")" "$ping_url/fail" "a refused stage pages the deploy check"

reset_case
export STUB_BOOTC_NO_STAGED=1
run_stage --commit "$commit" --digests "$digests"
unset STUB_BOOTC_NO_STAGED
check_eq "$rc" 5 "a null staged entry is refused with exit 5"
check_no_file "$state_dir/pending.json" "a null staged entry writes no pending record"
check_no_grep "$log/systemctl-calls" 'reboot' "a null staged entry never reboots"

# The switch is already on disk, so a mismatch that is only refused would leave
# the next boot staging an image nobody verified. The other deployment is put back
# and the read-back has to prove it.
reset_case
state_record_verified homelab-platform "$prev_commit" "$digest_prev_index" "$digest_prev_manifest"
printf 'staged=%s\nbooted=%s\n' "$digest_other" "$digest_other" >"$STUB_BOOTC_STATE"
export STUB_BOOTC_STAGE_ON_SWITCH=$digest_prev_manifest
run_stage --commit "$commit" --digests "$digests"
unset STUB_BOOTC_STAGE_ON_SWITCH
check_eq "$rc" 5 "a refused stage still exits 5 after restoring the deployed image"
check_eq "$(grep '^switch ' "$log/bootc-calls" | tail -n 1)" \
  "switch --enforce-container-sigpolicy $image_ref@$digest_prev_manifest" \
  "the refused stage switches back to the recorded deployed digest"
check_eq "$(journal_field stage-restored '.from')" "$digest_other" \
  "the restored staged entry is journaled with what bootc had staged"
if [[ -n $(journal_field stage-restore-failed '.staged') ]]; then
  bad "a restored stage is not journaled as a failed restore"
else
  ok "a restored stage is not journaled as a failed restore"
fi
check_no_file "$state_dir/pending.json" "a restored stage writes no pending record"
check_no_grep "$log/systemctl-calls" 'reboot' "a restored stage never reboots"

# A restore that also fails leaves the host one switch away from an unverified
# boot, which the operator has to hear about.
reset_case
state_record_verified homelab-platform "$prev_commit" "$digest_prev_index" "$digest_prev_manifest"
printf 'staged=%s\nbooted=%s\n' "$digest_other" "$digest_other" >"$STUB_BOOTC_STATE"
run_stage --commit "$commit" --digests "$digests"
check_eq "$rc" 5 "a stage whose restore does not take still refuses"
check_eq "$(journal_field stage-restore-failed '.staged')" "$digest_other" \
  "the failed restore is journaled with the digest still staged"
check_eq "$(tail -n 1 "$log/curl-urls")" "$ping_url/fail" \
  "a failed restore pages the deploy check"

# --- 3. the gate on a boot that is the staged deployment --------------------
reset_case
seed_pending "$digest_index" "$digest_manifest" "$commit" "$digest_manifest"
run_gate
check_eq "$rc" 0 "a healthy host on the staged deployment passes the gate"
check_eq "$(journal_field boot-gate-green '.commit')" "$commit" "the gate journals the landed commit"
recorded=$(cat "$state_dir/state.json" 2>/dev/null) || recorded='{}'
check_json "$recorded" '.repos["homelab-platform"].commit' "$commit" \
  "the gate records the deployed commit"
check_json "$recorded" '.repos["homelab-platform"].indexDigest' "$digest_index" \
  "the gate records the index digest"
check_json "$recorded" '.repos["homelab-platform"].manifestDigest' "$digest_manifest" \
  "the gate records the manifest digest"
check_eq "$(grub_flags '.boot_success')" 1 "success sets boot_success"
check_eq "$(grub_flags '.boot_counter')" 3 "success resets the boot counter"
check_no_file "$state_dir/pending.json" "success clears the pending record"
check_eq "$(cat "$log/curl-urls")" "$ping_url" "success pings the deploy check"
check_no_grep "$log/bootc-calls" 'rollback' "a healthy boot rolls nothing back"
# The health gate actually looked at the plan's app, its port and its Serve path.
check_grep "$log/systemctl-calls" 'is-active demo.container' \
  "the gate checks the plan's tenant unit"
check_grep "$log/tailscale-calls" 'serve status --json' "the gate reads the Serve routes"
check_json "$(cat "$state_dir/denylist.json" 2>/dev/null || printf '{}')" '.digests | length' 0 \
  "a healthy boot denylists nothing"

# A signed release that the operator had held is cleared once it lands, so
# `status` stops reporting a hold that no longer exists.
reset_case
seed_pending "$digest_index" "$digest_manifest" "$commit" "$digest_index"
jq -nc --arg d "$digest_index" --arg c "$commit" \
  '{schema:1,digest:$d,commit:$c,digests:{index:$d,manifest:$d},missingUnits:[],reason:"x",
    heldAt:"2026-11-20T00:00:00Z",released:true,releasedBy:"alice"}' | held_write
run_gate
check_eq "$rc" 0 "a booted index digest matches the pending record and passes"
check_no_file "$state_dir/held.json" "a landed released hold is cleared by the gate"

# --- 4. the gate fails closed on an unhealthy host -------------------------
# Each case names one health check, so a check that stops working is visible as
# the one assertion that fails rather than as "the gate is stricter now".
unhealthy() { # <label>
  local label=$1 denylist
  seed_pending "$digest_index" "$digest_manifest" "$commit" "$digest_manifest"
  run_gate
  if ((rc != 0)); then ok "$label fails the gate"; else bad "$label fails the gate" "$out"; fi
  check_eq "$(tail -n 1 "$log/bootc-calls")" 'rollback --apply' \
    "$label rolls back with the apply argv"
  denylist=$(cat "$state_dir/denylist.json" 2>/dev/null) || denylist='{}'
  check_eq "$(jq -r --arg d "$digest_index" '.digests[$d].reason // "" | startswith("boot-gate")' \
    <<<"$denylist")" true "the index digest is denylisted after $label"
  check_eq "$(jq -r --arg d "$digest_manifest" '.digests[$d].reason // "" | startswith("boot-gate")' \
    <<<"$denylist")" true "the manifest digest is denylisted after $label"
  check_eq "$(cat "$log/curl-urls")" "$ping_url/fail" "$label pages the deploy check"
  check_file "$state_dir/pending.json" "$label keeps the pending record for the next boot"
  check_no_file "$state_dir/state.json" "$label records no landed deployment"
  check_eq "$(grub_flags '.boot_counter')" -1 "the abandon path spends the boot counter after $label"
  check_eq "$(grub_flags '.boot_success')" 0 "the abandon path clears boot_success after $label"
  check_eq "$(grub_flags '.default')" 0 "the abandon path selects entry 0 after $label"
  if [[ $(journal_field boot-gate-failed '.reason') == *"$label"* ]]; then
    ok "the failure is journaled with its reason after $label"
  else
    bad "the failure is journaled with its reason after $label" \
      "$(journal_field boot-gate-failed '.reason')"
  fi
}

reset_case
printf 'core-one.service\n' >"$STUB_SYSTEMCTL_ACTIVE"
unhealthy unit-inactive

reset_case
printf 'core-two.service\n' >"$STUB_SYSTEMCTL_FAILED"
unhealthy unit-failed

reset_case
: >"$STUB_SYSTEMCTL_USER_ACTIVE"
unhealthy tenant-unit-inactive

reset_case
export STUB_ZPOOL_OK=0
unhealthy zpool-not-imported
unset STUB_ZPOOL_OK

reset_case
export STUB_MOUNTPOINT_OK=0
unhealthy apps-not-mounted
unset STUB_MOUNTPOINT_OK

reset_case
printf '{"Web":{":443":{"Handlers":{"/other":{}}}}}' >"$STUB_SERVE_JSON"
unhealthy serve-path-missing

# The ingress check is a real connect: nothing listens on this port, so the app
# is in the plan, its unit is active and the host still must not keep the boot.
reset_case
jq -nc '{version:1,apps:{demo:{basePath:"/apps/demo",containerPort:8080,loopbackPort:34612}}}' \
  >"$APPS_PLAN"
unhealthy ingress-unreachable

# --- 5. the health gate retries inside its budget, then fails closed -------
reset_case
seed_pending "$digest_index" "$digest_manifest" "$commit" "$digest_manifest"
printf 'core-one.service\n' >"$STUB_SYSTEMCTL_ACTIVE"
started=$(date -u +%s)
run_gate
elapsed=$(($(date -u +%s) - started))
attempts=$(grep -c 'is-active core-two.service' "$log/systemctl-calls")
if ((attempts >= 2)); then
  ok "the health gate retries inside its budget ($attempts attempts)"
else
  bad "the health gate retries inside its budget" "$attempts attempts"
fi
if ((elapsed >= 1)); then
  ok "the retries are spread over the budget (${elapsed}s)"
else
  bad "the retries are spread over the budget" "${elapsed}s"
fi
check_eq "$rc" 1 "an exhausted health budget fails the gate"
check_eq "$(tail -n 1 "$log/bootc-calls")" 'rollback --apply' \
  "an exhausted health budget rolls back"

# --- 6. a boot the bootloader already rolled back --------------------------
# The counter fell back (or an operator did): the staged deployment is not
# running, so there is nothing to roll back -- but the digest is refused and the
# stale record is consumed, so a later manual reboot cannot roll a healthy host
# back either.
reset_case
seed_pending "$digest_index" "$digest_manifest" "$commit" "$digest_other"
printf 'boot_success=0\nboot_counter=0\ndefault=1\n' >"$GRUB_ENV"
run_gate
check_eq "$rc" 0 "a booted digest that is not the staged one is not a failure"
check_eq "$(journal_field rolled-back-by-bootloader '.booted')" "$digest_other" \
  "the rollback is journaled with the deployment that booted"
check_json "$(cat "$state_dir/denylist.json" 2>/dev/null || printf '{}')" \
  ".digests[\"$digest_index\"].reason" rolled-back-by-bootloader \
  "a rolled-back index digest is denylisted"
check_json "$(cat "$state_dir/denylist.json" 2>/dev/null || printf '{}')" \
  ".digests[\"$digest_manifest\"].reason" rolled-back-by-bootloader \
  "a rolled-back manifest digest is denylisted"
check_no_grep "$log/bootc-calls" 'rollback' "the gate does not roll back a boot the bootloader chose"
check_no_file "$state_dir/pending.json" "a rolled-back deploy consumes the pending record"
check_eq "$(cat "$log/curl-urls")" "$ping_url/fail" "a rollback pages the deploy check"
check_eq "$(grub_flags '.default')" null "a rolled-back boot resets the GRUB default"
check_eq "$(grub_flags '.boot_counter')" 3 "a rolled-back boot resets the boot counter"
check_eq "$(grub_flags '.boot_success')" 1 "a rolled-back boot marks the boot good"
check_no_file "$state_dir/state.json" "a rolled-back deployment records nothing"
check_no_grep "$log/systemctl-calls" 'is-active' "a rolled-back boot runs no health checks"

# --- 7. no pending record: reconcile only ----------------------------------
# An interrupted apps apply is reverted by the gate itself; with no pending
# platform deployment nothing else happens -- no bootc, no health check.
reset_case
jq -nc '{schema:1,phase:"pulling",previousUnits:[],intendedUnits:[]}' | apply_write
run_gate
check_eq "$rc" 0 "a boot with no pending deploy passes"
check_eq "$(journal_field apply-interrupted '.phase')" pulling \
  "an interrupted apps apply is journaled with its phase"
check_grep "$log/apps-calls" 'revert' "the gate calls the apps revert"
check_eq "$(journal_field apply-reverted '.by')" boot-gate \
  "the gate journals the reverted apply"
check_no_file "$state_dir/apply.json" "the reverted apply clears the record"
check_no_grep "$log/bootc-calls" 'rollback' "no pending deploy means no rollback"
check_eq "$(grub_flags '.boot_success')" 1 "a boot with no pending deploy marks the boot good"
check_eq "$(grub_flags '.boot_counter')" 3 "a boot with no pending deploy resets the boot counter"
check_eq "$(grub_flags '.default')" null "a boot with no pending deploy clears the GRUB default"
# The operator's documented check reads this file, so it has to say what the
# comment in the runbook says: the boot is good and the counter is whole.
if grep -qx 'boot_success=1' "$GRUB_ENV" && grep -qx 'boot_counter=3' "$GRUB_ENV"; then
  ok "the operator's 'boot_success=1 boot_counter=3' check is true after an ordinary boot"
else
  bad "the operator's 'boot_success=1 boot_counter=3' check is true after an ordinary boot" \
    "$(cat "$GRUB_ENV")"
fi
if [[ -s $log/curl-urls ]]; then bad "a quiet boot notifies nothing"; else ok "a quiet boot notifies nothing"; fi
if [[ -s $log/systemctl-calls ]]; then
  bad "a quiet boot runs no health checks" "$(cat "$log"/systemctl-calls)"
else
  ok "a quiet boot runs no health checks"
fi

# With a pending deployment the revert still comes first: the health gate must
# judge the revision the recorded plan names, not a half-applied tenant.
reset_case
seed_pending "$digest_index" "$digest_manifest" "$commit" "$digest_manifest"
jq -nc '{schema:1,phase:"installing",previousUnits:[],intendedUnits:[]}' | apply_write
run_gate
check_eq "$rc" 0 "a matching boot with an interrupted apply passes"
revert_line=$(grep -n 'deploy-apps revert' "$log/gate-order" | head -n 1 | cut -d: -f1)
first_check=$(grep -n 'is-active' "$log/gate-order" | head -n 1 | cut -d: -f1)
if [[ -n $revert_line && -n $first_check && $revert_line -lt $first_check ]]; then
  ok "the apps revert runs before the health checks"
else
  bad "the apps revert runs before the health checks" "revert='$revert_line' first-check='$first_check'"
fi
check_no_file "$state_dir/apply.json" "a pending boot clears the reverted apply"

# An ordinary boot must not spend the counter: the GRUB snippet decrements it on
# every boot before userspace, and a gate that only reset it for a pending deploy
# would fall back to the previous deployment after three quiet reboots.
reset_case
for boot in 1 2 3; do
  # What the GRUB snippet does before userspace: the boot is unproven, one attempt
  # is spent, and at zero the previous entry is selected.
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
  if [[ $(grub_flags '.default') == null && $(grub_flags '.boot_counter') == 3 &&
    $(grub_flags '.boot_success') == 1 ]]; then
    ok "ordinary boot $boot keeps the counter reset and the default cleared"
  else
    bad "ordinary boot $boot keeps the counter reset and the default cleared" "$(cat "$GRUB_ENV")"
  fi
done

# --- 7b. a boot nobody recorded is paged, never rolled back ----------------
# A crash between `bootc switch` and the pending record, or a staged entry a
# refused stage left behind, boots an image state.json does not name. It is the
# operator's image -- a hand-run switch is a choice -- but the state the poll
# compares against is wrong, so it is journaled and paged.
reset_case
state_record_verified homelab-platform "$commit" "$digest_index" "$digest_manifest"
printf 'staged=\nbooted=%s\n' "$digest_other" >"$STUB_BOOTC_STATE"
run_gate
check_eq "$rc" 0 "an unrecorded booted image is not a failure"
check_eq "$(journal_field booted-unrecorded '.booted')" "$digest_other" \
  "the unrecorded boot is journaled with the digest that booted"
check_eq "$(cat "$log/curl-urls")" "$ping_url/fail" "an unrecorded boot pages the deploy check"
check_no_grep "$log/bootc-calls" 'rollback' "an unrecorded boot is never rolled back"

# The recorded form, either way round, is silent.
reset_case
state_record_verified homelab-platform "$commit" "$digest_index" "$digest_manifest"
printf 'staged=\nbooted=%s\n' "$digest_manifest" >"$STUB_BOOTC_STATE"
run_gate
check_eq "$rc" 0 "a boot that matches the recorded digest passes"
if [[ -s $log/curl-urls ]]; then
  bad "a recorded boot notifies nothing" "$(cat "$log/curl-urls")"
else
  ok "a recorded boot notifies nothing"
fi
if [[ -n $(journal_field booted-unrecorded '.booted') ]]; then
  bad "a recorded boot is not journaled as unrecorded"
else
  ok "a recorded boot is not journaled as unrecorded"
fi

# --- 7c. a failed apps revert still decides the platform -------------------
# With no pending deploy the boot is fine and there is no platform decision: the
# failure is journaled and paged, and the record stays for the next gate or drain.
reset_case
jq -nc '{schema:1,phase:"installing",previousUnits:[],intendedUnits:[]}' | apply_write
export STUB_APPS_EXIT=1
run_gate
unset STUB_APPS_EXIT
check_eq "$rc" 0 "a failed revert with no pending deploy leaves the boot alone"
check_eq "$(journal_field apply-revert-failed '.by')" boot-gate \
  "a failed revert is journaled"
check_file "$state_dir/apply.json" "a failed revert keeps the record for the next run"
check_eq "$(cat "$log/curl-urls")" "$ping_url/fail" \
  "a failed revert with no pending deploy pages the deploy check"

# With a pending deployment that is what booted, a tenant nobody restored is a
# failed health gate: denylist the digest and roll back.
reset_case
seed_pending "$digest_index" "$digest_manifest" "$commit" "$digest_manifest"
jq -nc '{schema:1,phase:"installing",previousUnits:[],intendedUnits:[]}' | apply_write
export STUB_APPS_EXIT=1
run_gate
unset STUB_APPS_EXIT
check_eq "$rc" 1 "a failed revert on the staged boot fails the gate"
check_eq "$(journal_field boot-gate-failed '.reason')" apply-revert-failed \
  "the failed revert names the gate failure"
check_eq "$(tail -n 1 "$log/bootc-calls")" 'rollback --apply' \
  "a failed revert on the staged boot rolls back"
check_eq "$(cat "$log/curl-urls")" "$ping_url/fail" \
  "a failed revert on the staged boot pages the deploy check"
check_json "$(cat "$state_dir/denylist.json" 2>/dev/null || printf '{}')" \
  ".digests[\"$digest_index\"].reason" boot-gate:apply-revert-failed \
  "a failed revert on the staged boot denylists the digest"
check_file "$state_dir/pending.json" "a failed gate keeps the pending record"

# --- 8. a host without grub2-editenv says so instead of doing nothing ------
# The counter is the only pre-userspace rollback; a host that cannot reset it
# must journal the gap rather than leave it invisible.
reset_case
seed_pending "$digest_index" "$digest_manifest" "$commit" "$digest_manifest"
export GRUB_EDITEV=$work/no-such-grub-tool
run_gate
unset GRUB_EDITEV
check_eq "$rc" 0 "a missing GRUB tool does not undo a healthy boot"
check_eq "$(journal_field grub-tool-missing '.tool')" "$work/no-such-grub-tool" \
  "a missing GRUB tool is journaled"
check_file "$state_dir/state.json" "the deployment is still recorded without the GRUB tool"
if [[ -s $log/grub-calls ]]; then
  bad "no GRUB write is attempted without the tool" "$(cat "$log/grub-calls")"
else
  ok "no GRUB write is attempted without the tool"
fi

# --- 9. a failed rollback is never silent ---------------------------------
reset_case
seed_pending "$digest_index" "$digest_manifest" "$commit" "$digest_manifest"
printf 'core-one.service\n' >"$STUB_SYSTEMCTL_ACTIVE"
export STUB_BOOTC_ROLLBACK_EXIT=1
run_gate
unset STUB_BOOTC_ROLLBACK_EXIT
check_eq "$rc" 1 "a rollback that fails fails the gate"
check_eq "$(journal_field rollback-failed '.exit')" 1 "the failed rollback is journaled"

# --- 10. the boot counter ships with the image ----------------------------
snippet=image/rootfs/usr/lib/bootupd/grub2-static/configs.d/10-smortress-count.cfg
check_grep "$snippet" 'set boot_success=0' "the GRUB snippet clears boot_success on every boot"
check_grep "$snippet" 'boot_counter=' "the GRUB snippet counts the attempts"
check_grep "$snippet" 'set default=1' "the GRUB snippet falls back to the previous deployment"
check_grep image/rootfs/etc/systemd/system.conf.d/10-watchdog.conf 'RuntimeWatchdogSec=1min' \
  "a hung PID 1 becomes a reboot the counter can act on"
# A panic reboot without a bootloader counter loops the same image forever, so
# the image must not ship one until counting is installed on the host.
if [[ -e image/rootfs/etc/sysctl.d/10-panic.conf ]]; then
  bad "no panic reboot ships without a counter"
else
  ok "no panic reboot ships without a counter"
fi

# --- 11. a host whose GRUB does not read the counter says so ----------------
# bootupd reports every component current and never regenerates grub.cfg, so the
# variables are written nowhere it would be read: the gate must journal that and
# still decide the deployment.
printf 'menuentry nothing\n' >"$GRUB_CFG"
printf 'boot_success=0\nboot_counter=0\ndefault=1\n' >"$GRUB_ENV"
# A clean boot: no deployment record, nothing to revert, and the units a healthy
# host has. The previous cases deliberately broke both.
rm -f "$state_dir/pending.json" "$state_dir/apply.json"
printf 'core-one.service\ncore-two.service\n' >"$STUB_SYSTEMCTL_ACTIVE"
: >"$STUB_SYSTEMCTL_FAILED"
run_gate
if ((rc == 0)); then
  ok "a host without boot counting still finishes the gate"
else
  bad "a host without boot counting still finishes the gate" "$out"
fi
check_eq "$(grub_flags '.boot_counter')" 0 "the counter is left untouched without counting"
check_eq "$(journal_field boot-counting-absent '.reason' | tail -1)" \
  "grub.cfg does not read boot_counter" "the missing counter is journaled"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
