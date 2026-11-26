#!/usr/bin/env bash
# Drain the deploy queue on the server (SDLC #798, T1; shared loop: design #939,
# T2). This script is the server role. The FIFO/pop/retry loop itself, the
# verification step and the counters live in bootc/lib/deploy/drain.sh, which
# both bootc images run; what stays here is what only this host can do:
#
#   drain_role_recover  repair the crash state of a tenant apply (revert an
#                       interrupted one, sweep its work trees) before draining;
#   drain_role_apply    the action a verified entry authorizes: the platform
#                       snapshot gate (T3) and the stage that reboots into the
#                       verified image (T4), or the apps apply (T5).
#
# The action is chosen by repository: a platform entry has a snapshot plane and a
# reboot, a tenant entry pulls, installs and reverts on its own and never
# reboots. Both are reached only with a verdict, and the platform one only with
# the digest pair the verdict resolved.
#
# Every knob is environment-overridable so tests/deploy/*.bats can drive this
# exact code. Production sets none of them.
#
# shellcheck disable=SC2034,SC2154  # deploy-state.sh and the shared loop use what this script sets, and the reverse
set -euo pipefail
# shellcheck source=/dev/null
_smolib=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/log.sh
[[ -r $_smolib ]] || _smolib=/usr/libexec/lib/log.sh
# shellcheck source=/dev/null
source "$_smolib"

self_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# The image installs the library beside this script as /usr/libexec/deploy-state
# (the smortress-src loop strips the `.sh`); a checkout has it beside the script.
state_lib=${DEPLOY_STATE_LIB:-}
if [[ -z $state_lib ]]; then
  # Sibling first: in the image both files land in /usr/libexec, and in a
  # checkout both are in scripts/. Preferring the fixed path made a checkout run
  # the installed copy from the running image -- the suites silently tested the
  # old library on the host that had one.
  if [[ -r $self_dir/deploy-state.sh ]]; then
    state_lib=$self_dir/deploy-state.sh
  elif [[ -r $self_dir/deploy-state ]]; then
    state_lib=$self_dir/deploy-state
  else
    state_lib=/usr/libexec/deploy-state
  fi
fi
[[ -r $state_lib ]] || {
  printf 'deploy-drain: no state library at %s\n' "$state_lib" >&2
  exit 1
}
# shellcheck source=/dev/null
source "$state_lib"

# The verifier ships in the image rootfs beside the receiver rather than through
# the `smortress-src` loop, which installs `.sh` files only.
verify_bin=$(deploy_resolve "${DEPLOY_VERIFY_BIN:-}" deploy-verify.py \
  "$self_dir/../bootc/server/rootfs/usr/libexec/deploy-verify.py")

# The platform gate ships the same way and owns its own 3600 s budget and every
# child's deadline; this is only the net under a wedged gate.
platform_bin=$(deploy_resolve "${DEPLOY_PLATFORM_BIN:-}" deploy-platform \
  "$self_dir/deploy-platform.sh")
gate_timeout=${DEPLOY_GATE_DEADLINE:-4200}

# The apps apply ships through the same loop. It keeps its own 5400 s budget and
# every child's deadline; this is the net under a wedged one, and it stays inside
# the drain unit's own TimeoutStartSec.
apps_bin=$(deploy_resolve "${DEPLOY_APPS_BIN:-}" deploy-apps "$self_dir/deploy-apps.sh")
apps_timeout=${DEPLOY_APPS_DEADLINE:-6000}

# The loop: the image installs it at /usr/libexec/deploy/drain.sh, beside the
# shared decisions; a checkout has it under bootc/lib. The checkout path is
# tried before the installed one for the reason the state library above gives.
drain_lib=${DEPLOY_DRAIN_LIB:-}
if [[ -z $drain_lib ]]; then
  if [[ -r $self_dir/../bootc/lib/deploy/drain.sh ]]; then
    drain_lib=$self_dir/../bootc/lib/deploy/drain.sh
  else
    drain_lib=/usr/libexec/deploy/drain.sh
  fi
fi
[[ -r $drain_lib ]] || {
  printf 'deploy-drain: no shared drain loop at %s\n' "$drain_lib" >&2
  exit 1
}
# shellcheck source=/dev/null
source "$drain_lib"

# The repositories this host deploys: the shell spelling of the server role's
# allowlist in bootc/lib/deploy/decisions.py. A queued entry for anything else is
# unreadable to this drain and is dropped with a record.
drain_repos="homelab-platform homelab-apps"

