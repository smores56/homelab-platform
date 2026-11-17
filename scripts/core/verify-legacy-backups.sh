#!/usr/bin/env bash
# Prove the legacy repositories still restore (SDLC #703, T0 of #701).
#
# The old HDD repository and the old R2 repository are the only copies of the
# retained trees, so both must be re-verified before a single disk is
# repartitioned. What this does:
#
#   * metadata reads with `--no-lock` (cat config, snapshots, stats, ls)
#   * `check --read-data-subset=<n>%` — sampled pack reads; this one must lock
#   * presence of every retained tree in the snapshot
#   * a restore of the small trees plus the live Immich dump
#   * the dump parsed as a PostgreSQL custom archive
#
# It never runs `init`, `forget`, `prune` or `unlock`. Repository URLs, the
# password file and the R2 credentials are read from the systemd units, so the
# verification uses exactly the configuration the nightly job uses.
#
# Usage (as root on smortress):
#   sudo scripts/core/verify-legacy-backups.sh
#   sudo scripts/core/verify-legacy-backups.sh --repo local --keep
# shellcheck disable=SC2016  # backticks and $ in printf formats are Markdown for the report
set -euo pipefail

readonly SELF=${0##*/}
readonly SCRATCH_ROOT=/var/tmp
readonly DUMP_PATH=/var/lib/data/immich/db-dumps/immich.dump

# Trees the new core retains. Presence is checked for every one of them; the
# restore sample is only the subset small enough to copy twice.
readonly RETAINED_TREES=(
  /var/lib/data/immich
  /var/lib/data/photos
  /var/lib/data/books
  /var/lib/data/music
  /var/lib/data/wallpapers
  /var/lib/data/vault
  /var/lib/data/todo
)
readonly SAMPLE_INCLUDES=(
  /var/lib/data/books
  /var/lib/data/vault
  /var/lib/data/todo
)

repo_sel=all
subset=1%
scratch=""
scratch_owned=0
do_restore=1
keep=0
force=0
restic_bin=${RESTIC:-}
failures=0
checks=0

usage() {
  cat <<'EOF'
usage: verify-legacy-backups.sh [options]

  --repo local|r2|all   repository selection (default: all)
  --subset N%|N         check --read-data-subset value (default: 1%)
  --scratch DIR         restore target; must be empty and under /var/tmp
                        (default: a directory this script creates)
  --keep                keep the restore tree instead of deleting it
  --no-restore          check repositories only, restore nothing
  --force               run even if a restic timer fires within two hours
  -h, --help            this text

Exit status: 0 when every check passed, 1 when any check failed.
EOF
}

while (($#)); do
  case $1 in
  --repo)
    repo_sel=${2:?--repo needs a value}
    shift 2
    ;;
  --subset)
    subset=${2:?--subset needs a value}
    shift 2
    ;;
  --scratch)
    scratch=${2:?--scratch needs a path}
    shift 2
    ;;
  --keep)
    keep=1
    shift
    ;;
  --no-restore)
    do_restore=0
    shift
    ;;
  --force)
    force=1
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    echo "$SELF: unknown argument: $1" >&2
    usage >&2
    exit 2
    ;;
  esac
done

case $repo_sel in local | r2 | all) ;; *)
  echo "$SELF: --repo must be local, r2 or all" >&2
  exit 2
  ;;
esac

if ((EUID != 0)); then
  echo "$SELF: run as root; the password file and the data trees are root-only" >&2
  exit 1
fi

fail_fatal() {
  echo "$SELF: $*" >&2
  exit 1
}

record() { # record <status> <label> [detail]
  checks=$((checks + 1))
  [[ $1 == FAIL ]] && failures=$((failures + 1))
  printf '| %s | %s | %s |\n' "$1" "$2" "${3:-}"
}

