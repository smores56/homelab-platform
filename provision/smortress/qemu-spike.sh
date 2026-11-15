#!/usr/bin/env bash
# QEMU spike for the smortress autoinstall artifact (SDLC #680 T6.1).
#
# Installs into a sparse NVMe image, boots it twice, and asserts the layout,
# crypttab, keyfile, pool properties and first-boot units. A throwaway admin
# key, host keys, root passphrase and password hash are generated per run, so
# nothing here is a real secret.
#
#   nix-shell -p qemu cloud-utils openssh gnupg curl python3 tar \
#     --run 'provision/smortress/qemu-spike.sh --iso /path/ubuntu-26.04.1-live-server-amd64.iso'
#
# Requires KVM for a usable runtime; falls back to TCG with a warning.
# The root passphrase is typed on the serial console, which is how the real
# host behaves until Clevis/TPM is enrolled.
set -euo pipefail

here=$(cd -- "$(dirname -- "$0")" && pwd)
die() { printf 'qemu-spike: %s\n' "$*" >&2; exit 1; }

iso=
workdir=
keep=0
ssh_port=2222

usage() { sed -n '2,14p' "$0"; }
while (($#)); do
  case $1 in
    --iso) iso=${2:?--iso needs a path}; shift 2 ;;
    --workdir) workdir=${2:?--workdir needs a path}; shift 2 ;;
    --ssh-port) ssh_port=${2:?--ssh-port needs a number}; shift 2 ;;
    --keep) keep=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ $iso ]] || die "--iso is required"
[[ -f $iso ]] || die "ISO not found: $iso"
for tool in qemu-system-x86_64 ssh-keygen ssh openssl tar python3; do
  command -v "$tool" >/dev/null 2>&1 || die "missing tool: $tool"
done

work=${workdir:-$(mktemp -d)}
mkdir -p "$work"
keep_work=0
cleanup() { if ((!keep && !keep_work)); then rm -rf "$work"; fi; }
trap cleanup EXIT

