#!/usr/bin/env bash
# Run every due Restic backup job for one backend (SDLC #706, T3).
#
#   smortress-restic-backup ssd|hdd|r2 [--unit <name>]... [--no-maintenance]
#
# One invocation is a driver: it runs every unit for that backend, records each
# result independently, and only then reports an aggregate failure. A failed
# unit never stops the next one, and a destination with no usable credentials
# records failures instead of disappearing.
#
# A unit is a restore unit from the storage table: every dataset it restores is
# snapshotted as <dataset>@<backend> and all of their snapshot paths go into one
# Restic snapshot, so raw data and the state it needs share a point in time.
# After the lock is taken, creation reconciles *only* this job's own staging
# snapshots; nothing here destroys a snapshot it did not create.
# shellcheck disable=SC2154  # variables and helpers come from restic-plane-common
# shellcheck disable=SC2016  # jq programs are single-quoted on purpose: jq expands $name, not the shell
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
usage: smortress-restic-backup <ssd|hdd|r2> [--unit <name>]... [--no-maintenance]

  --unit            run only this restore unit; repeatable
  --no-maintenance  skip forget/prune/check (tests and manual single jobs)

environment (defaults are the host contract):
  RESTIC_DEADLINE_LOCAL, RESTIC_DEADLINE_R2, RESTIC_ATTEMPTS,
  RESTIC_RETRY_SLEEP_LOCAL, RESTIC_RETRY_SLEEP_R2, RESTIC_LOCK_WAIT
EOF
}

backend=${1-}
[[ -n $backend ]] || { usage; exit 2; }
shift
case $backend in ssd | hdd | r2) ;; *) usage; exit 2 ;; esac

unit_filter=()
maintenance=1
while (($#)); do
  case $1 in
    --unit)
      [[ -n ${2-} ]] || { usage; exit 2; }
      unit_filter+=("$2")
      shift 2
      ;;
    --no-maintenance) maintenance=0; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done
for u in "${unit_filter[@]}"; do
  printf '%s\n' "${units[@]}" | grep -qx -- "$u" || { warn "unknown unit: $u"; exit 2; }
done

state=""
journal=""
lock=""
staging_paths=()
staging_snapshots=()
staging_created=()
repo=""
attempt_log=""
attempt_err=""
paths_json="[]"
attempt_start=""
deadline=$(job_deadline "$backend")
sleep_time=$(job_retry_sleep "$backend")

cleanup_staging() {
  local snapshot
  for snapshot in "${staging_created[@]}"; do
    with_deadline 120 "$zfs_bin" destroy "$snapshot" >/dev/null 2>&1 || true
  done
  staging_created=()
}

# Best effort by contract: a SIGKILL or power loss leaves the snapshot behind,
# and the next invocation's reconciliation removes it by name.
on_signal() {
  warn "$backend/${unit:-?}: terminated, cleaning up staging snapshots"
  cleanup_staging
  exit 143
}
trap on_signal TERM INT HUP

