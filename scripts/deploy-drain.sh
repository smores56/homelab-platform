#!/usr/bin/env bash
# Drain the deploy queue (SDLC #798, T1): validate, coalesce, and hand each
# request to the deploy action.
#
# This is the single writer of state.json, started by smortress-deploy.path when
# a request lands in the queue and re-triggered by every later one. It runs
# under `flock /run/smortress-deploy/deploy.lock`, drains in strict FIFO order except
# that a newer request for the same repository supersedes an older pending one,
# and rescans once before exiting so the window between "queue empty" and "unit
# inactive" cannot drop an event.
#
# The action is verification (T2), then the platform snapshot gate (T3) and the
# stage that reboots into the verified image (T4), or the apps apply (T5): the
# queued shape, the host's own checks -- tip, descendancy, tag-to-digest, revision
# label, denylist -- then the pre-reboot gate and `bootc switch`, or the tenant
# apply that installs the commit's units, secrets and Serve routes. The entry is
# popped once that verdict is recorded, and on a platform deploy the reboot is the
# exit: the record that the deployment landed is written by the boot gate on the
# way up, not here, and a staged reboot ends the run: nothing behind that entry
# may be started on a host that is going down. A rejection is final for that entry
# and is never retried, because the hourly poll and the next event would fail
# identically; an infrastructure failure leaves the entry queued with a
# `retry_at` stamp and exits 0, because this drain is re-fired the moment it
# exits and an immediate retry turns one 429 into a loop that spends the unit's
# start limit. A held deploy is popped too: the hold record is the resume point,
# and `smortress-deploy release --force` plus the next request is what carries it
# forward.
#
# The drain also owns the crash state of an apps apply: it reverts an interrupted
# one (apply.json) before it drains anything, because the next request would
# otherwise be applied on top of half of the previous one. The boot gate journals
# `apply-interrupted` when it finds one and leaves the record; on a boot without a
# pending platform deployment this is the process that repairs the tenant.
#
# Every knob is environment-overridable so tests/deploy/*.sh can drive this
# exact code. Production sets none of them.
#
# shellcheck disable=SC2154  # deploy-state.sh assigns these at source time
set -euo pipefail

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

# A pause before the final rescan. It costs one second on an idle host and buys
# two things: a burst of requests that arrived while the drain was working is
# drained by the same run, and the path unit's re-trigger of an already-running
# unit is not the only thing standing between an event and the next event.
rescan_pause=${DEPLOY_DRAIN_RESCAN_PAUSE:-1}

# How long a deferred entry waits before it is tried again. Five minutes is the
# period of smortress-deploy-retry.timer, so a deferred entry is retried by the
# timer when no event arrives, and the heartbeat pages long before a queue of
# deferrals goes unnoticed.
retry_delay=${DEPLOY_RETRY_DELAY:-300}
defer_cap=${DEPLOY_DRAIN_DEFER_CAP:-60}

# The verifier ships in the image rootfs beside the receiver rather than through
# the `smortress-src` loop, which installs `.sh` files only.
verify_bin=$(deploy_resolve "${DEPLOY_VERIFY_BIN:-}" deploy-verify.py \
  "$self_dir/../image/rootfs/usr/libexec/deploy-verify.py")
# The verifier bounds each HTTP call (30 s) itself; this bounds the call as a
# whole, so a wedged process cannot hold the deploy lock until TimeoutStartSec.
verify_deadline=${DEPLOY_VERIFY_DEADLINE:-300}

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

say() { printf 'deploy-drain: %s\n' "$*"; }
warn() { printf 'deploy-drain: %s\n' "$*" >&2; }

# The queued shape the verification action acts on. An entry that cannot be read
# must never wedge the queue: it is dropped with a record, which is also what a
# half-written legacy file becomes after a downgrade.
drain_entry_valid() { # <id>
  local file=$deploy_queue_dir/$1.json
  [[ -s $file ]] || return 1
  jq -e '
    (.repo == "homelab-platform" or .repo == "homelab-apps")
    and (.commit | type == "string" and test("^[0-9a-f]{40}$"))
    and (.id | type == "string")
  ' "$file" >/dev/null 2>&1
}