# `check` takes a lock; a timer firing mid-verification would then collide with
# it and fail the *nightly* run instead of this one.
next_timer_minutes() {
  local json now_us
  json=$(systemctl list-timers --no-pager --output=json 'restic-*' 2>/dev/null || true)
  now_us=$(($(date +%s) * 1000000))
  printf '%s' "$json" | sed 's/},{/}\n{/g' |
    sed -n 's/.*"next":\([0-9][0-9]*\).*/\1/p' |
    while read -r next; do
      minutes=$(((next - now_us) / 60000000))
      ((minutes < 0)) || echo "$minutes"
    done | sort -n | sed -n 1p
}

for unit in restic-backups-local.service restic-backups-r2.service; do
  if systemctl is-active --quiet "$unit"; then
    fail_fatal "$unit is running; wait for it to finish"
  fi
done
if ((force == 0)); then
  minutes_left=$(next_timer_minutes)
  if [[ -n $minutes_left ]] && ((minutes_left < 120)); then
    fail_fatal "a restic timer fires in ${minutes_left} min; rerun after it finishes or pass --force"
  fi
fi

# The binary the units use, so the version matches what wrote the data.
discover_restic() {
  [[ -n $restic_bin ]] && return
  local unit path
  for unit in restic-backups-local.service restic-backups-r2.service; do
    systemctl cat "$unit" >/dev/null 2>&1 || continue
    path=$(systemctl show -p ExecStart "$unit" |
      grep -o 'path=[^ ;]*/restic' | sed -n 1p | cut -d= -f2)
    if [[ -n $path && -x $path ]]; then
      restic_bin=$path
      return
    fi
  done
  restic_bin=$(command -v restic || true)
  [[ -n $restic_bin ]] || fail_fatal "no restic binary found; set RESTIC=/path/to/restic"
}

# RESTIC_* from the unit's Environment, AWS_* from its EnvironmentFile.
unit_env() {
  local unit=$1 file
  systemctl cat "$unit" >/dev/null 2>&1 || return 0
  systemctl show -p Environment "$unit" | sed 's/^Environment=//' | tr ' ' '\n' |
    grep -E '^RESTIC_' || true
  file=$(systemctl show -p EnvironmentFiles "$unit" | sed 's/^EnvironmentFiles=//' |
    cut -d' ' -f1)
  if [[ -n $file && -r $file ]]; then
    grep -E '^(AWS_|RESTIC_)' "$file" || true
  fi
}

field() { # field <json> <name>
  printf '%s' "$1" | grep -o "\"$2\": *\"[^\"]*\"" | head -1 | sed 's/.*: *"//; s/"$//'
}

