#!/usr/bin/env bash
# Deploy heartbeat: the dead-man for the receiver itself (SDLC #798, T6).
#
#   deploy-heartbeat
#
# The deploy check goes green only when the listener answers `/healthz` inside five
# seconds *and* no queued request has waited more than two hours. Anything else
# -- a stopped listener, a 5xx, a drain wedged behind a stalled pull with the lock
# held -- pings `/fail` with the reason.
#
# It is a separate program from the hourly poll on purpose: a poll-driven ping
# cannot see a wedged drain, because the poll's own request would be the one stuck
# in the queue while the poll keeps reporting that it enqueued something. The
# receiver's own liveness is therefore asserted from inside the host, not inferred
# from GitHub.
#
# Exit codes: 0 the check was pinged green (or the ping URL is absent, which is a
# journaled skip on a host mid-bootstrap), 1 the check was pinged red.
#
# Every knob is environment-overridable so tests/deploy/heartbeat.sh can drive this
# exact code. Production sets none of them.
#
# shellcheck disable=SC2154  # deploy-state.sh assigns these at source time
set -euo pipefail

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

health_url=${DEPLOY_HEALTH_URL:-http://127.0.0.1:8484/healthz}
health_timeout=${DEPLOY_HEALTH_TIMEOUT:-5}
# Two hours is longer than a drain can legitimately spend on one request with
# another waiting behind it: the snapshot gate's hour plus an apps apply's ninety
# minutes, and a healthy queue never comes near it. A request that old means the
# drain is not running rather than working -- the limit has to sit above the
# slowest honest deploy, or a healthy host pages on its own slow rollout.
queue_max_age=${DEPLOY_QUEUE_MAX_AGE:-7200}

say() { printf 'deploy-heartbeat: %s\n' "$*"; }
warn() { printf 'deploy-heartbeat: %s\n' "$*" >&2; }

fail_and_exit() { # <reason>
  # The reason carries the program name already: it is the line Pushover shows, and
  # a bare /fail there says the host is unhappy and nothing about which part.
  printf '%s\n' "$1" >&2
  journal_append heartbeat-failed "$(jq -nc --arg reason "$1" '{reason:$reason}')" ||
    warn "cannot journal the failed beat"
  deploy_notify fail "$1" || warn "cannot report the failure to the deploy check"
  exit 1
}

# The listener answers this on loopback without touching the queue, so a healthy
# idle host and a healthy busy host look the same. --fail makes any status >= 400
# a failure, which is what "answers 200" means here.
if ! "$deploy_curl_bin" --fail --silent --show-error --output /dev/null \
  --max-time "$health_timeout" "$health_url"; then
  fail_and_exit "deploy-heartbeat: the listener did not answer $health_url within ${health_timeout}s"
fi

# The oldest request, not the count: a queue with one entry younger than a minute
# is a deploy in flight, and a queue with one entry older than half an hour is a
# drain that is not running.
oldest_id=
oldest_age=0
now=$(date +%s)
if [[ -d $deploy_queue_dir ]]; then
  while IFS= read -r file; do
    [[ -n $file ]] || continue
    # An entry the drain cannot order is worse than an old one: the drain drops it
    # on its next run, but until then it is a record nobody can read, so it counts
    # as infinitely old rather than as fresh.
    queued=$(jq -er '.queued_at | tonumber' "$file" 2>/dev/null) || queued=0
    age=$((now - queued))
    # A queued_at in the future is a clock that stepped; it is not an old request.
    if ((age < 0)); then age=0; fi
    if ((age >= oldest_age)); then
      oldest_age=$age
      oldest_id=$(basename -- "$file" .json)
    fi
  done < <(find "$deploy_queue_dir" -maxdepth 1 -type f -name '*.json' 2>/dev/null | sort)
fi

if ((oldest_age > queue_max_age)); then
  fail_and_exit "deploy-heartbeat: queue entry $oldest_id is older than the ${queue_max_age}s limit (waited ${oldest_age}s)"
fi

journal_append heartbeat-ok "$(jq -nc --argjson oldest "$oldest_age" '{oldestQueuedSeconds:$oldest}')" ||
  warn "cannot journal the healthy beat"
# A success ping clears the check and unpages; the URL never reaches the journal.
deploy_notify success || warn "cannot ping the deploy check"
say "healthy; oldest queued request is ${oldest_age}s old"
