#!/usr/bin/env bash
# Restore-drill helper for the smortress Restic plane (SDLC #706, T3).
#
#   smortress-restic-restore-drill <ssd|hdd|r2> <group> [--snapshot <id>]
#                                   [--target <dir>] [--list]
#
# This is the by-hand path from docs/core/restic-plane.md: it selects a
# `verified` snapshot (never an untagged or incomplete one), restores it into a
# fresh directory under /var/tmp and verifies the written data. It never
# restores over a live dataset and never touches retention.
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
usage: smortress-restic-restore-drill <ssd|hdd|r2> <group> [options]

  --snapshot <id>  restore this snapshot instead of the latest verified one
  --target <dir>   restore here (default /var/tmp/restic-drill/<backend>-<group>-<time>)
  --list           print the verified snapshots and exit

The restore lands under <target>/var/tank/<group>/.zfs/snapshot/<backend>/,
because that is the absolute path the backup recorded.
EOF
}

[[ $# -ge 2 ]] || { usage; exit 2; }
backend=$1
group=$2
shift 2
case $backend in ssd | hdd | r2) ;; *) usage; exit 2 ;; esac
printf '%s\n' "${groups[@]}" | grep -qx -- "$group" || {
  warn "unknown group: $group"
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

staging=$(staging_for "$group" "$backend")
deadline=${RESTIC_DEADLINE_DRILL:-14400}

if ! json=$(with_deadline "$(job_deadline "$backend")" "$restic_bin" -r "$repo" \
  snapshots --json --no-lock --host "$restic_host" --path "$staging" \
  --tag "group:$group" --tag verified); then
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
    warn "snapshot $snapshot is not a verified snapshot of $backend/$group"
    exit 1
  fi
else
  snapshot=$(jq -r 'sort_by(.time) | last | .id // empty' <<<"$json")
  if [[ -z $snapshot ]]; then
    warn "$backend/$group has no verified snapshot; nothing to restore"
    exit 1
  fi
fi

if [[ -z $target ]]; then
  target=/var/tmp/restic-drill/$backend-$group-$(date -u +%Y%m%dT%H%M%SZ)
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

say "$backend/$group: restoring $snapshot into $target"
# restic restore clears xattrs on every file it writes, and SELinux denies
# removing security.selinux even for root (lremovexattr, not setxattr). A dump
# piped through tar --no-xattrs restores content, modes and ownership without
# needing CAP_MAC_ADMIN; the label is reapplied by the system on the real target.
if ! with_deadline "$deadline" bash -o pipefail -c \
  '"$1" -r "$2" dump "$3" "$4" | tar -xf - --no-xattrs -C "$5"' _ \
  "$restic_bin" "$repo" "$snapshot" "$staging" "$target"; then
  warn "restore failed; $target holds an incomplete tree"
  exit 1
fi

cat <<EOF

Restored into:
  $target/var/tank/$group/.zfs/snapshot/$backend

Check the contents, not the exit status: compare a known file and ownership,
then remove the tree:
  find "$target" -maxdepth 6 | head
  sudo rm -rf "$target"

A drill is only evidence once the restored file was opened and matched.
EOF
