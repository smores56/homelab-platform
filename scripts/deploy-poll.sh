#!/usr/bin/env bash
# Hourly deploy poll: the backstop trigger (SDLC #798, T6).
#
#   deploy-poll
#
# For each repository it resolves `main` through the anonymous GitHub API and
# enqueues one request when the tip differs from the deployed commit. That is the
# whole job: the tip, the commit graph, the registry, the signature and every gate
# belong to the drain, so this program decides nothing and records nothing except
# its own journal lines. A poll that made a decision would be a second, weaker
# verifier running outside the deploy lock.
#
# It is not a liveness signal -- smortress-deploy-heartbeat.timer is -- because a
# poll whose own request sits behind a wedged drain still looks healthy. What the
# poll does own is the case an event cannot cover: a notify job that never ran, a
# tailnet that was down, a build that landed while the host was off.
#
# A denylisted tip pages and enqueues nothing: the same commit would fail the same
# check on every hour, and a silent retry loop hides the failure until someone
# reads the journal. Removal from the denylist is the operator's (`unblock`).
#
# Exit codes: 0 every repository was polled, 1 at least one could not be (the unit
# fails, which is the visible signal), 2 usage.
#
# Every knob is environment-overridable so tests/deploy/poll.sh can drive this
# exact code against a throwaway directory. Production sets none of them.
#
# shellcheck disable=SC2154  # deploy-state.sh assigns these at source time
set -euo pipefail
# shellcheck source=/dev/null
_smolib=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/log.sh
[[ -r $_smolib ]] || _smolib=/usr/libexec/lib/log.sh
# shellcheck source=/dev/null
source "$_smolib"

