#!/usr/bin/env bash
# shellcheck disable=SC2154  # the table and its helpers come from storage-layout.sh
# Create the single-vdev pool on first boot, or import it afterwards, then make
# every dataset in the storage table present at its mountpoint.
#
# The pool deliberately keeps cachefile=none: the encrypted device name is
# stable and a stale cache would point at a device that no longer exists.
#
#   init-zpool              create or reconcile the pool and its datasets
#   init-zpool --print-plan print "<dataset> <mountpoint>" per dataset, no side effects
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
layout=${STORAGE_LAYOUT:-$here/storage-layout}
[[ -r $layout ]] || layout=$layout.sh
# shellcheck source=/dev/null
source "$layout"

readonly device=${ZPOOL_DEVICE:-/dev/mapper/data}

if [[ ${1:-} == --print-plan ]]; then
  for key in "${dataset_order[@]}"; do
    printf '%s %s\n' "$(dataset_name "$key")" "$(mountpoint_for "$key")"
  done
  exit 0
fi
[[ -z ${1:-} ]] || { echo "usage: init-zpool [--print-plan]" >&2; exit 2; }

if [[ ! -e $device ]]; then
  echo "init-zpool: $device is missing; data LUKS was not opened" >&2
  exit 1
fi

if ! zpool list -H -o name "$pool" >/dev/null 2>&1; then
  # A device with a ZFS label already holds a pool: import it. Creating over it
  # would either fail confusingly or, with a damaged label, produce an empty
  # pool that looks like data loss.
  if blkid -o value -s TYPE "$device" 2>/dev/null | grep -q zfs_member; then
    zpool import -d /dev/mapper "$pool" || {
      echo "init-zpool: $device holds a pool that will not import; refusing to create" >&2
      exit 1
    }
  else
    zpool create -o cachefile=none -o ashift=12 \
      -O mountpoint=none -O canmount=off \
      -O compression=zstd -O atime=off -O xattr=sa -O acltype=posixacl \
      -O aclmode="$dataset_acl_mode" \
      "$pool" "$device"
  fi
fi

zpool set cachefile=none "$pool"
# Both paths converge here: a freshly created pool inherits it from the create
# above, a pool imported from disk does not. Children inherit either way.
zfs set "aclmode=$dataset_acl_mode" "$pool"

# Parents of state datasets are plain directories: a cache or a version history
# is rebuilt, not restored, so it gets no dataset and no snapshot.
install -d -m 0755 /var/srv "${state_parents[@]}"

# A child cannot be created before its parent, and neither parent is mounted.
for parent in "${dataset_parents[@]}"; do
  if ! zfs list -H -o name "$pool/$parent" >/dev/null 2>&1; then
    zfs create -o mountpoint=none -o canmount=off "$pool/$parent"
  fi
done

for key in "${dataset_order[@]}"; do
  dataset=$(dataset_name "$key")
  mountpoint=$(mountpoint_for "$key")
  if ! zfs list -H -o name "$dataset" >/dev/null 2>&1; then
    zfs create -o canmount=on -o mountpoint="$mountpoint" "$dataset"
  else
    zfs set canmount=on "$dataset"
    zfs set mountpoint="$mountpoint" "$dataset"
  fi
  zfs mount "$dataset" 2>/dev/null || true
  # An unmounted dataset leaves an empty directory on the root filesystem; give
  # it the application's ownership only when the dataset really is mounted under
  # it, so nothing here can carry a permission onto the wrong tree.
  if mountpoint -q "$mountpoint"; then
    # A core dataset belongs to uid 1000: it is what lets a restored tree be
    # written without a manual chown. Restic still reads as root. The mode is
    # 0750 so the tenant user cannot read it; the tenant's own dataset belongs
    # to the tenant account and is 0700.
    chown "$(dataset_owner_for "$key")" "$mountpoint"
    chmod "$(dataset_mode_for "$key")" "$mountpoint"
    # Only now, and never before: chmod re-derives the ACL mask, so a grant
    # applied above it would survive as an entry with no effect -- which is how
    # the general plane lost its write access to /srv/git (SDLC #1009). `set -e`
    # is on, so a failure here stops the boot rather than leaving a tree the
    # plane cannot use while everything still looks healthy.
    if acl=$(dataset_acl_for "$key") && [[ -n $acl ]]; then
      setfacl -R -m "$acl" -- "$mountpoint"
      setfacl -R -m "$(dataset_acl_default_for "$key")" -- "$mountpoint"
    fi
    # Only the tenant's dataset has a quota in the table today; the applier
    # re-asserts it at every deploy, this makes the first boot match.
    if [[ -n ${dataset_quota[$key]:-} ]]; then
      zfs set "quota=${dataset_quota[$key]}" "$dataset"
    fi
  else
    echo "init-zpool: $dataset is not mounted at $mountpoint" >&2
    exit 1
  fi
done

echo "init-zpool: $pool is present with ${#dataset_order[@]} datasets and ${#units[@]} restore units"
