#!/usr/bin/env bash
# Unlock the existing 5 TB HDD LUKS container with a root-only keyfile.
# Unconfigured or absent hardware is a normal, logged condition; the unit runs
# this with a leading '-' so it can never block boot. T3 alerts on backup
# staleness when the HDD stays unavailable.
set -euo pipefail

readonly device_file=/etc/smortress/hdd-device
readonly key_file=/var/lib/homelab/keys/hdd.key
readonly mapper=luks-hdd

if [[ ! -s $device_file ]]; then
  echo "open-hdd: $device_file is absent; HDD not configured yet"
  exit 0
fi

if [[ ! -s $key_file ]]; then
  echo "open-hdd: $key_file is absent; stage it from the recovery kit" >&2
  exit 1
fi

read -r device <"$device_file"
if [[ ! -e $device ]]; then
  echo "open-hdd: $device is absent; HDD unplugged"
  exit 0
fi

if [[ -e /dev/mapper/$mapper ]]; then
  echo "open-hdd: /dev/mapper/$mapper is already open"
  exit 0
fi

cryptsetup open --type luks --key-file "$key_file" --allow-discards "$device" "$mapper"
echo "open-hdd: opened $mapper from $device"
