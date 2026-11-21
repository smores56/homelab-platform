#!/usr/bin/env bash
# Post-boot gate: keep the deployment this host just booted, or roll back
# (SDLC #798, T4).
#
#   smortress-boot-gate
#
# Runs on every boot from smortress-boot-gate.service, late in boot
# (After=multi-user.target) and before boot-complete.target. It always runs, so
# an interrupted apps apply is reconciled even on a boot with no pending
# platform deployment, but it acts on the platform only when `pending.json` says
# a stage was written and a reboot requested.
#
# The reconcile is a bounded `deploy-apps revert`: the tenant may be half of two
# revisions, with the plan already the new one, so no health check may judge it
# before the recorded revision is back. A revert that cannot finish is a failed
# gate, not a pass: the record stays for the next boot and no platform decision
# is made on a tenant nobody restored.
#
# With a pending record it compares the booted deployment's digest to the one the
# verifier recorded, in both forms bootc may report (index or platform manifest):
#
#   match    the staged deployment is running: run the health gate, then record
#            it as landed, reset the boot counter and clear the record;
#   no match the boot counter already fell back, or an operator rolled back:
#            record `rolled-back-by-bootloader`, denylist, page, reset the GRUB
#            flags and consume the record. The host is left alone -- there is
#            nothing to roll back and a manual reboot must not undo a healthy
#            host later;
#   unreadable  nothing is decided: the record stays for the next boot, and the
#            GRUB counter is what protects the host.
#
# Ownership of the rollback is explicit: while `pending.json` exists the gate
# decides, and its abandon path spends the counter so it cannot later select the
# deployment that just failed. The GRUB counter acts only when the gate cannot run
# at all (no userspace, a panicked kernel).
#
# Reaching this program is itself the verdict on the boot: the GRUB snippet spends
# an attempt on *every* boot, so the gate marks the boot good before it evaluates
# anything. Only the pending path's failure actions override that mark. Without it
# three ordinary reboots fall back to the previous deployment while state.json
# still names the newer commit, and the host then polls, finds nothing to do and
# reports healthy on an image it is not running.
#
# With no pending record the gate still compares the booted digest with what the
# state records: a crash between `bootc switch` and the pending record, or a
# staged entry a refused stage left behind, boots an image nothing recorded. That
# is journaled and paged, never rolled back -- a hand-run `bootc switch` is the
# operator's choice and the host is healthy.
#
# The health gate is retried inside its budget and fails closed: the units the
# image declares must be active and none failed, the pool imported, /srv/apps a
# mountpoint, every app in the tenant plan up with its ingress port answering,
# and every expected Serve path declared. The tenant is checked because a
# platform deploy is the only thing that can break it -- but `plan.json` is
# optional: a host with no rendered plan has no tenant to wait for.
#
# Exit codes: 0 nothing to do, or a deployment was recorded or rolled back;
# 1 the gate could not finish (an unreadable bootc status, an unwritable record,
# a failed rollback, an apps revert that could not run while a platform deployment
# is pending) or the health gate failed and the rollback was issued.
#
# Every knob is environment-overridable so tests/deploy/boot.sh can drive this
# exact code against fakes and a throwaway state directory. Production sets none
# of them: the defaults are the host contract, not a way to skip a check.
#
# shellcheck disable=SC2154  # deploy-state.sh assigns these at source time
set -euo pipefail

self_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# The image installs the library as /usr/libexec/deploy-state (the smortress-src
# loop strips the `.sh`); a checkout has it beside this script.
state_lib=${DEPLOY_STATE_LIB:-}
if [[ -z $state_lib ]]; then
  if [[ -r /usr/libexec/deploy-state ]]; then
    state_lib=/usr/libexec/deploy-state
  else
    state_lib=$self_dir/deploy-state.sh
  fi
fi
[[ -r $state_lib ]] || {
  printf 'smortress-boot-gate: no state library at %s\n' "$state_lib" >&2
  exit 1
}
# shellcheck source=/dev/null
source "$state_lib"

# The pool name and the /srv/apps mountpoint are the storage table's, not this
# script's: the gate must ask about the dataset the plane actually serves.
layout=${STORAGE_LAYOUT:-}
if [[ -z $layout ]]; then
  if [[ -r /usr/libexec/storage-layout ]]; then
    layout=/usr/libexec/storage-layout
  else
    layout=$self_dir/storage-layout.sh
  fi
