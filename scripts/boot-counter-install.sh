#!/usr/bin/env bash
# Install greenboot's GRUB snippet where this host's grub.cfg actually reads it.
#
# Both images ship this one program: a counter is a property of the boot loader,
# not of a host's role, and two copies of it would be two chances to drift.
#
# grub.cfg is generated once by bootupd, which reports every component current
# and will not regenerate (bootc/edge/runbook.md, "There is no boot counting
# on this box"), so the snippet greenboot ships in
# /usr/lib/bootupd/grub2-static/configs.d/ never reaches it and the counter it
# implements never runs. grub.cfg ends with `41_custom.cfg`, which sources
# /boot/grub2/custom.cfg when that file exists; that hook is the whole reason
# the counter needs no bootupd, and it survives a regeneration of grub.cfg
# because 41_custom.cfg is one of the generator's own inputs.
#
# Each image keeps greenboot's script under /usr/share and removes the package's
# copy from bootupd's directory, so a regeneration cannot install it twice: two
# passes in one boot would spend two of the three attempts. The content is
# greenboot's own, byte for byte -- its package is the definition of boot_success
# and boot_counter, and a copy written here would be a second answer to a
# question the package already answers.
set -euo pipefail

_smolib=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/log.sh
[[ -r $_smolib ]] || _smolib=/usr/libexec/lib/log.sh
# shellcheck source=/dev/null
source "$_smolib"

snippet=${BOOT_COUNTER_SNIPPET:-/usr/share/smoresnet/boot-counter.cfg}
boot_dir=${BOOT_COUNTER_BOOT_DIR:-/boot}
target=$boot_dir/grub2/custom.cfg
mount_bin=${MOUNT_BIN:-mount}

if [[ ! -r $snippet ]]; then
  # The image installs greenboot; a host without the snippet has no counter and
  # no way to acquire one, which is a gap the journal has to name.
  warn "$snippet is missing: the image's boot counter snippet was not installed and this host has no counter"
  exit 1
fi

if cmp -s -- "$snippet" "$target" 2>/dev/null; then
  say "the boot counter is already installed at $target"
  exit 0
fi

# /boot arrives read-only. smoresnet-boot-rw.service remounts it before this
# unit, and this is the belt to its braces for a boot where it did not run: an
# unwritable /boot is a counter greenboot cannot arm, never a failed boot.
if ! : >"$boot_dir/.counter-write-probe" 2>/dev/null; then
  "$mount_bin" -o remount,rw "$boot_dir" || {
    warn "cannot make $boot_dir writable: the boot counter was not installed"
    exit 1
  }
fi
rm -f -- "$boot_dir/.counter-write-probe"

install -m 0644 -- "$snippet" "$target"
sync

grep -q 'boot_counter' "$target" || {
  warn "$target does not read boot_counter after installation"
  exit 1
}
say "installed the boot counter at $target"
