#!/usr/bin/env bash
# Platform apply, part one: the pre-reboot snapshot gate, the hold and the
# break-glass waiver (SDLC #798, T3).
#
#   deploy-platform prepare --commit <sha> --digests <json>
#
# A platform deploy reboots the host, so every restore unit needs a verified
# local snapshot before that reboot: a unit without one is backed up once,
# directly, and a unit that no local repository can take holds the deploy
# instead of rebooting without it. The SSD is preferred and the HDD is the
# fallback, because the 970 can be absent while the machine is still deployable.
#
# `prepare` stages nothing, writes no `pending.json` and never reboots. Staging,
# the `bootc status` check and the reboot are T4 (#802) and attach as the `stage`
# arm of this script; the gate's outcome is a journal line (`gate-green`,
# `gate-released`, `deploy-held`), so a staged deploy and a green gate stay
# separate records.
#
# Exit codes: 0 the gate is green, or a released hold covers this digest;
# 2 usage; 4 the gate could not run and nothing was recorded (the caller keeps
# the request queued); 5 the deploy is held until an operator releases it.
#
# Every knob is environment-overridable so tests/deploy/platform.sh can drive
# this exact code. Production sets none of them: the defaults are the host
# contract, not a way to skip a check.
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
  printf 'deploy-platform: no state library at %s\n' "$state_lib" >&2
  exit 1
}
# shellcheck source=/dev/null
source "$state_lib"

# The gate's two helpers are the plane's, installed by the same loop. $PATH is
# consulted first so a test can put a stand-in in front of them without touching
# /usr/libexec; root's PATH does not contain /usr/libexec, so on the host the
# installed name wins.
resolve_tool() { # <env override> <installed name> <checkout file>
  local override=${1:-} name=$2 sibling=$3 found
  if [[ -n $override ]]; then
    printf '%s\n' "$override"
    return 0
  fi
  if found=$(command -v "$name" 2>/dev/null); then
    printf '%s\n' "$found"
    return 0
  fi
  if [[ -x /usr/libexec/$name ]]; then
    printf '%s\n' "/usr/libexec/$name"
    return 0
  fi
  printf '%s\n' "$sibling"
}

verify_bin=$(resolve_tool "${DEPLOY_GATE_VERIFY_BIN:-}" smortress-restic-verify \
  "$self_dir/smortress-restic-verify.sh")
backup_bin=$(resolve_tool "${DEPLOY_BACKUP_BIN:-}" smortress-restic-backup \
  "$self_dir/smortress-restic-backup.sh")

# The restore units are the storage table's, not the verifier payload's: a
# payload that reported no units would otherwise gate nothing and pass.
layout=${STORAGE_LAYOUT:-}
if [[ -z $layout ]]; then
  if [[ -r /usr/libexec/storage-layout ]]; then
    layout=/usr/libexec/storage-layout
  else
    layout=$self_dir/storage-layout.sh
  fi
fi
[[ -r $layout ]] || {
  printf 'deploy-platform: no storage layout at %s\n' "$layout" >&2
  exit 1
}
# shellcheck source=/dev/null
source "$layout"

# The gate's own budget, and the bounds inside it. A backup is capped at 1800 s
# and waits at most 900 s for a unit lock the hourly driver holds; maintenance is
# never run from here, because a gate that waited for a prune would hold every
# deploy behind it for hours.
gate_budget=${DEPLOY_GATE_BUDGET:-3600}
gate_verify_timeout=${DEPLOY_GATE_VERIFY_TIMEOUT:-900}
gate_backup_timeout=${DEPLOY_GATE_BACKUP_TIMEOUT:-1800}
gate_lock_wait=${DEPLOY_GATE_LOCK_WAIT:-900}
gate_deadline=0

say() { printf 'deploy-platform: %s\n' "$*"; }
warn() { printf 'deploy-platform: %s\n' "$*" >&2; }

usage() {
  cat >&2 <<'EOF'
usage: deploy-platform prepare --commit <40-hex> --digests <json>

  --commit   the commit the deploy was verified for
  --digests  {"index": "<sha256:...>", "manifest": "<sha256:...>"} as the
             verifier resolved them; the index form names the release
EOF
}

budget_left() {
  local left=$((gate_deadline - $(date -u +%s)))
  ((left > 0)) || left=0
  printf '%s\n' "$left"
}

# Every child gets the smaller of its own bound and what is left of the gate's:
# without that, one 1800 s backup at the end of a budget overruns it.
bounded() { # <cap> <command...>
  local cap=$1 left
  shift
  left=$(budget_left)
  if ((left < cap)); then cap=$left; fi
  timeout --signal=TERM --kill-after=60 "$cap" "$@"
}

gate_query() { bounded "$gate_verify_timeout" "$verify_bin" --local --json; }

gate_backup() { # <backend> <unit>
  RESTIC_LOCK_WAIT=$gate_lock_wait bounded "$gate_backup_timeout" \
    "$backup_bin" "$backend" --unit "$unit" --no-maintenance
}

