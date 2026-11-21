#!/usr/bin/env bash
# Hourly freshness verifier and deploy-gate query for the smortress Restic plane
# (SDLC #706, T3; the local mode is SDLC #798, T3).
#
#   smortress-restic-verify [--no-ping]
#   smortress-restic-verify --local --json
#
# The aggregate mode joins the durable attempt results under /var/lib/homelab/restic
# to what the repositories actually contain, then pings one Healthchecks.io check
# only when every destination is current. Missing state, an in-progress attempt
# past its retry window, a failed latest attempt, a snapshot that is not the
# recorded one, a missing tag, the wrong host or an unexpected source path all
# fail closed. An older successful snapshot never excuses a newer failed run: the
# latest recorded attempt is authoritative.
#
# The local mode answers the pre-reboot snapshot gate instead (deploy-platform
# `prepare`): per restore unit, per local repository, is the newest snapshot for
# this host and this unit's path set tagged `verified` and inside the max age.
# It is read-only -- no ping, no restic lock, no writes -- and it does not judge
# the plane: freshness and unusability are payload, because the caller owns the
# fallback from the SSD to the HDD. Only a query that cannot run at all (no
# durable state to join against) is an error exit.
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

# The gate's read-only probe of a repository: far shorter than a job deadline
# because it only proves the repository answers at all, and a gate that waits
# out a dead mount is a deploy that never happens.
local_probe_deadline=${RESTIC_PROBE_DEADLINE:-120}

usage() {
  cat >&2 <<'EOF'
usage: smortress-restic-verify [--no-ping]
       smortress-restic-verify --local --json

  --no-ping  evaluate and report only; never contact Healthchecks
  --local    report per restore unit, for the ssd and hdd repositories only,
             whether the newest snapshot for this host and path set is
             verified and fresh; read-only, never pings (requires --json)
  --json     print the local verdict object instead of a human report

exit: 0 the verdict was produced (freshness is in the payload), 2 usage,
      4 the query cannot run (no durable state to join against)

environment:
  RESTIC_HEALTHCHECK_URL  overrides the SOPS `restic-ping-url` value (tests)
EOF
}

mode=aggregate
want_json=0
ping=1
while (($#)); do
  case $1 in
    --no-ping) ping=0; shift ;;
    --local) mode=local; shift ;;
    --json) want_json=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done
if [[ $mode == local && $want_json == 0 ]] || [[ $mode == aggregate && $want_json == 1 ]]; then
  usage
  exit 2
fi

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

