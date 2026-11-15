#!/bin/sh
# Boot the smortress autoinstall in QEMU against a synthetic 980.
#
# The synthetic disk is sparse and carries the serial the autoinstall matches on
# (SMORTRESS980), so the same user-data that installs the hardware runs here.
# Use this spike to prove partitions, crypttab names, keyfiles and the first-boot
# pool before the real machine is touched.

set -eu

here=$(cd -- "$(dirname -- "$0")" && pwd)
seed=${SMORTRESS_SEED:-"$here/seed.iso"}
iso=${SMORTRESS_ISO:-"$here/ubuntu-26.04.1-live-server-amd64.iso"}
disk=${SMORTRESS_SPIKE_DISK:-"$here/spike-980.qcow2"}
vars=${SMORTRESS_OVMF_VARS:-"$here/spike-vars.fd"}
size=${SMORTRESS_SPIKE_SIZE:-460G}
ssh_port=${SMORTRESS_SPIKE_SSH_PORT:-2222}

die() {
  printf 'spike: %s\n' "$*" >&2
  exit 1
}

command -v qemu-system-x86_64 >/dev/null 2>&1 || die "qemu-system-x86_64 is required"
command -v qemu-img >/dev/null 2>&1 || die "qemu-img is required"
[ -f "$seed" ] || die "seed not found: $seed (run build-seed.sh)"
[ -f "$iso" ] || die "installer ISO not found: $iso (run build-seed.sh)"

find_firmware() {
  for candidate in "$@"; do
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

qemu_share=$(dirname "$(readlink -f "$(command -v qemu-system-x86_64)")")/../share/qemu

if [ -n "${SMORTRESS_OVMF_CODE:-}" ]; then
  code=$SMORTRESS_OVMF_CODE
else
  code=$(find_firmware \
    "$qemu_share/edk2-x86_64-code.fd" \
    /usr/share/OVMF/OVMF_CODE_4M.fd \
    /usr/share/OVMF/OVMF_CODE.fd \
    /run/libvirt/nix-uefi/OVMF_CODE.fd \
    /run/libvirt/nix-uefi/OVMF_CODE_4M.fd) || die "OVMF code not found; set SMORTRESS_OVMF_CODE"
fi
[ -f "$code" ] || die "OVMF code not readable: $code"
vars_template=$(find_firmware \
  "$qemu_share/edk2-i386-vars.fd" \
  "$qemu_share/edk2-x86_64-vars.fd" \
  /usr/share/OVMF/OVMF_VARS_4M.fd \
  /usr/share/OVMF/OVMF_VARS.fd \
  /run/libvirt/nix-uefi/OVMF_VARS.fd \
  /run/libvirt/nix-uefi/OVMF_VARS_4M.fd) || die "OVMF vars not found; set SMORTRESS_OVMF_VARS to a copy target"

if [ ! -f "$disk" ]; then
  qemu-img create -f qcow2 "$disk" "$size"
fi

if [ ! -f "$vars" ]; then
  cp "$vars_template" "$vars"
  chmod u+w "$vars"
fi

accel=tcg
if [ -w /dev/kvm ]; then
  accel=kvm
fi

# -nographic keeps the install log on the serial console, but the Ubuntu
# installer draws its own UI on the VGA console and shows nothing there. Set
# SMORTRESS_SPIKE_CURSES=1 to render the VGA console in the terminal instead.
set -- -nographic
if [ "${SMORTRESS_SPIKE_CURSES:-0}" = "1" ]; then
  set -- -display curses
fi

exec qemu-system-x86_64 \
  -machine q35 \
  -accel "$accel" \
  -m 8192 \
  -smp 4 \
  -drive if=pflash,format=raw,readonly=on,file="$code" \
  -drive if=pflash,format=raw,file="$vars" \
  -drive if=none,id=disk0,format=qcow2,file="$disk" \
  -device virtio-blk-pci,drive=disk0,serial=SMORTRESS980 \
  -drive if=none,id=seed0,format=raw,file="$seed" \
  -device virtio-blk-pci,drive=seed0 \
  -cdrom "$iso" \
  -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$ssh_port-:22" \
  -device virtio-net-pci,netdev=net0 \
  "$@"
