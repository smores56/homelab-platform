# shellcheck shell=bash
# The deploy queue: drain it in FIFO order, pop what was decided, retry what was
# not (SDLC #798, T1; shared by both roles in design #939, T2).
#
# This is the single writer of state.json, started by a path unit when a request
# lands in the queue and re-triggered by every later one. It runs under `flock
# $deploy_lock_file`, drains in strict FIFO order except that a newer request for
# the same repository supersedes an older pending one, and rescans once before
# exiting so the window between "queue empty" and "unit inactive" cannot drop an
# event.
#
# What is shared is the loop and the decision of *what to do with an entry*;
# what a role supplies is the action and its gate, because those are the parts
# that differ between an immutable host with a snapshot plane and one without:
#
#   verify_bin           the verifier this role runs (server: deploy-verify.py)
#   drain_repos          the repositories this role deploys, space-separated --
#                        the shell spelling of decisions.ROLES[<role>].repos
#   drain_role_recover   crash-state repair before the queue (server: revert an
#                        interrupted apps apply, sweep its work trees; a role
#                        with nothing to repair defines a no-op)
#   drain_role_apply     the action a verified entry authorizes, with the
#                        role's gate inside it: the server's snapshot gate and
#                        stage, or its tenant apply. It journals and reports
#                        what it did in `drain_action`; the loop counts it.
#
# A rejection is final for that entry and is never retried, because the hourly
# poll and the next event would fail identically; an infrastructure failure
# leaves the entry queued with a `retry_at` stamp, because this drain is re-fired
# the moment it exits and an immediate retry turns one 429 into a loop that
# spends the unit's start limit. A held deploy is popped too: the hold record is
# the resume point, and `smortress-deploy release --force` plus the next request
# is what carries it forward.
#
# Every knob is environment-overridable so tests/deploy/*.bats can drive this
# exact code. Production sets none of them.
#
# shellcheck disable=SC2154  # the role and deploy-state.sh assign these at source time

# A pause before the final rescan. It costs one second on an idle host and buys
# two things: a burst of requests that arrived while the drain was working is
# drained by the same run, and the path unit's re-trigger of an already-running
# unit is not the only thing standing between an event and the next event.
rescan_pause=${DEPLOY_DRAIN_RESCAN_PAUSE:-1}

# How long a deferred entry waits before it is tried again. Five minutes is the
# period of the retry timer, so a deferred entry is retried by the timer when no
# event arrives, and the poll's dead-man pages long before a queue of deferrals
# goes unnoticed.
retry_delay=${DEPLOY_RETRY_DELAY:-300}
defer_cap=${DEPLOY_DRAIN_DEFER_CAP:-60}

# The verifier bounds each HTTP call itself; this bounds the call as a whole, so
# a wedged process cannot hold the deploy lock until the unit's timeout.
verify_deadline=${DEPLOY_VERIFY_DEADLINE:-300}

# The queued shape the verification action acts on. An entry that cannot be read
# must never wedge the queue: it is dropped with a record, which is also what a
# half-written legacy file becomes after a downgrade.
drain_entry_valid() { # <id>
  local file=$deploy_queue_dir/$1.json
  [[ -s $file ]] || return 1
  jq -e --arg repos "$drain_repos" '
    (.repo as $repo | ($repos | split(" ")) | index($repo) != null)
    and (.commit | type == "string" and test("^[0-9a-f]{40}$"))
    and (.id | type == "string")
  ' "$file" >/dev/null 2>&1
}

# drain_verify <id> <repo> <commit>
#
# Journals the verdict and returns 0 (verified), 3 (rejected), 5 (no image) or 4
# (could not verify). The reason of the last call is left in $verify_reason. The
# written stdout of a successful run is left in $verify_verdict: it carries both
# digest forms, which is what the stage step needs and what a re-resolution would
# only re-derive at the cost of more API budget.
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
# immediate retry is a loop that re-runs the verification, the role's gate and
# its action until systemd's start limit fails the unit and the queue freezes.
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

# drain_main: the loop. The role script calls this last, after defining the four
# things listed at the top of this file.
drain_main() {
  : "${verify_bin:?drain_main: the role must resolve verify_bin}"
  : "${drain_repos:?drain_main: the role must name the repos it deploys}"
  declare -F drain_role_recover >/dev/null ||
    { warn "drain_main: the role defines no drain_role_recover"; exit 1; }
  declare -F drain_role_apply >/dev/null ||
    { warn "drain_main: the role defines no drain_role_apply"; exit 1; }

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

  # Before the queue: whatever the last run left half-done is not a state this
  # one may drain onto.
  drain_role_recover

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
        # The role acts on the verdict and journals what it did; a non-zero
        # return says the entry was not decided and must be retried. The digest
        # pair, when the verdict carries one, is what the stage needs and what a
        # re-resolution would only re-derive at the cost of more API budget.
        digests=$(jq -c '.digests // empty' <<<"$verify_verdict" 2>/dev/null) || digests=""
        drain_action=
        drain_defer_reason=
        if ! drain_role_apply "$id" "$repo" "$commit" "$digests"; then
          defer_entry "$id" "$drain_defer_reason"
        fi
        # Counters keep the shell suite's arithmetic: every popped entry that was
        # not deferred is counted in `drained`, and a hold, a refused stage and an
        # apps rejection are two things at once.
        case $drain_action in
          staged)
            drained=$((drained + 1))
            # A staged reboot ends the run: anything behind this entry would run
            # on a host that is already shutting down.
            staged_reboot=1
            ;;
          held)
            drained=$((drained + 1))
            held=$((held + 1))
            ;;
          refused)
            drained=$((drained + 1))
            refused=$((refused + 1))
            ;;
          rejected)
            drained=$((drained + 1))
            rejected=$((rejected + 1))
            ;;
          *)
            drained=$((drained + 1))
            ;;
        esac
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
}
