# Storage migration window (data-kind layout)

The one-time move from `/var/tank` to the split layout — pool `smortress`, raw
datasets under `/var/srv`, backed-up state under `/var/lib` — and the primary
account renamed `smores`. Every step needs `sudo`; the account rename ends the
session that runs it, so work from the console or a session you can lose.

The unit table is `scripts/storage-layout.sh`; the plane it feeds is described
in `docs/core/restic-plane.md`. Installed helpers live in `/usr/libexec/…`, not
on `PATH`.

## 0. Preconditions

- The offline recovery kit exists and its passphrases open the data LUKS
  (`docs/core/recovery-kit.md`); both legacy repositories verify.
- The current plane is healthy: `sudo /usr/libexec/smortress-restic-verify`.
- You hold the `smores` password hash (`ignition/operator/smores-password-hash`,
  `openssl passwd -6`), the YubiKey for `sudo`, and console access.
- Confirm the running image contains `storage-layout`: the sweep ships it to
  `/usr/libexec/storage-layout` (`image/Containerfile`), and every helper here
  sources it.

Stop the writers:

```sh
sudo systemctl stop smortress-restic-backup-ssd.timer smortress-restic-backup-hdd.timer \
  smortress-restic-backup-r2.timer smortress-restic-verify.timer smortress-immich-dump.timer
sudo systemctl stop immich-server.service immich-machine-learning.service immich-postgres.service \
  immich-valkey.service opdshelf.service syncthing.service
```

## 1. Rename the pool

```sh
sudo zpool export tank
sudo zpool import tank smortress
sudo zpool set cachefile=none smortress
sudo zpool list -o name,size,altroot          # smortress
```

`init-zpool` imports by name from `/dev/mapper`. The old child datasets come back
at their stored `/var/tank/<group>` mountpoints; the new ones do not exist yet.

## 2. Reconcile datasets

```sh
sudo /usr/libexec/init-zpool --print-plan     # look before touching anything
sudo /usr/libexec/init-zpool
sudo zfs list -o name,mountpoint              # raw/* → /var/srv, state/* → /var/lib
```

## 3. Move the data

Move *every* tree, not just the state:

```sh
# Raw content
for pair in photos:/var/srv/photos books:/var/srv/books music:/var/srv/music \
  wallpapers:/var/srv/wallpapers notes:/var/srv/files; do
  src=/var/tank/${pair%%:*}
  dst=${pair#*:}
  [[ -n $(ls -A "$src" 2>/dev/null) ]] || continue
  sudo rsync -aHAX --remove-source-files "$src/" "$dst/"
done

# Immich state: the old PGDATA becomes the new dataset root
sudo rsync -aHAX --remove-source-files /var/tank/photos/postgres/ /var/lib/immich/postgres/
sudo rsync -aHAX --remove-source-files /var/tank/photos/db-dumps/ /var/lib/immich/dumps/
# OPDShelf state
sudo rsync -aHAX --remove-source-files /var/tank/books/.opdshelf/ /var/lib/opdshelf/
# Syncthing identity and version history
sudo rsync -aHAX --remove-source-files /var/tank/syncthing/config/ /var/lib/syncthing/config/
sudo rsync -aHAX /var/tank/syncthing-versions/ /var/lib/syncthing/versions/
# Platform state (age identity, HDD keyfile, restic journals)
sudo install -d -m 0700 /var/lib/homelab/age /var/lib/homelab/keys
[[ -d /var/lib/smortress/age ]] && sudo cp -a /var/lib/smortress/age/. /var/lib/homelab/age/
[[ -d /var/lib/smortress/keys ]] && sudo cp -a /var/lib/smortress/keys/. /var/lib/homelab/keys/
```

Verify before destroying anything: `sudo diff -qr` each source against its
destination must be empty, and `du -sh` must match. Then retire the old
datasets, which is what makes `/var/tank` disappear:

```sh
sudo zfs destroy smortress/photos smortress/books smortress/notes smortress/music \
  smortress/wallpapers smortress/syncthing
sudo rmdir /var/tank
```

