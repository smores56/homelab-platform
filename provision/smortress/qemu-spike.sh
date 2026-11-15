#!/usr/bin/env bash
# QEMU spike for the smortress autoinstall artifact (SDLC #680 T6.1).
#
# Installs into a sparse NVMe image, boots it twice, and asserts the layout,
# crypttab, keyfile, pool properties and first-boot units. A throwaway admin
# key, host keys, root passphrase and password hash are generated per run, so
# nothing here is a real secret.
#
#   nix-shell -p qemu cloud-utils xorriso openssh openssl gnupg curl python3 gnutar \
#     --run 'provision/smortress/qemu-spike.sh --iso /path/ubuntu-26.04.1-live-server-amd64.iso'
#
# Requires KVM for a usable runtime; falls back to TCG with a warning.
# The root passphrase is typed on the serial console, which is how the real
# host behaves until Clevis/TPM is enrolled.
set -euo pipefail

here=$(cd -- "$(dirname -- "$0")" && pwd)
guest_up=0
# Assertions run on a booted guest: when one fails, the journal is the only
# evidence, and the VM dies with this script.
debug_dump() {
  printf '\n--- guest diagnostics ---\n' >&2
  guest_sudo systemctl status --no-pager -l smortress-provision zpool-import-tank 2>&1 | tail -30 >&2 || true
  guest_sudo journalctl -u smortress-provision -u zpool-import-tank -n 60 --no-pager 2>&1 | tail -40 >&2 || true
  guest_sudo systemctl status --no-pager -l 'systemd-cryptsetup@*' 2>&1 | tail -15 >&2 || true
  guest_sudo systemctl list-units 'dev-mapper-*' --no-pager 2>&1 | tail -5 >&2 || true
  guest_sudo sh -c 'ls -l /etc/luks /etc/crypttab; cat /etc/crypttab' 2>&1 | tail -10 >&2 || true
  guest_sudo systemctl list-jobs --no-pager 2>&1 | tail -10 >&2 || true
  guest_sudo dmsetup ls 2>&1 | tail -5 >&2 || true
  guest_sudo zpool list 2>&1 | tail -5 >&2 || true
  printf '%s\n' "--- end diagnostics ---" >&2
}
die() {
  if ((guest_up)); then debug_dump; fi
  printf 'qemu-spike: %s\n' "$*" >&2
  exit 1
}

iso=
workdir=
keep=0
ssh_port=2222
ovmf_dir=

usage() { sed -n '2,14p' "$0"; }
while (($#)); do
  case $1 in
    --iso) iso=${2:?--iso needs a path}; shift 2 ;;
    --workdir) workdir=${2:?--workdir needs a path}; shift 2 ;;
    --ssh-port) ssh_port=${2:?--ssh-port needs a number}; shift 2 ;;
    --ovmf-dir) ovmf_dir=${2:?--ovmf-dir needs a path}; shift 2 ;;
    --keep) keep=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ $iso ]] || die "--iso is required"
[[ -f $iso ]] || die "ISO not found: $iso"
for tool in qemu-system-x86_64 ssh-keygen ssh openssl tar python3 xorriso; do
  command -v "$tool" >/dev/null 2>&1 || die "missing tool: $tool"
done

work=${workdir:-$(mktemp -d)}
mkdir -p "$work"
keep_work=0
# A failed run must not leave a VM holding the SSH port for the next one.
qemu_pids=()
reap_vms() {
  local pid
  for pid in "${qemu_pids[@]-}"; do
    [[ $pid ]] || continue
    kill "$pid" 2>/dev/null || true
  done
}
cleanup() { if ((!keep && !keep_work)); then rm -rf "$work"; fi; }
trap 'reap_vms; cleanup' EXIT

# Fail fast instead of letting qemu report a forwarding error after the install
# has already been set up.
python3 - "$ssh_port" <<'PY' || die "port $ssh_port is already listening; a stale VM is holding it"
import socket
import sys

with socket.socket() as sock:
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.bind(("127.0.0.1", int(sys.argv[1])))
    except OSError:
        sys.exit(1)
PY

