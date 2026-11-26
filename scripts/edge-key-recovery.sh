#!/usr/bin/env bash
# Break-glass: place the edge's tailnet auth key where the booting deployment
# actually reads it.
#
# An ostree host keeps /etc PER DEPLOYMENT:
#
#   /ostree/deploy/<os>/deploy/<checksum>.0/etc      <- what systemd reads
#   /ostree/deploy/<os>/etc                          <- a tree nothing mounts
#
# The second path is the trap. `install -d` creates it without complaint, so a
# key can sit there at 0600 with the right SELinux label and the join unit still
# finds nothing -- LoadCredential reads /etc/smoresnet/tailscale-authkey of the
# booted deployment and nothing else. This script writes every deployment, which
# is what makes it correct without knowing which checksum the box booted.
#
# Run from the Fedora CoreOS live ISO, with the installed root mounted:
#
#   curl -fsSL <this file> | sudo bash -s
#
# The key is taken from the stray tree above if it is there (so a single-use key
# is never retyped), else from $KEY_FILE, else from the console.
set -euo pipefail

sysroot=${SYSROOT:-/mnt}
key_file=${KEY_FILE:-}

die() { printf 'edge-key: %s\n' "$*" >&2; exit 1; }
say() { printf 'edge-key: %s\n' "$*"; }

[[ $(id -u) == 0 ]] || die "run as root: curl -fsSL <file> | sudo bash -s"
[[ -d $sysroot/ostree ]] ||
  die "$sysroot holds no ostree tree; mount the root partition there first (lsblk -f)"

mapfile -t etcs < <(ls -d "$sysroot"/ostree/deploy/*/deploy/*/etc 2>/dev/null || true)
((${#etcs[@]})) ||
  die "no deployment under $sysroot/ostree/deploy; wrong partition or wrong sysroot (SYSROOT=...)"

# The first attempt's leftover, if any: a key already typed once, so the operator
# does not have to mint another single-use one.
stray=$(ls "$sysroot"/ostree/deploy/*/etc/*/tailscale-authkey 2>/dev/null | head -n1 || true)
key=''
if [[ -n $key_file ]]; then
  [[ -r $key_file ]] || die "$key_file is not readable"
  key=$(cat -- "$key_file")
elif [[ -n $stray && -s $stray ]]; then
  key=$(cat -- "$stray")
  say "reusing the key at $stray"
elif { true </dev/tty; } 2>/dev/null; then
  read -rsp 'tskey: ' key </dev/tty || true
  printf '\n' >/dev/tty || true
fi
[[ $key == tskey-* ]] ||
  die "no usable key${key:+ (it starts '${key:0:11}', want tskey-...)}; pass KEY_FILE=<file>"

# A key with whitespace in it is a truncated paste, and the column after it would
# be the next argument tailscale never sees.
[[ $key != *[[:space:]]* ]] || die "the key carries whitespace; re-mint it"

rc=0
for d in "${etcs[@]}"; do
  deployment=$(dirname -- "$d")
  say "== $deployment"
  grep -q . "$deployment/origin" 2>/dev/null && say "   origin: $(cat -- "$deployment/origin")"

  install -d -m 0700 "$d/smoresnet"
  printf '%s\n' "$key" >"$d/smoresnet/tailscale-authkey"
  chmod 0600 "$d/smoresnet/tailscale-authkey"
  # Without the type, LoadCredential is denied and the unit fails before
  # `tailscale up` runs. restorecon cannot do this from the live environment:
  # its rules are anchored at /, so /mnt/... matches nothing and stays default_t.
  chcon -t etc_t "$d/smoresnet" "$d/smoresnet/tailscale-authkey"
  ls -lZ "$d/smoresnet/tailscale-authkey"

  unit=$deployment/usr/lib/systemd/system/smoresnet-tailscale-up.service
  if [[ -f $unit ]]; then
    say "   unit: present"
  else
    say "   unit: MISSING -- this deployment predates the edge image; do not boot it"
    rc=1
  fi
  wants=$d/systemd/system/multi-user.target.wants/smoresnet-tailscale-up.service
  # A dangling link is still an enablement the image meant to make; -L covers it
  # because the target is inside a deployment that is not mounted at / here.
  if [[ -e $wants || -L $wants ]]; then
    say "   enabled: yes"
  else
    say "   enabled: NO -- the join will not run at boot"
    rc=1
  fi
done

# Drop the tree the first attempt invented, so a later reader is not told it is
# the system's /etc.
if [[ -n $stray ]]; then
  invented=$(dirname -- "$(dirname -- "$stray")")
  if [[ $(ls -A "$invented" 2>/dev/null) == smoresnet ]]; then
    rm -rf -- "$invented"
    say "removed the stray tree $invented (it is not a deployment)"
  fi
fi

if ((rc != 0)); then
  die "a deployment above is incomplete; report it before rebooting"
fi

say "done. next, in this order:"
say "  1. delete the ghost 'smoresnet' device in the Tailscale admin console"
say "  2. panel: boot device Hard Disk"
say "  3. sync; sudo umount $sysroot; sudo reboot"
say "  4. tailscale status | grep -i smoresnet"