`smortress/raw/*` and `smortress/state/*` are now the only datasets with data.

## 4. Repoint Syncthing's folder

The configuration records host paths, and the volume moved from
`/var/tank/notes` to `/srv/files`:

```sh
sudo sed -i 's|/var/tank/notes|/srv/files|g' /var/lib/syncthing/config/config.xml
sudo grep -o '<folder[^>]*path="[^"]*"' /var/lib/syncthing/config/config.xml
```

The folder path must be `/srv/files` (or a subdirectory of it). A restore of the
`files` unit needs the same edit before Syncthing starts.

## 5. Start the new plane

```sh
sudo systemctl restart smortress-zpool.service
sudo systemctl daemon-reload
sudo systemctl restart smortress-app-secrets.service
sudo systemctl start immich-postgres.service immich-valkey.service immich-machine-learning.service \
  immich-server.service opdshelf.service syncthing.service
sudo systemctl start smortress-restic-backup-ssd.timer smortress-restic-backup-hdd.timer \
  smortress-restic-backup-r2.timer smortress-restic-verify.timer smortress-immich-dump.timer
```

Per service: `systemctl status`, the journal, and the loopback port. A unit that
reports `nothing is mounted at /var/srv/<group>` means the dataset is not ready;
fix that before starting the application. `zfs-ready` is required, not merely
ordered, so a missing dataset fails the unit.

## 6. Rename the account

From the console, as root. This ends the `core` session.

```sh
sudo systemctl stop 'container-*' 2>/dev/null || true
sudo loginctl terminate-user core || true
sudo usermod -l smores -d /var/home/smores -m core
sudo groupmod -n smores core
sudo sed -i 's/^core:/smores:/' /etc/subuid /etc/subgid
sudo chown -R smores:smores /var/home/smores
```

Then, logged in as `smores`: enrol the YubiKey for `sudo`, re-link the dotfiles
so the absolute symlinks under `~` point at `/var/home/smores`, and confirm
`sshd -T | grep allowusers` reports `smores`.

## 7. Prove the new plane

```sh
sudo /usr/libexec/smortress-restic-backup ssd --unit photos
sudo /usr/libexec/smortress-restic-backup ssd --unit files
sudo /usr/libexec/smortress-restic-backup ssd --unit repo-archive
sudo /usr/libexec/smortress-restic-verify
sudo /usr/libexec/smortress-restic-restore-drill ssd photos --target /var/tmp/drill-photos
```

The drill must contain both `/var/tmp/drill-photos/var/srv/photos/…` and
`/var/tmp/drill-photos/var/lib/immich/postgres/…` from the same snapshot, and
the restored database must start against the restored library. Only after this
drill passes is the old family retired:

```sh
for b in ssd hdd; do
  for g in photos books notes music wallpapers syncthing; do
    sudo env RESTIC_PASSWORD_FILE=/run/smortress/secrets/restic-password.yaml \
      restic -r /var/lib/restic/$b/restic forget --host smortress \
      --path "/var/tank/$g/.zfs/snapshot/$b" --tag "group:$g" --tag verified --prune
  done
done
sudo env RESTIC_PASSWORD_FILE=/run/smortress/secrets/restic-password.yaml \
  restic -r /var/lib/restic/ssd/restic snapshots | head   # no /var/tank rows
```

R2 keeps its old-family snapshots until the same `forget` runs against it with
its credentials loaded.

## 8. Acceptance

- `zfs list` shows `smortress`, no dataset mounted at `/var/tank`.
- `grep -rn '/var/tank' /usr/libexec /usr/share/smortress || true` is empty.
- `smortress-restic-verify` pings Healthchecks, and every unit has today's
  snapshot whose paths are under `/var/srv` or `/var/lib`.
- A `photos` and a `books` drill start both applications after the documented
  `chown`/`chcon`.
- `id` reports `smores`, `sshd -T` allows only `smores`, and
  `/var/lib/homelab/{age,keys}` holds the identity and keyfile.
