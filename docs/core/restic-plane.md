# Restic backup plane (T3)

Three independent repositories, one shared password, one job per restore unit
per destination. This document is the host contract: layout, schedule, tags,
retention, what a failed run means, how to restore by hand, and what is still
unproven. Operator actions are in `docs/manual-steps.md` section 38; the disks,
ZFS pool and readiness units are described in `docs/core/server-image.md`.

Everything here runs on the host: bash, systemd, `restic` 0.19.1, `zfs`, `jq`,
`flock`, `curl`. No Nix, no container, no second scheduler.

## Destinations

| Backend | Repository | Mount | Schedule | Timer |
| --- | --- | --- | --- | --- |
| `ssd` | `/var/lib/restic/ssd/restic` | 970, ext4 `LABEL=restic-ssd`, `/var/lib/restic/ssd` | hourly at `:05` | `smortress-restic-backup-ssd.timer` |
| `hdd` | `/var/lib/restic/hdd/restic` | 5 TB HDD, ext4 `LABEL=restic-hdd`, `/var/lib/restic/hdd` | hourly at `:05` | `smortress-restic-backup-hdd.timer` |
| `r2` | `s3:https://385f7d47e2e8438fbda5d6f76d760434.r2.cloudflarestorage.com/homelab-restic/smortress` | none | daily at `00:00` | `smortress-restic-backup-r2.timer` |

The mount units key on the filesystem UUID, not on a device name:

- `var-lib-restic-ssd.mount`: `e040eab7-3df0-4b7d-96e0-71fb9a5eff93`
- `var-lib-restic-hdd.mount`: `973b7492-bb88-43c7-bac3-772384e45220`

Both are `WantedBy=local-fs.target`, so neither can block boot. The HDD is the
one with `nofail` semantics by contract: `JobTimeoutSec=45` bounds the wait for
a missing device, the HDD jobs then record failures, and the freshness verifier
turns that into an alert. A missing 970 is treated the same way at boot; unlike
the HDD it is expected to be present, and its jobs fail until it is.

The R2 bucket and repository path already exist. The write key pair is read from
SOPS (`r2_access_key_id`, `r2_secret_access_key`); when either is absent or
empty the `r2` jobs record failures and the verifier stays red rather than
skipping the destination. The legacy migration repository is a different bucket
and is never referenced by this plane.

## Restore units and snapshot paths

A unit is the application, and it names the datasets restored together: `files`
(`raw/files` + `state/syncthing-config`), `photos` (`raw/photos` +
`state/immich-postgres` + `state/immich-dumps`), `books` (`raw/books` +
`state/opdshelf`), and the raw-only `music`, `wallpapers`, `git`, `apps` and
`repo-archive`. The table in `scripts/storage-layout.sh` is the single source;
`/srv` holds raw data and `/var/lib` holds the state no raw file regenerates.

A job snapshots **every dataset in its unit** and passes all of their staging
paths to one restic snapshot:

```text
zfs snapshot smortress/raw/photos@<backend>
zfs snapshot smortress/state/immich-postgres@<backend>
zfs snapshot smortress/state/immich-dumps@<backend>
restic backup /var/srv/photos/.zfs/snapshot/<backend> \
              /var/lib/immich/postgres/.zfs/snapshot/<backend> \
              /var/lib/immich/dumps/.zfs/snapshot/<backend>
```

The staging snapshot name is the backend name, so one unit/backend job never
touches another job's snapshot. Never pass a parent snapshot path: a parent
snapshot cannot expose a child dataset's contents, and the resulting
"successful" backup would silently be empty. Adding a dataset to a unit means
adding it to that unit's path list, which changes the `host,paths` identity and
therefore starts a new retention family.

## Tags and identity

Every snapshot is written with:

- `--host smortress`
- `--tag unit:<unit>`
- `--tag host:smortress`
- the unit's fixed path list

After exit 0 the snapshot is tagged `verified` in a separate command. Restic's
`host,paths` parent selection and retention address the same unit because
those two values never change for a given unit/backend. An incomplete snapshot
(exit 3) is never tagged and can never be selected by retention or by the
verifier.

## A run: states and persistence