# A unit is satisfied by a fresh SSD snapshot, else a fresh HDD one: the SSD is
# the machine that is always present, the HDD is the copy that survives it.
fresh_on() { # <doc> <unit> -> backend
  local doc=$1 unit=$2
  if [[ $(jq -r --arg u "$unit" '.ssd.usable and (.ssd.units[$u].fresh // false)' <<<"$doc") == true ]]; then
    printf 'ssd\n'
    return 0
  fi
  if [[ $(jq -r --arg u "$unit" '.hdd.usable and (.hdd.units[$u].fresh // false)' <<<"$doc") == true ]]; then
    printf 'hdd\n'
    return 0
  fi
  return 1
}

usable_backends() { # <doc> -> every backend a backup can be written to, in order
  local doc=$1 backend
  for backend in ssd hdd; do
    if [[ $(jq -r --arg b "$backend" '.[$b].usable // false' <<<"$doc") == true ]]; then
      printf '%s\n' "$backend"
    fi
  done
  return 0
}

missing_units() { # <doc> -> one unit per line
  local doc=$1 unit
  for unit in "${units[@]}"; do
    fresh_on "$doc" "$unit" >/dev/null || printf '%s\n' "$unit"
  done
}

backends_json() { # <doc> -> {"<unit>": "<backend>"} for every satisfied unit
  local doc=$1 out='{}' unit backend
  for unit in "${units[@]}"; do
    backend=$(fresh_on "$doc" "$unit") || continue
    out=$(jq -c --arg u "$unit" --arg b "$backend" '.[$u] = $b' <<<"$out")
  done
  printf '%s\n' "$out"
}

# hold <reason> <doc> [<unit>...]: record, journal, page, and stop this deploy.
#
# Units named after the document are satisfied by now (a backup that succeeded
# before the budget ran out), so they are not listed: the record is what the
# operator reads to decide whether to release, and over-reporting missing data
# pushes them towards a waiver they do not need.
#
# Journaled before the file is written, like every other record here: a crash
# between the two leaves the journal as the truth about why the host did not
# reboot. The page is best effort -- a hold the operator cannot release is worse
# than a hold nobody was told about, and `status` always reports it.
hold() { # <reason> <doc> [<unit>...]
  local reason=$1 doc=$2 satisfied missing
  shift 2
  satisfied=$(jq -nc --args '$ARGS.positional' -- "$@")
  missing=$(missing_units "$doc" | jq -R . | jq -sc --argjson s "$satisfied" '. - $s')
  journal_append deploy-held "$(jq -nc --arg reason "$reason" --arg commit "$commit" \
    --arg digest "$digest" --argjson missing "$missing" \
    '{reason:$reason,commit:$commit,digest:$digest,missingUnits:$missing}')" ||
    warn "cannot journal the hold"
  jq -nc --arg digest "$digest" --arg commit "$commit" --arg reason "$reason" \
    --argjson digests "$digests" --argjson missing "$missing" --arg at "$(deploy_now)" \
    '{schema:1,digest:$digest,commit:$commit,digests:$digests,missingUnits:$missing,
      reason:$reason,heldAt:$at,released:false}' | held_write || return 1
  say "held ($reason): $(jq -r 'join(", ")' <<<"$missing")"
  deploy_notify fail "snapshot-gate-$reason" || warn "could not report the hold to the deploy check"
  return 0
}

