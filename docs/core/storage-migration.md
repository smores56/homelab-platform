# Storage migration window (data-kind layout)

The one-time move from `/var/tank` to the split layout — pool `smortress`, raw
datasets under `/var/srv`, backed-up state under `/var/lib` — plus the primary
account renamed `smores`.

**Order matters.** The migration runs on the *current* image, from a checkout of
this repository at the merge commit, because the new image's units expect the
new layout on first boot. Upgrade only after the data is moved; the new units
then start against a host that already matches them.

Run it from a tailnet SSH session for phases A–B, and at the console for phase C:
renaming the account ends the session, and the old image's sshd only allows
`core` while the new one allows `smores`.

## A. Prepare (SSH, unprivileged checks)

```sh
cd ~/ghq/github.com/smores56/homelab-platform   # or wherever the checkout lives
git log --oneline -1                            # must contain storage-layout.sh
ls scripts/storage-layout.sh
```

- Offline recovery kit exists and its passphrases open the data LUKS
  (`docs/core/recovery-kit.md`).
- `sudo /usr/libexec/smortress-restic-verify` is green.
- You hold the `smores` password (`secrets/server/smortress-password-hash.yaml`,
  a sha512crypt hash minted with `openssl passwd -6`, docs/manual-steps.md
  section 37), the YubiKey for `sudo`, and console access.
- The SSD/HDD repositories have room for one more copy of the raw data
  (`df -h /var/lib/restic/ssd /var/lib/restic/hdd`).

Stop the writers:

```sh
sudo systemctl stop smortress-restic-backup-ssd.timer smortress-restic-backup-hdd.timer \
  smortress-restic-backup-r2.timer smortress-restic-verify.timer smortress-immich-dump.timer
sudo systemctl stop immich-server.service immich-machine-learning.service immich-postgres.service \
  immich-valkey.service opdshelf.service syncthing.service
```

## B. Migrate the data (SSH, from the checkout)

Every helper below is the repository's own script, run against the host. Do not
use `/usr/libexec/…` yet: the running image predates the table.

### B1. Rename the pool

```sh
sudo zpool export tank
sudo zpool import tank smortress
sudo zpool set cachefile=none smortress
sudo zpool list -o name,size,altroot
```

The old child datasets return at their stored `/var/tank/<group>` mountpoints.

### B2. Create the new datasets

```sh
sudo ./scripts/init-zpool.sh --print-plan     # read it before running it
sudo ./scripts/init-zpool.sh
sudo zfs list -o name,mountpoint
```

### B3. Copy the data (state first)

Media and state live inside the same old dataset, so take the state out before
the bulk copy — copying a whole `photos` tree first would put `postgres/` and
`db-dumps/` inside the raw dataset. Copy, do not move: the attic in B4 keeps the
original until the drills pass.

```sh
# Immich state: the old PGDATA becomes the new dataset root
sudo rsync -aHAX /var/tank/photos/postgres/ /var/lib/immich/postgres/
sudo rsync -aHAX /var/tank/photos/db-dumps/ /var/lib/immich/dumps/

# Syncthing identity and version history
sudo rsync -aHAX /var/tank/syncthing/config/ /var/lib/syncthing/config/
sudo rsync -aHAX /var/lib/syncthing-versions/ /var/lib/syncthing/versions/

# The media tree's *contents* are the /srv/photos dataset root, because the
# Quadlet mounts that root at /data/library.
sudo rsync -aHAX /var/tank/photos/library/ /var/srv/photos/

# The vault: its contents become /srv/files, which is the Syncthing folder.
# On a host where the notes dataset is already empty this is a no-op.
if [[ -d /var/tank/notes/vault ]]; then
  sudo rsync -aHAX /var/tank/notes/vault/ /var/srv/files/
elif [[ -n $(ls -A /var/tank/notes 2>/dev/null) ]]; then
  sudo rsync -aHAX /var/tank/notes/ /var/srv/files/
fi

# Empty or small groups
for pair in books:/var/srv/books music:/var/srv/music wallpapers:/var/srv/wallpapers; do
  src=/var/tank/${pair%%:*}; dst=${pair#*:}
  [[ -n $(ls -A "$src" 2>/dev/null) ]] && sudo rsync -aHAX "$src/" "$dst/"
done

# Platform state (age identity, HDD keyfile)
sudo install -d -m 0700 /var/lib/homelab/age /var/lib/homelab/keys
[[ -d /var/lib/smortress/age ]] && sudo cp -a /var/lib/smortress/age/. /var/lib/homelab/age/
[[ -d /var/lib/smortress/keys ]] && sudo cp -a /var/lib/smortress/keys/. /var/lib/homelab/keys/
```

