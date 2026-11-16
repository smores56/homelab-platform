#!/usr/bin/env bash
# Hourly freshness verifier for the smortress Restic plane (SDLC #706, T3).
#
#   smortress-restic-verify [--no-ping]
#
# Joins the durable attempt results under /var/lib/smortress/restic to what the
# repositories actually contain, then pings one Healthchecks.io check only when
# every destination is current. Missing state, an in-progress attempt past its
# retry window, a failed latest attempt, a snapshot that is not the recorded
# one, a missing tag, the wrong host or an unexpected source path all fail
# closed. An older successful snapshot never excuses a newer failed run: the
# latest recorded attempt is authoritative.
# shellcheck disable=SC2154  # variables and helpers come from restic-plane-common
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
common=$here/restic-plane-common
[[ -r $common ]] || common=$common.sh
# shellcheck source=/dev/null
source "$common"

# Everything this plane creates (lock files, journals, maintenance logs) is
# private to root by default; explicit modes are set on top of this.
umask 0077

usage() {
  cat >&2 <<'EOF'
usage: smortress-restic-verify [--no-ping]

  --no-ping  evaluate and report only; never contact Healthchecks

environment:
  RESTIC_HEALTHCHECK_URL  overrides the SOPS `restic-ping-url` value (tests)
EOF
}

ping=1
case ${1-} in
  --no-ping) ping=0 ;;
  -h | --help) usage; exit 0 ;;
  "") ;;
  *) usage; exit 2 ;;
esac

failures=0
fail() {
  warn "FAIL $*"
  failures=$((failures + 1))
}
ok() { say "ok   $*"; }

healthcheck_url() {
  if [[ -n ${RESTIC_HEALTHCHECK_URL:-} ]]; then
    printf '%s\n' "$RESTIC_HEALTHCHECK_URL"
    return 0
  fi
  yaml_value "$healthcheck_secret" restic-ping-url
}

# Never echo the URL: its UUID is the capability to keep the check green.
ping_url() {
  "$curl_bin" --fail --silent --show-error --max-time 20 --retry 2 \
    --retry-delay 2 "$1" >/dev/null
}