fi
[[ -r $layout ]] || {
  printf 'smortress-boot-gate: no storage layout at %s\n' "$layout" >&2
  exit 1
}
# shellcheck source=/dev/null
source "$layout"
# /srv is the ostree symlink to /var/srv, so the table's mountpoint is the path
# the kernel reports for the dataset either way.
apps_mount=$(mountpoint_for raw/apps)

bootc_bin=${BOOTC_BIN:-bootc}
systemctl_bin=${SYSTEMCTL_BIN:-systemctl}
tailscale_bin=${TAILSCALE_BIN:-tailscale}
zpool_bin=${ZPOOL_BIN:-zpool}
mountpoint_bin=${MOUNTPOINT_BIN:-mountpoint}
grub_editev=${GRUB_EDITEV:-grub2-editenv}
grub_env=${GRUB_ENV:-/boot/grub2/grubenv}
deploy_units_file=${DEPLOY_UNITS_FILE:-/usr/share/smortress/deploy-units.txt}
apps_plan=${APPS_PLAN:-/var/lib/homelab/apps/plan.json}
apps_user=${APPS_USER:-apps}
# Three attempts, matching the GRUB snippet: the number a fresh counter is reset
# to on every boot the gate accepts.
boot_budget=${DEPLOY_BOOT_BUDGET:-3}
gate_budget=${DEPLOY_BOOT_GATE_BUDGET:-300}
gate_pause=${DEPLOY_BOOT_GATE_PAUSE:-4}
lock_wait=${DEPLOY_BOOT_GATE_LOCK_WAIT:-300}
ctl_timeout=${DEPLOY_BOOT_GATE_CTL_TIMEOUT:-10}
probe_timeout=${DEPLOY_BOOT_GATE_PROBE_TIMEOUT:-10}
connect_timeout=${DEPLOY_BOOT_GATE_CONNECT_TIMEOUT:-5}
status_timeout=${DEPLOY_BOOT_GATE_STATUS_TIMEOUT:-60}
grub_timeout=${DEPLOY_BOOT_GATE_GRUB_TIMEOUT:-30}
rollback_timeout=${DEPLOY_ROLLBACK_TIMEOUT:-900}
# deploy-apps carries its own 5400 s apply budget; a revert pulls no image, so
# this shorter net under one that wedges still fits in the gate unit's
# TimeoutStartSec alongside the health budget and a rollback.
apps_bin=${DEPLOY_APPS_BIN:-}
if [[ -z $apps_bin ]]; then
  if [[ -x /usr/libexec/deploy-apps ]]; then
    apps_bin=/usr/libexec/deploy-apps
  else
    apps_bin=$self_dir/deploy-apps.sh
  fi
fi
apps_revert_timeout=${DEPLOY_APPS_REVERT_TIMEOUT:-1200}

say() { printf 'smortress-boot-gate: %s\n' "$*"; }
warn() { printf 'smortress-boot-gate: %s\n' "$*" >&2; }

# --- the GRUB flags ---------------------------------------------------------
# The counter is the only rollback that exists before userspace, so an absent
# grub2-editenv is a gap the journal has to name: a host that quietly fails to
# reset it rolls back a healthy deployment after three good boots.
grub_available() {
  if ! command -v "$grub_editev" >/dev/null 2>&1; then
    journal_append grub-tool-missing "$(jq -nc --arg tool "$grub_editev" '{tool:$tool}')" ||
      true
    warn "$grub_editev is missing: the boot counter cannot be reset"
    return 1
  fi
  return 0
}

# The snippet spends one attempt on every boot and the gate runs after
# multi-user.target, so a boot the gate reached is a boot that got to userspace:
# it is marked good and the counter is reset here, before anything is decided.
# `default` is cleared with it -- a fallback entry left selected by an earlier
# boot would otherwise pull the next reboot back to the older deployment while
# this one is healthy.
grub_mark_good() {
  grub_available || return 1
  timeout --signal=TERM --kill-after=5 "$(clamp_timeout "$grub_timeout")" "$grub_editev" \
    "$grub_env" set "boot_success=1" "boot_counter=$boot_budget" || return 1
  timeout --signal=TERM --kill-after=5 "$(clamp_timeout "$grub_timeout")" "$grub_editev" \
    "$grub_env" unset default || return 1
  return 0
}

