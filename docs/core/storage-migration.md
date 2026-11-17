# Storage migration window (data-kind layout)

This is the one-time move from `/var/tank` to the split layout: pool `smortress`,
raw datasets under `/var/srv`, backed-up state under `/var/lib`, and the primary
account renamed `smores`. It is operator work — every step needs `sudo`, and the
account rename ends the session that runs it.

Read `docs/core/restic-plane.md` first; the unit table it refers to is
`scripts/storage-layout.sh`. Run every step on the console or a session you can
lose: the tailscale path may drop when the account is renamed.

## 0. Preconditions

- The offline recovery kit exists and its passphrases open the data LUKS
  (`docs/core/recovery-kit.md`), and both legacy repositories verify
  (`scripts/core/verify-legacy-backups.sh`).
- The current plane is healthy: `sudo smortress-restic-verify`.
- You hold the `smores` password hash for Ignition
  (`ignition/operator/smores-password-hash`, `openssl passwd -6`) and the
  YubiKey you want for `sudo`.
- Nothing else is writing: stop the application timers and units.

```sh
sudo systemctl stop smortress-restic-backup-ssd.timer smortress-restic-backup-hdd.timer \
  smortress-restic-backup-r2.timer smortress-restic-verify.timer smortress-immich-dump.timer
sudo systemctl stop immich-server.service immich-machine-learning.service immich-postgres.service \
  immich-valkey.service opdshelf.service syncthing.service
```

## 1. Record the old snapshot family

Retention selects by `host,paths`. Every snapshot taken under `/var/tank` becomes
unreachable to the new jobs, so it is retired now, not orphaned.

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

R2 keeps its daily snapshots until the new family replaces them; `restic forget`
for the same paths against the R2 repository is the equivalent step when its
credentials are loaded.

## 2. Rename the pool

```sh
sudo zpool export tank
sudo zpool import tank smortress
sudo zpool set cachefile=none smortress
sudo zpool list -o name,size,altroot          # smortress
```

`init-zpool` imports the pool by name from `/dev/mapper`, so the rename in code
and on the device must land together; the boot after this step proves it.

## 3. Reconcile datasets

`init-zpool` creates the new datasets and sets their mountpoints from the table.
The raw datasets keep their data; only their mountpoints change.

```sh
sudo /usr/libexec/init-zpool        # or: sudo scripts/init-zpool.sh --print-plan first
sudo zfs list -o name,mountpoint    # raw/* under /var/srv, state/* under /var/lib
```

Then move the state that currently lives inside a raw dataset:

```sh
# Immich: the old PGDATA was /var/tank/photos/postgres; the new dataset root is PGDATA.
sudo rsync -aHAX --remove-source-files /var/tank/photos/postgres/ /var/lib/immich/postgres/
sudo rsync -aHAX --remove-source-files /var/tank/photos/db-dumps/ /var/lib/immich/dumps/

# OPDShelf state
sudo rsync -aHAX --remove-source-files /var/tank/books/.opdshelf/ /var/lib/opdshelf/

# Syncthing identity and version history
sudo rsync -aHAX --remove-source-files /var/tank/syncthing/config/ /var/lib/syncthing/config/
sudo rsync -aHAX /var/tank/syncthing-versions/ /var/lib/syncthing/versions/

# The vault becomes /srv/files (the notes group is empty on a fresh plane)
sudo rsync -aHAX --remove-source-files /var/tank/notes/ /var/srv/files/
```

Stop and compare before deleting anything: `diff -qr` between each source and
destination must be empty, and `sudo du -sh` must match. The old paths are then
removed with the dataset (`/var/tank` itself disappears with the rename below).

`PGDATA` is now the dataset root: the postgres container mounts
`/var/lib/immich/postgres` at `/data` and expects `PG_VERSION` at `/data`.

## 4. Repoint every consumer

```sh
sudo systemctl daemon-reload
sudo systemctl restart smortress-app-secrets.service
sudo systemctl start immich-postgres.service immich-valkey.service immich-machine-learning.service \
  immich-server.service opdshelf.service syncthing.service
sudo systemctl start smortress-restic-backup-ssd.timer smortress-restic-backup-hdd.timer \
  smortress-restic-backup-r2.timer smortress-restic-verify.timer smortress-immich-dump.timer
```

Check, per service: `systemctl status`, the unit journal, and the loopback port
(`curl -fsS http://127.0.0.1:<port>/`). A unit that reports
`nothing is mounted at /var/srv/<group>` means the dataset is not ready — fix
that before starting the application.

## 5. Rename the account

Do this last, from the console, and expect your SSH session to end.

```sh
sudo systemctl stop 'container-*' 2>/dev/null || true
sudo loginctl terminate-user core
sudo usermod -l smores -d /var/home/smores -m core
sudo groupmod -n smores core
sudo sed -i 's/^core:/smores:/' /etc/subuid /etc/subgid
sudo chown -R smores:smores /var/home/smores
```

Then, on the new session:

- `sudo -l` as `smores`; enrol the YubiKey for `sudo` as the design describes.
- Re-link the dotfiles (`mise`/the repository's link step) so the absolute
  symlinks under `~` point at `/var/home/smores`.
- Confirm `AllowUsers smores` is in the running sshd (`sshd -T | grep allowusers`).
- Re-run this session as `smores`, and re-run the checks below.

## 6. Prove the new plane

```sh
sudo smortress-restic-backup ssd --unit photos
sudo smortress-restic-backup ssd --unit files
sudo smortress-restic-backup ssd --unit repo-archive
sudo smortress-restic-verify
sudo /usr/libexec/smortress-restic-restore-drill ssd photos --target /var/tmp/drill-photos
```

The drill must contain both `/var/tmp/drill-photos/var/srv/photos/...` and
`/var/tmp/drill-photos/var/lib/immich/postgres/...` from the same snapshot, and
the restored database must start against the restored library. Only then delete
the old `/var/tank` tree if the dataset rename left one behind.

## 7. Acceptance

- `zfs list` shows `smortress` and no `/var/tank` mountpoint.
- `grep -rn '/var/tank' /usr/libexec /usr/share/smortress || true` is empty.
- `smortress-restic-verify` pings Healthchecks and every unit has a snapshot
  from today whose paths are under `/var/srv` or `/var/lib`.
- A restore drill of `photos` and `books` starts both applications from the
  restored tree after the documented `chown`/`chcon`.
- `id` reports `smores`, and `sshd -T` allows only that account.