Valkey's `appendonlydir/` is deliberately not copied: it lives in an unbacked
directory now and only holds in-flight jobs, so valkey starts empty.

Prove each copy before the next step; all three must print nothing:

```sh
sudo diff -qr --no-dereference /var/tank/photos/postgres /var/lib/immich/postgres
sudo diff -qr --no-dereference /var/tank/photos/library  /var/srv/photos
sudo diff -qr --no-dereference /var/tank/syncthing/config /var/lib/syncthing/config
```

### B4. Retire the old datasets into an attic

Not `destroy`: the attic is the rollback path until the drills pass.

```sh
sudo zfs create -o mountpoint=none -o canmount=off smortress/attic
for d in photos books notes music wallpapers syncthing; do
  sudo zfs rename smortress/$d smortress/attic/$d
  # mountpoint=none unmounts the old tree; without it /var/tank stays busy
  sudo zfs set mountpoint=none smortress/attic/$d
  sudo zfs set canmount=off smortress/attic/$d
done
sudo rmdir /var/tank
sudo zfs list -o name,mountpoint,canmount
```

### B5. Rewrite Syncthing's recorded folder path

```sh
sudo sed -i 's|/var/tank/notes|/srv/files|g' /var/lib/syncthing/config/config.xml
sudo grep -o '<folder[^>]*path="[^"]*"' /var/lib/syncthing/config/config.xml
```

## C. Cut over the image and the account (console)

Fetch the image that contains the new units, disable the old readiness symlinks
(they live in `/etc` and survive upgrades), then rename the account at the
console and reboot. `systemctl disable` the old instances first, or the boot
after the upgrade starts units whose argument no longer exists.

```sh
sudo bootc upgrade                     # stages the newest published image
for g in photos books notes music wallpapers syncthing; do
  sudo systemctl disable "zfs-ready@$g.service" 2>/dev/null || true
done
```

At the console, as root:

```sh
sudo loginctl terminate-user core 2>/dev/null || true
sudo usermod -l smores -d /var/home/smores -m core
sudo groupmod -n smores core
sudo sed -i 's/^core:/smores:/' /etc/subuid /etc/subgid
sudo chown -R smores:smores /var/home/smores
sudo systemctl reboot
```

## D. Prove the new plane (SSH as smores)

```sh
ls -l /usr/libexec/storage-layout
sudo /usr/libexec/zfs-ready raw-photos
for u in immich-postgres immich-valkey immich-machine-learning immich-server opdshelf syncthing; do
  systemctl status --no-pager "$u" | head -3
done
```

Then the plane:

```sh
sudo /usr/libexec/smortress-restic-backup ssd --unit photos
sudo /usr/libexec/smortress-restic-backup ssd --unit files
sudo /usr/libexec/smortress-restic-backup ssd --unit repo-archive
sudo /usr/libexec/smortress-restic-verify
sudo /usr/libexec/smortress-restic-restore-drill ssd photos --target /var/lib/restic/hdd/drill/photos
```

