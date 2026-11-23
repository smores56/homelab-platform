# Pool rebuild and root resize

`p4` is 300 GiB and `p5` takes the rest of the 980. An installed host that was
made before this change has a 100 GiB root, and root is where everything that is
not a dataset lands: the container images, the journal, `/var/home`, and any
restore that fails to name a data disk. Drill scratch filled it three times; the
third took Immich's AOF writes, the restic state files, the root Podman storage
and sshd's agent forwarding down with it.

**Growing root means destroying the pool.** `smortress` is a single ZFS vdev on
`nvme0n1p5`, and ZFS cannot shrink a vdev, so the only way to hand space from
`p5` to `p4` is to delete `p5` and recreate it smaller. This document is that
procedure, plus the staging that keeps it from depending on the backups.

The live tree is staged on the 970 first. That is the whole risk model: Restic
has never been proven to restore every unit cold (`docs/core/restic-plane.md`,
"What is not proven yet"), and `state/agent-model` is in no restore unit at all,
so the move is a filesystem copy of the running layout and the repositories are
the second copy, not the first.

## A. Stage: get the tooling and the tree off the pool

Run this from a checkout that does not live on the pool. `/srv/git` **is**
`raw/git`: the repository worktrees, the bare git directories and this document
are all on the dataset that is about to be deleted.

```sh
git clone --origin origin git@github.com:smores56/homelab-platform.git ~/homelab-platform
cd ~/homelab-platform
```

Copy the git dataset first (it is small), then the media trees, one rsync per
dataset so `.zfs` automounts are never followed. State trees are not copied
here: they have writers, and a live PGDATA or sqlite file copies into a corrupt
tree. Phase B copies those after the units are stopped.

`.zfs` gives way to `--one-file-system`. There is no `-X`: rsync removes
`security.selinux` from every destination directory, ext4 answers
`fremovexattr: Permission denied`, and rsync exits 23 after moving every byte —
a red gate over nothing. This rsync build has no `--xattrs-include` either, so
the choice is all xattrs or none; none is correct here because SELinux labels
are rebuilt in phase E with `chcon`, exactly as section 40.18 does for a drill,
and no application under these trees keeps `user.*` xattrs. ACLs still travel in
`-A`, which is what the tenants' trees actually carry.

```sh
sudo install -d -m 0755 /var/lib/restic/ssd/pool-copy
opts=(-aHA --numeric-ids --one-file-system)
sudo rsync "${opts[@]}" /var/srv/git/ /var/lib/restic/ssd/pool-copy/srv/git/
for d in files photos books music wallpapers apps repo-archive; do
  sudo rsync "${opts[@]}" "/var/srv/$d/" "/var/lib/restic/ssd/pool-copy/srv/$d/"
done
```

Space: the tree is ~270 GiB logical (`zfs list -o logicalused`) because the pool
compresses with zstd, and the 970 has 661 GiB free. The restic repository stays
on the same disk as the second copy.

Take a copy of the partition table before anything is deleted; it is the one
artefact a wrong `parted` cannot be talked out of:

```sh
sudo sgdisk --backup="/var/lib/restic/ssd/gpt-$(date -u +%Y%m%dT%H%M%SZ).bin" /dev/nvme0n1
```

## B. Stop the writers

Stop the timers first, then the applications. A timer that fires after the pool
is recreated but before the tree is back snapshots an empty dataset, and that
snapshot is tagged `verified` and enters the retention window as the newest good
restore point:

```sh
sudo systemctl stop smortress-restic-backup-ssd.timer smortress-restic-backup-hdd.timer \
  smortress-restic-backup-r2.timer smortress-restic-verify.timer smortress-immich-dump.timer \
  'smortress-agent-collect-*.timer' 'smortress-agent-collect-*.path'
sudo systemctl stop immich-server.service immich-machine-learning.service immich-postgres.service \
  immich-valkey.service opdshelf.service syncthing.service
sudo systemctl stop 'smortress-agent-*'
```

The collectors matter as much as the applications: they write into
`/var/lib/agent/local/quarantine`, which is a state tree below.

Containers are not units, and a Quadlet's unit is named after its file, not
after its container: `units/quadlet/agent-model.container` generates
`agent-model.service` and starts a container called `smortress-agent-model`. A
`systemctl stop 'smortress-agent-*'` therefore misses it. Two containers hold
bind mounts into `/var/lib/agent/local` and `/var/lib/agent/model`, so the pool
refuses to export with `pool is busy` until they are stopped by container name:

```sh
sudo podman ps -a --format '{{.Names}}	{{.Status}}'
sudo podman stop smortress-agent-mail-stream smortress-agent-model
```

A container with a restart policy is the second half of the same problem: the
reboot in phase D brings `podman-restart.service` up before the datasets exist,
and the container writes into a plain directory on the root filesystem. Park
them for the window and restore the policy afterwards:

