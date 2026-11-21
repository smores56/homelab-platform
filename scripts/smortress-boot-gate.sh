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
# decides, and its abandon path resets the flags so the counter cannot later
# select the deployment that just failed. The GRUB counter acts only when the
# gate cannot run at all (no userspace, a panicked kernel).
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
# a failed rollback) or the health gate failed and the rollback was issued.
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

say() { printf 'smortress-boot-gate: %s\n' "$*"; }
warn() { printf 'smortress-boot-gate: %s\n' "$*" >&2; }

# --- the GRUB flags ---------------------------------------------------------
# The counter is the only rollback that exists before userspace, so an absent
# grub2-editenv is a gap the journal has to name: a host that quietly fails to
# reset it rolls back a healthy deployment after three good boots.
grub_flags() { # <success|abandon>
  local kind=$1
  if ! command -v "$grub_editev" >/dev/null 2>&1; then
    journal_append grub-tool-missing "$(jq -nc --arg tool "$grub_editev" '{tool:$tool}')" ||
      true
    warn "$grub_editev is missing: the boot counter cannot be reset"
    return 1
  fi
  timeout --signal=TERM "$grub_timeout" "$grub_editev" "$grub_env" set \
    "boot_success=1" "boot_counter=$boot_budget" || return 1
  # Only the abandon path clears `default`: it was pointing at the previous
  # deployment, and after a rollback that entry is the one that just failed.
  if [[ $kind == abandon ]]; then
    timeout --signal=TERM "$grub_timeout" "$grub_editev" "$grub_env" unset default || return 1
  fi
  return 0
}

# --- the bootc answer -------------------------------------------------------
booted_digest() {
  local doc
  doc=$(timeout --signal=TERM "$status_timeout" "$bootc_bin" status --booted --json 2>/dev/null) ||
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
  timeout --signal=TERM "$connect_timeout" bash -c 'exec 3<>"/dev/tcp/127.0.0.1/$1"' _ "$1" \
    2>/dev/null
}

serve_status_paths() {
  local doc
  doc=$(timeout --signal=TERM "$probe_timeout" "$tailscale_bin" serve status --json 2>/dev/null) ||
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
    if [[ $(timeout --signal=TERM "$ctl_timeout" "$systemctl_bin" --user \
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
    if [[ $(timeout --signal=TERM "$ctl_timeout" "$systemctl_bin" is-active "$unit" \
      2>/dev/null) != active ]]; then
      health_reason="unit-inactive:$unit"
      return 1
    fi
  done
  # `failed` is asked about the declared units only: an unrelated unit that
  # failed must not roll the host back.
  for unit in "${gate_units[@]}"; do
    if [[ $(timeout --signal=TERM "$ctl_timeout" "$systemctl_bin" is-failed "$unit" \
      2>/dev/null) == failed ]]; then
      health_reason="unit-failed:$unit"
      return 1
    fi
  done
  timeout --signal=TERM "$probe_timeout" "$zpool_bin" list -H -o name "$pool" \
    >/dev/null 2>&1 || {
    health_reason="zpool-not-imported"
    return 1
  }
  timeout --signal=TERM "$probe_timeout" "$mountpoint_bin" -q "$apps_mount" \
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
  grub_flags success || warn "the boot counter was not reset"
  # The only writer of a landed deployment: nothing else may claim a commit is
  # running, and this runs on the boot that proves it.
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
  # counter left pointing at the failed deployment would select it again.
  grub_flags abandon || warn "the GRUB flags were not reset"
  deploy_notify fail "boot-gate-$reason" || warn "could not report the failed boot"
  timeout --signal=TERM --kill-after=30 "$rollback_timeout" "$bootc_bin" rollback --apply ||
    rc=$?
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
  grub_flags abandon || warn "the GRUB flags were not reset"
  deploy_notify fail rolled-back-by-bootloader || warn "could not report the rollback"
  pending_clear || {
    warn "cannot clear the pending record"
    return 1
  }
  warn "booted $booted, not the staged $index: left the host alone"
  return 0
}

# --- main -------------------------------------------------------------------
# An interrupted apps apply is T5's to revert; for now the boot has to say that
# it found one and leave the record, which is what makes the revert possible.
reconcile_apply() {
  local phase
  record_exists apply || return 0
  phase=$(record_field apply phase 2>/dev/null) || phase=unknown
  journal_append apply-interrupted "$(jq -nc --arg phase "$phase" '{phase:$phase}')" ||
    warn "cannot journal the interrupted apps apply"
  say "an apps apply was interrupted (phase $phase); the record is left for the revert"
}

main() {
  local doc commit index manifest booted
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
  reconcile_apply

  if ! record_exists pending; then
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
    if health_gate; then
      succeed "$commit" "$index" "$manifest" || exit 1
      exit 0
    fi
    fail_gate "$health_reason" "$commit" "$index" "$manifest" || exit 1
    exit 1
  fi

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
