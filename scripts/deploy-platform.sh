#!/usr/bin/env bash
# Platform apply, part one: the pre-reboot snapshot gate, the hold and the
# break-glass waiver (SDLC #798, T3), and the stage that follows it (T4).
#
#   deploy-platform prepare --commit <sha> --digests <json>
#   deploy-platform stage   --commit <sha> --digests <json>
#
# A platform deploy reboots the host, so every restore unit needs a verified
# local snapshot before that reboot: a unit without one is backed up once,
# directly, and a unit that no local repository can take holds the deploy
# instead of rebooting without it. The SSD is preferred and the HDD is the
# fallback, because the 970 can be absent while the machine is still deployable.
#
# `prepare` stages nothing, writes no `pending.json` and never reboots; the
# gate's outcome is a journal line (`gate-green`, `gate-released`,
# `deploy-held`), so a staged deploy and a green gate stay separate records.
#
# `stage` is the second half and only ever follows a `prepare` that exited 0:
# `bootc switch --enforce-container-sigpolicy` to the tracked tag (stage only,
# never `--apply`, so nothing reboots behind the gate's back), the `bootc status`
# read-back that proves the staged digest is one of the forms the verifier
# resolved -- a tag that moved between resolution and switch is refused, not
# rebooted into -- `pending.json`, and the reboot. A host that already runs the
# verified image records the deployment and exits 6 with no reboot. It deliberately does not live inside
# `prepare`, so a gate that ran twice cannot stage twice, and it takes no deploy
# lock: the drain that calls it already holds one.
#
# Exit codes: 0 the gate is green, or a released hold covers this digest (prepare),
# or the deployment is staged and the reboot requested (stage);
# 2 usage; 4 the gate could not run and nothing was recorded (the caller keeps
# the request queued), or `bootc switch` / the reboot failed;
# 5 the deploy is held until an operator releases it (prepare), or the staged
# digest is not the verified one (stage -- nothing is staged, nothing reboots).
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
  printf 'deploy-platform: no state library at %s\n' "$state_lib" >&2
  exit 1
}
# shellcheck source=/dev/null
source "$state_lib"

# The gate's two helpers are the plane's, installed by the same loop and resolved
# by the state library's one `resolve_tool`.
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
       deploy-platform stage   --commit <40-hex> --digests <json>

  --commit   the commit the deploy was verified for
  --digests  {"index": "<sha256:...>", "manifest": "<sha256:...>"} as the
             verifier resolved them; the index form names the release and the
             manifest form is what bootc switches to
EOF
}

# Both arms take the same pair, and both refuse a pair they cannot trust.
check_commit_digests() { # <commit> <digests-json>
  [[ $1 =~ ^[0-9a-f]{40}$ ]] || {
    warn "--commit must be a 40-character lowercase hex sha"
    return 2
  }
  # Both forms are required: the release names the index digest, and the boot
  # gate has to accept whichever form bootc reports for the staged image.
  jq -e '(.index | type == "string" and test("^sha256:[0-9a-f]{64}$"))
         and (.manifest | type == "string" and test("^sha256:[0-9a-f]{64}$"))' \
    <<<"$2" >/dev/null 2>&1 || {
    warn "--digests must carry the index and manifest digests"
    return 2
  }
}

# The bounds of a stage: one switch and one status read, each on its own clock,
# plus the reboot. The switch is the only call in this script that pulls an
# image, so it gets the design's 3600 s; nothing here runs under the snapshot
# gate's budget, which is a different clock entirely.
switch_timeout=$(clamp_timeout "${DEPLOY_SWITCH_TIMEOUT:-3600}")
stage_status_timeout=$(clamp_timeout "${DEPLOY_STAGE_STATUS_TIMEOUT:-60}")
stage_reboot_timeout=$(clamp_timeout "${DEPLOY_STAGE_REBOOT_TIMEOUT:-60}")
bootc_bin=${BOOTC_BIN:-bootc}
stage_systemctl=${SYSTEMCTL_BIN:-systemctl}
image_repo=${DEPLOY_IMAGE_REPO:-ghcr.io/smores56/homelab-platform/server}
# The reference the host tracks. A tag keeps `bootc upgrade` usable; the stage
# still refuses a tag that does not resolve to the verified digest.
image_tag=${DEPLOY_IMAGE_TAG:-latest}

budget_left() {
  local left=$((gate_deadline - $(date -u +%s)))
  ((left > 0)) || left=0
  printf '%s\n' "$left"
}

