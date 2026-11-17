#!/usr/bin/env bash
# Shared vocabulary for the smortress Restic plane (SDLC #706, T3).
#
# Sourced by smortress-restic-{backup,verify,init,restore-drill}; never run on
# its own. Every knob is environment-overridable so tests/core/restic-plane.sh
# can drive this exact code against stubs. Production sets none of them: the
# defaults are the host paths, and a wrong override is a wrong host path, not a
# way to skip a check.
#
# shellcheck disable=SC2034  # sourced library: consumers use a subset

# The dataset and unit tables are the storage layout's, not a copy: a unit in
# this plane is exactly an entry there.
common_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
layout=${STORAGE_LAYOUT:-$common_dir/storage-layout}
[[ -r $layout ]] || layout=$layout.sh
# shellcheck source=/dev/null
source "$layout"

restic_host=${RESTIC_HOST:-smortress}
backends=(ssd hdd r2)

restic_base=${RESTIC_BASE:-/var/lib/restic}
state_root=${RESTIC_STATE_ROOT:-/var/lib/homelab/restic}
secrets_dir=${SMORTRESS_SECRETS_DIR:-/run/smortress/secrets}
mountinfo=${RESTIC_MOUNTINFO:-/proc/self/mountinfo}

restic_bin=${RESTIC_BIN:-restic}
zfs_bin=${ZFS_BIN:-zfs}
zfs_ready_bin=${ZFS_READY_BIN:-/usr/libexec/zfs-ready}
curl_bin=${CURL_BIN:-curl}

password_file=${RESTIC_PASSWORD_FILE_PATH:-$secrets_dir/restic-password.yaml}
r2_secret=$secrets_dir/r2-credentials.yaml
healthcheck_secret=$secrets_dir/healthchecks.yaml

# The R2 bucket and repository path already exist. Only the write key pair is a
# secret, and it comes from SOPS (r2_access_key_id / r2_secret_access_key).
# The legacy migration repositories live elsewhere and are never referenced
# from this plane.
r2_repository='s3:https://385f7d47e2e8438fbda5d6f76d760434.r2.cloudflarestorage.com/homelab-restic/smortress'

# Per-attempt deadlines, not per-job ones: every command gets its own bound so
# a hung zfs, restic or curl becomes a recorded failure instead of a wedged
# unit. A local attempt has to fit inside the hourly schedule; an R2 attempt has
# a whole day and a slower network, so it gets hours.
deadline_local=${RESTIC_DEADLINE_LOCAL:-1800}
deadline_r2=${RESTIC_DEADLINE_R2:-14400}
deadline_maintenance=${RESTIC_DEADLINE_MAINTENANCE:-14400}
attempts=${RESTIC_ATTEMPTS:-2}
retry_sleep_local=${RESTIC_RETRY_SLEEP_LOCAL:-60}
retry_sleep_r2=${RESTIC_RETRY_SLEEP_R2:-600}
lock_wait=${RESTIC_LOCK_WAIT:-300}
kill_after=${RESTIC_KILL_AFTER:-60}

# Freshness budget: schedule + every bounded retry + grace. A snapshot older
# than this cannot be a current recovery point. keep-in-sync with
# docs/core/restic-plane.md and the numbers asserted by
# tests/core/restic-plane.sh.
max_age_local=${RESTIC_MAX_AGE_LOCAL:-8400}       # 3600 + 2*(1800+60) + 1200
max_age_r2=${RESTIC_MAX_AGE_R2:-118800}           # 86400 + 2*(14400+600) + 3600
run_expiry_local=${RESTIC_RUN_EXPIRY_LOCAL:-4320} # 2*(1800+60) + 600
run_expiry_r2=${RESTIC_RUN_EXPIRY_R2:-31800}      # 2*(14400+600) + 1800

say() { printf '%s\n' "$*"; }
warn() { printf '%s: %s\n' "${0##*/}" "$*" >&2; }

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_epoch() { date -u +%s; }
iso_epoch() { date -u -d "$1" +%s 2>/dev/null; }

# An unparsable timestamp is infinitely old, never "now": freshness fails
# closed on a state file it cannot understand.
age_seconds() {
  local ts=${1-} epoch
  if [[ -z $ts ]]; then
    printf '999999999\n'
    return 0
  fi
  if ! epoch=$(iso_epoch "$ts"); then
    printf '999999999\n'
    return 0
  fi
  printf '%s\n' "$(($(now_epoch) - epoch))"
}

# yaml_value <file> <key>: one scalar from the decrypted YAML. sops-decrypt
# writes plain YAML; the plane only ever reads simple top-level scalars, so a
# multi-key or malformed file fails instead of silently yielding a partial
# value.
yaml_value() {
  local file=$1 key=$2
  [[ -r $file ]] || return 1
  awk -v want="$key" '
    /^[[:space:]]*(#|$)/ { next }
    {
      i = index($0, ":")
      if (i == 0) next
      name = substr($0, 1, i - 1)
      val = substr($0, i + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
      if (name != want) next
      if (val ~ /^".*"$/ || val ~ /^\047.*\047$/) val = substr(val, 2, length(val) - 2)
      found = 1
      out = val
    }
    END { if (!found || out == "") exit 1; print out }
  ' "$file"
}

repo_for() {
  case $1 in
    ssd) printf '%s/ssd/restic\n' "$restic_base" ;;
    hdd) printf '%s/hdd/restic\n' "$restic_base" ;;
    r2) printf '%s\n' "$r2_repository" ;;
    *) return 2 ;;
  esac
}