```sh
sudo systemctl mask --now podman-restart.service
```

Only now copy the state trees. `opdshelf` and both gateways keep state of their
own; they are the reason this is a separate phase, not a footnote:

```sh
for d in immich/postgres immich/dumps syncthing/config opdshelf agent/local agent/general agent/model; do
  sudo install -d -m 0755 "/var/lib/restic/ssd/pool-copy/lib/$d"
  sudo rsync -aHA --numeric-ids --one-file-system "/var/lib/$d/" "/var/lib/restic/ssd/pool-copy/lib/$d/"
done
sudo sync   # the pool is destroyed next; do not leave the copy in page cache
```

**Prove both halves before touching a partition.** A second pass that compares
checksums over every copied tree must report no content difference. Read the
itemised output by its first column: a leading `.` is metadata only (directory
times, or a file whose checksum matched anyway), and anything else would move
data. `git` is the one tree that legitimately moves while the window is open — an automated fetch rewrites `FETCH_HEAD` and `.git/objects`
— so its content diffs are a warning to re-sync rather than a failed gate.

```sh
for t in srv/git srv/files srv/photos srv/books srv/music srv/wallpapers \
  srv/apps srv/repo-archive lib/immich/postgres lib/immich/dumps \
  lib/syncthing/config lib/opdshelf lib/agent/local lib/agent/general lib/agent/model; do
  src=${t#srv/}; src=${src#lib/}
  case $t in srv/*) src=/var/srv/$src ;; *) src=/var/lib/$src ;; esac
  sudo rsync -aHA --numeric-ids --one-file-system --checksum -ni "$src/" "/var/lib/restic/ssd/pool-copy/$t/"
done
```

## C. Rebuild p5, grow p4

```sh
sudo systemctl stop zfs-mount smortress-zpool
sudo zpool export smortress                 # unmounts every dataset; -f if busy
sudo zpool labelclear -f /dev/mapper/data   # the second vdev label sits at the disk tail
sudo cryptsetup close data || sudo dmsetup remove -f data
sudo wipefs -a /dev/disk/by-partlabel/luks-data
```

Clear the labels before the partition goes, not just the LUKS header:
`init-zpool` branches on `blkid` reporting `zfs_member`, and a stale trailing
label under the new partition's tail is what makes it try to import a pool that
is not there and exit 1.

`parted` is not in the server image, so the repartition uses `sgdisk` and
`growpart`. Create p5 first, at the offset p4 has to stop at, then let
`growpart` fill the gap: it takes its limit from the next partition's start and
aligns to 1 MiB, which lands p4 on exactly 300 GiB.

```sh
# p4 starts at sector 1050624 on this disk (cat /sys/block/nvme0n1/nvme0n1p4/start).
# 300 GiB is 629145600 sectors, so p5 starts at 1050624 + 629145600.
sudo sgdisk -d 5 /dev/nvme0n1
sudo sgdisk -n 5:630196224:0 -c 5:luks-data -t 5:8300 /dev/nvme0n1
sudo sgdisk -p /dev/nvme0n1                 # p4 ends 630196223, p5 starts 630196224
sudo growpart /dev/nvme0n1 4
sudo partx -u /dev/nvme0n1 && sudo cryptsetup resize root && sudo xfs_growfs /var
df -h /var                                 # ~299G: p4 starts after /boot
```

Never reboot between the `rm` and the `mkpart` of p5: a boot with p5 absent
leaves `smortress-data-init.service` with no device, and the pool unit fails
with it.

If `partx` refuses because a partition is in use, reboot instead. Nothing on
the host grows the filesystem on the way up: dracut resizes the mapping when it
opens root, and the `xfs_growfs` above still has to be run afterwards or the
filesystem stays 100 GiB on a 300 GiB partition.

## D. Bring the pool back empty

The GPT name is the partlabel, and `/etc/crypttab` keys on
`/dev/disk/by-partlabel/luks-data`, not on a UUID, so the entry survives a
re-format as long as the label is restored:

```sh
sudo parted /dev/nvme0n1 mkpart luks-data ext4 307201MiB 100%
sudo reboot
```

On boot `smortress-data-init.service` formats `p5` with `/etc/luks/data`, writes
nothing (the crypttab entry is already there), opens the mapper, and
`smortress-zpool.service` runs `/usr/libexec/init-zpool`, which creates the pool
and all fifteen datasets at their mountpoints.

If that oneshot fails with `Option --allow-discards is not allowed with
luksFormat action`, the image predates the fix and p5 is still unformatted.
Format it the way the current script does — `luksFormat` without the flag, then
`cryptsetup open --allow-discards --persistent` — and start
`smortress-zpool.service`; the oneshot then finds a valid header and succeeds.