# drain_verify <id> <repo> <commit>
#
# Journals the verdict and returns 0 (verified), 3 (rejected) or 4 (could not
# verify). The reason of the last call is left in $verify_reason. The written
# stdout of a successful run is left in $verify_verdict: it carries both digest
# forms, which is what the stage step needs and what a re-resolution would only
# re-derive at the cost of more API budget.
verify_reason=
verify_verdict=
drain_verify() {
  local id=$1 repo=$2 sha=$3 rc=0
  verify_reason=
  verify_verdict=
  # An entry is verified against the tip main is at *now*: the verifier answers
  # from a 120 s cache, and a commit pushed inside that window would fail the tip
  # check for as long as the entry lives. The cache is worth having for one
  # run's repeated calls, not across two requests.
  cache_clear || warn "cannot clear the API cache; this verification may read a stale tip"
  verify_verdict=$(timeout --signal=TERM --kill-after=60 "$(clamp_timeout "$verify_deadline")" \
    "$verify_bin" --repo "$repo" --commit "$sha") || rc=$?
  case $rc in
    0)
      # A verifier that exits 0 without a parseable verdict is not a permission
      # to act: treat it as a failure to verify, never as a pass.
      if ! jq -e '.verdict == "verified"' <<<"$verify_verdict" >/dev/null 2>&1; then
        verify_reason=malformed-verdict
        verify_verdict=
        return 4
      fi
      if ! journal_append verified "$(jq -nc --arg id "$id" --arg repo "$repo" --arg commit "$sha" \
        --argjson verdict "$verify_verdict" '{id:$id,repo:$repo,commit:$commit,verdict:$verdict}')"; then
        verify_reason=journal-unwritable
        return 4
      fi
      return 0
      ;;
    3)
      verify_reason=$(jq -er '.reason' <<<"$verify_verdict" 2>/dev/null) || verify_reason=unspecified
      verify_verdict=
      if ! journal_append verify-rejected "$(jq -nc --arg id "$id" --arg repo "$repo" --arg commit "$sha" \
        --arg reason "$verify_reason" '{id:$id,repo:$repo,commit:$commit,reason:$reason}')"; then
        verify_reason=journal-unwritable
        return 4
      fi
      return 3
      ;;
    5)
      # No image for this commit: not a rejection, not an outage. The entry is
      # final either way, and the caller journals it as its own event so an
      # hourly poll over a docs-only commit does not look like a failure.
      verify_reason=$(jq -er '.reason' <<<"$verify_verdict" 2>/dev/null) || verify_reason=tag-missing
      verify_verdict=
      return 5
      ;;
    *)
      # Anything else -- exit 4, a crash, the deadline -- says nothing about the
      # commit, so the entry keeps its place in the queue.
      verify_reason=$(jq -er '.reason' <<<"$verify_verdict" 2>/dev/null) || verify_reason="verifier-exit-$rc"
      verify_verdict=
      journal_append verify-infra-failure "$(jq -nc --arg id "$id" --arg repo "$repo" --arg commit "$sha" \
        --arg reason "$verify_reason" --argjson exit "$rc" \
        '{id:$id,repo:$repo,commit:$commit,reason:$reason,exit:$exit}')" ||
        warn "cannot journal the verification failure of $id"
      return 4
      ;;
  esac
}

