#!/usr/bin/env bash
# Create the data LUKS container on the host's first boot.
#
# Ignition creates p5 (`luks-data`) unformatted and carries no key for it (design
# #701: no secret enters Ignition or the installer media). This oneshot
# generates the key file from the kernel RNG inside the encrypted root, formats
# the partition with it, writes the crypttab entry and opens the device that
# smortress-zpool.service creates the pool on. It is idempotent: an already
# formatted device, an existing key file and an open mapper are all left alone,
# so the unit runs on every boot and only the first one formats anything.
set -euo pipefail

readonly device=/dev/disk/by-partlabel/luks-data
readonly name=data
readonly mapper=/dev/mapper/$name
readonly keydir=/etc/luks
readonly keyfile=$keydir/$name
readonly crypttab=/etc/crypttab

if [[ ${1:-} == --print-plan ]]; then
  printf '%s %s %s\n' "$name" "$device" "$keyfile"
  exit 0
fi
[[ -z ${1:-} ]] || { echo "usage: init-data-luks [--print-plan]" >&2; exit 2; }

# The partlabel node is udev's, and this unit is ordered before cryptsetup.target
# and the pool, not after udev settled. Bounded wait, then fail loudly: the pool
# unit fails with it, and nothing creates data on a device that is not there.
for _ in {1..30}; do
  [[ -e $device ]] && break
  sleep 1
done
if [[ ! -e $device ]]; then
  echo "init-data-luks: $device is missing; the installer did not create p5" >&2
  exit 1
fi

# 0400 root: only the root filesystem, on this host, can read it. Written to a
# sibling and renamed so a crash mid-write cannot leave a truncated key.
install -d -m 0700 -o root -g root "$keydir"
if [[ ! -s $keyfile ]]; then
  ( umask 077; head -c 64 /dev/urandom | base64 >"$keyfile.new" )
  chmod 0400 "$keyfile.new"
  mv -f "$keyfile.new" "$keyfile"
  echo "init-data-luks: generated $keyfile from the kernel RNG"
else
  chmod 0400 "$keyfile"
fi

if ! cryptsetup isLuks "$device"; then
  # No --allow-discards here: current cryptsetup rejects it on luksFormat, and a
  # first boot that fails here leaves p5 unformatted and the pool unit with no
  # device. The flag is an open-time option, persisted into the LUKS2 header by
  # the open below with --persistent.
  cryptsetup luksFormat --batch-mode --type luks2 --label luks-data \
    --key-file "$keyfile" "$device"
  echo "init-data-luks: formatted $device with $keyfile"
fi

# systemd-cryptsetup-generator builds systemd-cryptsetup@data.service from this
# entry alone, and the pool unit is ordered after it: the entry is written before
# the first open so every later boot takes the same path. `nofail` keeps an
# unopenable data device off the boot critical path, and the entry is not marked
# for the initramfs: the key lives on the encrypted root, so the device must only
# ever open after root.
if ! grep -qE "^${name}[[:space:]]" "$crypttab" 2>/dev/null; then
  printf '%s %s %s luks,discard,nofail\n' "$name" "$device" "$keyfile" >>"$crypttab"
  echo "init-data-luks: wrote the $name entry to $crypttab"
fi

if [[ ! -e $mapper ]]; then
  # --persistent records the discard flag in the LUKS2 header, the same setting
  # Ignition wrote for the root volume, so every later boot keeps TRIM.
  cryptsetup open --allow-discards --persistent --key-file "$keyfile" "$device" "$name"
  echo "init-data-luks: opened $mapper"
else
  echo "init-data-luks: $mapper is already open"
fi
