#!/usr/bin/env bash
# Restore-drill helper for the smortress Restic plane (SDLC #706, T3).
#
#   smortress-restic-restore-drill <ssd|hdd|r2> <unit> [--snapshot <id>]
#                                   [--target <dir>] [--list]
#
# This is the by-hand path from docs/core/restic-plane.md: it selects a
# `verified` snapshot (never an untagged or incomplete one), restores it into a
# fresh directory and verifies the written data. It never restores over a live
# dataset and never touches retention.
#
# The target defaults to a data disk, not /var/tmp: the root filesystem carries
# the system and the container images, and the `photos` unit alone restores
# 116 GiB, so a drill there can only end in ENOSPC against a disk other services
# need (docs/core/pool-rebuild.md). The snapshot's restore size is compared with
# the target filesystem before anything is written, and a target without room is
# refused.
#
# Env: RESTIC_DRILL_METHOD (restore|dump, default restore), RESTIC_DRILL_ROOT,
# RESTIC_DEADLINE_DRILL.
# shellcheck disable=SC2154  # variables and helpers come from restic-plane-common
# shellcheck disable=SC2016  # the bash -c script takes its values as positional parameters
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
usage: smortress-restic-restore-drill <ssd|hdd|r2> <unit> [options]

  --snapshot <id>  restore this snapshot instead of the latest verified one
  --target <dir>   restore here (default <drill root>/<backend>-<group>-<time>)
  --list           print the verified snapshots and exit

The restore lands under <target>/<mountpoint>/.zfs/snapshot/<backend>/, one
path per dataset in the unit, because those are the absolute paths the backup
recorded.
EOF
}

[[ $# -ge 2 ]] || { usage; exit 2; }
backend=$1
unit=$2
shift 2
case $backend in ssd | hdd | r2) ;; *) usage; exit 2 ;; esac
printf '%s\n' "${units[@]}" | grep -qx -- "$unit" || {
  warn "unknown unit: $unit"
  exit 2
}

snapshot=""
target=""
list=0
while (($#)); do
  case $1 in
    --snapshot) snapshot=${2-}; shift 2 || true ;;
    --target) target=${2-}; shift 2 || true ;;
    --list) list=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

if ! repo=$(repo_for "$backend" 2>/dev/null); then
  warn "$backend: repository is not configured"
  exit 1
fi
if ! load_backend_env "$backend"; then
  warn "$backend: credentials are not configured"
  exit 1
fi

mapfile -t staging_paths < <(unit_staging_paths "$unit" "$backend")
deadline=${RESTIC_DEADLINE_DRILL:-14400}

if ! json=$(with_deadline "$(job_deadline "$backend")" "$restic_bin" -r "$repo" \
  snapshots --json --no-lock --host "$restic_host" \
  --tag "unit:$unit,verified"); then
  warn "$backend: cannot list snapshots in $repo"
  exit 1
fi

if ((list)); then
  jq -r 'sort_by(.time)[] | "\(.id)  \(.time)  \(.hostname)  \(.tags // [] | join(","))"' \
    <<<"$json"
  exit 0
fi

if [[ -n $snapshot ]]; then
  if ! jq -e --arg id "$snapshot" 'any(.[]; .id == $id and ((.tags // []) | index("verified") != null))' \
    >/dev/null <<<"$json"; then
    warn "snapshot $snapshot is not a verified snapshot of $backend/$unit"
    exit 1
  fi
else
  snapshot=$(jq -r 'sort_by(.time) | last | .id // empty' <<<"$json")
  if [[ -z $snapshot ]]; then
    warn "$backend/$unit has no verified snapshot; nothing to restore"
    exit 1
  fi
fi

# Prefer a disk that holds the repositories; root is far too small for a media
# unit. RESTIC_DRILL_ROOT overrides the choice, and --target overrides both.
if [[ -z $target ]]; then
  drill_root=${RESTIC_DRILL_ROOT:-}
  if [[ -z $drill_root ]]; then
    for candidate in /var/lib/restic/hdd /var/lib/restic/ssd; do
      if mountpoint -q "$candidate"; then
        drill_root=$candidate/drill
        break
      fi
    done
    drill_root=${drill_root:-/var/tmp/restic-drill}
  fi
  target=$drill_root/$backend-$unit-$(date -u +%Y%m%dT%H%M%SZ)
