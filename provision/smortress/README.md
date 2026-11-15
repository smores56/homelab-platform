# smortress autoinstall

`user-data` is the whole install: partitions, LUKS containers, the bootstrap
user, the data-volume keyfile, and a first-boot unit that creates `tank`.
`build-seed.sh` renders it with values that must not live in git and packs a
NoCloud `cidata` ISO; `spike.sh` boots that seed in QEMU against a synthetic
980 so the layout is proven before hardware.

## Layout it produces

On the disk whose serial is `SMORTRESS980`:

| Partition | Size | Contents |
| --- | --- | --- |
| p1 | 1G | ESP, `/boot/efi` |
| p2 | 2G | plain ext4 `/boot` |
| p3 | 148G | `luks-root` (passphrase), ext4 `/` |
| p4 | 300G | `luks-data` (keyfile), bare mapper for `tank` |

The rest of the disk stays unallocated on purpose: the pool grows into it
without touching the other volumes, and the primary repository lives on the 970.

`luks-root` unlocks with the passphrase at first boot and, once the spike has
proven Clevis on 26.04.1, with Tang plus TPM2. The data volume unlocks from
`/etc/luks/data.key`, which is only readable after root is up.

## Building a seed

```sh
nix-shell -p xorriso curl gnupg --run 'provision/smortress/build-seed.sh'
```

It fetches the pinned 26.04.1 ISO, verifies the Ubuntu signature over
`SHA256SUMS`, verifies the ISO checksum, generates
`~/.config/smortress/luks-root.passphrase` if absent, and writes `seed.iso`.

The seed contains the root LUKS passphrase and a random data keyfile. Put the
passphrase in Bitwarden, install, then destroy the seed.

## Spike

```sh
nix-shell -p qemu xorriso curl gnupg --run 'provision/smortress/spike.sh'
```

The VM installs onto a sparse 460G qcow2, exposes SSH on `127.0.0.1:2222`, and
runs the same first-boot pool unit. Pass criteria: three partitions with the
expected crypttab names, a data keyfile at `/etc/luks/data.key`, `tank` present
after the first boot, and a host that still boots with `luks-data` left closed.

Operator-facing steps for the real machine live in `docs/manual-steps.md`.

## The reboot trap

The installer reboots with the ISO still attached, and the firmware happily
boots it again: autoinstall re-runs and wipes the disk it just built. In the
spike, stop QEMU at the first post-install reboot and start it again with
`SMORTRESS_SPIKE_BOOT=disk`. On hardware, remove the seed USB before the
reboot, exactly as you would remove any install medium.