# The one override of that mark: a deployment this gate rejects leaves the flags
# spent. boot_success=0 stops the bootloader from treating the boot as good,
# boot_counter=-1 spends the attempts, and default=0 selects the entry
# `bootc rollback --apply` is about to make current. Resetting them to the
# success values instead would re-arm the counter that must never pick the failed
# deployment again.
grub_abandon() {
  grub_available || return 1
  timeout --signal=TERM --kill-after=5 "$(clamp_timeout "$grub_timeout")" "$grub_editev" \
    "$grub_env" set "boot_success=0" "boot_counter=-1" "default=0" || return 1
  return 0
}

# --- the bootc answer -------------------------------------------------------
booted_digest() {
  local doc
  doc=$(timeout --signal=TERM --kill-after=10 "$(clamp_timeout "$status_timeout")" \
    "$bootc_bin" status --booted --json 2>/dev/null) ||
    return 1
  jq -er '.status.booted.image.imageDigest // empty' <<<"$doc" 2>/dev/null
}

# Either recorded form is a match: bootc reports the index digest on one host and
# the platform manifest digest on another for the same boot.
digest_matches() { # <booted> <index> <manifest>
  [[ -n $1 ]] || return 1
  [[ -n $2 && $1 == "$2" ]] && return 0
  [[ -n $3 && $1 == "$3" ]] && return 0
  return 1
}

# --- the health gate --------------------------------------------------------
health_reason=

# The single quotes are the point: the port is expanded by the child bash that
# opens the connection, not by this shell, so no path here can be a hostname.
# shellcheck disable=SC2016
tcp_open() { # <port>
  timeout --signal=TERM "$(clamp_timeout "$connect_timeout")" bash -c 'exec 3<>"/dev/tcp/127.0.0.1/$1"' _ "$1" \
    2>/dev/null
}