The drill must contain both `/var/lib/restic/hdd/drill/photos/var/srv/photos/…`
and `/var/lib/restic/hdd/drill/photos/var/lib/immich/postgres/…` from the same
snapshot, and the restored database must start against the restored library.
Never stage a restore under `/var/tmp` or anywhere on the 100 GiB root
filesystem: `photos` alone restores more than that, and the helper refuses a
target without room instead of filling the disk.

Re-link the dotfiles as `smores` (the absolute symlinks under `~` still point at
`/var/home/core`), enrol the YubiKey for `sudo`, and confirm
`sshd -T | grep allowusers` reports `smores`.

Two stores under `~` record the old home path as absolute state and fail after
the rename, because `usermod -m` moves the tree without rewriting them:

```sh
# Rootless Podman's database pins the old static dir, and `podman system reset`
# refuses on the same mismatch. The store only holds this account's dev images,
# so move it aside and let Podman initialise a fresh one.
mv ~/.local/share/containers/storage ~/.local/share/containers/storage.stale-core
podman info >/dev/null          # re-initialises under /var/home/smores
podman unshare rm -rf ~/.local/share/containers/storage.stale-core

# mise tools that bake $HOME into their build (python, yamllint, uv/pipx tools,
# conda:zsh) keep the old prefix; reinstall, do not re-link.
mise install -f yamllint python
```

`scripts/bootstrap-task.sh` already reinstalls `conda:zsh` when its modules fail
to load. The `dotfiles` SSH config names `smores` instead of `core`; the
wallpaper SFTP transport this step used to name was deleted with the legacy
stack, so there is nothing to rename there any more.

## E. Retire the old family

Only after D passes, in this order: the old Restic path family, then the attic.

```sh
# `restic forget` with a filter needs a policy; retire by explicit id instead.
for b in ssd hdd; do
  repo=/var/lib/restic/$b/restic
  ids=$(
    sudo env RESTIC_PASSWORD_FILE=/run/smortress/secrets/restic-password.yaml \
      restic -r "$repo" snapshots --json --no-lock --host smortress \
      | jq -r '.[] | select((.tags // []) | index("host:smortress")) | select((.tags // []) | index("verified")) | select(.paths | any(startswith("/var/tank/"))) | .id'
  )
  if [[ -n $ids ]]; then
    sudo env RESTIC_PASSWORD_FILE=/run/smortress/secrets/restic-password.yaml \
      restic -r "$repo" forget $ids
    sudo env RESTIC_PASSWORD_FILE=/run/smortress/secrets/restic-password.yaml \
      restic -r "$repo" prune
  fi
done
sudo env RESTIC_PASSWORD_FILE=/run/smortress/secrets/restic-password.yaml \
  restic -r /var/lib/restic/ssd/restic snapshots | grep -c '/var/tank' || true   # 0
```

R2 keeps its old-family snapshots until the same `forget` runs against it with
its credentials loaded.

## Rollback

Before E, the escape hatch is: boot the previous deployment (`rpm-ostree
rollback`), rename the attic datasets back (`zfs rename smortress/attic/<g>
smortress/<g>`), restore their mountpoints to `/var/tank/<g>`, rename the pool
back (`zpool export smortress; zpool import smortress tank`), and rename the
account back. After E the data exists only in the new layout and in today's
snapshots.

## Acceptance

- `zfs list` shows `smortress` with no dataset mounted at `/var/tank`.
- `grep -rn '/var/tank' /usr/libexec /usr/share/smortress || true` is empty.
- Every unit has today's snapshot whose paths are under `/var/srv` or `/var/lib`,
  and `smortress-restic-verify` pings Healthchecks.
- `photos` and `books` drills start both applications after the documented
  `chown`/`chcon`.
- `id` reports `smores`, `sshd -T` allows only `smores` on a listener bound to
  loopback (`127.0.0.1`/`::1`, #748: the Access tunnel is the only route in), and
  `/var/lib/homelab/{age,keys}` holds the identity and the HDD keyfile.