restore_sample() { # restore_sample <snap> <target>
  local snap=$1 target=$2
  local -a includes=()
  local path
  for path in "${SAMPLE_INCLUDES[@]}" "$DUMP_PATH"; do
    if "$restic_bin" ls --no-lock "$snap" "$path" >/dev/null 2>&1; then
      includes+=("--include" "$path")
    fi
  done
  if ((${#includes[@]} == 0)); then
    record FAIL "sample restore" "none of the sample paths exist in the snapshot"
    return
  fi
  if ! "$restic_bin" restore --no-lock "$snap" --target "$target" "${includes[@]}" \
    >"$target/restore.log" 2>&1; then
    record FAIL "sample restore" "see $target/restore.log"
    return
  fi
  record PASS "sample restore" "${#includes[@]} include(s) restored to $target"

  local inc restored listed
  for inc in "${SAMPLE_INCLUDES[@]}"; do
    [[ -d $target$inc ]] || continue
    restored=$(find "$target$inc" -type f | wc -l)
    listed=$("$restic_bin" ls --long --no-lock "$snap" "$inc" 2>/dev/null | grep -c '^-' || true)
    if ((restored == 0)); then
      record FAIL "restored $inc" "no files restored"
    elif ((listed > 0)) && ((restored == listed)); then
      record PASS "restored $inc" "$restored files match the snapshot listing"
    else
      record FAIL "restored $inc" "$restored files restored, listing says ${listed:-unknown}"
    fi
  done

  local dump=$target$DUMP_PATH
  if [[ ! -f $dump ]]; then
    record FAIL "Immich dump restored" "no $DUMP_PATH in this snapshot"
    return
  fi
  local magic
  magic=$(head -c 5 "$dump" || true)
  if [[ $magic == PGDMP ]]; then
    record PASS "Immich dump is a PostgreSQL custom archive" "$(du -h "$dump" | cut -f1)"
  else
    record FAIL "Immich dump is a PostgreSQL custom archive" "magic '$magic'"
  fi

  local pg_restore entries
  pg_restore=$(command -v pg_restore || true)
  if [[ -z $pg_restore ]]; then
    pg_restore=$(find /nix/store -maxdepth 4 -type f -path '*-postgresql-*/bin/pg_restore' \
      2>/dev/null | sort | tail -1 || true)
  fi
  if [[ -z $pg_restore || ! -x $pg_restore ]]; then
    record FAIL "pg_restore --list" \
      "pg_restore absent; run 'nix shell nixpkgs#postgresql --command pg_restore --list $dump'"
    return
  fi
  entries=$("$pg_restore" --list "$dump" 2>/dev/null | grep -c '^[0-9]' || true)
  if ((entries > 0)); then
    record PASS "pg_restore --list" "$entries archive entries"
  else
    record FAIL "pg_restore --list" "no entries"
  fi
}

check_repo() { # check_repo <name> <unit>
  local name=$1 unit=$2
  local env_lines repository password_file
  env_lines=$(unit_env "$unit")
  repository=$(printf '%s\n' "$env_lines" | sed -n 's/^RESTIC_REPOSITORY=//p' | head -1)
  password_file=$(printf '%s\n' "$env_lines" | sed -n 's/^RESTIC_PASSWORD_FILE=//p' | head -1)

  printf '\n### %s\n\n' "$name"
  printf '| status | check | detail |\n| --- | --- | --- |\n'

  if [[ -z $repository ]]; then
    record FAIL "unit $unit exposes a repository" "unit missing or unreadable"
    printf '\n'
    return
  fi
  printf 'repository: `%s`\n\n' "$repository"
  if [[ ! -r $password_file ]]; then
    record FAIL "password file readable" "$password_file"
    printf '\n'
    return
  fi

  local target=$scratch/$name
  mkdir -p "$target" && chmod 700 "$target"
  export RESTIC_REPOSITORY=$repository
  export RESTIC_PASSWORD_FILE=$password_file
  export RESTIC_CACHE_DIR=$scratch/cache-$name
  export AWS_DEFAULT_REGION=auto
  local line
  while IFS= read -r line; do
    case $line in
    AWS_ACCESS_KEY_ID=*) export AWS_ACCESS_KEY_ID=${line#*=} ;;
    AWS_SECRET_ACCESS_KEY=*) export AWS_SECRET_ACCESS_KEY=${line#*=} ;;
    esac
  done <<<"$env_lines"

  local config
  if config=$("$restic_bin" cat config --no-lock 2>/dev/null); then
    record PASS "repository opens" "id $(field "$config" id)"
  else
    record FAIL "repository opens" "restic cat config failed"
    unset RESTIC_REPOSITORY RESTIC_PASSWORD_FILE RESTIC_CACHE_DIR AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
    printf '\n'
    return
  fi

  local snaps snap_time stat_line
  if snaps=$("$restic_bin" snapshots --last --json --no-lock 2>/dev/null) && [[ -n $snaps ]]; then
    record PASS "latest snapshot listed" \
      "$(field "$snaps" short_id) at $(field "$snaps" time) on $(field "$snaps" hostname)"
  else
    record FAIL "latest snapshot listed" "restic snapshots failed"
    unset RESTIC_REPOSITORY RESTIC_PASSWORD_FILE RESTIC_CACHE_DIR AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
    printf '\n'
    return
  fi

  local snap now then_ age_hours
  snap=$(field "$snaps" short_id)
  snap_time=$(field "$snaps" time)
  now=$(date -u +%s)
  then_=$(date -u -d "$snap_time" +%s 2>/dev/null || echo "$now")
  age_hours=$(((now - then_) / 3600))
  if ((age_hours <= 36)); then
    record PASS "latest snapshot is recent" "${age_hours}h old"
  else
    record FAIL "latest snapshot is recent" "${age_hours}h old; the nightly job runs 03:30"
  fi

  if stat_line=$("$restic_bin" stats --json latest --no-lock 2>/dev/null); then
    record PASS "stats readable" "restore size $(printf '%s' "$stat_line" | grep -o '"total_size":[0-9]*' | cut -d: -f2) bytes"
  else
    record FAIL "stats readable" "restic stats failed"
  fi

  local tree entries
  for tree in "${RETAINED_TREES[@]}"; do
    entries=$("$restic_bin" ls --no-lock "$snap" "$tree" 2>/dev/null | wc -l)
    if ((entries > 0)); then
      record PASS "retained $tree present" "$entries entries"
    else
      record FAIL "retained $tree present" "absent from snapshot $snap"
    fi
  done

  if "$restic_bin" check --read-data-subset="$subset" >"$target/check.log" 2>&1; then
    record PASS "check --read-data-subset=$subset" "packs verified, no errors"
  else
    record FAIL "check --read-data-subset=$subset" "see $target/check.log"
  fi

  if ((do_restore)); then
    restore_sample "$snap" "$target"
  fi

  unset RESTIC_REPOSITORY RESTIC_PASSWORD_FILE RESTIC_CACHE_DIR AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  printf '\n'
}

discover_restic
run_id=$(date -u '+%Y%m%dT%H%M%SZ')

if [[ -n $scratch ]]; then
  [[ $scratch == "$SCRATCH_ROOT"/* ]] ||
    fail_fatal "--scratch must be under $SCRATCH_ROOT; refusing to touch $scratch"
  if [[ -e $scratch ]] && [[ -n $(ls -A "$scratch" 2>/dev/null) ]]; then
    fail_fatal "--scratch $scratch is not empty; refusing to reuse it"
  fi
  mkdir -p "$scratch" && chmod 700 "$scratch"
elif ((do_restore)); then
  scratch=$(mktemp -d "$SCRATCH_ROOT/t0-restore.XXXXXX")
  scratch_owned=1
fi

if ((do_restore)); then
  free_bytes=$(df --output=avail -B1 "$scratch" | tail -1)
  if ((free_bytes < 8 * 1024 * 1024 * 1024)); then
    fail_fatal "$scratch has $((free_bytes / 1024 / 1024)) MiB free; the restore needs 8 GiB"
  fi
  chmod 700 "$scratch"
fi

echo "$SELF: $("$restic_bin" version | sed -n 1p)"
echo "$SELF: scratch ${scratch:-(none)}"

units=()
if [[ $repo_sel == local || $repo_sel == all ]]; then
  units+=("local:restic-backups-local.service")
fi
if [[ $repo_sel == r2 || $repo_sel == all ]]; then
  units+=("r2:restic-backups-r2.service")
fi

printf '\n## Legacy restore verification %s\n' "$run_id"
for entry in "${units[@]}"; do
  check_repo "${entry%%:*}" "${entry#*:}"
done

printf '## Summary\n\n%s checks, %s failed. Restore tree: `%s`\n' \
  "$checks" "$failures" "${scratch:-(none)}"

if ((failures > 0)); then
  echo "$SELF: FAIL; the legacy repositories are not proven restorable" >&2
  exit 1
fi
if ((keep == 1)); then
  echo "$SELF: PASS; kept $scratch"
elif ((scratch_owned == 1)); then
  rm -rf "$scratch"
  echo "$SELF: PASS; removed $scratch"
else
  echo "$SELF: PASS; left the operator-supplied $scratch in place"
fi