# --- throwaway material -----------------------------------------------------
pass=$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)
[[ ${#pass} -eq 32 ]] || die "could not generate a passphrase"
# Kept so a later debug boot of the same image can unlock it; throwaway only.
( umask 077; printf '%s\n' "$pass" >"$work/passphrase" )
hash=$(openssl passwd -6 "$pass")

ssh-keygen -q -t ed25519 -N '' -C spike -f "$work/admin"
mkdir -p "$work/hostkeys/etc/ssh"
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

# --- boot media -------------------------------------------------------------
# A seed alone does not make the installer unattended: `autoinstall` must be on
# the kernel command line. Boot the ISO's kernel/initrd directly and pass it.
vmlinuz=$work/vmlinuz
initrd=$work/initrd
xorriso -osirrox on -indev "$iso" -extract /casper/vmlinuz "$vmlinuz" >/dev/null 2>&1 \
  || die "could not extract /casper/vmlinuz from the ISO"
if ! xorriso -osirrox on -indev "$iso" -extract /casper/initrd "$initrd" >/dev/null 2>&1; then
  xorriso -osirrox on -indev "$iso" -extract /casper/initrd.gz "$initrd" >/dev/null 2>&1 \
    || die "could not extract the initrd from the ISO"
fi

# --- virtual hardware -------------------------------------------------------
disk=$work/nvme0.img
truncate -s 600G "$disk"

# The 980 boots UEFI. Booting the spike under SeaBIOS makes curtin install
# grub-pc on a GPT disk with no BIOS-boot partition, and grub-install fails.
if [[ -z $ovmf_dir ]]; then
  command -v nix-build >/dev/null 2>&1 || die "pass --ovmf-dir or provide nix-build"
  ovmf_dir=$(nix-build '<nixpkgs>' -A OVMF.fd --no-out-link)
fi
[[ -f $ovmf_dir/FV/OVMF_CODE.fd && -f $ovmf_dir/FV/OVMF_VARS.fd ]] \
  || die "OVMF_CODE.fd/OVMF_VARS.fd not found in $ovmf_dir"
cp "$ovmf_dir/FV/OVMF_VARS.fd" "$work/OVMF_VARS.fd"
chmod u+w "$work/OVMF_VARS.fd"

accel=(-accel tcg)
if [[ -r /dev/kvm ]]; then accel=(-enable-kvm -cpu host); else
  printf 'warning: no /dev/kvm; the spike will be very slow\n' >&2
fi

qemu_common=(
  -m 4096 -smp 4 -display none -no-reboot
  "${accel[@]}"
  -drive "if=pflash,format=raw,readonly=on,file=$ovmf_dir/FV/OVMF_CODE.fd"
  -drive "if=pflash,format=raw,file=$work/OVMF_VARS.fd"
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
last_send = 0.0
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
            # initramfs-tools asks "Please unlock disk luks-root:" and never says
            # "passphrase"; match the real prompt, and answer a retry after a bad
            # entry instead of hanging on it.
            prompt = re.search(
                r"(?i)(passphrase|please unlock disk|enter any existing)", text
            )
            if prompt and (not sent or time.time() - last_send > 15):
                s.sendall(passphrase.encode() + b"\r")
                sent = True
                last_send = time.time()
            if re.search(r"(?i)login:", text):
                sys.exit(0)
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
# `%q` is required: the command is re-parsed by the remote shell, so a bare `$*`
# turns `stat -c '%a %s %U %G' file` into four filenames there.
guest_sudo() {
  local cmd
  cmd=$(printf '%q ' "$@")
  guest "printf '%s\n' '$pass' | sudo -S -p '' $cmd"
}

boot() {
  local name=$1
  local sock=$work/$name.sock
  rm -f "$sock"
  qemu-system-x86_64 "${qemu_common[@]}" -boot c \
    -serial "unix:$sock,server=on,wait=off" &
  local pid=$!
  qemu_pids+=("$pid")
  console "$sock" "$work/$name.console.log" &
  local cpid=$!
  if ! wait_ssh; then
    kill "$pid" "$cpid" 2>/dev/null || true
    die "$name: SSH never came up (console log: $work/$name.console.log)"
  fi
  guest_up=1
  wait "$cpid" || true
  printf '%s\n' "$pid" >"$work/$name.pid"
}

stop_vm() {
  local pid
  pid=$(cat "$1")
  guest_up=0
  guest_sudo poweroff || true
  for _ in $(seq 1 60); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 1
  done
  kill "$pid" 2>/dev/null || true
}

# --- install ----------------------------------------------------------------
printf 'installing; this takes a while\n'
# The ISO is a virtio block device, not an IDE CD: casper scans block devices
# by label, and that path works under OVMF where the ide-cd device did not.
timeout 900 qemu-system-x86_64 "${qemu_common[@]}" \
  -drive "file=$iso,format=raw,if=none,id=iso0,readonly=on" \
  -device "virtio-blk-pci,drive=iso0" \
  -kernel "$vmlinuz" -initrd "$initrd" \
  -append 'autoinstall ds=nocloud console=ttyS0,115200 boot=casper ---' \
  -drive "file=$seed_dir/seed.iso,format=raw,if=virtio,readonly=on" \
  -serial "file:$work/install.log" &
qpid=$!
qemu_pids+=("$qpid")
(
  for _ in $(seq 1 480); do
    if grep -qE 'An error occurred|Unable to find a medium' "$work/install.log" 2>/dev/null; then
      kill "$qpid" 2>/dev/null || true
      break
    fi
    sleep 5
  done
) &
watch=$!
irc=0
wait "$qpid" || irc=$?
kill "$watch" 2>/dev/null || true
printf 'install qemu exited %s\n' "$irc" >&2
if ((irc != 0)); then
  die "the installer qemu exited $irc; see $work/install.log"
fi
if grep -qE 'An error occurred|Unable to find a medium' "$work/install.log"; then
  die "installer failed; see $work/install.log"
fi
if ((irc == 137)); then
  die "the installer was SIGKILLed; check the host for an external killer"
fi
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
  # The installer must not put a filesystem on the bare mapper. ZFS labels are
  # expected once the pool exists, so only a real filesystem is a failure.
  data_fstype=$(guest_sudo blkid -o value -s TYPE /dev/mapper/luks-data 2>/dev/null | head -1 || true)
  case ${data_fstype:-none} in
    none | zfs_member) ;;
    *) die "luks-data carries a ${data_fstype} filesystem" ;;
  esac
  # The oneshot runs from multi-user.target and SSH can come up before it
  # finishes, so give it time instead of racing the assertion.
  for _ in $(seq 1 60); do
    guest_sudo test -f /var/lib/smortress/pool-created && break
    sleep 2
  done
  guest_sudo zpool list -H -o name | grep -qx tank \
    || die "pool: tank was not created"
  for prop in 'ashift 12' 'cachefile none'; do
    read -r key value <<<"$prop"
    guest_sudo zpool get -H -o value "$key" tank | grep -qx "$value" \
      || die "pool: $key is not $value"
  done
  for prop in 'compression zstd' 'atime off' 'xattr sa' \
              'mountpoint none' 'canmount off'; do
    read -r key value <<<"$prop"
    guest_sudo zfs get -H -o value "$key" tank | grep -qx "$value" \
      || die "pool: $key is not $value"
  done
  # OpenZFS renamed acltype=posixacl to acltype=posix (#10918); posixacl stays
  # an alias on input but reads back as posix, so accept both spellings.
  guest_sudo zfs get -H -o value acltype tank | grep -qxE 'posix|posixacl' \
    || die "pool: acltype is neither posix nor posixacl"
  guest systemctl is-enabled smortress-provision.service | grep -qx enabled \
    || die "unit: provision is not enabled"
  guest systemctl is-enabled zpool-import-tank.service | grep -qx enabled \
    || die "unit: import is not enabled"
  guest_sudo zpool get -H -o value guid tank >"$work/pool.guid"
}

boot boot1
check_layout
printf 'boot 1 passed\n'
stop_vm "$work/boot1.pid"

boot boot2
guest_sudo zpool list -H -o name | grep -qx tank \
  || die "boot 2: tank did not import"
  # The marker guards the work, not the unit: RemainAfterExit=yes leaves it
  # active (exited). Prove the no-op by an unchanged pool GUID and rc 0.
  [[ -s $work/pool.guid ]] || die "boot 2: no pool GUID recorded on boot 1"
  guest_sudo zpool get -H -o value guid tank | grep -qxF "$(cat "$work/pool.guid")" \
    || die "boot 2: provision recreated the pool"
  guest_sudo systemctl show -p ExecMainStatus --value smortress-provision.service \
    | grep -qx 0 || die "boot 2: provision unit did not exit 0"
printf 'boot 2 passed\n'
stop_vm "$work/boot2.pid"

keep_work=1
printf 'PASS: %s\n' "$work"
