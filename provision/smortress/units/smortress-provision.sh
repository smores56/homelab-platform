#!/bin/sh
# Create tank once, on the encrypted data mapper, with the properties
# roles/zfs applies. A present pool is adopted instead of recreated, so a retry
# after a partial first boot is safe.
set -eu

marker=/var/lib/smortress/pool-created

if zpool list -H -o name tank >/dev/null 2>&1; then
  install -d -m 0755 /var/lib/smortress
  : >"$marker"
  exit 0
fi

zpool create -f \
  -o ashift=12 \
  -o cachefile=none \
  -O compression=zstd \
  -O atime=off \
  -O xattr=sa \
  -O acltype=posixacl \
  -O mountpoint=none \
  -O canmount=off \
  tank /dev/mapper/luks-data

install -d -m 0755 /var/lib/smortress
: >"$marker"
