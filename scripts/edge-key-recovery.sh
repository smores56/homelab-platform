#!/usr/bin/env bash
# Break-glass: place the edge's tailnet auth key where the booting deployment
# actually reads it, on whichever partition carries the deployment.
#
# Two traps this walks around, both of which cost a console round trip:
#
#   1. An ostree host keeps /etc PER DEPLOYMENT:
#        ostree/deploy/<os>/deploy/<checksum>.0/etc   <- what systemd reads
#        ostree/deploy/<os>/etc                       <- a tree nothing mounts
#      `install -d` creates the second silently, so a key can be present, 0600,
#      correctly labelled, and still invisible to LoadCredential.
#   2. /boot also holds an `ostree/` directory (the boot repo), so "has ostree"
#      does not mean "is the root". The script mounts each candidate read-only
#      and looks for the deployment shape instead of trusting a path.
#
# Run from the Fedora CoreOS live ISO:
#
#   curl -fsSL <this file> | sudo bash -s
#
# The key comes from $KEY_FILE, else from any tailscale-authkey already on the
# disks (so a single-use key is never retyped), else from the console.
set -euo pipefail

key_file=${KEY_FILE:-}
explicit=${SYSROOT:-}

die() { printf 'edge-key: %s\n' "$*" >&2; exit 1; }
say() { printf 'edge-key: %s\n' "$*"; }

[[ $(id -u) == 0 ]] || die "run as root: curl -fsSL <file> | sudo bash -s"

mounts=()
cleanup() {
  local m
  for m in "${mounts[@]}"; do
    umount "$m" 2>/dev/null || true
    rmdir "$m" 2>/dev/null || true
  done
}
trap cleanup EXIT

has_deployments() { compgen -G "$1/ostree/deploy/*/deploy/*/etc" >/dev/null; }

key=''
if [[ -n $key_file ]]; then
  [[ -r $key_file ]] || die "$key_file is not readable"
  key=$(cat -- "$key_file")
fi

# A directory the operator already mounted is the cheapest answer; otherwise
# mount each filesystem carrying a real filesystem read-only and look.
rootdirs=()
if [[ -n $explicit ]]; then
  has_deployments "$explicit" || die "$explicit holds no deployment (ostree/deploy/*/deploy/*/etc)"
  rootdirs+=("$explicit")
else
  for cand in /mnt /sysroot; do
    if has_deployments "$cand"; then
      rootdirs+=("$cand")
      break
    fi
  done
fi

if ((${#rootdirs[@]} == 0)); then
  while read -r dev fstype; do
    case $fstype in xfs | ext4 | ext3 | btrfs) ;; *) continue ;; esac
    m=$(mktemp -d)
    if ! mount -o ro "$dev" "$m" 2>/dev/null; then
      rmdir "$m"
      continue
    fi
    mounts+=("$m")
    if [[ -z $key ]]; then
      f=$(find "$m" -maxdepth 6 -name tailscale-authkey -type f -size +20c 2>/dev/null | head -n1 || true)
      if [[ -n $f ]]; then
        key=$(cat -- "$f")
        say "reusing the key already on $dev"
      fi
    fi
    if has_deployments "$m"; then
      say "deployment tree found on $dev"
      rootdirs+=("$m")
    fi
  done < <(lsblk -ln -o PATH,FSTYPE | awk 'NF == 2')
  [[ ${#mounts[@]} -gt 0 ]] || die "no mountable filesystem; lsblk -f: $(lsblk -ln -o NAME,FSTYPE,LABEL | tr '\n' ';')"
fi

((${#rootdirs[@]} > 0)) || die "no partition carries ostree/deploy/*/deploy/*/etc; lsblk -f: $(lsblk -ln -o NAME,FSTYPE,LABEL | tr '\n' ';')"

# A key already written by an earlier attempt, wherever it landed: the first
# version of these instructions created one under a tree nothing mounts, and a
# single-use key must not be retyped to recover from that.
if [[ -z $key ]]; then
  for root in "${rootdirs[@]}"; do
    f=$(find "$root" -maxdepth 6 -name tailscale-authkey -type f -size +20c 2>/dev/null | head -n1 || true)
    if [[ -n $f ]]; then
      key=$(cat -- "$f")
      say "reusing the key already under $root"
      break
    fi
  done
fi

if [[ -z $key ]]; then
  if { true </dev/tty; } 2>/dev/null; then
    read -rsp 'tskey: ' key </dev/tty || true
    printf '\n' >/dev/tty || true
  fi
fi
[[ $key == tskey-* ]] || die "no usable key; pass KEY_FILE=<file> or type one at the prompt"
[[ $key != *[[:space:]]* ]] || die "the key carries whitespace; re-mint it"

rc=0
for root in "${rootdirs[@]}"; do
  # The scan mounted read-only; writing needs it writable.
  if ! touch "$root/.edge-key-probe" 2>/dev/null; then
    mount -o remount,rw "$root" || die "cannot remount $root writable"
  fi
  rm -f -- "$root/.edge-key-probe"

  for d in "$root"/ostree/deploy/*/deploy/*/etc; do
    deployment=$(dirname -- "$d")
    say "== $deployment"
    grep -q . "$deployment/origin" 2>/dev/null && say "   origin: $(cat -- "$deployment/origin")"

    install -d -m 0700 "$d/smoresnet"
    printf '%s\n' "$key" >"$d/smoresnet/tailscale-authkey"
    chmod 0600 "$d/smoresnet/tailscale-authkey"
    # restorecon cannot do this from the live environment: its rules anchor at
    # /, so the mounted path matches nothing and the file stays default_t, which
    # LoadCredential is denied.
    chcon -t etc_t "$d/smoresnet" "$d/smoresnet/tailscale-authkey"
    ls -lZ "$d/smoresnet/tailscale-authkey" | sed 's/^/   /'

    unit=$deployment/usr/lib/systemd/system/smoresnet-tailscale-up.service
    if [[ -f $unit ]]; then
      say "   unit: present"
    else
      say "   unit: MISSING -- this deployment predates the edge image; do not boot it"
      rc=1
    fi
    wants=$d/systemd/system/multi-user.target.wants/smoresnet-tailscale-up.service
    if [[ -e $wants || -L $wants ]]; then
      say "   enabled: yes"
    else
      say "   enabled: NO -- the join will not run at boot"
      rc=1
    fi
  done
  sync
done

# Drop any invented ostree/deploy/<os>/etc tree so a later reader is not told it
# is the system's /etc.
for root in "${rootdirs[@]}"; do
  for invented in "$root"/ostree/deploy/*/etc; do
    [[ -d $invented ]] || continue
    [[ $(ls -A "$invented" 2>/dev/null) == smoresnet ]] || continue
    rm -rf -- "$invented"
    say "removed the stray tree $invented (it is not a deployment)"
  done
done

((rc == 0)) || die "a deployment above is incomplete; report it before rebooting"

say "done. next, in this order:"
say "  1. delete the ghost 'smoresnet' device in the Tailscale admin console"
say "  2. panel: boot device Hard Disk"
say "  3. sync; reboot            (this script unmounts what it mounts)"
say "  4. tailscale status | grep -i smoresnet"
