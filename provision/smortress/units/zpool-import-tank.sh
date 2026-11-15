#!/bin/sh
# Import tank on every boot after the pool exists. With cachefile=none there is
# no import cache, so the mapper is scanned directly. A missing or closed mapper
# fails this unit without blocking boot; consumers fail closed on their own.
set -eu

if zpool list -H -o name tank >/dev/null 2>&1; then
  exit 0
fi

zpool import -N -d /dev/mapper/luks-data tank
