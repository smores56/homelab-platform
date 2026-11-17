#!/usr/bin/env bash
# shellcheck disable=SC2154  # the table and its helpers come from storage-layout.sh
# Fail unless one childless dataset is actually mounted at its expected
# mountpoint. A directory that merely exists is not proof: it may be the empty
# root-filesystem path an application would write into.
#
#   zfs-ready raw-files
#   zfs-ready state-immich-postgres
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
layout=${STORAGE_LAYOUT:-$here/storage-layout}
[[ -r $layout ]] || layout=$layout.sh
# shellcheck source=/dev/null
source "$layout"

instance=${1:-}
key=$(readiness_key "$instance") || {
  echo "usage: zfs-ready <raw-|state-><name>" >&2
  exit 2
}
if [[ -z ${dataset_mount[$key]:-} ]]; then
  echo "zfs-ready: unknown dataset: $key" >&2
  exit 2
fi

dataset=$(dataset_name "$key")
mountpoint=$(mountpoint_for "$key")

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
if ! awk -v mp="$mountpoint" '$5 == mp { found = 1 } END { exit !found }' "${ZFS_READY_MOUNTINFO:-/proc/self/mountinfo}"; then
  echo "zfs-ready: nothing is mounted at $mountpoint" >&2
  exit 1
fi

echo "zfs-ready: $dataset is mounted at $mountpoint"