finish_attempt() {
  local result=$1 exitcode=$2 reason=$3 snapshot=$4
  local end n line
  end=$(now_iso)
  n=$(jq -r '.last_attempt.n // 0' "$state" 2>/dev/null) || return 1
  state_write "$state" '
      .last_attempt.end = $end
    | .last_attempt.exit = $exit
    | .last_attempt.result = $result
    | .last_attempt.reason = $reason
    | .last_attempt.snapshot = (if $snap == "" then null else $snap end)
    | (if ($result == "failure" and $snap != "") then
         .pending_reap = ((.pending_reap + [$snap]) | unique)
       else . end)' \
    --arg end "$end" --argjson exit "$exitcode" --arg result "$result" \
    --arg reason "$reason" --arg snap "$snapshot" || return 1

  line=$(jq -cn --argjson n "$n" --argjson exit "$exitcode" \
    --arg result "$result" --arg reason "$reason" --arg snap "$snapshot" \
    --arg start "${attempt_start:-}" --arg end "$end" \
    --arg backend "$backend" --arg unit "$unit" \
    --arg host "$restic_host" --arg repo "$repo" --argjson paths "$paths_json" '
    {schema: 2, attempt: $n, result: $result, exit: $exit, reason: $reason,
     snapshot: (if $snap == "" then null else $snap end),
     start: $start, end: $end,
     backend: $backend, unit: $unit, host: $host, repository: $repo,
     paths: $paths}') || return 1
  journal_append "$journal" "$line" || return 1

  if [[ $result == success ]]; then
    state_write "$state" \
      '.last_success = {end: $end, snapshot: $snap} | .final = {end: $end, snapshot: $snap}' \
      --arg end "$end" --arg snap "$snapshot" || return 1
  fi
  return 0
}

fail_attempt() {
  local reason=$1 exitcode=${2:-0} snapshot=${3:-}
  warn "$backend/$unit: attempt failed: $reason${snapshot:+ (snapshot $snapshot)}"
  finish_attempt failure "$exitcode" "$reason" "$snapshot" ||
    warn "$backend/$unit: could not persist the failure record"
  cleanup_staging
  if [[ -n ${attempt_log:-} ]]; then
    rm -f "$attempt_log"
    attempt_log=""
  fi
  if [[ -n ${attempt_err:-} ]]; then
    rm -f "$attempt_err"
    attempt_err=""
  fi
  return 0
}

# Reap only snapshots whose IDs this job recorded: an untagged snapshot is not
# automatically a failure (a good one is untagged between backup and tag), so a
# bulk "delete everything unverified" is exactly the wrong move.
reap_pending() {
  local ids id list
  ids=$(jq -r '.pending_reap[]?' "$state" 2>/dev/null) || return 0
  [[ -n $ids ]] || return 0
  list=$(with_deadline "$deadline" "$restic_bin" -r "$repo" snapshots --json --no-lock \
    --host "$restic_host" --tag "unit:$unit" 2>/dev/null) || return 0
  while IFS= read -r id; do
    [[ -n $id ]] || continue
    if jq -e --arg id "$id" 'any(.[]; .id == $id)' >/dev/null 2>&1 <<<"$list"; then
      if ! restic_with_lock "$deadline" "$repo" forget "$id" >/dev/null 2>&1; then
        continue
      fi
      say "$backend/$unit: reaped recorded failed snapshot $id"
    fi
    state_write "$state" '.pending_reap -= [$id]' --arg id "$id" || return 0
  done <<<"$ids"
}

attempt_locked() {
  local rc=0 sid="" reason=""
  attempt_log=$(mktemp) || {
    warn "$backend/$unit: cannot create a scratch file"
    return 1
  }
  attempt_err=$(mktemp) || {
    warn "$backend/$unit: cannot create a scratch error file"
    rm -f "$attempt_log"
    attempt_log=""
    return 1
  }
  local key dataset mountpoint snapshot path
  staging_paths=()
  staging_snapshots=()
  staging_created=()
  for key in $(unit_keys "$unit"); do
    dataset=$(dataset_name "$key")
    mountpoint=$(mountpoint_for "$key")
    # Readiness is the dataset, not the directory: zfs-ready checks the exact
    # mountinfo entry, so an empty root-filesystem path cannot pass.
    if ! "$zfs_ready_bin" "$(readiness_instance "$key")" >/dev/null 2>&1; then
      fail_attempt readiness
      return 1
    fi
    if [[ ! -d $mountpoint/.zfs/snapshot ]]; then
      fail_attempt snapshot-path-missing
      return 1
    fi
    staging_paths+=("$mountpoint/.zfs/snapshot/$backend")
    staging_snapshots+=("$dataset@$backend")
  done
  paths_json=$(jq -cn --args '$ARGS.positional' -- "${staging_paths[@]}")
  if [[ $backend != r2 ]] && ! is_mountpoint "$restic_base/$backend"; then
    fail_attempt repo-not-mounted
    return 1
  fi

  reap_pending || true

  for snapshot in "${staging_snapshots[@]}"; do
    if with_deadline 120 "$zfs_bin" list -H -o name -t snapshot "$snapshot" >/dev/null 2>&1; then
      if ! with_deadline 120 "$zfs_bin" destroy "$snapshot" >/dev/null 2>&1; then
        fail_attempt snapshot-reconcile
        return 1
      fi
      say "$backend/$unit: reconciled a stale staging snapshot $snapshot"
    fi
  done

  for snapshot in "${staging_snapshots[@]}"; do
    if ! with_deadline "$deadline" "$zfs_bin" snapshot "$snapshot" >/dev/null 2>&1; then
      fail_attempt snapshot-create
      return 1
    fi
    staging_created+=("$snapshot")
  done

  # .zfs/snapshot entries are automounted on first lookup. Without touching each
  # one here, restic stats the path before the mount exists and --one-file-system
  # prunes the whole tree as cross-device, recording an empty backup.
  for path in "${staging_paths[@]}"; do
    if ! with_deadline 60 ls -A "$path" >/dev/null 2>&1; then
      fail_attempt snapshot-create
      return 1
    fi
  done

  if restic_with_lock "$deadline" "$repo" backup \
    --host "$restic_host" --tag "unit:$unit" --tag "host:$restic_host" \
    --one-file-system --json "${staging_paths[@]}" >"$attempt_log" 2>"$attempt_err"; then
    rc=0
  else
    rc=$?
  fi
  sid=$(jq -r 'select(.message_type == "summary") | .snapshot_id // empty' \
    "$attempt_log" 2>/dev/null | tail -n1)

  if ((rc != 0)); then
    if ((rc == 124 || rc == 137)); then reason=timeout; else reason="exit-$rc"; fi
    tail -n 20 "$attempt_err" >&2 || true
    fail_attempt "$reason" "$rc" "$sid"
    return 1
  fi
  if [[ -z $sid ]]; then
    fail_attempt no-snapshot-id 0
    return 1
  fi

  # Only an exit 0 snapshot becomes eligible; tagging is a separate command
  # with its own deadline, and its failure makes the run failed.
  #
  # `restic tag` rewrites the snapshot, so its id changes: the id from the
  # backup summary is dead the moment tagging succeeds. The post-tag id is read
  # back from the repository and must be the same snapshot (same tree and time),
  # otherwise nothing is recorded.
  # The tree identifies the snapshot content independently of its id, which
  # tagging rewrites. The backup summary does not carry it; the snapshot does.
  backup_tree=$(with_deadline "$deadline" "$restic_bin" -r "$repo" cat snapshot \
    "$sid" 2>/dev/null | jq -r '.tree // empty' 2>/dev/null) || backup_tree=""
  if [[ -z $backup_tree ]]; then
    fail_attempt no-snapshot-id 0 "$sid"
    return 1
  fi
  if ! restic_with_lock "$deadline" "$repo" tag --add verified \
    "$sid" >/dev/null 2>&1; then
    fail_attempt tag-failed 0 "$sid"
    return 1
  fi
  verified_json=$(with_deadline "$deadline" "$restic_bin" -r "$repo" snapshots \
    --json --no-lock --host "$restic_host" --tag "unit:$unit" \
    --tag verified --latest 1 2>/dev/null) || verified_json=""
  verified_sid=$(printf '%s' "$verified_json" | jq -r '.[0].id // empty' 2>/dev/null) || verified_sid=""
  verified_tree=$(printf '%s' "$verified_json" | jq -r '.[0].tree // empty' 2>/dev/null) || verified_tree=""
  if [[ -z $verified_sid || -z $verified_tree || $verified_tree != "$backup_tree" ]]; then
    fail_attempt tag-failed 0 "$sid"
    return 1
  fi
  sid=$verified_sid
  if ! finish_attempt success 0 "" "$sid"; then
    warn "$backend/$unit: snapshot $sid verified but the result was not persisted; treating the run as failed"
    cleanup_staging
    rm -f "$attempt_log" "$attempt_err"
    attempt_log=""
    attempt_err=""
    return 1
  fi

  cleanup_staging
  rm -f "$attempt_log" "$attempt_err"
  attempt_log=""
  attempt_err=""
  say "$backend/$unit: ok (snapshot $sid)"
  return 0
}

run_attempt() {
  local start lock_fd rc=0
  start=$(now_iso)
  state_write "$state" '
      .last_attempt = {n: ((.last_attempt.n // 0) + 1), start: $start,
                       end: null, exit: null, result: "running",
                       reason: "", snapshot: null}' \
    --arg start "$start" || {
    warn "$backend/$unit: cannot record a running attempt"
    return 1
  }

  attempt_start=$start
  exec {lock_fd}>"$lock"
  if flock -w "$lock_wait" "$lock_fd"; then
    if ! attempt_locked; then rc=1; fi
  else
    fail_attempt lock-timeout
    rc=1
  fi
  exec {lock_fd}>&-
  return "$rc"
}

write_maintenance_result() {
  local result=$1 exitcode=$2 end=$3 file
  file="$state_root/state/$backend-maintenance.json"
  jq -n --arg backend "$backend" --arg end "$end" --argjson exit "$exitcode" \
    --arg result "$result" '
    {schema: 1, backend: $backend, end: $end, exit: $exit, result: $result}' \
    >"$file.tmp" && chmod 0600 "$file.tmp" && mv -f "$file.tmp" "$file" &&
    sync "$file" 2>/dev/null || true
}

# Repository-wide maintenance: forget per restore unit with the verified
# filter, one prune for the repository, and a weekly read-data-subset check.
# Restic's own lock is what serializes this against a running backup.
run_maintenance() {
  local stamp check_stamp now rc=0 g log
  stamp=$(maintenance_stamp "$backend" daily)
  check_stamp=$(maintenance_stamp "$backend" check)
  log=$state_root/maintenance/$backend.log
  now=$(now_epoch)
  local due=1 check_due=0
  if [[ -s $stamp ]] && ((now - $(stat -c %Y "$stamp") < 86400)); then due=0; fi
  if [[ ! -s $check_stamp ]] || ((now - $(stat -c %Y "$check_stamp") >= 604800)); then
    check_due=1
  fi
  if ((due == 0 && check_due == 0)); then
    say "$backend: maintenance not due"
    return 0
  fi

  if ((due)); then
    for g in "${units[@]}"; do
      if ! restic_with_lock "$deadline_maintenance" "$repo" forget \
        --host "$restic_host" \
        --tag "unit:$g" --tag verified \
        --keep-daily 14 --keep-weekly 8 --keep-monthly 12 >>"$log" 2>&1; then
        rc=1
      fi
    done
    restic_with_lock "$deadline_maintenance" "$repo" prune \
      >>"$log" 2>&1 || rc=1
    : >"$stamp"
    chmod 0600 "$stamp"
  fi

  if ((check_due)); then
    if restic_with_lock "$deadline_maintenance" "$repo" \
      check --read-data-subset=1/30 >>"$log" 2>&1; then
      : >"$check_stamp"
      chmod 0600 "$check_stamp"
    else
      rc=1
    fi
  fi

  if ((rc == 0)); then
    write_maintenance_result success 0 "$(now_iso)"
    say "$backend: maintenance ok"
  else
    write_maintenance_result failure 1 "$(now_iso)"
    warn "$backend: maintenance failed; last log lines:"
    tail -n 20 "$log" >&2 || true
  fi
  return "$rc"
}

main() {
  ensure_state_dirs || {
    warn "cannot create $state_root"
    exit 1
  }

  local resolved=0
  repo=$(repo_for "$backend" 2>/dev/null) && resolved=1
  if ((resolved == 0)) || ! load_backend_env "$backend"; then
    warn "$backend: repository or credentials are not configured (see docs/core/restic-plane.md)"
    repo=${repo:-unconfigured}
    for unit in "${units[@]}"; do
      state=$(state_file_for "$backend" "$unit")
      journal=$(journal_for "$backend" "$unit")
      lock=$(lock_for "$backend" "$unit")
      paths_json=$(unit_paths_json "$unit" "$backend")
      state_init "$state" "$backend" "$unit" "$repo" "$paths_json" || continue
      state_write "$state" '
          .last_attempt = {n: ((.last_attempt.n // 0) + 1), start: $start,
                           end: null, exit: null, result: "running",
                           reason: "", snapshot: null}' --arg start "$(now_iso)" || continue
      fail_attempt not-configured 0 ""
    done
    exit 1
  fi

  local failed=0 unit job_ok attempt in_filter g
  for unit in "${units[@]}"; do
    if ((${#unit_filter[@]} > 0)); then
      in_filter=0
      for g in "${unit_filter[@]}"; do [[ $g == "$unit" ]] && in_filter=1; done
      ((in_filter)) || continue
    fi
    state=$(state_file_for "$backend" "$unit")
    journal=$(journal_for "$backend" "$unit")
    lock=$(lock_for "$backend" "$unit")
    paths_json=$(unit_paths_json "$unit" "$backend")
    if ! state_init "$state" "$backend" "$unit" "$repo" "$paths_json"; then
      warn "$backend/$unit: cannot initialise status state"
      failed=1
      continue
    fi

    job_ok=0
    attempt=0
    while ((attempt < attempts)); do
      attempt=$((attempt + 1))
      if run_attempt; then
        job_ok=1
        break
      fi
      if ((attempt < attempts)); then
        warn "$backend/$unit: retrying in ${sleep_time}s (attempt $attempt/$attempts)"
        sleep "$sleep_time"
      fi
    done
    if ((job_ok == 0)); then failed=1; fi
  done

  if ((maintenance)); then
    run_maintenance || failed=1
  fi

  if ((failed)); then
    warn "$backend: at least one job or maintenance step failed"
    exit 1
  fi
  say "$backend: all due jobs succeeded"
}

main "$@"