# Every child gets the smaller of its own bound and what is left of the gate's:
# without that, one 1800 s backup at the end of a budget overruns it. Both numbers
# pass through clamp_timeout, because `timeout 0` is not a one-second bound -- it
# is no bound at all, which is exactly what an exhausted budget must not grant.
bounded() { # <cap> <command...>
  local cap left
  cap=$(clamp_timeout "$1")
  shift
  left=$(budget_left)
  if ((left < cap)); then cap=$left; fi
  timeout --signal=TERM --kill-after=60 "$(clamp_timeout "$cap")" "$@"
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
  check_commit_digests "$commit" "$digests" || return 2
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

# restore_staged_deployment: put the boot entry back on the digest the state says
# is running, and prove bootc staged it.
#
# A refused stage has already written a BLS entry: refusing it and returning would
# leave the next boot rolling into an image nobody verified. The other deployment
# is the one the state recorded, and the read-back is what makes "restored" a fact
# rather than an exit code.
restore_staged_deployment() {
  local doc index manifest target staged rc=0
  doc=$(state_read 2>/dev/null) || return 1
  index=$(jq -r '.repos["homelab-platform"].indexDigest // ""' <<<"$doc" 2>/dev/null) || index=""
  manifest=$(jq -r '.repos["homelab-platform"].manifestDigest // ""' <<<"$doc" 2>/dev/null) ||
    manifest=""
  # The manifest form is what a switch can name; the index form is the fallback
  # for a state written before both were recorded.
  target=${manifest:-$index}
  [[ -n $target ]] || {
    warn "the state records no deployed digest; nothing to switch back to"
    return 1
  }
  timeout --signal=TERM --kill-after=60 "$switch_timeout" "$bootc_bin" switch \
    --enforce-container-sigpolicy "$image_repo@$target" || rc=$?
  if ((rc != 0)); then
    warn "switching back to $target failed (exit $rc)"
    return 1
  fi
  staged=$(timeout --signal=TERM --kill-after=10 "$stage_status_timeout" \
    "$bootc_bin" status --json 2>/dev/null |
    jq -er '.status.staged.image.imageDigest // empty' 2>/dev/null) || staged=''
  if [[ -z $staged || ($staged != "$index" && $staged != "$manifest") ]]; then
    return 1
  fi
  say "restored the staged entry to $staged"
  return 0
}

# stage: switch, prove what bootc staged, record it, reboot.
#
# `switch` and not `upgrade`: `--enforce-container-sigpolicy` exists only on
# switch/install, and a digest-pinned host never moves on upgrade. There is no
# `--apply` here on purpose -- the reboot is the deploy, and it happens only after
# `pending.json` exists, so a crash between the two leaves the boot gate a record
# to judge instead of an unrecorded new deployment.
# The booted image, for the "already running" decision. Not the gate's helper:
# this script is also run by hand, where the gate's state is not its business.
booted_digest() {
  local doc
  doc=$(timeout --signal=TERM --kill-after=10 "$(clamp_timeout "$stage_status_timeout")" \
    "$bootc_bin" status --booted --json 2>/dev/null) || return 1
  jq -er '.status.booted.image.imageDigest // empty' <<<"$doc" 2>/dev/null
}

# booted_matches <index> <manifest>: the verified image is what this host is
# already running. Both forms are accepted for the same reason the staged check
# accepts both: bootc reports one or the other.
booted_matches() {
  local index=$1 manifest=$2 booted
  booted=$(booted_digest 2>/dev/null) || return 1
  [[ -n $booted ]] || return 1
  [[ $booted == "$index" || $booted == "$manifest" ]]
}

cmd_stage() {
  local commit='' digests='' index='' manifest='' staged='' rc=0
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
  check_commit_digests "$commit" "$digests" || return 2
  index=$(jq -r '.index' <<<"$digests")
  # The switch names the platform manifest digest, which is the image a host
  # actually boots; the index digest is what the release and the denylist name.
  manifest=$(jq -r '.manifest' <<<"$digests")

  deploy_state_init || {
    warn "cannot create $deploy_state_dir"
    return 4
  }
  journal_append stage-start "$(jq -nc --arg commit "$commit" --arg digest "$index" \
    --arg manifest "$manifest" \
    '{commit:$commit,digest:$digest,manifest:$manifest}')" || {
    warn "cannot journal the stage start"
    return 4
  }

  # Already running the verified image: a manual `bootc upgrade` (or a deploy
  # that repeats itself) leaves bootc with nothing to stage, and "no staged
  # entry" is not a refusal when the booted image *is* the verified one. Record
  # the deployment instead so the state stops naming an older commit.
  if booted_matches "$index" "$manifest"; then
    state_record_verified homelab-platform "$commit" "$index" "$manifest" || {
      warn "cannot record the already-booted image"
      return 4
    }
    record_clear held || warn "cannot clear the satisfied hold record"
    journal_append stage-already-booted "$(jq -nc --arg commit "$commit" --arg digest "$index" \
      '{commit:$commit,digest:$digest}')" || warn "cannot journal the already-booted image"
    say "already running $commit; recorded without a reboot"
    return 6
  fi

  # The host tracks the tag, so `bootc upgrade` and a hand-run switch both work
  # later. The digest is still what was verified and what the denylist and the
  # boot gate name: the read-back below refuses a tag that moved between the
  # resolution and this switch.
  timeout --signal=TERM --kill-after=60 "$switch_timeout" "$bootc_bin" switch \
    --enforce-container-sigpolicy "$image_repo:$image_tag" || rc=$?
  if ((rc != 0)); then
    journal_append stage-failed "$(jq -nc --arg commit "$commit" --arg manifest "$manifest" \
      --argjson exit "$rc" '{commit:$commit,manifest:$manifest,exit:$exit}')" ||
      warn "cannot journal the failed switch"
    warn "bootc switch $image_repo:$image_tag failed (exit $rc); nothing was staged"
    deploy_notify fail stage-failed || warn "could not report the failed stage"
    return 4
  fi

  # What bootc staged is the only thing the boot gate can compare a boot to, so
  # a staged entry that is not one of the digests the verifier resolved means the
  # deploy would reboot into an image nobody checked. Nothing is recorded.
  staged=$(timeout --signal=TERM --kill-after=10 "$stage_status_timeout" \
    "$bootc_bin" status --json 2>/dev/null |
    jq -er '.status.staged.image.imageDigest // empty' 2>/dev/null) || staged=''
  if [[ -z $staged || ($staged != "$index" && $staged != "$manifest") ]]; then
    journal_append stage-digest-mismatch "$(jq -nc --arg commit "$commit" --arg staged "$staged" \
      --arg digest "$index" --arg manifest "$manifest" \
      '{commit:$commit,staged:$staged,digest:$digest,manifest:$manifest}')" ||
      warn "cannot journal the staged digest mismatch"
    warn "bootc staged '${staged:-nothing}', not $index or $manifest; not rebooting"
    deploy_notify fail stage-digest-mismatch || warn "could not report the staged digest mismatch"
    if restore_staged_deployment; then
      journal_append stage-restored "$(jq -nc --arg commit "$commit" --arg digest "$index" \
        --arg from "${staged:-}" \
        '{commit:$commit,digest:$digest,from:$from}')" ||
        warn "cannot journal the restored stage"
    else
      # The host is one switch, or one reboot, away from an image nothing
      # verified: the refusal has to reach the operator, not just the journal.
      journal_append stage-restore-failed "$(jq -nc --arg commit "$commit" --arg digest "$index" \
        --arg staged "${staged:-}" \
        '{commit:$commit,digest:$digest,staged:$staged}')" ||
        warn "cannot journal the failed restore"
      warn "the staged entry is still not the deployed deployment"
      deploy_notify fail stage-restore-failed || warn "could not report the failed restore"
    fi
    return 5
  fi

  # No boot budget here: the counter is the GRUB snippet's and the gate resets it
  # on every boot it reaches, so a number in this record would be a second, unused
  # source of truth about the same three attempts.
  jq -nc --arg commit "$commit" --arg digest "$index" --arg manifest "$manifest" \
    --argjson digests "$digests" --arg at "$(deploy_now)" \
    '{schema:1,phase:"staged",commit:$commit,digest:$digest,digests:$digests,
      stagedAt:$at}' | pending_write || {
    journal_append stage-pending-failed "$(jq -nc --arg commit "$commit" \
      --arg manifest "$manifest" '{commit:$commit,manifest:$manifest}')" ||
      warn "cannot journal the failed pending record"
    warn "cannot write the pending record; not rebooting"
    return 4
  }
  journal_append stage-pending "$(jq -nc --arg commit "$commit" --arg digest "$index" \
    --arg manifest "$manifest" --arg staged "$staged" \
    '{commit:$commit,digest:$digest,manifest:$manifest,staged:$staged}')" ||
    warn "cannot journal the pending record"

  # A released hold is not cleared here: it is cleared by the boot gate that sees
  # this deployment actually run, so a release cannot outlive a failed boot.
  say "staged $staged for $commit; rebooting"
  rc=0
  timeout --signal=TERM --kill-after=15 "$stage_reboot_timeout" "$stage_systemctl" reboot || rc=$?
  if ((rc != 0)); then
    journal_append stage-reboot-failed "$(jq -nc --argjson exit "$rc" '{exit:$exit}')" ||
      warn "cannot journal the failed reboot"
    warn "systemctl reboot failed (exit $rc); the pending record stays for the next boot"
    deploy_notify fail stage-reboot-failed || warn "could not report the failed reboot"
    return 4
  fi
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
  stage)
    shift
    rc=0
    cmd_stage "$@" || rc=$?
    exit "$rc"
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    usage
    exit 2
    ;;
esac
