#!/usr/bin/env bash
# End-to-end proof for the smortress autoinstall: install into a synthetic disk,
# shellcheck disable=SC2016,SC2329 # remote scripts are quoted literals; has/lacks go via check()
# stop at the reboot, boot it, unlock root, and assert the result.
#
# Requires: qemu, xorriso, curl, gnupg, socat, openssh (and swtpm for --tpm).
# Environment:
#   SMORTRESS_SSH_KEY        private key for ansible@smortress (default ~/.ssh/smortress-bootstrap)
#   SMORTRESS_SSH_PUBKEY     public key for the seed   (default "$SMORTRESS_SSH_KEY.pub")
#   SMORTRESS_ROOT_PASSPHRASE_FILE  default ~/.config/smortress/luks-root.passphrase
#   SMORTRESS_WORK           scratch dir (default mktemp -d)
set -euo pipefail

here=$(cd -- "$(dirname -- "$0")" && pwd)
key=${SMORTRESS_SSH_KEY:-"$HOME/.ssh/smortress-bootstrap"}
pub=${SMORTRESS_SSH_PUBKEY:-"$key.pub"}
pass_file=${SMORTRESS_ROOT_PASSPHRASE_FILE:-"$HOME/.config/smortress/luks-root.passphrase"}
work=${SMORTRESS_WORK:-$(mktemp -d)}
port=${SMORTRESS_VERIFY_PORT:-2240}
disk=$work/verify.qcow2
vars=$work/vars.fd
seed=$work/seed.iso
log=$work/console.log
ssh="ssh -i $key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 -o LogLevel=ERROR -p $port ansible@127.0.0.1"

fail=0
check() {
  local name=$1
  shift
  if "$@"; then printf 'PASS %s\n' "$name"; else printf 'FAIL %s\n' "$name" >&2; fail=1; fi
}
remote() { local b64; b64=$(printf '%s' "$1" | base64 -w0); $ssh "echo $b64 | base64 -d | sudo -n sh"; }

for tool in qemu-system-x86_64 qemu-img xorriso socat curl gpgv; do
  command -v "$tool" >/dev/null 2>&1 || { echo "verify: missing $tool" >&2; exit 2; }
done
[ -f "$key" ] && [ -f "$pub" ] || { echo "verify: SSH key pair not found" >&2; exit 2; }
[ -f "$pass_file" ] || { echo "verify: passphrase file not found" >&2; exit 2; }

echo "== installing =="
# A throwaway host key: the point is that the seeded key is the installed one.
hostkey=$work/ssh_host_ed25519_key
ssh-keygen -q -t ed25519 -N '' -f "$hostkey" >/dev/null
seeded_hostkey=$(ssh-keygen -y -P '' -f "$hostkey" | cut -d' ' -f1,2)
SMORTRESS_CACHE=$work SMORTRESS_SEED=$seed SMORTRESS_DISK_SERIAL=SMORTRESS980 \
  SMORTRESS_SSH_KEY=$pub SMORTRESS_HOST_KEY=$hostkey "$here/build-seed.sh" >/dev/null

setsid env SMORTRESS_SEED="$seed" SMORTRESS_OVMF_VARS="$vars" \
  SMORTRESS_SPIKE_DISK="$disk" SMORTRESS_SPIKE_SSH_PORT="$port" \
  SMORTRESS_SPIKE_SERIAL_SOCKET="$work/serial.sock" \
  "$here/spike.sh" >/dev/null 2>&1 &
installer=$!
session=
trap 'kill -- -$installer 2>/dev/null || true; kill -- -$session 2>/dev/null || true' EXIT

for _ in $(seq 1 120); do [ -S "$work/serial.sock" ] && break; sleep 1; done
[ -S "$work/serial.sock" ] || { echo "verify: installer never started" >&2; exit 1; }

mkfifo "$work/in"
cat "$work/in" | socat - "UNIX-CONNECT:$work/serial.sock" > "$log" &
exec 3>"$work/in"

for _ in $(seq 1 900); do
  if grep -q 'finish: subiquity/Install/install:' "$log" 2>/dev/null; then break; fi
  if grep -q 'An error occurred' "$log" 2>/dev/null; then
    echo "verify: autoinstall failed" >&2
    tail -30 "$log" >&2
    exit 1
  fi
  sleep 1
done
kill -- -$installer 2>/dev/null || true
sleep 3
kill -- -$installer 2>/dev/null || true

echo "== booting the installed disk =="
setsid env SMORTRESS_SPIKE_BOOT=disk SMORTRESS_OVMF_VARS="$vars" \
  SMORTRESS_SPIKE_DISK="$disk" SMORTRESS_SPIKE_SSH_PORT="$port" \
  SMORTRESS_SPIKE_SERIAL_SOCKET="$work/boot.sock" \
  "$here/spike.sh" >/dev/null 2>&1 &
session=$!
trap 'kill -- -$session 2>/dev/null || true' EXIT
for _ in $(seq 1 60); do [ -S "$work/boot.sock" ] && break; sleep 1; done
rm -f "$work/in2"
mkfifo "$work/in2"
: > "$log"
cat "$work/in2" | socat - "UNIX-CONNECT:$work/boot.sock" > "$log" &
exec 4>"$work/in2"

for _ in $(seq 1 90); do grep -qi 'passphrase for disk luks-root' "$log" 2>/dev/null && break; sleep 2; done
printf '%s\n' "$(cat "$pass_file")" >&4
for _ in $(seq 1 90); do $ssh true 2>/dev/null && break; sleep 2; done
if ! $ssh true 2>/dev/null; then
  echo "verify: installed host never came up" >&2
  tail -20 "$log" >&2
  exit 1
fi

echo "== assertions =="
check "root is on the encrypted volume" remote 'findmnt -no SOURCE / | grep -q /dev/mapper/luks-root'
check "/boot is its own filesystem" remote 'findmnt -no SOURCE /boot | grep -qv mapper'
check "crypttab unlocks data from the keyfile" remote 'grep -q "luks-data .*/etc/luks/data.key.*nofail" /etc/crypttab'
check "data keyfile is 0400" remote 'test "$(stat -c %a /etc/luks/data.key)" = 400'
check "data header backup exists" remote 'test "$(stat -c %a /etc/luks/luks-data.header)" = 400'
check "data volume has two keyslots" remote 'dev=$(cryptsetup status luks-data | awk "/device:/{print $2}"); [ "$(cryptsetup luksDump "$dev" | grep -c \"^  [0-9]: luks2\")" = 2 ]'
check "pool exists" remote 'zpool list -H -o name tank | grep -qx tank'
check "pool is not cached" remote 'test "$(zpool get -H -o value cachefile tank)" = none'
check "provision unit ran" remote 'systemctl is-active smortress-provision | grep -qx active'
installed_hostkey=$(remote 'ssh-keygen -y -P "" -f /etc/ssh/ssh_host_ed25519_key | cut -d" " -f1,2')
check "installed system keeps the seeded host key" test "$installed_hostkey" = "$seeded_hostkey"
check "generated rsa/ecdsa host keys are gone" remote 'test ! -e /etc/ssh/ssh_host_rsa_key -a ! -e /etc/ssh/ssh_host_ecdsa_key'

echo "== $([ "$fail" -eq 0 ] && echo PASS || echo FAIL) =="
exit "$fail"
