#!/usr/bin/env bash
# Fail unless one childless recovery-group dataset is actually mounted at its
# expected mountpoint. A directory that merely exists is not proof: it may be
# the empty root-filesystem path an application would write into.
set -euo pipefail

group=${1:-}
if [[ -z $group || $group == */* ]]; then
  echo "usage: zfs-ready <group>" >&2
  exit 2
fi

dataset="tank/$group"
mountpoint="/var/tank/$group"

if ! zfs list -H -o name "$dataset" >/dev/null 2>&1; then
  echo "zfs-ready: dataset $dataset does not exist" >&2
  exit 1
fi

if [[ $(zfs get -H -o value mounted "$dataset") != yes ]]; then
  echo "zfs-ready: dataset $dataset is not mounted" >&2
  exit 1
fi

if [[ $(zfs get -H -o value mountpoint "$dataset") != "$mountpoint" ]]; then
  echo "zfs-ready: $dataset mountpoint is not $mountpoint" >&2
  exit 1
fi

# /proc/self/mountinfo field 5 is the mount point. Compare it exactly so a
# bind mount or a same-named directory on the root filesystem cannot pass.
if ! awk -v mp="$mountpoint" '$5 == mp { found = 1 } END { exit !found }' /proc/self/mountinfo; then
  echo "zfs-ready: nothing is mounted at $mountpoint" >&2
  exit 1
fi

echo "zfs-ready: $dataset is mounted at $mountpoint"