# defer_entry <id> <reason>
#
# An infrastructure failure -- a 429, a dead tailnet, a full image store -- says
# nothing about the commit, so the entry keeps its place in the queue. It does not
# keep its turn: the path unit re-fires this drain as soon as it exits, so an
# immediate retry is a loop that re-runs the verification, the snapshot gate and
# `bootc switch` until systemd's start limit fails the unit and the queue freezes.
# The entry carries the time it may be tried again, and the retry timer is what
# brings that attempt when no event does. Exits 0: there is nothing to fail here.
defer_entry() { # <id> <reason>
  local id=$1 reason=$2
  if ! queue_defer "$id" "$(($(date +%s) + retry_delay))" "$reason"; then
    warn "cannot stamp a retry on $id; leaving it queued"
    exit 1
  fi
  journal_append deferred "$(jq -nc --arg id "$id" --arg repo "$repo" --arg commit "$commit" \
    --arg reason "$reason" --argjson retry "$retry_delay" \
    '{id:$id,repo:$repo,commit:$commit,reason:$reason,retryIn:$retry}')" ||
    warn "cannot journal the deferred entry $id"
  say "$repo $commit: $reason; retrying in ${retry_delay}s"
  exit 0
}

# Bounded wait, not an unbounded one: a wedged holder turns into a failing unit
# instead of a drain that never returns.
if ! deploy_lock_acquire; then
  warn "another drain holds $deploy_lock_file; gave up after ${deploy_lock_wait}s"
  exit 1
fi
trap deploy_lock_release EXIT

deploy_state_init || {
  warn "cannot create $deploy_state_dir"
  exit 1
}

journal_append drain-start '{"source":"queue"}' || {
  warn "cannot journal the drain start"
  exit 1
}

# Before the queue: an interrupted apps apply is half of one revision and the
# installed plan may already be the new one, so draining a request onto it would
# snapshot a state that never existed. The revert is idempotent and the gate has
# already journaled that it found the record.
if record_exists apply; then
  apps_rc=0
  timeout --signal=TERM --kill-after=60 "$(clamp_timeout "$apps_timeout")" "$apps_bin" revert ||
    apps_rc=$?
  if ((apps_rc != 0)); then
    warn "an interrupted apps apply could not be reverted (exit $apps_rc); not draining"
    exit 1
  fi
  journal_append apply-reverted "$(jq -nc --arg by drain '{by:$by}')" ||
    warn "cannot journal the reverted apply"
fi

# Every work tree an apps apply leaves behind holds the decrypted tenant secrets,
# and an interrupted one never gets to remove its own. They are swept here, under
# the lock and before the queue, so the tree the next apply needs is the one
# apply.json still names and every other one older than a day is garbage.
sweep_rc=0
timeout --signal=TERM --kill-after=60 "$(clamp_timeout "$apps_timeout")" "$apps_bin" sweep ||
  sweep_rc=$?
if ((sweep_rc != 0)); then
  warn "cannot sweep the stale apps work trees (exit $sweep_rc)"
fi