Check the installed table before trusting it: `docs/core/storage-migration.md`
warns that an installed `init-zpool` can predate `scripts/storage-layout.sh`,
and a stale table silently skips `repo-archive` and the `agent-*` datasets.

```sh
/usr/libexec/init-zpool --print-plan
sudo /usr/libexec/zfs-ready raw-files
```

Then add the offline recovery passphrase back. Ignition carries no key for the
data volume at all: `scripts/init-data-luks.sh` generates 64 random bytes into
`/etc/luks/data` on the first boot, and the passphrase in
`docs/core/recovery-kit.md` is a separate keyslot the operator adds by hand. A
re-format keeps only the keyfile's slot, so the kit stops opening the volume
until it is added again:

```sh
sudo cryptsetup luksAddKey /dev/disk/by-partlabel/luks-data
sudo cryptsetup open --test-passphrase --key-file /etc/luks/data /dev/disk/by-partlabel/luks-data
sudo cryptsetup open --test-passphrase /dev/disk/by-partlabel/luks-data
```

Both opens must succeed: the first proves the key file the boot path uses, the
second proves the kit still opens the volume without it.

## E. Move the tree back

```sh
for d in files photos books music wallpapers apps repo-archive; do
  sudo rsync -aHA --numeric-ids "/var/lib/restic/ssd/pool-copy/srv/$d/" "/var/srv/$d/"
done
for d in immich/postgres immich/dumps syncthing/config opdshelf agent/local agent/general agent/model; do
  sudo rsync -aHA --numeric-ids "/var/lib/restic/ssd/pool-copy/lib/$d/" "/var/lib/$d/"
done
sudo rsync -aHA --numeric-ids /var/lib/restic/ssd/pool-copy/srv/git/ /var/srv/git/
```

Then, in order:

1. `sudo install -d -o 1000 -g 1000` on the group roots if `init-zpool` did not
   own them; application trees are uid 1000 and Podman may only mount labelled
   content, so `sudo chcon -R -t container_file_t` the restored trees as
   `docs/manual-steps.md#run-the-agent-runtime-drill` does for a drill.
2. `sudo /usr/libexec/zfs-ready raw-files` (and `state-immich-postgres`) before
   any unit that `Requires=` them starts.
3. Start the applications, then the timers.
4. Run every drill: `sudo scripts/agent-runtime-drill.sh restore agent-local
   --backend ssd` for the agent side, and section 40.18's unit loop for the media
   side. A pool that came back without a passing drill is not restored.
5. Take a fresh backup (`sudo /usr/libexec/smortress-restic-backup ssd`) and let
   `smortress-restic-verify` go green, then delete
   `/var/lib/restic/ssd/pool-copy`.

### What the 2026-11-22 window proved for `agent-local`

The full `agent-runtime-drill.sh restore agent-local --backend ssd` was stopped,
not passed: under the old `dump` method it wrote 39 GiB of 520 expanded GB in 24
minutes, which could not finish inside the helper's four-hour deadline. What
stands in its place:

- `scripts/legacy/retirement-gate.sh` cold-restores every unit from each destination
  and matches one sample file per dataset against the live tree. That matrix is
  the retirement evidence.
- 400 files spread across the first 383,794 restored files of `agent-local`
  matched byte for byte, with owner and mode, against `/var/lib/agent/local`.
- the old method expanded hardlinks (`restic dump` emits none). The source is
  36.8 GB unique with 4,365,676 of its 4,592,084 files sharing an inode, but
  those 519.8 GB of paths arrived as distinct files: the 8 % restored held
  43.8 GB unique and zero multi-link files, 118 % of the whole source's unique
  bytes. The drill's default is `restic restore` now, which preserves links and
  needs far less than 520 GB, but no completed `agent-local` restore has been
  timed (`docs/core/restic-plane.md`, "Restore by hand"): the unit is unproven,
  not done.

Record a deferred drill as deferred. `smortress-restic-verify` going green says
the snapshots are fresh; it does not say this unit was restored in full.

### Measurement decision (2026-11-22)

The owner canceled the `agent-local` timing drill. The restore path is covered by
the offline tests and the runbook; this document claims no wall-clock or
restored-bytes figure for that unit.

## Rollback

There is no rollback past phase C: `p5` is gone. The two copies that exist by
then are the staged tree on the 970 and the repositories, which is why phase A
proves its copy before phase C starts and why the r2 repository is refreshed
before the window.

Do the partition work **last**, after every unit has been cold-restored from the
repositories once (`docs/core/restic-plane.md`, "Restore by hand"). That drill is
the only evidence that the repositories can carry the pool on their own.

## What this does not fix

Root is bigger; it is not fenced. Drill scratch still writes under a data disk by
default and the helper refuses a target without room, but nothing caps total
usage of root. If a fourth incident is not acceptable, put a project quota on
`/var/tmp` or move it to its own volume.