if (($#)); then
  printf 'usage: deploy-poll\n' >&2
  exit 2
fi

self_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# The image installs the library as /usr/libexec/deploy-state (the smortress-src
# loop strips the `.sh`); a checkout has it beside the script.
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
  printf 'deploy-poll: no state library at %s\n' "$state_lib" >&2
  exit 1
}
# shellcheck source=/dev/null
source "$state_lib"

poll_repos=${DEPLOY_POLL_REPOS:-homelab-platform homelab-apps}
github_api=${DEPLOY_GITHUB_API:-https://api.github.com}
github_api=${github_api%/}
# Same owner as the verifier's, and not a knob: the repositories this host deploys
# are the two in that account, and a typo here would poll a stranger's tip.
owner=smores56
# One deadline per call, as in the verifier: a wedged TLS read must not spend the
# time the next repository needs, and the unit bounds the run as a whole.
poll_timeout=${DEPLOY_POLL_TIMEOUT:-30}
# The verifier answers from a 120 s on-disk cache; this is the same rule under its
# own file. It cannot share that file: the verifier writes it while holding the
# deploy lock, and a second writer outside the lock would drop its entries.
poll_cache=${DEPLOY_POLL_CACHE:-$deploy_state_dir/poll-cache.json}
poll_cache_ttl=${DEPLOY_POLL_CACHE_TTL:-120}
# The listener's own queue cap, mirrored rather than read: the listener refuses the
# 33rd request and the poll must not be the thing that grows the queue past it.
poll_queue_cap=${DEPLOY_QUEUE_CAP:-32}


# -- the 120 s cache --------------------------------------------------------

cache_tip() { # <url> -> the cached document's sha, if the entry is fresh
  [[ -s $poll_cache ]] || return 1
  jq -er --arg url "$1" --argjson now "$(date +%s)" --argjson ttl "$poll_cache_ttl" \
    '.entries[$url]
     | select(type == "object" and (.at | type) == "number")
     | select(($now - .at) <= $ttl)
     | .value.object.sha' "$poll_cache" 2>/dev/null
}

# The prune is written so that one unreadable entry costs that entry and nothing
# else. The whole document is rewritten from the one just read, so a filter that
# raises -- a missing `at`, a string where a number belongs -- leaves jq with no
# output at all and atomic_write would replace the cache with an empty file: the
# next run then pays for every URL again, which is the budget this file exists to
# protect. `.value` inside with_entries is the entry, so its stamp is `.value.at`.
cache_put() { # <url> <document-json>
  local current
  current=$(cat -- "$poll_cache" 2>/dev/null) || current=''
  jq -e 'type == "object" and (.entries | type) == "object"' <<<"${current:-{\}}" \
    >/dev/null 2>&1 || current='{}'
  jq -c --arg url "$1" --argjson now "$(date +%s)" --argjson ttl "$poll_cache_ttl" \
    --argjson value "$2" '
      {schema: 1,
       entries: ((.entries // {})
         | with_entries(select((.value.at? // null) as $at
             | ($at | type) == "number" and ($now - $at) <= $ttl))
         | .[$url] = {at: $now, value: $value})}
    ' <<<"$current" | atomic_write "$poll_cache"
}

# -- GitHub: what `main` points at now --------------------------------------

tip_reason=

github_tip() { # <repo>; prints the tip sha
  local repo=$1 url out code rc=0 sha
  url=$github_api/repos/$owner/$repo/git/ref/heads/main
  if sha=$(cache_tip "$url"); then
    printf '%s\n' "$sha"
    return 0
  fi
  out=$(mktemp "$deploy_state_dir/.poll.XXXXXX")
  # --write-out instead of --fail: a 403 is not a network failure, and the two have
  # to be told apart because only an exhausted budget is worth a page.
  code=$("$deploy_curl_bin" --silent --show-error --max-time "$poll_timeout" \
    --output "$out" --write-out '%{http_code}' "$url") || rc=$?
  if ((rc != 0)); then
    rm -f -- "$out"
    tip_reason="github-unreachable (curl exit $rc)"
    return 4
  fi
  case $code in
    200) ;;
    403 | 429)
      # Its own exit code: "the budget is gone" is paged and "the API is not
      # answering" is not, and a global flag set here would not survive the
      # command substitution the caller reads this function through.
      rm -f -- "$out"
      tip_reason="github-rate-limited ($code)"
      return 3
      ;;
    *)
      rm -f -- "$out"
      tip_reason="github-http-$code"
      return 4
      ;;
  esac
  sha=$(jq -er '.object.sha' "$out" 2>/dev/null) || sha=""
  if [[ ! $sha =~ ^[0-9a-f]{40}$ ]]; then
    rm -f -- "$out"
    tip_reason=github-bad-response
    return 4
  fi
  cache_put "$url" "$(jq -c '{object: {sha: .object.sha}}' "$out")" ||
    warn "cannot write the poll cache; the next run pays for the API again"
  rm -f -- "$out"
  printf '%s\n' "$sha"
}

# -- the queue is the only thing this program writes ------------------------

# `queue_has` is the state library's, so the poll and the drain agree on what an
# entry is and what revision it names. A second entry for the same commit would
# drain the same revision twice.

poll_enqueue() { # <repo> <commit>
  local id
  # The kernel's uuid4: the listener mints its ids the same way, and the drain
  # accepts only that shape as a path component, so nothing here needs a library.
  id=$(cat /proc/sys/kernel/random/uuid) || return 1
  jq -cn --arg id "$id" --arg repo "$1" --arg commit "$2" --argjson at "$(date +%s)" \
    '{schema: 1, id: $id, repo: $repo, commit: $commit, queued_at: $at, source: "poll"}' |
    atomic_write "$deploy_queue_dir/$id.json" || return 1
  journal_append poll-enqueued "$(jq -nc --arg id "$id" --arg repo "$1" --arg commit "$2" \
    '{id:$id,repo:$repo,commit:$commit}')" || return 1
}

deploy_state_init || {
  warn "cannot create $deploy_state_dir"
  exit 1
}

status=0
enqueued=0
current=0
queued=0
denied=0
skipped=0
for repo in $poll_repos; do
  tip_reason=
  rc=0
  tip=$(github_tip "$repo") || rc=$?
  if ((rc != 0)); then
    if ((rc == 3)); then
      # An exhausted anonymous budget looks exactly like a host with nothing to
      # deploy, for ever, so it is paged rather than journaled.
      journal_append poll-failed "$(jq -nc --arg repo "$repo" --arg reason "$tip_reason" \
        '{repo:$repo,reason:$reason,paged:true}')" ||
        warn "cannot journal the rate limit"
      deploy_notify fail "deploy-poll: $repo $tip_reason" ||
        warn "cannot report the rate limit to the deploy check"
    else
      journal_append poll-failed "$(jq -nc --arg repo "$repo" --arg reason "$tip_reason" \
        '{repo:$repo,reason:$reason,paged:false}')" ||
        warn "cannot journal the failure"
    fi
    warn "$repo: cannot resolve main ($tip_reason)"
    status=1
    continue
  fi

  if denylist_has commit "$tip"; then
    say "$repo $tip: denylisted; not enqueuing"
    journal_append poll-denylisted "$(jq -nc --arg repo "$repo" --arg commit "$tip" \
      '{repo:$repo,commit:$commit}')" || warn "cannot journal the denylisted tip"
    deploy_notify fail "deploy-poll: $repo $tip is denylisted" ||
      warn "cannot report the denylisted tip to the deploy check"
    denied=$((denied + 1))
    continue
  fi

  deployed=$(deployed_commit "$repo" 2>/dev/null) || deployed=""
  if [[ -z $deployed ]]; then
    # Bootstrap is explicit (design #798): the operator records the running commit
    # once after a restore, and the poll must not invent an ancestor for it.
    say "$repo: no deployed commit recorded; not enqueuing"
    journal_append poll-unseeded "$(jq -nc --arg repo "$repo" --arg commit "$tip" \
      '{repo:$repo,commit:$commit}')" || warn "cannot journal the unseeded repository"
    skipped=$((skipped + 1))
    continue
  fi
  if [[ $tip == "$deployed" ]]; then
    journal_append poll-current "$(jq -nc --arg repo "$repo" --arg commit "$tip" \
      '{repo:$repo,commit:$commit}')" || warn "cannot journal the current tip"
    current=$((current + 1))
    continue
  fi
  if queue_has "$repo" "$tip"; then
    journal_append poll-queued "$(jq -nc --arg repo "$repo" --arg commit "$tip" \
      '{repo:$repo,commit:$commit}')" || warn "cannot journal the queued tip"
    queued=$((queued + 1))
    continue
  fi
  if [[ $(queue_count) -ge $poll_queue_cap ]]; then
    # The listener refuses the 33rd request for the same reason; a full queue that
    # never drains is what the heartbeat's thirty-minute limit exists to catch.
    journal_append poll-queue-full "$(jq -nc --arg repo "$repo" --arg commit "$tip" \
      '{repo:$repo,commit:$commit}')" || warn "cannot journal the full queue"
    warn "$repo $tip: the queue is full; not enqueuing"
    status=1
    continue
  fi
  if ! poll_enqueue "$repo" "$tip"; then
    warn "$repo $tip: cannot enqueue"
    status=1
    continue
  fi
  say "$repo $tip: enqueued"
  enqueued=$((enqueued + 1))
done

journal_append poll-finish "$(jq -nc --argjson enqueued "$enqueued" --argjson current "$current" \
  --argjson queued "$queued" --argjson denied "$denied" --argjson skipped "$skipped" \
  '{enqueued:$enqueued,current:$current,queued:$queued,denied:$denied,skipped:$skipped}')" ||
  warn "cannot journal the poll finish"
say "enqueued $enqueued, current $current, queued $queued, denylisted $denied, unseeded $skipped"
exit "$status"