drained=0
rejected=0
not_deployable=0
held=0
refused=0
noop=0
superseded=0
invalid=0
rescanned=0
staged_reboot=0
while :; do
  # Coalesce on every pass, not once at the start: an entry that landed while the
  # previous one was being handled is superseded by the same rule.
  while IFS= read -r id; do
    [[ -n $id ]] || continue
    journal_append queue-superseded "$(jq -nc --arg id "$id" '{id:$id,by:"newer request"}')" ||
      warn "cannot journal the superseded entry $id"
    superseded=$((superseded + 1))
  done < <(queue_coalesce)

  mapfile -t ids < <(queue_list)
  if ((${#ids[@]} == 0)); then
    # One more scan before exit: this is the only thing closing the race between
    # the path unit's trigger and this unit going inactive.
    if ((rescanned)); then
      break
    fi
    rescanned=1
    [[ $rescan_pause == 0 ]] || sleep "$rescan_pause"
    continue
  fi
  rescanned=0

  # The first entry that is not waiting out a deferral. The rest keep their
  # place: the retry timer is what brings the next attempt, and re-firing this
  # drain for an entry it has just deferred is the storm the stamp exists to stop.
  id=
  for candidate in "${ids[@]}"; do
    if queue_ready "$candidate"; then
      id=$candidate
      break
    fi
  done
  if [[ -z $id ]]; then
    # Parking, not exiting: systemd re-fires a path-triggered oneshot as soon as
    # it exits while the queue is non-empty, so exiting here is a hot loop that
    # ends in start-limit-hit and a failed path unit. Wait for the nearest stamp
    # and re-scan, capped so a changed queue and the unit timeout stay in play.
    park=$(queue_next_retry_in "$defer_cap")
    journal_append drain-parked "$(jq -nc --argjson wait "$park" '{wait:$wait}')" ||
      warn "cannot journal the parked drain"
    say "every queued request is deferred; next attempt in ${park}s"
    sleep "$park"
    continue
  fi
  repo=
  commit=
  # A read that fails here is the same case as an unreadable entry: it must not
  # end the unit with work still queued, because a oneshot the path unit already
  # triggered would then wait for the next event to be retried.
  if ! drain_entry_valid "$id" ||
    ! repo=$(queue_field "$id" repo) ||
    ! commit=$(queue_field "$id" commit); then
    journal_append queue-invalid "$(jq -nc --arg id "$id" '{id:$id,reason:"unreadable entry"}')" ||
      warn "cannot journal the invalid entry $id"
    invalid=$((invalid + 1))
    queue_pop "$id" || warn "cannot remove the invalid entry $id"
    continue
  fi

  # Already deployed is a no-op, not a verification: there is nothing to stage
  # and the commit graph would answer `identical`. The listener answers 200 for
  # the same case; this closes the race where the state moved while the entry
  # waited in the queue.
  if [[ $(deployed_commit "$repo") == "$commit" ]]; then
    journal_append already-deployed "$(jq -nc --arg id "$id" --arg repo "$repo" --arg commit "$commit" \
      '{id:$id,repo:$repo,commit:$commit}')" || {
      warn "cannot journal the already-deployed entry $id; leaving it queued"
      exit 1
    }
    noop=$((noop + 1))
    queue_pop "$id" || {
      warn "cannot remove $id from the queue"
      exit 1
    }
    continue
  fi

  verdict_rc=0
  drain_verify "$id" "$repo" "$commit" || verdict_rc=$?
  case $verdict_rc in
    0)
      say "$repo $commit: verified"
      if [[ $repo == homelab-platform ]]; then
        # The gate before any reboot: every restore unit must have a fresh
        # verified local snapshot, or the host holds instead of staging. Only a
        # green gate ($gate_rc 0) reaches `stage`, which is what keeps this drain
        # from rebooting the host for a commit nobody checked the backups of.
        digests=$(jq -c '.digests // empty' <<<"$verify_verdict" 2>/dev/null) || digests=""
        if [[ -z $digests ]]; then
          defer_entry "$id" verdict-without-digests
        fi
        gate_rc=0
        timeout --signal=TERM --kill-after=60 "$(clamp_timeout "$gate_timeout")" \
          "$platform_bin" prepare --commit "$commit" --digests "$digests" || gate_rc=$?
        case $gate_rc in
          0)
            say "$repo $commit: snapshot gate green"
            # Staging is the last thing this drain does for the entry: it writes
            # pending.json before it asks for the reboot, so the record the boot
            # gate needs is on disk even if the shutdown kills this process. A
            # successful stage has no verdict to journal -- the boot gate records
            # the deployment on the way back up.
            stage_rc=0
            timeout --signal=TERM --kill-after=60 "$(clamp_timeout "$gate_timeout")" \
              "$platform_bin" stage --commit "$commit" --digests "$digests" || stage_rc=$?
            case $stage_rc in
              0)
                # The reboot is the deploy. Anything behind this entry would run
                # on a host that is already shutting down, and an apps apply there
                # would be half-applied with a reboot on its way.
                say "$repo $commit: staged; rebooting into it"
                staged_reboot=1
                ;;
              5)
                # The staged image is not the one the verifier resolved. Nothing
                # was recorded and the same switch would fail identically, so the
                # entry is popped and the operator reads the journal.
                say "$repo $commit: staged image refused"
                refused=$((refused + 1))
                ;;
              6)
                # The host already runs the verified image: a manual upgrade
                # moved it, and the state now catches up without a reboot.
                journal_append stage-already-booted "$(jq -nc --arg id "$id" --arg repo "$repo" \
                  --arg commit "$commit" '{id:$id,repo:$repo,commit:$commit}')" ||
                  warn "cannot journal the already-running image"
                say "$repo $commit: already running; recorded"
                ;;
              *)
                # A staging failure is an outage, not a verdict: the path unit
                # re-fires this drain as soon as it exits, so exiting here would
                # re-run verification, the gate and the switch in a tight loop.
                # Defer the entry like every other infrastructure failure.
                defer_entry "$id" "staging-exit-$stage_rc"
                ;;
            esac
            ;;
          5)
            # Held is a decision, not an outage: the entry is popped and the
            # hold record is what the operator releases.
            say "$repo $commit: deploy held"
            held=$((held + 1))
            ;;
          *)
            defer_entry "$id" "snapshot-gate-exit-$gate_rc"
            ;;
        esac
      else
        # Apps has no reboot and no snapshot gate: the apply pulls, installs and
        # reverts on its own, so its exit is the whole verdict. 3 is a commit the
        # validator refused and the apply already denylisted, which is final for
        # this entry; anything else changed nothing (or was rolled back) and the
        # entry keeps its place.
        apps_rc=0
        timeout --signal=TERM --kill-after=60 "$(clamp_timeout "$apps_timeout")" \
          "$apps_bin" apply --commit "$commit" || apps_rc=$?
        case $apps_rc in
          0) say "$repo $commit: applied" ;;
          3)
            say "$repo $commit: rejected by the apps schema"
            rejected=$((rejected + 1))
            ;;
          *)
            defer_entry "$id" "apps-apply-exit-$apps_rc"
            ;;
        esac
      fi
      drained=$((drained + 1))
      ;;
    3)
      # Popped, not retried: the same commit would fail every check identically
      # on the next trigger, and a silent retry loop hides the failure.
      say "$repo $commit: rejected ($verify_reason)"
      rejected=$((rejected + 1))
      ;;
    5)
      # The commit has no image (a docs-only or test-only main commit): nothing
      # will change until an image-bearing commit, so this is not a failure, not
      # a denylist entry and not a page.
      journal_append verify-not-deployable "$(jq -nc --arg id "$id" --arg repo "$repo" \
        --arg commit "$commit" --arg reason "$verify_reason" \
        '{id:$id,repo:$repo,commit:$commit,reason:$reason}')" ||
        warn "cannot journal the not-deployable verdict for $id"
      say "$repo $commit: no image for this commit"
      not_deployable=$((not_deployable + 1))
      ;;
    *)
      defer_entry "$id" "$verify_reason"
      ;;
  esac
  queue_pop "$id" || {
    warn "cannot remove $id from the queue"
    exit 1
  }
  if ((staged_reboot)); then
    # pending.json is the record the boot gate resumes from, and the reboot is
    # already requested: the loop stops here so no later entry is acted on.
    break
  fi
done

journal_append drain-finish "$(jq -nc --argjson drained "$drained" --argjson rejected "$rejected" \
  --argjson held "$held" --argjson refused "$refused" \
  --argjson noop "$noop" --argjson superseded "$superseded" --argjson invalid "$invalid" \
  --argjson not_deployable "$not_deployable" \
  '{drained:$drained,rejected:$rejected,held:$held,refused:$refused,
    noop:$noop,superseded:$superseded,invalid:$invalid,
    notDeployable:$not_deployable}')" ||
  warn "cannot journal the drain finish"
say "drained $drained, rejected $rejected, held $held, refused $refused, no-op $noop, not-deployable $not_deployable, superseded $superseded, invalid $invalid"