The driver `smortress-restic-backup <backend>` runs every unit for one backend,
in order, recording each result before moving on. Nothing is reported until all
units and the maintenance step have finished; the unit then fails if any of
them failed.

State lives under `/var/lib/homelab/restic`:

| Path | Contents | Mode |
| --- | --- | --- |
| `state/<backend>-<unit>.json` | current run, last success, final snapshot, pending reap list | `0600` |
| `journal/<backend>-<unit>.jsonl` | one line per completed attempt | `0600` |
| `locks/<backend>-<unit>.lock` | flock serialization point | `0600` |
| `maintenance/<backend>.{daily,check}` | maintenance stamps | `0600` |
| `maintenance/<backend>.log` | forget/prune/check output | `0600` |

`state/` is written as temp file → `fsync` → rename; journal lines are appended
and `fsync`ed. The directory tree is `0700 root:root`.

Attempt states:

1. `running` — written and synced *before* any command runs, with the attempt
   number and start time. This is what detects a SIGKILL or power loss: the
   record exists even when no completion was written.
2. `success` — restic exited 0, returned a snapshot ID, the `verified` tag was
   added, and the final snapshot ID/result were persisted. `last_success` and
   `final` are written in the same successful completion.
3. `failure` — anything else, with a reason and, when restic produced one, the
   snapshot ID.

A run is **failed** when any of these happens:

| Reason | Cause |
| --- | --- |
| `lock-timeout` | the per-job flock was not acquired within `RESTIC_LOCK_WAIT` |
| `readiness` | `/usr/libexec/zfs-ready <instance>` refused: dataset missing, unmounted, wrong mountpoint |
| `repo-not-mounted` | the local repository path is not the exact mountinfo mountpoint |
| `snapshot-path-missing` | `<mountpoint>/.zfs/snapshot` is absent |
| `snapshot-reconcile` / `snapshot-create` | `zfs destroy` or `zfs snapshot` failed or timed out |
| `exit-<n>` | restic exited 1, 3, 10, 11, 12 or anything else non-zero |
| `timeout` | the per-command deadline fired (exit 124/137) |
| `no-snapshot-id` | exit 0 without a snapshot ID in the JSON summary |
| `tag-failed` | `restic tag --add verified` failed |
| `persist-failed` | the tag succeeded but the result could not be written durably |
| `not-configured` | the R2 key pair is absent or empty in SOPS; no job touches that repository |

The attempt is retried `RESTIC_ATTEMPTS` times (default 2) with a bounded sleep
between attempts. Every command — `zfs list/destroy/snapshot`, `restic
backup/tag/snapshots/forget/prune/check`, `curl` — goes through `timeout`, so a
hang is a recorded failure, not a wedged unit. `TimeoutStartSec` in the unit is
only a safety net above those.

Cleanup is best effort by design. On normal exit and on TERM/INT the job
destroys its own staging snapshot; after SIGKILL or power loss the next
invocation reconciles it. Reconciliation happens *after* the lock is acquired
and destroys only `<dataset>@<backend>` for its own unit — never another job's
snapshot.

## Retention

Retention runs repository-wide, once per backend per day, after that backend's
jobs (including failed ones). For every restore unit:

```text
restic forget --host smortress \
  --tag unit:<unit> --tag verified \
  --keep-daily 14 --keep-weekly 8 --keep-monthly 12
```

Both tags are required, so an incomplete or unverified snapshot cannot occupy a
bucket and displace a complete restore point. 14/8/12 is four-hourly to daily
resolution: hourly jobs shorten the normal recovery-point interval, they do not
provide fourteen days of hourly restore points.

One `restic prune` follows the per-unit forgets. A weekly
`restic check --read-data-subset=1/30` is part of the same maintenance pass.
Maintenance is attempted at most once per day (weekly for the check); a failure
is recorded in `state/<backend>-maintenance.json`, printed to the journal, and
makes the driver unit red, but is not retried until the next window so a failed
prune cannot re-run hourly.

Failed snapshots are removed only by their recorded IDs (`pending_reap`), and
only after a successful `restic snapshots` query shows the ID still exists.
There is no "delete every untagged snapshot" step: a good snapshot is untagged
between backup and tag, and a bulk delete would race it.