# drain_role_recover: an interrupted apps apply is half of one revision and the
# installed plan may already be the new one, so draining a request onto it would
# snapshot a state that never existed. The revert is idempotent and the boot gate
# has already journaled that it found the record.
#
# Every work tree an apps apply leaves behind holds the decrypted tenant secrets,
# and an interrupted one never gets to remove its own. They are swept here, under
# the lock and before the queue, so the tree the next apply needs is the one
# apply.json still names and every other one older than a day is garbage.
drain_role_recover() {
  local apps_rc=0
  if record_exists apply; then
    timeout --signal=TERM --kill-after=60 "$(clamp_timeout "$apps_timeout")" "$apps_bin" revert ||
      apps_rc=$?
    if ((apps_rc != 0)); then
      warn "an interrupted apps apply could not be reverted (exit $apps_rc); not draining"
      exit 1
    fi
    journal_append apply-reverted "$(jq -nc --arg by drain '{by:$by}')" ||
      warn "cannot journal the reverted apply"
  fi

  apps_rc=0
  timeout --signal=TERM --kill-after=60 "$(clamp_timeout "$apps_timeout")" "$apps_bin" sweep ||
    apps_rc=$?
  if ((apps_rc != 0)); then
    warn "cannot sweep the stale apps work trees (exit $apps_rc)"
  fi
}

# drain_role_apply <id> <repo> <commit> <digests>
#
# The action a verified entry authorizes, and the journal of what it did. Sets
# `drain_action` to `staged`, `held`, `refused`, `already-booted` or `applied`,
# and returns non-zero only when the entry was not decided: the reason is left in
# `drain_defer_reason` and the loop stamps a retry on it.
drain_role_apply() {
  local id=$1 repo=$2 commit=$3 digests=$4 rc=0
  if [[ $repo == homelab-platform ]]; then
    if [[ -z $digests ]]; then
      drain_defer_reason=verdict-without-digests
      return 1
    fi
    # The gate before any reboot: every restore unit must have a fresh verified
    # local snapshot, or the host holds instead of staging. Only a green gate
    # reaches `stage`, which is what keeps this drain from rebooting the host for
    # a commit nobody checked the backups of.
    rc=0
    timeout --signal=TERM --kill-after=60 "$(clamp_timeout "$gate_timeout")" \
      "$platform_bin" prepare --commit "$commit" --digests "$digests" || rc=$?
    case $rc in
      0)
        say "$repo $commit: snapshot gate green"
        # Staging is the last thing this drain does for the entry: it writes
        # pending.json before it asks for the reboot, so the record the boot gate
        # needs is on disk even if the shutdown kills this process. A successful
        # stage has no verdict to journal -- the boot gate records the deployment
        # on the way back up.
        rc=0
        timeout --signal=TERM --kill-after=60 "$(clamp_timeout "$gate_timeout")" \
          "$platform_bin" stage --commit "$commit" --digests "$digests" || rc=$?
        case $rc in
          0)
            # The reboot is the deploy.
            say "$repo $commit: staged; rebooting into it"
            drain_action=staged
            ;;
          5)
            # The staged image is not the one the verifier resolved. Nothing was
            # recorded and the same switch would fail identically, so the entry is
            # popped and the operator reads the journal.
            say "$repo $commit: staged image refused"
            drain_action=refused
            ;;
          6)
            # The host already runs the verified image: a manual upgrade moved it,
            # and the state now catches up without a reboot.
            journal_append stage-already-booted "$(jq -nc --arg id "$id" --arg repo "$repo" \
              --arg commit "$commit" '{id:$id,repo:$repo,commit:$commit}')" ||
              warn "cannot journal the already-running image"
            say "$repo $commit: already running; recorded"
            drain_action=already-booted
            ;;
          *)
            # A staging failure is an outage, not a verdict: the path unit re-fires
            # this drain as soon as it exits, so exiting here would re-run
            # verification, the gate and the switch in a tight loop.
            drain_defer_reason="staging-exit-$rc"
            return 1
            ;;
        esac
        ;;
      5)
        # Held is a decision, not an outage: the entry is popped and the hold
        # record is what the operator releases.
        say "$repo $commit: deploy held"
        drain_action=held
        ;;
      6)
        # The host carries a drop-in the image does not ship, and staging would
        # reboot into a host whose apps apply cannot land (#152). The gate
        # journaled the paths; the entry keeps its place until an operator removes
        # them.
        drain_defer_reason=host-drift
        return 1
        ;;
      *)
        drain_defer_reason="snapshot-gate-exit-$rc"
        return 1
        ;;
    esac
    return 0
  fi

  # Apps has no reboot and no snapshot gate: the apply pulls, installs and reverts
  # on its own, so its exit is the whole verdict. 3 is a commit the validator
  # refused and the apply already denylisted, which is final for this entry;
  # anything else changed nothing (or was rolled back) and the entry keeps its
  # place.
  rc=0
  timeout --signal=TERM --kill-after=60 "$(clamp_timeout "$apps_timeout")" \
    "$apps_bin" apply --commit "$commit" || rc=$?
  case $rc in
    0)
      say "$repo $commit: applied"
      drain_action=applied
      ;;
    3)
      say "$repo $commit: rejected by the apps schema"
      drain_action=rejected
      ;;
    *)
      drain_defer_reason="apps-apply-exit-$rc"
      return 1
      ;;
  esac
}

drain_main