serve_status_paths() {
  local doc
  doc=$(timeout --signal=TERM --kill-after=10 "$(clamp_timeout "$probe_timeout")" \
    "$tailscale_bin" serve status --json 2>/dev/null) ||
    return 1
  jq -r '.Web // {} | to_entries[]
    | select(.key | endswith(":443"))
    | (.value.Handlers // {}) | keys[]' <<<"$doc" 2>/dev/null
}

health_plan() {
  local rows serve_paths loopback unit path name
  # No plan is a host with no tenant: nothing to wait for, and a gate that
  # failed closed here would roll back every deploy before the first apps apply.
  [[ -e $apps_plan ]] || return 0
  jq -e '(.apps | type) == "object"' "$apps_plan" >/dev/null 2>&1 || {
    health_reason="plan-unreadable"
    return 1
  }
  rows=$(jq -r '(.apps // {}) | to_entries[]
    | [.key, (.value.unitName // (.key + ".container")), (.value.basePath // ""),
       ((.value.loopbackPort // "") | tostring)] | @tsv' "$apps_plan" 2>/dev/null) || {
    health_reason="plan-unreadable"
    return 1
  }
  [[ -n $rows ]] || return 0
  serve_paths=$(serve_status_paths) || {
    health_reason="serve-status-unreadable"
    return 1
  }
  while IFS=$'\t' read -r name unit path loopback; do
    [[ -n $name ]] || continue
    if [[ -z $path || -z $unit ]]; then
      health_reason="plan-unreadable:$name"
      return 1
    fi
    # A user unit is reached through the tenant's own manager: the deploy runs as
    # root and cannot `--user` against a session it does not have.
    if [[ $(timeout --signal=TERM "$(clamp_timeout "$ctl_timeout")" "$systemctl_bin" --user \
      --machine="$apps_user@.host" is-active "$unit" 2>/dev/null) != active ]]; then
      health_reason="tenant-unit-inactive:$name"
      return 1
    fi
    if [[ ! $loopback =~ ^[0-9]+$ ]] || ! tcp_open "$loopback"; then
      health_reason="ingress-unreachable:$name:$loopback"
      return 1
    fi
    if ! grep -qxF -- "$path" <<<"$serve_paths" 2>/dev/null; then
      health_reason="serve-path-missing:$path"
      return 1
    fi
  done <<<"$rows"
  return 0
}

health_check() {
  local unit
  local -a gate_units=()
  [[ -r $deploy_units_file ]] || {
    health_reason="units-file-missing"
    return 1
  }
  mapfile -t gate_units < <(sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    -e '/^$/d' "$deploy_units_file")
  ((${#gate_units[@]})) || {
    health_reason="units-file-empty"
    return 1
  }
  for unit in "${gate_units[@]}"; do
    if [[ $(timeout --signal=TERM "$(clamp_timeout "$ctl_timeout")" "$systemctl_bin" is-active "$unit" \
      2>/dev/null) != active ]]; then
      health_reason="unit-inactive:$unit"
      return 1
    fi
  done
  # `failed` is asked about the declared units only: an unrelated unit that
  # failed must not roll the host back.
  for unit in "${gate_units[@]}"; do
    if [[ $(timeout --signal=TERM "$(clamp_timeout "$ctl_timeout")" "$systemctl_bin" is-failed "$unit" \
      2>/dev/null) == failed ]]; then
      health_reason="unit-failed:$unit"
      return 1
    fi
  done
  timeout --signal=TERM "$(clamp_timeout "$probe_timeout")" "$zpool_bin" list -H -o name "$pool" \
    >/dev/null 2>&1 || {
    health_reason="zpool-not-imported"
    return 1
  }
  timeout --signal=TERM "$(clamp_timeout "$probe_timeout")" "$mountpoint_bin" -q "$apps_mount" \
    >/dev/null 2>&1 || {
    health_reason="apps-not-mounted"
    return 1
  }
  health_plan
}

health_gate() {
  local deadline attempts=0
  deadline=$(($(date -u +%s) + gate_budget))
  while :; do
    attempts=$((attempts + 1))
    health_reason=
    if health_check; then
      say "healthy after $attempts attempt(s)"
      return 0
    fi
    if (($(date -u +%s) >= deadline)); then break; fi
    say "not healthy yet ($health_reason); retrying"
    sleep "$gate_pause"
  done
  warn "the host is not healthy after $attempts attempt(s): $health_reason"
  return 1
}

# --- the three outcomes -----------------------------------------------------
pending_fields() { # <doc> -> "<commit>\t<index>\t<manifest>"
  local doc=$1
  jq -r '[.commit // "", .digests.index // .digest // "", .digests.manifest // .digest // ""]
    | @tsv' <<<"$doc" 2>/dev/null
}

denylist_forms() { # <index> <manifest> <reason>
  local index=$1 manifest=$2 reason=$3
  [[ -z $index ]] || denylist_add digest "$index" "$reason" ||
    warn "cannot denylist $index"
  [[ -z $manifest || $manifest == "$index" ]] ||
    denylist_add digest "$manifest" "$reason" || warn "cannot denylist $manifest"
}

succeed() { # <commit> <index> <manifest>
  local commit=$1 index=$2 manifest=$3
  journal_append boot-gate-green "$(jq -nc --arg commit "$commit" --arg index "$index" \
    --arg manifest "$manifest" \
    '{commit:$commit,digests:{index:$index,manifest:$manifest}}')" || {
    warn "cannot journal the green gate"
    return 1
  }
  # The GRUB flags were marked good when this boot reached the gate; nothing here
  # writes them again. This is the only writer of a landed deployment: nothing
  # else may claim a commit is running, and it runs on the boot that proves it.
  state_record_verified homelab-platform "$commit" "$index" "$manifest" || {
    warn "cannot record the deployed commit"
    return 1
  }
  # A hold the operator released has now landed: the release is history, and
  # leaving it would make `status` report a hold on a deployed digest.
  local held
  if held=$(held_read 2>/dev/null) &&
    [[ $(jq -r --arg d "$index" '.released == true and (.digest == $d or .digests.index == $d)
      and .digest != ""' <<<"$held" 2>/dev/null) == true ]]; then
    record_clear held || warn "cannot clear the landed hold record"
  fi
  deploy_notify success || warn "could not report the deployment to the deploy check"
  # Cleared last: a crash before this leaves the record, and the next boot
  # repeats an idempotent success instead of forgetting the deploy.
  pending_clear || {
    warn "cannot clear the pending record"
    return 1
  }
  say "$commit is running"
  return 0
}

# The pending record is deliberately left in place: `bootc rollback --apply`
# reboots, the next boot does not match the staged digest, and the rolled-back
# path is what consumes the record -- one code path clears it, not two.
fail_gate() { # <reason> <commit> <index> <manifest>
  local reason=$1 commit=${2:-} index=${3:-} manifest=${4:-} rc=0
  journal_append boot-gate-failed "$(jq -nc --arg reason "$reason" --arg commit "$commit" \
    --arg index "$index" --arg manifest "$manifest" \
    '{reason:$reason,commit:$commit,digests:{index:$index,manifest:$manifest}}')" ||
    warn "cannot journal the gate failure"
  denylist_forms "$index" "$manifest" "boot-gate:$reason"
  # Before the rollback, not after: `bootc rollback --apply` reboots, and a
  # counter left armed would select the failed deployment again.
  grub_abandon || warn "the GRUB flags were not abandoned"
  deploy_notify fail "boot-gate-$reason" || warn "could not report the failed boot"
  timeout --signal=TERM --kill-after=30 "$(clamp_timeout "$rollback_timeout")" \
    "$bootc_bin" rollback --apply || rc=$?
  if ((rc != 0)); then
    journal_append rollback-failed "$(jq -nc --argjson exit "$rc" '{exit:$exit}')" ||
      warn "cannot journal the failed rollback"
    warn "bootc rollback --apply failed (exit $rc); the host is still on the failed deployment"
    return 1
  fi
  return 0
}

rolled_back() { # <booted> <commit> <index> <manifest>
  local booted=$1 commit=$2 index=$3 manifest=$4
  journal_append rolled-back-by-bootloader "$(jq -nc --arg commit "$commit" --arg index "$index" \
    --arg manifest "$manifest" --arg booted "$booted" \
    '{commit:$commit,digests:{index:$index,manifest:$manifest},booted:$booted}')" ||
    warn "cannot journal the rollback"
  denylist_forms "$index" "$manifest" rolled-back-by-bootloader
  # The boot itself is healthy -- it is just not the staged deployment -- so the
  # flags are the good ones rather than the abandon ones. Re-asserted here so a
  # write that failed earlier in the run cannot leave a spent counter behind.
  grub_mark_good || warn "the GRUB flags were not reset"
  deploy_notify fail rolled-back-by-bootloader || warn "could not report the rollback"
  pending_clear || {
    warn "cannot clear the pending record"
    return 1
  }
  warn "booted $booted, not the staged $index: left the host alone"
  return 0
}

# --- main -------------------------------------------------------------------
# The tenant a previous boot or a watchdog left half-applied. This runs before
# the health checks because they check the revision the plan names; on a
# half-applied tenant that revision is not what is running.
reconcile_apply() {
  local phase rc=0
  record_exists apply || return 0
  phase=$(record_field apply phase 2>/dev/null) || phase=unknown
  journal_append apply-interrupted "$(jq -nc --arg phase "$phase" '{phase:$phase}')" ||
    warn "cannot journal the interrupted apps apply"
  timeout --signal=TERM --kill-after=60 "$(clamp_timeout "$apps_revert_timeout")" \
    "$apps_bin" revert || rc=$?
  if ((rc != 0)); then
    journal_append apply-revert-failed "$(jq -nc --arg phase "$phase" --argjson exit "$rc" \
      '{phase:$phase,exit:$exit,by:"boot-gate"}')" ||
      warn "cannot journal the failed apps revert"
    warn "an interrupted apps apply (phase $phase) could not be reverted (exit $rc); the record is kept"
    return 1
  fi
  journal_append apply-reverted "$(jq -nc --arg phase "$phase" '{phase:$phase,by:"boot-gate"}')" ||
    warn "cannot journal the reverted apps apply"
  say "reverted the interrupted apps apply (phase $phase)"
  return 0
}

# A boot with no pending record still gets compared with the state. Two paths
# reach it: a crash between `bootc switch` and the pending write, and the staged
# entry a refused stage leaves behind. Either way the host is running an image
# state.json does not name, and state.json is what the poll compares the tip
# against -- silently wrong there means the poll stops deploying and nothing says
# so. It is never rolled back: a hand-run `bootc switch` is the operator's
# choice, and this boot is healthy.
check_unrecorded_boot() {
  local booted index manifest
  [[ -s $deploy_state_file ]] || return 0
  index=$(state_field 'repos.homelab-platform.indexDigest' 2>/dev/null) || index=""
  manifest=$(state_field 'repos.homelab-platform.manifestDigest' 2>/dev/null) || manifest=""
  # A state seeded by `bootstrap` records a commit and no digest: there is
  # nothing to compare, which is a host awaiting its first deploy, not a fault.
  [[ -n $index || -n $manifest ]] || return 0
  if ! booted=$(booted_digest); then
    journal_append bootc-status-failed '{"pending":false}' || true
    warn "cannot read the booted deployment; nothing was compared"
    return 0
  fi
  digest_matches "$booted" "$index" "$manifest" && return 0
  journal_append booted-unrecorded "$(jq -nc --arg booted "$booted" --arg index "$index" \
    --arg manifest "$manifest" \
    '{booted:$booted,digests:{index:$index,manifest:$manifest}}')" ||
    warn "cannot journal the unrecorded boot"
  deploy_notify fail booted-unrecorded || warn "could not report the unrecorded boot"
  warn "booted $booted, which $deploy_state_file does not name; left alone"
  return 0
}

main() {
  local doc commit index manifest booted revert_rc=0
  deploy_state_init || {
    warn "cannot create $deploy_state_dir"
    exit 1
  }
  if ! deploy_lock_acquire "$lock_wait"; then
    journal_append boot-gate-locked "$(jq -nc --arg lock "$deploy_lock_file" '{lock:$lock}')" || true
    warn "another deploy holds $deploy_lock_file; the gate did not run"
    exit 1
  fi
  trap deploy_lock_release EXIT

  journal_append boot-gate-start '{}' || warn "cannot journal the gate start"
  # First, before any decision: this boot reached userspace, which is what a good
  # boot means here. The GRUB snippet spends an attempt on every boot, so a gate
  # that only marked the pending path good would let three ordinary reboots fall
  # back to the previous deployment with state.json naming the newer one.
  grub_mark_good || warn "the GRUB flags were not reset; the counter will fall back"
  reconcile_apply || revert_rc=$?

  if ! record_exists pending; then
    if ((revert_rc != 0)); then
      # The tenant may be half of two revisions and nothing will repair it on
      # this boot, so the operator hears about it even though the platform
      # decision is "nothing to do".
      deploy_notify fail apps-revert-failed || warn "could not report the failed revert"
    fi
    check_unrecorded_boot || true
    say "no staged deployment"
    exit 0
  fi
  if ! doc=$(pending_read); then
    journal_append pending-unreadable '{"reason":"cannot read the record"}' || true
    warn "cannot read $deploy_state_dir/pending.json"
    exit 1
  fi
  IFS=$'\t' read -r commit index manifest < <(pending_fields "$doc")
  if [[ -z $commit || (-z $index && -z $manifest) ]]; then
    journal_append pending-unreadable '{"reason":"the record names no commit or digest"}' || true
    warn "the pending record names no commit or digest"
    exit 1
  fi

  if ! booted=$(booted_digest); then
    # Nothing is decided: no denylist, no rollback, and the record stays so the
    # next boot can try again.
    journal_append bootc-status-failed "$(jq -nc --arg commit "$commit" '{commit:$commit}')" ||
      true
    deploy_notify fail bootc-status-unreadable || warn "could not report the undecided boot"
    warn "cannot read the booted deployment; nothing was decided"
    exit 1
  fi

  if digest_matches "$booted" "$index" "$manifest"; then
    # The staged deployment is running, so the tenant has to be the revision the
    # plan names before the health gate judges it. A revert that could not run
    # leaves half of two revisions under a plan nobody restored: that is a failed
    # gate, and it takes the same denylist and rollback as any other.
    if ((revert_rc != 0)); then
      fail_gate apply-revert-failed "$commit" "$index" "$manifest" || exit 1
      exit 1
    fi
    if health_gate; then
      succeed "$commit" "$index" "$manifest" || exit 1
      exit 0
    fi
    fail_gate "$health_reason" "$commit" "$index" "$manifest" || exit 1
    exit 1
  fi

  # Booted something else: the bootloader already fell back, or an operator did.
  # Nothing is rolled back, and the record is consumed so a later manual reboot
  # cannot roll a healthy host back either. A revert that did not finish is in the
  # journal and the page names the rollback; the record it kept stays for the next
  # boot gate or drain.
  rolled_back "$booted" "$commit" "$index" "$manifest" || exit 1
  exit 0
}

case ${1-} in
  -h | --help)
    cat >&2 <<'EOF'
usage: smortress-boot-gate

  Runs on every boot: reconciles an interrupted apps apply, then keeps or rolls
  back the deployment a pending.json says was staged. No arguments.
EOF
    exit 0
    ;;
  '') main ;;
  *)
    printf 'smortress-boot-gate: no arguments\n' >&2
    exit 2
    ;;
esac