cmd_prepare() {
  local commit='' digests='' digest='' held_doc='' doc='' reason='' unit='' backend='' attempt_rc=0
  local -a missing=() candidates=() backed_up=()
  local exhausted=0 rc=0

  while (($#)); do
    case $1 in
      --commit)
        commit=${2-}
        shift 2
        ;;
      --digests)
        digests=${2-}
        shift 2
        ;;
      *) usage; return 2 ;;
    esac
  done
  [[ $commit =~ ^[0-9a-f]{40}$ ]] || {
    warn "--commit must be a 40-character lowercase hex sha"
    return 2
  }
  # Both forms are required: the release names the index digest, and the boot
  # gate has to accept whichever form bootc reports for the staged image.
  jq -e '(.index | type == "string" and test("^sha256:[0-9a-f]{64}$"))
         and (.manifest | type == "string" and test("^sha256:[0-9a-f]{64}$"))' \
    <<<"$digests" >/dev/null 2>&1 || {
    warn "--digests must carry the index and manifest digests"
    return 2
  }
  digest=$(jq -r '.index' <<<"$digests")

  deploy_state_init || {
    warn "cannot create $deploy_state_dir"
    return 4
  }

  # Break-glass: a release waives the gate for the digest the operator saw held,
  # and for nothing else. Reusing it for a later image would silently ship an
  # image nobody looked at.
  if held_doc=$(held_read 2>/dev/null) &&
    [[ $(jq -r --arg d "$digest" '.released == true and .digest == $d' <<<"$held_doc" 2>/dev/null) == true ]]; then
    journal_append gate-released "$(jq -nc --arg commit "$commit" --arg digest "$digest" \
      --arg by "$(jq -r '.releasedBy // ""' <<<"$held_doc")" \
      '{commit:$commit,digest:$digest,releasedBy:$by}')" || {
      warn "cannot journal the released hold"
      return 4
    }
    say "$digest was released by the operator: the snapshot gate is waived"
    return 0
  fi

  gate_deadline=$(($(date -u +%s) + gate_budget))
  journal_append gate-start "$(jq -nc --arg commit "$commit" --arg digest "$digest" \
    '{commit:$commit,digest:$digest}')" || {
    warn "cannot journal the gate start"
    return 4
  }

  doc=$(gate_query) || rc=$?
  if ((rc != 0)) || ! jq -e '.ssd.units and .hdd.units' <<<"$doc" >/dev/null 2>&1; then
    # No payload is not a verdict about the host's snapshots: nothing is
    # recorded and the caller retries, which is the opposite of a hold.
    reason=query-failed
    if ((rc == 0)); then reason=malformed-verdict; fi
    journal_append gate-infra-failure "$(jq -nc --arg commit "$commit" --arg digest "$digest" \
      --arg reason "$reason" --argjson exit "$rc" \
      '{commit:$commit,digest:$digest,reason:$reason,exit:$exit}')" ||
      warn "cannot journal the gate failure"
    warn "the local snapshot query could not run ($reason)"
    return 4
  fi

  mapfile -t missing < <(missing_units "$doc")
  if ((${#missing[@]})); then
    mapfile -t candidates < <(usable_backends "$doc")
    if ((${#candidates[@]} == 0)); then
      hold no-usable-repository "$doc" || return 4
      return 5
    fi
    for unit in "${missing[@]}"; do
      if (($(budget_left) <= 0)); then
        exhausted=1
        break
      fi
      say "$unit: no fresh local snapshot; backing it up"
      for backend in "${candidates[@]}"; do
        attempt_rc=0
        gate_backup "$backend" "$unit" || attempt_rc=$?
        journal_append gate-backup "$(jq -nc --arg unit "$unit" --arg backend "$backend" \
          --argjson exit "$attempt_rc" '{unit:$unit,backend:$backend,exit:$exit}')" ||
          warn "cannot journal the backup of $unit"
        if ((attempt_rc == 0)); then
          backed_up+=("$unit")
          break
        fi
        if (($(budget_left) <= 0)); then
          exhausted=1
          break
        fi
        warn "$unit: backup on $backend failed (exit $attempt_rc)"
      done
      if ((exhausted)); then break; fi
    done

    if ((exhausted)) || (($(budget_left) <= 0)); then
      hold budget-exhausted "$doc" "${backed_up[@]}" || return 4
      return 5
    fi

    # Re-verify: only what the repositories now say is green. A backup that
    # reported success but left nothing tagged `verified` is exactly the case a
    # second look catches.
    rc=0
    doc=$(gate_query) || rc=$?
    if ((rc != 0)) || ! jq -e '.ssd.units and .hdd.units' <<<"$doc" >/dev/null 2>&1; then
      reason=query-failed
      if ((rc == 0)); then reason=malformed-verdict; fi
      journal_append gate-infra-failure "$(jq -nc --arg commit "$commit" --arg digest "$digest" \
        --arg reason "$reason" --argjson exit "$rc" \
        '{commit:$commit,digest:$digest,reason:$reason,exit:$exit}')" ||
        warn "cannot journal the gate failure"
      warn "the local snapshot query could not run after the backups ($reason)"
      return 4
    fi
    mapfile -t missing < <(missing_units "$doc")
    if ((${#missing[@]})); then
      hold snapshot-not-fresh "$doc" || return 4
      return 5
    fi
  fi

  journal_append gate-green "$(jq -nc --arg commit "$commit" --arg digest "$digest" \
    --argjson units "$(backends_json "$doc")" \
    '{commit:$commit,digest:$digest,units:$units}')" || {
    warn "cannot journal the green gate"
    return 4
  }
  # A hold on this digest that the gate has now satisfied is history, not state:
  # leaving it would have `status` report a held deploy that is no longer held.
  # A hold for another digest is that deploy's, and is left alone.
  if held_doc=$(held_read 2>/dev/null) &&
    [[ $(jq -r --arg d "$digest" '.digest == $d' <<<"$held_doc" 2>/dev/null) == true ]]; then
    record_clear held || warn "cannot clear the satisfied hold record"
  fi
  say "snapshot gate green for $digest"
  return 0
}

cmd=${1-}
case $cmd in
  prepare)
    shift
    rc=0
    cmd_prepare "$@" || rc=$?
    exit "$rc"
    ;;
  # T4 (#802) adds `stage --commit <sha> --digests <json>` here: `bootc switch`,
  # the `bootc status --json` digest check, `pending.json` and the reboot. It
  # deliberately does not live inside `prepare`, so a gate that ran twice cannot
  # stage twice.
  -h | --help)
    usage
    exit 0
    ;;
  *)
    usage
    exit 2
    ;;
esac
