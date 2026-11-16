#!/usr/bin/env bash
# Prove the legacy repositories still restore (SDLC #703, T0 of #701).
#
# The old HDD repository and the old R2 repository are the only copies of the
# data the new core has not backed up yet, so both must be re-verified before a
# single disk is repartitioned. This script is read-only and bounded:
#
#   * `snapshots`, `stats`, `cat config` — metadata only
#   * `check --read-data-subset=<n>%` — a sampled read of real packs
#   * `restore --include ...` of a small set of trees into root-only scratch
#   * the newest Immich dump restored and checked as a PostgreSQL archive
#
# It never runs `init`, `forget`, `prune` or `unlock`, and it refuses to run
# while a backup unit is active. Repository URLs, the password file and the R2
# credentials are read from the systemd units themselves, so the verification
# uses exactly the configuration the nightly job uses.
#
# Usage (as root on smortress):
#   sudo scripts/core/verify-legacy-backups.sh
#   sudo scripts/core/verify-legacy-backups.sh --repo r2 --subset 2% --keep
set -euo pipefail

readonly SELF=${0##*/}
readonly SCRATCH_PARENT=/var/tmp
readonly SAMPLE_INCLUDES=(/var/lib/data/books /var/lib/data/db /var/lib/data/vault)

repo_sel=all
subset=1%
scratch=""
do_restore=1
keep=0
restic_bin=${RESTIC:-}
failures=0
checks=0

usage() {
  cat <<'EOF'
usage: verify-legacy-backups.sh [options]

  --repo local|r2|all   repository selection (default: all)
  --subset N%|N         check --read-data-subset value (default: 1%)
  --scratch DIR         restore target (default: /var/tmp/t0-restore.<utc>)
  --keep                keep the restore tree instead of deleting it
  --no-restore          check repositories only, restore nothing
  -h, --help            this text

Exit status: 0 when every executed check passed, 1 when any check failed.
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

# `check` takes a lock, and a shared cache must not move under a live backup.
for unit in restic-backups-local.service restic-backups-r2.service; do
  if systemctl is-active --quiet "$unit"; then
    fail_fatal "$unit is running; wait for it to finish"
  fi
done

# The binary the units use, so the version matches what wrote the data.
discover_restic() {
  [[ -n $restic_bin ]] && return
  local unit path
  for unit in restic-backups-local.service restic-backups-r2.service; do
    systemctl cat "$unit" >/dev/null 2>&1 || continue
    path=$(systemctl show -p ExecStart "$unit" |
      grep -o 'path=[^ ;]*/restic' | head -1 | cut -d= -f2)
    if [[ -n $path && -x $path ]]; then
      restic_bin=$path
      return
    fi
  done
  restic_bin=$(command -v restic || true)
  [[ -n $restic_bin ]] || fail_fatal "no restic binary found; set RESTIC=/path/to/restic"
}

# RESTIC_* from the unit's Environment, AWS_* from its EnvironmentFile. Returns
# one KEY=VALUE per line; nothing else is exported.
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

latest_json() { "$restic_bin" snapshots --last --json 2>/dev/null | head -c 8192; }

field() { # field <json> <name>
  printf '%s' "$1" | grep -o "\"$2\": *\"[^\"]*\"" | head -1 | sed 's/.*: *"//; s/"$//'
}

restore_sample() { # restore_sample <snapshot> <target>
  local snap=$1 target=$2
  local -a includes=()
  local path
  for path in "${SAMPLE_INCLUDES[@]}"; do
    if "$restic_bin" ls "$snap" "$path" >/dev/null 2>&1; then
      includes+=("--include" "$path")
    fi
  done
  if ((${#includes[@]} == 0)); then
    record FAIL "sample restore" "none of the sample paths exist in the snapshot"
    return
  fi
  if ! "$restic_bin" restore "$snap" --target "$target" "${includes[@]}" \
    >"$target/restore.log" 2>&1; then
    record FAIL "sample restore" "see $target/restore.log"
    return
  fi
  record PASS "sample restore" "${#includes[@]} include(s) restored to $target"

  local inc restored listed
  for inc in "${SAMPLE_INCLUDES[@]}"; do
    [[ -d $target$inc ]] || continue
    restored=$(find "$target$inc" -type f | wc -l)
    listed=$("$restic_bin" ls --long "$snap" "$inc" 2>/dev/null | grep -c '^-' || true)
    if ((restored == 0)); then
      record FAIL "restored $inc" "no files restored"
    elif ((listed > 0)) && ((restored == listed)); then
      record PASS "restored $inc" "$restored files match the snapshot listing"
    else
      record FAIL "restored $inc" "$restored files restored, listing says ${listed:-unknown}"
    fi
  done

  local dump=$target/var/lib/data/db/immich.dump
  if [[ ! -f $dump ]]; then
    record FAIL "Immich dump restored" "no dump at $dump"
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
  if [[ -n $pg_restore && -x $pg_restore ]]; then
    entries=$("$pg_restore" --list "$dump" 2>/dev/null | grep -c '^[0-9]' || true)
    if ((entries > 0)); then
      record PASS "pg_restore --list" "$entries archive entries"
    else
      record FAIL "pg_restore --list" "no entries"
    fi
  else
    record PARTIAL "pg_restore --list" "no pg_restore on this host; magic check only"
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
  mkdir -p "$target"
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
  if config=$("$restic_bin" cat config 2>/dev/null); then
    record PASS "repository opens" "id $(field "$config" id)"
  else
    record FAIL "repository opens" "restic cat config failed"
    unset RESTIC_REPOSITORY RESTIC_PASSWORD_FILE RESTIC_CACHE_DIR AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
    printf '\n'
    return
  fi

  local snaps snap_time
  if snaps=$(latest_json) && [[ -n $snaps ]]; then
    record PASS "latest snapshot listed" "$(field "$snaps" short_id) at $(field "$snaps" time) on $(field "$snaps" hostname)"
  else
    record FAIL "latest snapshot listed" "restic snapshots failed"
    unset RESTIC_REPOSITORY RESTIC_PASSWORD_FILE RESTIC_CACHE_DIR AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
    printf '\n'
    return
  fi

  local now then_ age_hours
  snap_time=$(field "$snaps" time)
  now=$(date -u +%s)
  then_=$(date -u -d "$snap_time" +%s 2>/dev/null || echo "$now")
  age_hours=$(((now - then_) / 3600))
  if ((age_hours <= 36)); then
    record PASS "latest snapshot is recent" "${age_hours}h old"
  else
    record FAIL "latest snapshot is recent" "${age_hours}h old; the nightly job runs 03:30"
  fi

  if "$restic_bin" stats --json latest >/dev/null 2>&1; then
    record PASS "stats readable" "$("$restic_bin" stats latest 2>/dev/null | tail -1)"
  else
    record FAIL "stats readable" "restic stats failed"
  fi

  if "$restic_bin" check --read-data-subset="$subset" >"$target/check.log" 2>&1; then
    record PASS "check --read-data-subset=$subset" "packs verified, no errors"
  else
    record FAIL "check --read-data-subset=$subset" "see $target/check.log"
  fi

  if ((do_restore)); then
    restore_sample "$(field "$snaps" short_id)" "$target"
  fi

  unset RESTIC_REPOSITORY RESTIC_PASSWORD_FILE RESTIC_CACHE_DIR AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  printf '\n'
}

discover_restic
run_id=$(date -u '+%Y%m%dT%H%M%SZ')
scratch=${scratch:-$SCRATCH_PARENT/t0-restore.$run_id}
mkdir -p "$scratch"
chmod 700 "$scratch"

echo "$SELF: $("$restic_bin" version | head -1)"
echo "$SELF: scratch $scratch"

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

printf '## Summary\n\n%s checks, %s failed. Restore tree: `%s`\n' "$checks" "$failures" "$scratch"

if ((failures > 0)); then
  echo "$SELF: FAIL; the legacy repositories are not proven restorable" >&2
  exit 1
fi
if ((keep == 0)); then
  rm -rf "$scratch"
  echo "$SELF: PASS; removed $scratch"
else
  echo "$SELF: PASS; kept $scratch"
fi
