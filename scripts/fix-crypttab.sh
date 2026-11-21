#!/usr/bin/env bash
# Keep the data LUKS out of the initramfs.
#
# The data entry is written by smortress-data-init.service, without an initramfs
# attach flag. An install from before that unit had Ignition write it with
# `x-initrd.attach`, which tells Dracut to attach the device in the initramfs —
# and to copy its key file there, i.e. onto the unencrypted /boot. The device
# only needs to open after root (its key lives on the encrypted root), so the
# flag is removed once, before the next kernel update rebuilds the initramfs.
set -euo pipefail

readonly crypttab=/etc/crypttab

[[ -f $crypttab ]] || exit 0
if grep -qE '^data[[:space:]].*x-initrd\.attach' "$crypttab"; then
  sed -i '/^data[[:space:]]/s/,x-initrd\.attach//' "$crypttab"
  echo "fix-crypttab: removed x-initrd.attach from the data entry"
else
  echo "fix-crypttab: data entry already excluded from the initramfs"
fi
