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

Copy the git dataset first (it is small), then every dataset root, one rsync per
dataset so `.zfs` automounts are never followed:

```sh
sudo install -d -m 0755 /var/lib/restic/ssd/pool-copy
sudo rsync -aHAX /var/srv/git/ /var/lib/restic/ssd/pool-copy/srv/git/
for d in files photos books music wallpapers apps repo-archive; do
  sudo rsync -aHAX --numeric-ids --one-file-system "/var/srv/$d/" "/var/lib/restic/ssd/pool-copy/srv/$d/"
done
for d in immich/postgres immich/dumps syncthing/config opdshelf agent/local agent/general agent/model; do
  sudo install -d -m 0755 "/var/lib/restic/ssd/pool-copy/lib/$(dirname "$d")"
  sudo rsync -aHAX --numeric-ids --one-file-system "/var/lib/$d/" "/var/lib/restic/ssd/pool-copy/lib/$d/"
done
```

Space: the tree is ~270 GiB logical (`zfs list -o logicalused`) because the pool
compresses with zstd, and the 970 has 661 GiB free. The restic repository stays
on the same disk as the second copy.

**Prove the copy before touching a partition.** A second pass that compares
checksums must print nothing:

```sh
sudo rsync -aHAX --numeric-ids --checksum -ni /var/srv/photos/ /var/lib/restic/ssd/pool-copy/srv/photos/
```

## B. Stop the writers

A live PGDATA or sqlite file copies into a corrupt tree, and a timer that fires
against the empty pool snapshots nothing, tags it `verified`, and leaves the
verifier green. Stop the timers first, then the applications:

```sh
sudo systemctl stop smortress-restic-backup-ssd.timer smortress-restic-backup-hdd.timer \
  smortress-restic-backup-r2.timer smortress-restic-verify.timer smortress-immich-dump.timer
sudo systemctl stop immich-server.service immich-machine-learning.service immich-postgres.service \
  immich-valkey.service opdshelf.service syncthing.service
sudo systemctl stop 'smortress-agent-*'
```

Copy immich's state and syncthing's config only now, not in phase A, if any of
them was still writing when the loop ran.

## C. Rebuild p5, grow p4

```sh
sudo systemctl stop zfs-mount smortress-zpool
sudo zpool export smortress                 # unmounts every dataset
sudo zpool labelclear -f /dev/mapper/data   # the second vdev label sits at the disk tail
sudo cryptsetup close data
sudo wipefs -a /dev/disk/by-partlabel/luks-data
sudo parted /dev/nvme0n1 rm 5
sudo parted /dev/nvme0n1 resizepart 4 307200MiB
sudo partx -u /dev/nvme0n1
sudo cryptsetup resize root
sudo xfs_growfs /var
df -h /var                                 # expect 300G
```

Clear the labels before the partition goes, not just the LUKS header:
`init-zpool` branches on `blkid` reporting `zfs_member`, and a stale trailing
label under the new partition's tail is what makes it try to import a pool that
is not there and exit 1.

If `partx` refuses because a partition is in use, reboot instead: dracut resizes
the root mapping on open, and the `xfs_growfs` above runs after it.

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

Check the installed table before trusting it: `docs/core/storage-migration.md`
warns that an installed `init-zpool` can predate `scripts/storage-layout.sh`,
and a stale table silently skips `repo-archive` and the `agent-*` datasets.

```sh
/usr/libexec/init-zpool --print-plan
sudo /usr/libexec/zfs-ready raw-files
```

Then confirm the offline recovery passphrase still opens the data volume. Ignition
wrote `/etc/luks/data` as the recovery passphrase, but a host that ever ran
`scripts/init-data-luks.sh` on a missing key file holds a random key instead, and
a re-format keeps only the keyslot that key forms:

```sh
sudo cryptsetup open --test-passphrase --key-file /etc/luks/data /dev/disk/by-partlabel/luks-data
```

If the kit's passphrase is not that value, add it as a second keyslot now, before
anything else is written.

## E. Move the tree back

```sh
for d in files photos books music wallpapers apps repo-archive; do
  sudo rsync -aHAX --numeric-ids "/var/lib/restic/ssd/pool-copy/srv/$d/" "/var/srv/$d/"
done
for d in immich/postgres immich/dumps syncthing/config opdshelf agent/local agent/general agent/model; do
  sudo rsync -aHAX --numeric-ids "/var/lib/restic/ssd/pool-copy/lib/$d/" "/var/lib/$d/"
done
sudo rsync -aHAX /var/lib/restic/ssd/pool-copy/srv/git/ /var/srv/git/
```

Then, in order:

1. `sudo install -d -o 1000 -g 1000` on the group roots if `init-zpool` did not
   own them; application trees are uid 1000 and Podman may only mount labelled
   content, so `sudo chcon -R -t container_file_t` the restored trees as
   `docs/manual-steps.md` section 40.18 does for a drill.
2. `sudo /usr/libexec/zfs-ready raw-files` (and `state-immich-postgres`) before
   any unit that `Requires=` them starts.
3. Start the applications, then the timers.
4. Run every drill: `sudo scripts/agent-runtime-drill.sh restore agent-local
   --backend ssd` for the agent side, and section 40.18's unit loop for the media
   side. A pool that came back without a passing drill is not restored.
5. Take a fresh backup (`sudo /usr/libexec/smortress-restic-backup ssd`) and let
   `smortress-restic-verify` go green, then delete
   `/var/lib/restic/ssd/pool-copy`.

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