# Credentials reach restic through the environment, never argv or the journal.
load_backend_env() {
  local backend=$1 id secret region
  export RESTIC_PASSWORD_FILE=$password_file
  # systemd units have no HOME, and restic refuses to guess a cache directory.
  # An explicit cache also keeps the repository lock and index cache off /tmp.
  cache_dir=${RESTIC_CACHE_DIR:-/var/cache/smortress-restic}
  mkdir -p "$cache_dir"
  export RESTIC_CACHE_DIR=$cache_dir
  case $backend in
    r2)
      id=$(yaml_value "$r2_secret" r2_access_key_id) || return 1
      secret=$(yaml_value "$r2_secret" r2_secret_access_key) || return 1
      [[ -n $id && -n $secret ]] || return 1
      export AWS_ACCESS_KEY_ID=$id AWS_SECRET_ACCESS_KEY=$secret
      region=$(yaml_value "$r2_secret" r2_region 2>/dev/null) || region=auto
      export AWS_DEFAULT_REGION=$region
      ;;
  esac
  return 0
}

# Exact field-5 match, like zfs-ready: a directory that merely exists at the
# mountpoint is how a repository would be written into the root filesystem.
is_mountpoint() {
  local path=$1
  [[ -r $mountinfo ]] || return 1
  awk -v p="$path" '$5 == p { found = 1 } END { exit !found }' "$mountinfo"
}

# One snapshot path per dataset in the unit, in table order. The backup passes
# all of them to a single snapshot, and a restore reads the same list back.
unit_staging_paths() { # unit backend
  local key
  for key in $(unit_keys "$1"); do
    printf '%s/.zfs/snapshot/%s\n' "$(mountpoint_for "$key")" "$2"
  done
}


state_file_for() { printf '%s/state/%s-%s.json\n' "$state_root" "$1" "$2"; }
journal_for() { printf '%s/journal/%s-%s.jsonl\n' "$state_root" "$1" "$2"; }
lock_for() { printf '%s/locks/%s-%s.lock\n' "$state_root" "$1" "$2"; }
maintenance_stamp() { printf '%s/maintenance/%s.%s\n' "$state_root" "$1" "$2"; }

ensure_state_dirs() {
  install -d -m 0700 "$state_root" "$state_root/state" "$state_root/journal" \
    "$state_root/locks" "$state_root/maintenance"
}

# Every external command goes through this, local disk included.
with_deadline() {
  local secs=$1
  shift
  timeout --signal=TERM --kill-after="$kill_after" "$secs" "$@"
}

job_deadline() { if [[ $1 == r2 ]]; then printf '%s\n' "$deadline_r2"; else printf '%s\n' "$deadline_local"; fi; }
job_retry_sleep() { if [[ $1 == r2 ]]; then printf '%s\n' "$retry_sleep_r2"; else printf '%s\n' "$retry_sleep_local"; fi; }
max_age_for() { if [[ $1 == r2 ]]; then printf '%s\n' "$max_age_r2"; else printf '%s\n' "$max_age_local"; fi; }
run_expiry_for() { if [[ $1 == r2 ]]; then printf '%s\n' "$run_expiry_r2"; else printf '%s\n' "$run_expiry_local"; fi; }

# Fail-closed state writes. jq writes a sibling, the file is fsynced, then
# renamed; a caller that cannot persist the result treats the run as failed.
state_write() {
  local file=$1 program=$2
  shift 2
  local tmp
  tmp=$(mktemp "$state_root/state/.write.XXXXXX") || return 1
  if ! jq "$@" "$program" "$file" >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  chmod 0600 "$tmp" || {
    rm -f "$tmp"
    return 1
  }
  if ! mv -f "$tmp" "$file"; then
    rm -f "$tmp"
    return 1
  fi
  sync "$file" 2>/dev/null || true
  sync "$state_root/state" 2>/dev/null || true
  return 0
}

journal_append() {
  local file=$1 line=$2
  printf '%s\n' "$line" >>"$file" || return 1
  sync "$file" 2>/dev/null || true
  return 0
}

state_init() {
  local file=$1 backend=$2 unit=$3 repo=$4 paths_json=$5
  [[ -s $file ]] && return 0
  local tmp
  tmp=$(mktemp "$state_root/state/.init.XXXXXX") || return 1
  if ! jq -n --arg b "$backend" --arg u "$unit" --arg h "$restic_host" \
    --arg r "$repo" --argjson p "$paths_json" \
    '{schema:2,backend:$b,unit:$u,host:$h,repository:$r,paths:$p,
      last_attempt:null,last_success:null,final:null,pending_reap:[]}' >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  chmod 0600 "$tmp"
  mv -f "$tmp" "$file" || {
    rm -f "$tmp"
    return 1
  }
  sync "$file" 2>/dev/null || true
  return 0
}

# Restic write commands need a lock. A stale lock from a killed job or a reboot
# surfaces as exit 11; `restic unlock` removes only locks whose process is gone,
# so retrying once after that is safe even while another group is backing up.
restic_with_lock() { # restic_with_lock <deadline> <repo> <restic args...>
  local deadline=$1 repo=$2 rc=0
  shift 2
  with_deadline "$deadline" "$restic_bin" -r "$repo" --retry-lock 2m "$@" || rc=$?
  if ((rc == 11)); then
    with_deadline 120 "$restic_bin" -r "$repo" unlock >/dev/null 2>&1 || true
    rc=0
    with_deadline "$deadline" "$restic_bin" -r "$repo" --retry-lock 2m "$@" || rc=$?
  fi
  return $rc
}