check_group() {
  local backend=$1 group=$2 repo=$3
  local state journal staging max_age expiry line result start end reason snap final_snap succ_end succ_snap n
  local jline jatt jresult jsnap
  state=$(state_file_for "$backend" "$group")
  journal=$(journal_for "$backend" "$group")
  staging=$(staging_for "$group" "$backend")
  max_age=$(max_age_for "$backend")
  expiry=$(run_expiry_for "$backend")

  if [[ ! -s $state ]]; then
    fail "$backend/$group: no status state at $state"
    return
  fi
  if [[ ! -s $journal ]]; then
    fail "$backend/$group: no attempt journal at $journal"
    return
  fi
  if ! line=$(jq -r '[.last_attempt.n // 0, .last_attempt.result // "",
        .last_attempt.start // "", .last_attempt.end // "",
        .last_attempt.reason // "", .last_attempt.snapshot // "",
        .final.snapshot // "", .last_success.end // "",
        .last_success.snapshot // ""]
        | join("\u001f")' "$state" 2>/dev/null); then
    fail "$backend/$group: unreadable status state"
    return
  fi
  # Unit separator, not a tab: IFS whitespace collapses empty fields, and an
  # empty reason would silently shift every later field.
  IFS=$'\x1f' read -r n result start end reason snap final_snap succ_end succ_snap <<<"$line"

  # The journal is the durable completion trail. A state file that claims an
  # attempt the journal never saw means the persistence step failed and the
  # run is not proven.
  jline=$(tail -n1 "$journal" 2>/dev/null) || jline=""
  [[ -n $jline ]] || jline='{}'
  jatt=$(jq -r '.attempt // 0' <<<"$jline" 2>/dev/null) || jatt=0
  jresult=$(jq -r '.result // ""' <<<"$jline" 2>/dev/null) || jresult=""
  jsnap=$(jq -r '.snapshot // ""' <<<"$jline" 2>/dev/null) || jsnap=""
  if [[ $result == running ]]; then
    if ((jatt != n - 1)); then
      fail "$backend/$group: attempt $n is running but the journal ends at attempt $jatt"
    fi
  else
    if ((jatt != n)); then
      fail "$backend/$group: attempt $n is not durably journaled (journal ends at $jatt)"
    elif [[ $jresult != "$result" || $jsnap != "$snap" ]]; then
      fail "$backend/$group: journal and state disagree for attempt $n"
    fi
  fi

  local age

  # A run that is still in flight is fine only inside its retry/deadline
  # window; a run that died without recording completion (SIGKILL, power loss)
  # leaves `running` behind and expires here.
  if [[ $result == running ]]; then
    age=$(age_seconds "$start")
    if ((age > expiry)); then
      fail "$backend/$group: run started ${start:-unknown} never completed (${age}s, window ${expiry}s)"
    fi
  elif [[ $result != success ]]; then
    fail "$backend/$group: latest attempt is ${result:-missing}${reason:+ ($reason)}${end:+ at $end}"
  fi

  if [[ $result == success ]]; then
    [[ $snap == "$final_snap" ]] ||
      fail "$backend/$group: last attempt snapshot does not match the persisted final snapshot"
    [[ $succ_snap == "$final_snap" ]] ||
      fail "$backend/$group: last success snapshot does not match the persisted final snapshot"
  fi

  if [[ -z $final_snap || -z $succ_end ]]; then
    fail "$backend/$group: no persisted successful snapshot"
    return
  fi
  age=$(age_seconds "$succ_end")
  if ((age > max_age)); then
    fail "$backend/$group: last success is ${age}s old (maximum ${max_age}s)"
  fi

  local out verdict stime
  if ! out=$(with_deadline "$(job_deadline "$backend")" "$restic_bin" -r "$repo" \
    snapshots --json --no-lock --host "$restic_host" --path "$staging" 2>/dev/null); then
    fail "$backend/$group: cannot read snapshots from $repo"
    return
  fi
  if ! verdict=$(jq -r --arg id "$final_snap" --arg g "$group" \
    --arg h "$restic_host" --arg p "$staging" '
      ([.[] | select(.id == $id)]) as $m
      | if ($m | length) != 1 then "missing"
        else ($m[0]) as $s
          | [(($s.tags // []) | index("verified") != null),
             (($s.tags // []) | index("group:" + $g) != null),
             (($s.tags // []) | index("host:" + $h) != null),
             ($s.hostname == $h),
             (($s.paths // []) == [$p]),
             ($s.time == ([.[] | .time] | max))]
          | map(if . then "1" else "0" end) | join("")
        end' <<<"$out" 2>/dev/null); then
    fail "$backend/$group: unreadable snapshot list from $repo"
    return
  fi
  if [[ $verdict == missing ]]; then
    fail "$backend/$group: recorded snapshot $final_snap is not in $repo"
    return
  fi
  if [[ $verdict != 111111 ]]; then
    fail "$backend/$group: snapshot $final_snap fails checks [tags,group,host,hostname,paths,newest]=$verdict"
  fi

  if ! stime=$(jq -r --arg id "$final_snap" '.[] | select(.id == $id) | .time' \
    <<<"$out" 2>/dev/null | head -n1); then
    fail "$backend/$group: cannot read the snapshot time"
    return
  fi
  if [[ -n $stime ]]; then
    age=$(age_seconds "$stime")
    if ((age > max_age)); then
      fail "$backend/$group: repository snapshot is ${age}s old (maximum ${max_age}s)"
    fi
  fi

  ok "$backend/$group snapshot $final_snap"
}

for backend in "${backends[@]}"; do
  if ! repo=$(repo_for "$backend" 2>/dev/null); then
    fail "$backend: repository is not configured"
    continue
  fi
  if ! load_backend_env "$backend"; then
    fail "$backend: credentials are not configured"
    continue
  fi
  for group in "${groups[@]}"; do
    check_group "$backend" "$group" "$repo"
  done
done

if ((failures)); then
  say "$failures freshness check(s) failed"
  if ((ping)); then
    if url=$(healthcheck_url 2>/dev/null); then
      # Report the failure now instead of waiting out the grace period.
      ping_url "${url%/}/fail" || warn "could not report the failure to Healthchecks"
    else
      warn "no Healthchecks ping URL is configured; nothing was reported"
    fi
  fi
  exit 1
fi

if ((ping)); then
  if ! url=$(healthcheck_url 2>/dev/null); then
    warn "no Healthchecks ping URL is configured; refusing to claim freshness"
    exit 1
  fi
  if ! ping_url "$url"; then
    warn "Healthchecks ping failed"
    exit 1
  fi
  say "pinged Healthchecks"
fi
say "all destinations are fresh"
