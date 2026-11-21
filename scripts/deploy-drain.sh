#!/usr/bin/env bash
# Drain the deploy queue (SDLC #798, T1): validate, coalesce, and hand each
# request to the deploy action.
#
# This is the single writer of state.json, started by smortress-deploy.path when
# a request lands in the queue and re-triggered by every later one. It runs
# under `flock /run/smortress/deploy.lock`, drains in strict FIFO order except
# that a newer request for the same repository supersedes an older pending one,
# and rescans once before exiting so the window between "queue empty" and "unit
# inactive" cannot drop an event.
#
# The T1 action is a stub: verify the queued shape, journal `drained-stub`,
# remove the entry. T2 replaces the action with the GitHub graph and registry
# resolution; the queue handling around it does not change.
#
# Every knob is environment-overridable so tests/deploy/state.sh can drive this
# exact code. Production sets none of them.
#
# shellcheck disable=SC2154  # deploy-state.sh assigns these at source time
set -euo pipefail

self_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# The image installs the library beside this script as /usr/libexec/deploy-state
# (the smortress-src loop strips the `.sh`); a checkout has it beside the script.
state_lib=${DEPLOY_STATE_LIB:-}
if [[ -z $state_lib ]]; then
  if [[ -r /usr/libexec/deploy-state ]]; then
    state_lib=/usr/libexec/deploy-state
  else
    state_lib=$self_dir/deploy-state.sh
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

say() { printf 'deploy-drain: %s\n' "$*"; }
warn() { printf 'deploy-drain: %s\n' "$*" >&2; }

# The queued shape T2 will act on. An entry that cannot be read must never wedge
# the queue: it is dropped with a record, which is also what a half-written
# legacy file becomes after a downgrade.
drain_entry_valid() { # <id>
  local file=$deploy_queue_dir/$1.json
  [[ -s $file ]] || return 1
  jq -e '
    (.repo == "homelab-platform" or .repo == "homelab-apps")
    and (.commit | type == "string" and test("^[0-9a-f]{40}$"))
    and (.id | type == "string")
  ' "$file" >/dev/null 2>&1
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

drained=0
superseded=0
invalid=0
rescanned=0
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

  id=${ids[0]}
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

  journal_append drained-stub "$(jq -nc --arg id "$id" --arg repo "$repo" --arg commit "$commit" \
    '{id:$id,repo:$repo,commit:$commit}')" || {
    warn "cannot journal $id; leaving it queued"
    exit 1
  }
  say "$repo $commit: drained (stub)"
  drained=$((drained + 1))
  queue_pop "$id" || {
    warn "cannot remove $id from the queue"
    exit 1
  }
done

journal_append drain-finish "$(jq -nc --argjson drained "$drained" --argjson superseded "$superseded" \
  --argjson invalid "$invalid" \
  '{drained:$drained,superseded:$superseded,invalid:$invalid}')" ||
  warn "cannot journal the drain finish"
say "drained $drained, superseded $superseded, invalid $invalid"