# --- throwaway material -----------------------------------------------------
pass=$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)
[[ ${#pass} -eq 32 ]] || die "could not generate a passphrase"
hash=$(openssl passwd -6 "$pass")

ssh-keygen -q -t ed25519 -N '' -C spike -f "$work/admin"
mkdir -p "$work/hostkeys"
ssh-keygen -q -A -f "$work/hostkeys"
tar -C "$work/hostkeys" -cf "$work/host-keys.tar" etc/ssh

printf 'building the seed\n'
seed_dir=$(
  SMORTRESS_ROOT_PASSPHRASE=$pass \
  SMORTRESS_ADMIN_PASSWORD_HASH=$hash \
  SMORTRESS_ADMIN_KEY=$work/admin.pub \
  SMORTRESS_HOST_KEYS_TAR=$work/host-keys.tar \
    "$here/build-seed.sh" --iso "$iso"
)
[[ -f $seed_dir/seed.iso ]] || die "build-seed did not produce a seed"

# --- virtual hardware -------------------------------------------------------
disk=$work/nvme0.img
truncate -s 600G "$disk"

accel=(-accel tcg)
if [[ -r /dev/kvm ]]; then accel=(-enable-kvm -cpu host); else
  printf 'warning: no /dev/kvm; the spike will be very slow\n' >&2
fi

qemu_common=(
  -m 4096 -smp 4 -display none -no-reboot
  "${accel[@]}"
  -drive "file=$disk,format=raw,if=none,id=n0"
  -device "nvme,serial=nvme0,drive=n0"
  -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$ssh_port-:22"
  -device "virtio-net-pci,netdev=net0"
)

# Typed into the serial console: the root LUKS passphrase, exactly as the real
# host prompts until Clevis/TPM is enrolled.
console() {
  local sock=$1 log=$2
  python3 - "$sock" "$log" "$pass" <<'PY'
import re
import socket
import sys
import time

sock_path, log_path, passphrase = sys.argv[1:4]
deadline = time.time() + 900
sent = False
buffer = b""
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
    s.settimeout(5)
    while time.time() < deadline:
        try:
            s.connect(sock_path)
            break
        except OSError:
            time.sleep(0.5)
    else:
        sys.exit("console: could not connect to the serial socket")
    with open(log_path, "wb") as log:
        while time.time() < deadline:
            try:
                chunk = s.recv(4096)
            except socket.timeout:
                continue
            if not chunk:
                break
            log.write(chunk)
            log.flush()
            buffer = (buffer + chunk)[-4096:]
            text = buffer.decode("utf-8", "replace")
            if not sent and re.search(r"(?i)passphrase", text):
                s.sendall(passphrase.encode() + b"\r")
                sent = True
            if re.search(r"(?i)login:", text):
                return
    sys.exit("console: timed out before a login prompt")
PY
}

wait_ssh() {
  for _ in $(seq 1 240); do
    if ssh -q -o BatchMode=yes -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 \
        -i "$work/admin" -p "$ssh_port" smores@127.0.0.1 true 2>/dev/null; then
      return 0
    fi
    sleep 2
  done
  return 1
}

guest() {
  ssh -o BatchMode=yes -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
      -i "$work/admin" -p "$ssh_port" smores@127.0.0.1 "$@"
}

# No NOPASSWD: feed the throwaway password on stdin, as the real operator does.
guest_sudo() {
  guest "printf '%s\n' '$pass' | sudo -S -p '' $*"
}

boot() {
  local name=$1
  local sock=$work/$name.sock
  rm -f "$sock"
  qemu-system-x86_64 "${qemu_common[@]}" -boot c \
    -serial "unix:$sock,server=on,wait=off" &
  local pid=$!
  console "$sock" "$work/$name.console.log" &
  local cpid=$!
  if ! wait_ssh; then
    kill "$pid" "$cpid" 2>/dev/null || true
    die "$name: SSH never came up (console log: $work/$name.console.log)"
  fi
  wait "$cpid" || true
  printf '%s\n' "$pid" >"$work/$name.pid"
}

stop_vm() {
  local pid
  pid=$(cat "$1")
  guest_sudo poweroff || true
  for _ in $(seq 1 60); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 1
  done
  kill "$pid" 2>/dev/null || true
}

# --- install ----------------------------------------------------------------
printf 'installing; this takes a while\n'
qemu-system-x86_64 "${qemu_common[@]}" -boot d -cdrom "$iso" \
  -drive "file=$seed_dir/seed.iso,format=raw,if=virtio,readonly=on" \
  -serial "file:$work/install.log"
grep -qiE 'error-commands|Traceback|install failed' "$work/install.log" \
  && die "installer reported an error; see $work/install.log"

# --- assertions -------------------------------------------------------------
check_layout() {
  guest 'lsblk -no NAME,SIZE,FSTYPE' | grep -q 'nvme0n1p1' \
    || die "layout: ESP partition missing"
  guest_sudo cat /etc/crypttab | grep -q '^luks-root ' \
    || die "crypttab: luks-root entry missing"
  guest_sudo cat /etc/crypttab | grep -q '^luks-data .* /etc/luks/data.key ' \
    || die "crypttab: luks-data does not use the keyfile"
  guest_sudo stat -c '%a %s %U %G' /etc/luks/data.key | grep -qx '400 64 root root' \
    || die "keyfile: expected 0400, 64 bytes, root:root"
  if guest_sudo blkid /dev/mapper/luks-data | grep -q .; then
    die "luks-data must stay unformatted"
  fi
  guest_sudo zpool list -H -o name | grep -qx tank \
    || die "pool: tank was not created"
  for prop in 'ashift 12' 'compression zstd' 'atime off' 'xattr sa' \
              'acltype posixacl' 'mountpoint none' 'canmount off' 'cachefile none'; do
    read -r key value <<<"$prop"
    guest_sudo zpool get -H -o value "$key" tank | grep -qx "$value" \
      || die "pool: $key is not $value"
  done
  guest systemctl is-enabled smortress-provision.service | grep -qx enabled \
    || die "unit: provision is not enabled"
  guest systemctl is-enabled zpool-import-tank.service | grep -qx enabled \
    || die "unit: import is not enabled"
}

boot boot1
check_layout
printf 'boot 1 passed\n'
stop_vm "$work/boot1.pid"

boot boot2
guest_sudo zpool list -H -o name | grep -qx tank \
  || die "boot 2: tank did not import"
guest systemctl is-active smortress-provision.service | grep -qx inactive \
  || die "boot 2: provision should be skipped by its marker"
printf 'boot 2 passed\n'
stop_vm "$work/boot2.pid"

keep_work=1
printf 'PASS: %s\n' "$work"
