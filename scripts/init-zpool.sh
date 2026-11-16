#!/usr/bin/env bash
# Create the single-vdev tank pool on first boot, or import it afterwards.
# The pool deliberately keeps cachefile=none: the encrypted device name is
# stable and a stale cache would point at a device that no longer exists.
set -euo pipefail

readonly device=/dev/mapper/data
readonly pool=tank
readonly groups=(photos books notes music wallpapers)

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
      "$pool" "$device"
  fi
fi

zpool set cachefile=none "$pool"

install -d -m 0755 /var/tank

for group in "${groups[@]}"; do
  dataset="$pool/$group"
  if ! zfs list -H -o name "$dataset" >/dev/null 2>&1; then
    zfs create -o canmount=on -o mountpoint="/var/tank/$group" "$dataset"
  else
    zfs set canmount=on "$dataset"
    zfs set mountpoint="/var/tank/$group" "$dataset"
  fi
  zfs mount "$dataset" 2>/dev/null || true
done

echo "init-zpool: $pool is present with ${#groups[@]} recovery groups"