fi
if [[ -e $target ]]; then
  if [[ -n $(find "$target" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null) ]]; then
    warn "$target is not empty; refusing to mix a drill into old data"
    exit 1
  fi
else
  install -d -m 0700 "$target"
fi
target=$(cd -- "$target" && pwd)

# Refuse before writing: an ENOSPC halfway through a media unit leaves a
# partial tree and can fill the filesystem other services need.
if ! restore_size=$(with_deadline 300 "$restic_bin" -r "$repo" stats "$snapshot" \
  --mode restore-size --json | jq -r '.total_size // empty'); then
  warn "$backend: cannot size snapshot $snapshot; refusing to guess"
  exit 1
fi
if [[ ! $restore_size =~ ^[0-9]+$ ]]; then
  warn "$backend: restic reported no restore size for $snapshot"
  exit 1
fi
if ! avail_blocks=$(df -Pk "$target" | awk 'NR == 2 { print $4 }'); then
  warn "$target: cannot read free space"
  exit 1
fi
avail_bytes=$((avail_blocks * 1024))
margin=$((2 * 1024 ** 3))
if ((restore_size + margin > avail_bytes)); then
  warn "$backend/$unit restores $((restore_size / 1024 ** 3)) GiB, but $target has $((avail_bytes / 1024 ** 3)) GiB free"
  warn "choose --target on a disk with room, or set RESTIC_DRILL_ROOT"
  exit 1
fi

say "$backend/$unit: restoring $snapshot into $target"
# Applying or removing security.selinux needs privileges the drill does not have
# (CAP_MAC_ADMIN and a relabelto policy), and the label is reapplied by the
# system on the real target, so it is excluded here.
#
# `dump` piped through tar was the original path and is kept behind
# RESTIC_DRILL_METHOD=dump, but it is the wrong default: dump walks the tree one
# node at a time, emits hardlinked content as separate files (a 36 GiB agent
# tree arrives as 444 GiB, docs/core/restic-plane.md), and over S3 a single
# stalled read hangs the whole drill until the deadline. restore loads packs in
# parallel and preserves hardlinks.
method=${RESTIC_DRILL_METHOD:-restore}
case $method in
  restore)
    if ! with_deadline "$deadline" "$restic_bin" -r "$repo" restore "$snapshot" \
      --target "$target" --sparse --exclude-xattr 'security.selinux'; then
      warn "restore failed; $target holds an incomplete tree"
      exit 1
    fi
    # restore succeeds for whatever the snapshot holds, so it succeeds for a
    # snapshot that predates one of the unit's paths. dump failed on a missing
    # path, and a drill that prints "Restored into" for a tree it never wrote is
    # evidence that does not exist.
    for path in "${staging_paths[@]}"; do
      if [[ ! -d $target$path ]]; then
        warn "$snapshot has no $path; the drill restored an incomplete unit"
        exit 1
      fi
    done
    ;;
  dump)
    for path in "${staging_paths[@]}"; do
      if ! with_deadline "$deadline" bash -o pipefail -c \
        '"$1" -r "$2" dump "$3" "$4" | tar -xf - --no-xattrs -C "$5"' _ \
        "$restic_bin" "$repo" "$snapshot" "$path" "$target"; then
        warn "restore failed; $target holds an incomplete tree"
        exit 1
      fi
    done
    ;;
  *)
    warn "unknown RESTIC_DRILL_METHOD: $method (restore or dump)"
    exit 2
    ;;
esac

{
  printf '\nRestored into:\n'
  for path in "${staging_paths[@]}"; do
    printf '  %s%s\n' "$target" "$path"
  done
} >&2
cat <<EOF

The exit status is a gate, not evidence: open a known file, compare ownership and
mode, then remove the tree:
  find "$target" -maxdepth 6 | head
  sudo rm -rf "$target"

A drill is only evidence once the restored file was opened and matched.
EOF