Restic's own repository lock serializes forget/prune/check against backups. An
exit 11 (lock conflict) is a failed attempt and is retried; there is no routine
`unlock`. A stale lock is cleared by hand only after confirming the holder is
gone (`docs/core/restic-plane.md` restore section and restic's `unlock` docs),
never by a timer.

## Freshness verifier

`smortress-restic-verify` runs hourly at `:40`, after the `:05` jobs and their
bounded retries, and checks every backend/unit pair (24 checks). It fails
closed on anything it cannot prove.

**The join.** For each pair it reads the durable state and the repository:

1. `state/<backend>-<unit>.json` and the journal must exist and parse.
2. The latest recorded attempt is authoritative:
   - `running` and younger than the run expiry → still in flight, not a fail;
   - `running` and older than the run expiry → fail (SIGKILL/power loss);
   - `failure` → fail, regardless of any older success;
   - `success` → the attempt's snapshot must equal `final.snapshot` and
     `last_success.snapshot`.
3. `last_success.end` must be no older than the maximum age for the backend.
4. `restic snapshots --json --host smortress --path <staging path>` must return
   exactly one snapshot with the recorded final ID, and that snapshot must:
   - carry `verified`, `unit:<unit>` and `host:smortress`;
   - report `hostname == smortress`;
   - have exactly `[<staging path>]` as its paths;
   - be the newest snapshot for that host/path;
   - be no older than the maximum age.

**An older success cannot hide a newer expired run.** Because step 2 uses the
latest attempt and not `last_success`, a failure at 10:05 fails the 10:40
verification even though the 09:05 snapshot is recent and present. A run that
died without writing a completion leaves `running` behind and expires after the
run window. The persisted `final` snapshot is cross-checked against the attempt,
so a success whose result could not be written also fails.

**Thresholds.** Schedule + every bounded retry + grace:

| Backend | Schedule | Per-attempt deadline | Attempts | Run expiry | Max snapshot age |
| --- | --- | --- | --- | --- | --- |
| `ssd`, `hdd` | 3600 s | 1800 s | 2 (+60 s sleep) | 4320 s | 8400 s |
| `r2` | 86400 s | 14400 s | 2 (+600 s sleep) | 31800 s | 118800 s |

Run expiry is `attempts × (deadline + sleep) + grace` (600 s local, 1800 s r2);
max age adds the schedule interval and a grace of 1080 s (local) or 2400 s
(r2): `8400 = 3600 + 2×1860 + 1080` and `118800 = 86400 + 2×15000 + 2400`.

The repository query is read-only and uses `restic snapshots --no-lock`: a prune
holding the exclusive lock must not manufacture a freshness failure, and an
hourly check should not leave a lock object in R2. The verifier never writes to
a repository.

**Reporting.** If every pair passes, the verifier pings the Healthchecks check
and exits 0. If anything fails, it pings `<url>/fail` (best effort, so Pushover
fires immediately) and exits 1. A missing ping URL, a missing state file, an
unreadable repository or a failed ping all exit non-zero: the check must go red
rather than be silently unmonitored. The URL is read from SOPS
(`healthchecks.yaml`, key `restic-ping-url`) and never logged.

Healthchecks.io owns the dead-man timer and Pushover delivery. Nothing on the
host sends notifications, and no ntfy or observability stack is involved.

## Secrets

| File (decrypted at boot) | Key | Use |
| --- | --- | --- |
| `/run/smortress/secrets/restic-password.yaml` | single value | `RESTIC_PASSWORD_FILE` for all three repositories |
| `/run/smortress/secrets/r2-credentials.yaml` | `r2_access_key_id`, `r2_secret_access_key` | exported as `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` for `r2` only |
| `/run/smortress/secrets/healthchecks.yaml` | `restic-ping-url` | verifier ping URL |

`restic-password.yaml` is decrypted with `format=value` in
`image/rootfs/etc/smortress/secrets.manifest`, so the file contains only the
password; restic cannot read a YAML document with a key. Credentials reach
restic through the environment, never argv, and are never printed.
`r2-credentials.yaml` is committed ciphertext and is listed in the manifest.
`healthchecks.yaml` is absent until the operator creates the check (section 38
step 3): listing a ciphertext before it exists fails `sops-decrypt.service`
and every dependent unit, so the file and its manifest line are added in the
same image build.

## Restore by hand

On the host (or any machine with restic and the password):

```sh
export RESTIC_PASSWORD_FILE=/run/smortress/secrets/restic-password.yaml

# What exists, newest last, verified only:
sudo /usr/libexec/smortress-restic-restore-drill ssd photos --list

# Restore the newest verified snapshot of one unit into /var/tmp:
sudo /usr/libexec/smortress-restic-restore-drill ssd photos

# A specific snapshot:
sudo /usr/libexec/smortress-restic-restore-drill r2 books --snapshot <id> \
  --target /var/tmp/drill-books
```

The helper restores every path in the unit under
`<target>/<mountpoint>/.zfs/snapshot/<backend>/` because those are the absolute
paths the backup recorded. It refuses a non-empty
target and only accepts `verified` snapshots. Check the contents, not the exit
status.

The raw equivalent, for any machine:

```sh
export RESTIC_PASSWORD_FILE=<file with only the password>
restic -r /var/lib/restic/ssd/restic snapshots --host smortress \
  --tag unit:photos --tag verified
restic -r /var/lib/restic/ssd/restic restore <id> --target /var/tmp/drill --verify
```

For `r2` set `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and use the URI from
the table above. Restore into a scratch tree; never restore over a live dataset
while the applications are writing.

## Failure semantics summary

| Event | Result |
| --- | --- |
| restic exit 1/3/10/11/12 | failed run; exit-3 snapshot ID recorded for reaping; never tagged |
| restic exit 0, no snapshot ID | failed run, nothing recorded as successful |
| tag failure | failed run; the untagged snapshot ID is reaped by recorded ID |
| result-persistence failure | failed run; the verifier cross-check fails closed |
| SIGTERM/INT | staging snapshot destroyed best effort, exit 143, `running` left behind and expired by the verifier |
| SIGKILL/power loss | stale staging snapshot reconciled next run |
| HDD/SSD unmounted | that backend's jobs record `repo-not-mounted`; other backends continue |
| one dataset not ready | only that unit's job records `readiness`; others continue |
| R2 credentials absent | every `r2` group records `not-configured`; verifier stays red |
| lock conflict | bounded retry; then failed run |
| prune/check failure | maintenance recorded, driver red, retried next daily/weekly window |

## What is not proven yet

These need the physical host and are not claimed by the repository tests:

- Both mounts appearing at the UUIDs after boot, and the HDD `nofail` behaviour
  with the disk unplugged.
- ZFS snapshot visibility at `.zfs/snapshot/<backend>` for every group, and the
  first real restic backup reading it.
- The first full R2 upload fitting `RESTIC_DEADLINE_R2` (4 h); if it does not,
  run the driver by hand with a longer deadline and let the hourly/daily timers
  continue afterwards.
- Healthchecks.io delivery through Pushover, and the `/fail` ping path.
- Prune/check runtimes, restic lock contention between a prune and the hourly
  jobs, and `read-data-subset` cost on the 5 TB repository.
- A cold restore of every group from each destination (the T6 gate), including
  ownership and database recovery.

## Local proof

`tests/core/restic-plane.sh` (also run by `tests/core/check.sh`) stubs restic,
zfs, curl and sops and asserts: exit-code handling for 0/1/3, the verified-tag
gate, `pending_reap` for failed IDs, stale-staging reconciliation before
creation, readiness and mount gates that prevent any backup, retention carrying
both tags, no wildcard retention or bulk deletion, the fail-closed freshness
join (missing state, newer failure over an older success, expired running
attempt, missing repository snapshot, unverified tag/wrong path), repository
init refusing an unmounted or non-empty directory, and `format=value` in
`sops-decrypt`. `scripts/check-server-image.sh` asserts the static shape: mount
units present with the right UUIDs, every restic unit enabled, the driver
ordered after all five readiness instances, and both tags on every retention
command.
