# smortress autoinstall (T6.1)

The reproducible installer for the 980: Ubuntu 26.04.1 with an ext4-on-LUKS
root, a bare LUKS2 `luks-data` mapper for `tank`, and no pool. The pool is
created once on first boot by `smortress-provision.service`; later boots import
it with `zpool-import-tank.service`.

The 970 and the 5 TB HDD are not touched here. The 970 layout and the rollback
system are T6.2; mounting the HDD is T6.4.

## Inputs

Four secrets are required and all come from outside the repo:

| Variable | Where it comes from |
| --- | --- |
| `SMORTRESS_ROOT_PASSPHRASE` | the new LUKS root passphrase; store it in the password manager before building |
| `SMORTRESS_ADMIN_PASSWORD_HASH` | `sops -d --extract '["smores-password-hash"]' ~/repos/github.com/smores56/nix-config/secrets/common.yaml` |
| `SMORTRESS_ADMIN_KEY` | path to the operator's OpenSSH public key |
| `SMORTRESS_HOST_KEYS_TAR` | a tar of the old host's `/etc/ssh/ssh_host_*` files |

`build-seed.sh` refuses to run with any of them missing, a passphrase under 20
characters, a password that is not a crypt(3) hash, or a key that is not an
OpenSSH public key.

The rendered `user-data` and `seed.iso` live in a 0700 `mktemp` directory and
are secrets: the passphrase, the hash and the private host keys are inside.
Destroy the directory after the install.

## Build

```sh
nix-shell -p curl gnupg coreutils python3 cloud-utils tar --run \
  'SMORTRESS_ROOT_PASSPHRASE=… \
   SMORTRESS_ADMIN_PASSWORD_HASH=… \
   SMORTRESS_ADMIN_KEY=~/.ssh/id_ed25519.pub \
   SMORTRESS_HOST_KEYS_TAR=./host-keys.tar \
   provision/smortress/build-seed.sh --iso ~/Downloads/ubuntu-26.04.1-live-server-amd64.iso'
```

Without `--iso` it downloads the pinned image from
`releases.ubuntu.com/26.04.1`. Either way it verifies the signed
`SHA256SUMS` (Ubuntu key `D94AA3F0EFE21092`) and then the pinned line in
`iso.sha256`. A hash match alone is not trust; the signature is.

Building the old-host key tar, before the 980 is wiped:

```sh
sudo tar -C / -cf host-keys.tar etc/ssh/ssh_host_*
```

## Install

1. Write the Ubuntu ISO to a USB stick (or attach it to the 980).
2. Attach the seed ISO as a second device. On bare metal, `dd` it to a second
   USB stick; in QEMU, pass it as a virtio drive.
3. Boot the installer with:

   ```text
   autoinstall ds=nocloud;s=/cdrom/nocloud/
   ```

   The `autoinstall` argument is required even with the seed: without it the
   installer still asks for confirmation.
4. When the installer reboots, remove both media. Destroy the seed directory
   and any copy of it.

## What the installer produces

| Partition | Size | Contents |
| --- | --- | --- |
| `nvme0n1p1` | 1G | vfat ESP at `/boot/efi` |
| `nvme0n1p2` | 2G | ext4 `/boot` (unencrypted: GRUB cannot read LUKS without cryptodisk) |
| `nvme0n1p3` | 148G | `luks-root` → ext4 `/` |
| `nvme0n1p4` | 300G | `luks-data` (bare LUKS2, no filesystem) |
| remainder | ~479G | unallocated reserve |

`luks-root` opens with the passphrase (`none` in `/etc/crypttab`), so boot
prompts at the console until Clevis or TPM2 is enrolled. `luks-data` opens from
`/etc/luks/data.key` (64 bytes, `0400 root:root`), generated in the installer's
`early-commands` and copied into the target in `late-commands` — curtin writes
the path into crypttab but never copies the file itself.

Curtin writes the root line correctly as `luks-root UUID=… none luks`, but it
records `none` as the key column for `luks-data` too: its `crypttab_keyfile`
only changes for `/dev/random` and `/dev/urandom`, so `keyfile:` never reaches
`/etc/crypttab` and boot would prompt for a passphrase for the bare mapper. A
late-command rewrites the file to `luks-data UUID=… /etc/luks/data.key luks` and
asserts both lines, plus `cryptsetup-initramfs` in the target, so a regression
fails the install instead of the first reboot.

The initramfs only reads that file because `cryptsetup-initramfs` is installed:
`cryptsetup` alone ships no `cryptroot` hook, and without it the kernel panics
down to an initramfs shell on `root=UUID=… does not exist`.

The account `smores` is created with the reused password hash, in `sudo` and
`adm`, with the operator's key in `authorized-keys` and `allow-pw: false`.
There is no passwordless sudo: converge with `ansible-playbook -K`.

The old host keys are installed in `late-commands`, so SSH fingerprints do not
change across the rebuild.

## First boot

`smortress-provision.service` runs once (guarded by
`/var/lib/smortress/pool-created`) and creates `tank` on
`/dev/mapper/luks-data` with `ashift=12`, `compression=zstd`, `atime=off`,
`xattr=sa`, `acltype=posixacl`, `mountpoint=none`, `canmount=off` and
`cachefile=none` — the properties `roles/zfs` applies, so later runs do not
drift. `zpool-import-tank.service` imports it on every later boot. Both
`Requires=` the data mapper, so a failed unlock fails them visibly without
blocking boot; every data consumer must fail closed on its own.

## QEMU spike

```sh
nix-shell -p qemu cloud-utils xorriso openssh openssl gnupg curl python3 gnutar --run \
  'provision/smortress/qemu-spike.sh --iso ./ubuntu-26.04.1-live-server-amd64.iso --keep'
```

It boots UEFI through OVMF (``nix-build -A OVMF.fd``, or pass ``--ovmf-dir``), because
SeaBIOS makes curtin install grub-pc and fail on the GPT layout. It generates
throwaway secrets, installs into a sparse 600G NVMe image, boots
it twice, types the root passphrase on the serial console, and asserts the
layout, crypttab lines, keyfile mode and size, the untouched data mapper, the
pool properties and unit enablement. `--keep` preserves the logs and the image
under the printed directory.

Known gap (accepted in the T6.1 plan): the spike proves one boot with the
passphrase and Tang available. The Tang-unreachable and no-Tang boots are the
T6.4 hardware gate before cutover.

## Not covered here

- The 970 rollback layout and `nixos-anywhere` (T6.2).
- Converging `site.yml`, datasets and mounts (T6.4).
- NVIDIA, zram and the swapfile: Ansible-owned, and absent from the spike
  because QEMU has no GPU.
