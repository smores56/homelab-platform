#!/usr/bin/env bash
# Deploy heartbeat: the dead-man for the deploy queue (SDLC #798, T6; #1010).
#
#   deploy-heartbeat
#
# The deploy check goes green only when no queued request has waited more than the
# host's limit. Anything else -- a drain wedged behind a stalled pull with the lock
# held -- pings `/fail` with the reason.
#
# It is a separate program from the quarter-hour poll on purpose: a poll-driven ping
# cannot see a wedged drain, because the poll's own request would be the one stuck
# in the queue while the poll keeps reporting that it enqueued something. Since
# #1018 deleted the receiver there is no listener to probe: the queue is the whole
# of the state a beat judges, and #1019 replaces this program with a poll-side ping.
#
# Exit codes: 0 the check was pinged green (or the ping URL is absent, which is a
# journaled skip on a host mid-bootstrap), 1 the check was pinged red.
#
# Every knob is environment-overridable so tests/deploy/heartbeat.sh can drive this
# exact code. Production sets none of them.
#
# shellcheck disable=SC2154  # deploy-state.sh assigns these at source time
set -euo pipefail
# shellcheck source=/dev/null
_smolib=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/log.sh
[[ -r $_smolib ]] || _smolib=/usr/libexec/lib/log.sh
# shellcheck source=/dev/null
source "$_smolib"

if (($#)); then
  printf 'usage: deploy-heartbeat\n' >&2
  exit 2
fi

self_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
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
  printf 'deploy-heartbeat: no state library at %s\n' "$state_lib" >&2
  exit 1
}
# shellcheck source=/dev/null
source "$state_lib"

# Two hours is longer than a drain can legitimately spend on one request with
# another waiting behind it: the snapshot gate's hour plus an apps apply's ninety
# minutes, and a healthy queue never comes near it. A request that old means the
# drain is not running rather than working -- the limit has to sit above the
# slowest honest deploy, or a healthy host pages on its own slow rollout.
queue_max_age=${DEPLOY_QUEUE_MAX_AGE:-7200}

fail_and_exit() { # <reason>
  # The reason carries the program name already: it is the line Pushover shows, and
  # a bare /fail there says the host is unhappy and nothing about which part.
  printf '%s\n' "$1" >&2
  journal_append heartbeat-failed "$(jq -nc --arg reason "$1" '{reason:$reason}')" ||
    warn "cannot journal the failed beat"
  deploy_notify fail "$1" || warn "cannot report the failure to the deploy check"
  exit 1
}

# The oldest request, not the count: a queue with one entry younger than a minute
# is a deploy in flight, and a queue with one entry older than half an hour is a
# drain that is not running. The scan is the state library's `queue_oldest`, so
# the heartbeat and the drain agree on which files are entries.
oldest_id=
oldest_age=0
read -r oldest_age oldest_id < <(queue_oldest)

if ((oldest_age > queue_max_age)); then
  fail_and_exit "deploy-heartbeat: queue entry $oldest_id is older than the ${queue_max_age}s limit (waited ${oldest_age}s)"
fi

journal_append heartbeat-ok "$(jq -nc --argjson oldest "$oldest_age" '{oldestQueuedSeconds:$oldest}')" ||
  warn "cannot journal the healthy beat"
# A success ping clears the check and unpages; the URL never reaches the journal.
deploy_notify success || warn "cannot ping the deploy check"
say "healthy; oldest queued request is ${oldest_age}s old"
