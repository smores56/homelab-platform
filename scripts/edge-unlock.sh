#!/usr/bin/env bash
# Break-glass, step two: put a key in place AND give yourself a way back in.
#
# Two facts make this necessary. The image admits no public 22 at all (the
# public zone is 443, 41641/udp and ICMP echo), so a failed tailnet join leaves a
# box reachable by ping and nothing else. And a failed join is invisible from
# outside: the only evidence is the unit's journal, which needs a shell to read.
#
# So this writes the key where the booting deployment reads it, and adds
# ssh to the public zone for the next boot. SSH is key-only on this image, and
# the rule goes away with the next image that ships a pre-join window properly
# (design #939 T4/T5) -- until then it is the difference between debugging over
# ssh and debugging through a VNC console.
#
# Run from the Fedora CoreOS live ISO:
#
#   curl -fsSL <this file> | sudo bash -s
#
# A fresh key comes from $KEY_FILE, else any tailscale-authkey on the disk is
# reused. Close the window afterwards with:
#
#   sudo sed -i '/<service name="ssh"\/>/d' /usr/share/smoresnet/firewalld/zones/public.xml
#   sudo firewall-cmd --reload
set -euo pipefail

key_file=${KEY_FILE:-}
explicit=${SYSROOT:-}

die() { printf 'edge-unlock: %s\n' "$*" >&2; exit 1; }
say() { printf 'edge-unlock: %s\n' "$*"; }

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

rootdirs=()
if [[ -n $explicit ]]; then
  has_deployments "$explicit" || die "$explicit holds no deployment"
  rootdirs+=("$explicit")
elif has_deployments /mnt; then
  rootdirs+=("/mnt")
else
  while read -r dev fstype; do
    case $fstype in xfs | ext4 | ext3 | btrfs) ;; *) continue ;; esac
    m=$(mktemp -d)
    if ! mount -o ro "$dev" "$m" 2>/dev/null; then
      rmdir "$m"
      continue
    fi
    mounts+=("$m")
    if has_deployments "$m"; then
      say "deployment tree on $dev"
      rootdirs+=("$m")
    fi
  done < <(lsblk -ln -o PATH,FSTYPE | awk 'NF == 2')
fi
((${#rootdirs[@]} > 0)) || die "no deployment found; lsblk -f: $(lsblk -ln -o NAME,FSTYPE,LABEL | tr '\n' ';')"

if [[ -z $key ]]; then
  for root in "${rootdirs[@]}"; do
    f=$(find "$root" -maxdepth 6 -name tailscale-authkey -type f -size +20c 2>/dev/null | head -n1 || true)
    if [[ -n $f ]]; then
      key=$(cat -- "$f")
      say "reusing the key already on disk"
      break
    fi
  done
fi
if [[ -z $key ]] && { true </dev/tty; } 2>/dev/null; then
  read -rsp 'tskey: ' key </dev/tty || true
  printf '\n' >/dev/tty || true
fi
[[ $key == tskey-* ]] || die "no usable key; mint one and pass KEY_FILE=<file>"
[[ $key != *[[:space:]]* ]] || die "the key carries whitespace; re-mint it"

rc=0
wrote=0
for root in "${rootdirs[@]}"; do
  if ! touch "$root/.edge-unlock-probe" 2>/dev/null; then
    if ! mount -o remount,rw "$root" 2>/dev/null; then
      say "skipping $root: read-only and not remountable"
      continue
    fi
  fi
  rm -f -- "$root/.edge-unlock-probe"
  wrote=$((wrote + 1))

  for d in "$root"/ostree/deploy/*/deploy/*/etc; do
    deployment=$(dirname -- "$d")
    say "== $deployment"

    install -d -m 0700 "$d/smoresnet"
    printf '%s\n' "$key" >"$d/smoresnet/tailscale-authkey"
    chmod 0600 "$d/smoresnet/tailscale-authkey"
    chcon -t etc_t "$d/smoresnet" "$d/smoresnet/tailscale-authkey"

    # The zone the boot copies into /etc/firewalld/zones; smoresnet-firewall-zones
    # rewrites /etc from here on every boot, so this is the one place an edit
    # survives.
    zone=$deployment/usr/share/smoresnet/firewalld/zones/public.xml
    if [[ -f $zone ]]; then
      if ! grep -q '<service name="ssh"/>' "$zone"; then
        sed -i 's#^</zone>$#  <service name="ssh"/>\n</zone>#' "$zone"
        say "   opened ssh on the public zone (temporary)"
      else
        say "   ssh already open on the public zone"
      fi
      chcon -t usr_t "$zone" 2>/dev/null || true
    else
      say "   no public zone at $zone -- this deployment has no edge firewall"
      rc=1
    fi

    unit=$deployment/usr/lib/systemd/system/smoresnet-tailscale-up.service
    [[ -f $unit ]] || { say "   unit: MISSING"; rc=1; }
    wants=$d/systemd/system/multi-user.target.wants/smoresnet-tailscale-up.service
    [[ -e $wants || -L $wants ]] || { say "   enabled: NO"; rc=1; }
  done
  sync
done

((wrote > 0)) || die "found deployment trees but none writable"
((rc == 0)) || die "a deployment above is incomplete; report it before rebooting"

say "done: a key is in place and public 22 will be open on the next boot"
say "next: panel -> Hard Disk -> reboot"
say "then: ssh -i ~/.ssh/id_smortress root@192.236.188.99"
say "and read: journalctl -u smoresnet-tailscale-up.service -b --no-pager"
say "close the window when the join works:"
say "  sudo sed -i '/<service name=\"ssh\"\\/>/d' /usr/share/smoresnet/firewalld/zones/public.xml && sudo firewall-cmd --reload"