check_unit() {
  local backend=$1 unit=$2 repo=$3
  local failures_before=$failures
  local state journal max_age expiry line result start end reason snap final_snap succ_end succ_snap n
  local jline jatt jresult jsnap
  local staging_json
  state=$(state_file_for "$backend" "$unit")
  journal=$(journal_for "$backend" "$unit")
  staging_json=$(unit_paths_json "$unit" "$backend")
  max_age=$(max_age_for "$backend")
  expiry=$(run_expiry_for "$backend")

  if [[ ! -s $state ]]; then
    fail "$backend/$unit: no status state at $state"
    return
  fi
  if [[ ! -s $journal ]]; then
    fail "$backend/$unit: no attempt journal at $journal"
    return
  fi
  if ! line=$(jq -r '[.last_attempt.n // 0, .last_attempt.result // "",
        .last_attempt.start // "", .last_attempt.end // "",
        .last_attempt.reason // "", .last_attempt.snapshot // "",
        .final.snapshot // "", .last_success.end // "",
        .last_success.snapshot // ""]
        | join("\u001f")' "$state" 2>/dev/null); then
    fail "$backend/$unit: unreadable status state"
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
      fail "$backend/$unit: attempt $n is running but the journal ends at attempt $jatt"
    fi
  else
    if ((jatt != n)); then
      fail "$backend/$unit: attempt $n is not durably journaled (journal ends at $jatt)"
    elif [[ $jresult != "$result" || $jsnap != "$snap" ]]; then
      fail "$backend/$unit: journal and state disagree for attempt $n"
    fi
  fi

  local age

  # A run that is still in flight is fine only inside its retry/deadline
  # window; a run that died without recording completion (SIGKILL, power loss)
  # leaves `running` behind and expires here. A unit with no success yet is in
  # its first upload, which is bounded by the first-upload deadline and its
  # single attempt: the routine window would expire a run that is still legal.
  if [[ $result == running ]]; then
    age=$(age_seconds "$start")
    if [[ -z $succ_end ]]; then expiry=$(run_expiry_first_for "$backend"); fi
    if ((age > expiry)); then
      fail "$backend/$unit: run started ${start:-unknown} never completed (${age}s, window ${expiry}s)"
    fi
  elif [[ $result != success ]]; then
    fail "$backend/$unit: latest attempt is ${result:-missing}${reason:+ ($reason)}${end:+ at $end}"
  fi

  if [[ $result == success ]]; then
    [[ $snap == "$final_snap" ]] ||
      fail "$backend/$unit: last attempt snapshot does not match the persisted final snapshot"
    [[ $succ_snap == "$final_snap" ]] ||
      fail "$backend/$unit: last success snapshot does not match the persisted final snapshot"
  fi

  if [[ -z $final_snap || -z $succ_end ]]; then
    fail "$backend/$unit: no persisted successful snapshot"
    return
  fi
  age=$(age_seconds "$succ_end")
  if ((age > max_age)); then
    fail "$backend/$unit: last success is ${age}s old (maximum ${max_age}s)"
  fi

  local out verdict stime
  if ! out=$(with_deadline "$(job_deadline "$backend")" "$restic_bin" -r "$repo" \
    snapshots --json --no-lock --host "$restic_host" --tag "unit:$unit,verified" 2>/dev/null); then
    fail "$backend/$unit: cannot read snapshots from $repo"
    return
  fi
  if ! verdict=$(jq -r --arg id "$final_snap" --arg u "$unit" \
    --arg h "$restic_host" --argjson p "$staging_json" '
      ([.[] | select(.id == $id)]) as $m
      | if ($m | length) != 1 then "missing"
        else ($m[0]) as $s
          | [(($s.tags // []) | index("verified") != null),
             (($s.tags // []) | index("unit:" + $u) != null),
             (($s.tags // []) | index("host:" + $h) != null),
             ($s.hostname == $h),
             ((($s.paths // []) | sort) == ($p | sort)),
             ($s.time == ([.[] | .time] | max))]
          | map(if . then "1" else "0" end) | join("")
        end' <<<"$out" 2>/dev/null); then
    fail "$backend/$unit: unreadable snapshot list from $repo"
    return
  fi
  if [[ $verdict == missing ]]; then
    fail "$backend/$unit: recorded snapshot $final_snap is not in $repo"
    return
  fi
  if [[ $verdict != 111111 ]]; then
    fail "$backend/$unit: snapshot $final_snap fails checks [tags,group,host,hostname,paths,newest]=$verdict"
  fi

  if ! stime=$(jq -r --arg id "$final_snap" '.[] | select(.id == $id) | .time' \
    <<<"$out" 2>/dev/null | head -n1); then
    fail "$backend/$unit: cannot read the snapshot time"
    return
  fi
  if [[ -n $stime ]]; then
    age=$(age_seconds "$stime")
    if ((age > max_age)); then
      fail "$backend/$unit: repository snapshot is ${age}s old (maximum ${max_age}s)"
    fi
  fi

  if ((failures == failures_before)); then
    ok "$backend/$unit snapshot $final_snap"
  fi
}

# --- the deploy gate's local query -------------------------------------------
#
# One restic listing per unit, no writing, no lock. A unit's path set comes from
# the state file the backup driver wrote (that is the set it actually archived),
# and falls back to the storage table for a unit that has never run, so the
# answer is about the data a restore would need rather than about a naming
# convention.
local_paths() { # <backend> <unit>
  local file paths
  file=$(state_file_for "$1" "$2")
  if [[ -s $file ]]; then
    paths=$(jq -c '.paths // empty | select(type == "array" and length > 0)' "$file" 2>/dev/null) || paths=""
    if [[ -n $paths ]]; then
      printf '%s\n' "$paths"
      return 0
    fi
  fi
  unit_paths_json "$2" "$1"
}

local_unit_verdict() { # <backend> <unit> <repo> <paths-json> -> one object
  local backend=$1 unit=$2 repo=$3 want=$4 out newest max_age id="" time="" verified="" age reason
  max_age=$(max_age_for "$backend")
  if ! out=$(with_deadline "$(job_deadline "$backend")" "$restic_bin" -r "$repo" \
    snapshots --json --no-lock --host "$restic_host" --tag "unit:$unit" 2>/dev/null); then
    printf '{"fresh":false,"reason":"repository-unreadable"}\n'
    return 0
  fi
  # The newest matching snapshot decides: an older verified one does not excuse a
  # newer unverified run, which is the same rule the aggregate mode applies.
  newest=$(jq -r --arg h "$restic_host" --argjson p "$want" '
      [.[] | select(.hostname == $h)
           | select((((.paths // []) | sort) == ($p | sort)))]
      | sort_by(.time) | last
      | if . == null then ""
        else [.id, .time,
              (if ((.tags // []) | index("verified")) != null then "1" else "0" end)]
             | join("\u001f")
        end' <<<"$out" 2>/dev/null) || newest=""
  if [[ -n $newest ]]; then
    IFS=$'\x1f' read -r id time verified <<<"$newest"
  fi
  if [[ -z $id ]]; then
    printf '{"fresh":false,"reason":"no-snapshot"}\n'
    return 0
  fi
  if [[ $verified != 1 ]]; then
    jq -cn --arg id "$id" '{fresh:false,reason:"unverified",snapshot:$id}'
    return 0
  fi
  age=$(age_seconds "$time")
  if ((age > max_age)); then reason=stale; else reason=ok; fi
  jq -cn --argjson age "$age" --arg id "$id" --arg reason "$reason" \
    '{fresh:($reason == "ok"),reason:$reason,snapshot:$id,age:$age}'
}

# A repository the gate cannot write to is reported, never raised: with no SSD
# the HDD is the whole point of the fallback, and the caller decides what an
# unusable pair means (a hold).
local_backend_verdict() { # <backend> -> {"units":{...},"usable":bool}
  local backend=$1 repo units_doc='{}' unit obj
  if repo=$(repo_for "$backend" 2>/dev/null) &&
    load_backend_env "$backend" &&
    is_mountpoint "$restic_base/$backend" &&
    with_deadline "$local_probe_deadline" "$restic_bin" -r "$repo" cat config --no-lock >/dev/null 2>&1; then
    for unit in "${units[@]}"; do
      obj=$(local_unit_verdict "$backend" "$unit" "$repo" "$(local_paths "$backend" "$unit")")
      [[ -n $obj ]] || obj='{"fresh":false,"reason":"unreadable"}'
      units_doc=$(jq -c --arg u "$unit" --argjson o "$obj" '.[$u] = $o' <<<"$units_doc")
    done
    jq -cn --argjson u "$units_doc" '{units:$u,usable:true}'
    return 0
  fi
  for unit in "${units[@]}"; do
    units_doc=$(jq -c --arg u "$unit" \
      '.[$u] = {fresh:false,reason:"repository-unusable"}' <<<"$units_doc")
  done
  jq -cn --argjson u "$units_doc" '{units:$u,usable:false}'
}

local_report() {
  local backend doc='{}'
  for backend in ssd hdd; do
    doc=$(jq -c --arg b "$backend" --argjson r "$(local_backend_verdict "$backend")" \
      '.[$b] = $r' <<<"$doc")
  done
  printf '%s\n' "$doc"
}

# The verifier is read-only and may run where /var/cache is not writable (a
# test runner, a hand-run check as an unprivileged user). It gets its own cache
# directory unless the caller named one, so a read-only query never depends on a
# host path it does not own.
if [[ -z ${RESTIC_CACHE_DIR:-} ]]; then
  RESTIC_CACHE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/smortress-restic-cache.XXXXXX") || {
    warn "cannot create a restic cache directory"
    exit 4
  }
  export RESTIC_CACHE_DIR
  trap 'rm -rf -- "$RESTIC_CACHE_DIR"' EXIT
fi

if [[ $mode == local ]]; then
  # The state tree is the join the aggregate mode uses; without it there is
  # nothing to read the units' path sets or attempt history from, and inventing
  # an answer is how a gate would wave through a host whose plane is gone.
  [[ -d $state_root ]] || {
    warn "no Restic plane state at $state_root; cannot answer the gate"
    exit 4
  }
  local_report
  exit 0
fi

for backend in "${backends[@]}"; do
  if ! repo=$(repo_for "$backend" 2>/dev/null); then
    fail "$backend: repository is not configured"
    continue
  fi
  if ! load_backend_env "$backend"; then
    fail "$backend: credentials are not configured"
    continue
  fi
  for unit in "${units[@]}"; do
    check_unit "$backend" "$unit" "$repo"
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
