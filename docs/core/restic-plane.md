# Restic backup plane (T3)

Three independent repositories, one shared password, one job per restore unit
per destination. This document is the host contract: layout, schedule, tags,
retention, what a failed run means, how to restore by hand, and what is still
unproven. Operator actions are in `docs/manual-steps.md#bringing-the-plane-up`; the disks,
ZFS pool and readiness units are described in `docs/core/server-image.md`.

Everything here runs on the host: bash, systemd, `restic` 0.19.1, `zfs`, `jq`,
`flock`, `curl`. No Nix, no container, no second scheduler.

## Destinations

| Backend | Repository | Mount | Schedule | Timer |
| --- | --- | --- | --- | --- |
| `ssd` | `/var/lib/restic/ssd/restic` | 970, ext4 `LABEL=restic-ssd`, `/var/lib/restic/ssd` | hourly at `:05` | `smortress-restic-backup-ssd.timer` |
| `hdd` | `/var/lib/restic/hdd/restic` | 5 TB HDD, ext4 `LABEL=restic-hdd`, `/var/lib/restic/hdd` | hourly at `:05` | `smortress-restic-backup-hdd.timer` |
| `r2` | `s3:https://385f7d47e2e8438fbda5d6f76d760434.r2.cloudflarestorage.com/homelab-restic/smortress` | none | daily at `00:00` | `smortress-restic-backup-r2.timer` |

The mount units key on an identity the disk keeps, not on a device name:

- `var-lib-restic-ssd.mount`: `LABEL=restic-ssd`. The 970 is re-created by wiping
  it, and a new filesystem means a new UUID, so a UUID here stops matching after
  the first re-wipe. The label survives that.
- `var-lib-restic-hdd.mount`: `973b7492-bb88-43c7-bac3-772384e45220`, its
  filesystem UUID; the disk is repartitioned only under a migration delta.

Both are `WantedBy=local-fs.target`, so neither can block boot. The HDD is the
one with `nofail` semantics by contract: `JobTimeoutSec=45` bounds the wait for
a missing device, the HDD jobs then record failures, and the freshness verifier
turns that into an alert. A missing 970 is treated the same way at boot; unlike
the HDD it is expected to be present, and its jobs fail until it is.

That red state is the expected state until the 970 is partitioned and labelled
(SDLC #796). While it is absent, every `ssd` unit records `repo-not-mounted`, the
verifier counts them as failures and reports the check down, and `hdd` and `r2`
prove the plane on their own. Nothing in the plane skips or mutes a destination
that is not there.

The R2 bucket and repository path already exist. The write key pair is read from
`secrets/boot.json` (`["r2"]["r2_access_key_id"]`, `["r2"]["r2_secret_access_key"]`)
and is derived from `secrets/cloudflare.yaml` key `restic-backup-rw-*` by
`scripts/cloudflare-derive.sh`;
when either is absent or empty the `r2` jobs record failures and the verifier stays
red rather than skipping the destination. The legacy migration repository is a different bucket
and is never referenced by this plane.

## Restore units and snapshot paths

A unit is the application, and it names the datasets restored together: `files`
(`raw/files` + `state/syncthing-config`), `photos` (`raw/photos` +
`state/immich-postgres` + `state/immich-dumps`), `books` (`raw/books` +
`state/opdshelf`), `music` (`raw/music` + `state/navidrome`), `agent-local`
(`state/agent-local`) and `agent-general` (`state/agent-general`) for the two
agent deployments, and the raw-only `wallpapers`, `git`, `apps` and
`repo-archive`. The table in `scripts/storage-layout.sh` is the single source;
`/srv` holds raw data and `/var/lib` holds the state no raw file regenerates.

Navidrome's database joined `music` after the unit had already run with
`raw/music` alone, so its first backup reads the whole library again (already
stored chunks dedupe) and starts a new `host,paths` parent family. The old family
keeps its 14/8/12 retention until the one-time `restic forget` in
`docs/manual-steps.md` retires it after the first new-family snapshot verifies.
Restic's `--path` filter keeps a snapshot that contains the path among others,
so it cannot separate the two families: the steps pick the old family by its
single-path set and forget those snapshots by ID.

`state/agent-model` is the one dataset in **no** unit, and the table says so
(`dataset_unrestored`): it holds the 4.7 GiB GGUF blob the personal model server
loads, which `docs/manual-steps.md#fetch-the-pinned-model` re-downloads and verifies by
checksum. Backing it up would put a fully reconstructable artefact in every
snapshot and in R2 for no restore value, so a cold restore fetches it instead.
The gateway cannot start without it, which is a loud failure rather than a silent
one.

An agent gateway's state is a recovery point: `state/agent-local` and
`state/agent-general` hold the runtime's sessions, memory and skills, none of which
any raw file regenerates. The deployment's web UI keeps its chats and workspaces
under `webui/` in the same dataset, so one snapshot returns the whole deployment to
a point in time. Restoring one returns the agent to that point; it must be started
after the restore with its own state directory owned by uid 1000, exactly as any
other application dataset.

The two groups are one dataset each, not one group split in two: the personal
deployment writes everything it owns under `/var/lib/agent/local` and the general
deployment everything under `/var/lib/agent/general`, including the collectors'
quarantine and replica trees and the gateways' memory and index. That is what makes
them restore-united — one snapshot, one restore, no half deployment. It is also
the boundary: no unit on either side mounts the other's dataset, and the general
group restores exactly its own. Both are in every destination's run, retention and
freshness check because they are entries in the same table as any other unit.
`tests/core/agent-recovery.bats` asserts all of this, including against a tree
broken on purpose.

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
`host,paths` parent selection and retention address the same unit, and the
driver rewrites the state's `paths` to the set it just archived. A unit that
gains a dataset therefore starts a new parent family: the deploy gate's local
query falls back to the storage table whenever the recorded set no longer
matches it, so the unit is not called fresh until the new set has a snapshot.
The aggregate verifier compares against the table throughout, so it stays red
until that first success. An incomplete snapshot (exit 3) is never tagged and
can never be selected by retention or by the verifier.

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

A `snapshot-reconcile` or `snapshot-create` failure also prints zfs's own
message on the attempt's stderr, and a busy `destroy` is retried once: the
snapshot's `.zfs/snapshot` automount may still be releasing. Recording the
message is not decoration — without it the record says only that a destroy
failed, which is why the 2026-11-22 `hdd/photos` failure could not be diagnosed
after it self-cleared.

The attempt is retried `RESTIC_ATTEMPTS` times (default 2) with a bounded sleep
between attempts. Every command — `zfs list/destroy/snapshot`, `restic
backup/tag/snapshots/forget/prune/check`, `curl` — goes through `timeout`, so a
hang is a recorded failure, not a wedged unit. `TimeoutStartSec` in the unit is
only a safety net above those.

A unit with no `last_success` recorded **against the repository it is writing**
is a first upload — a brand-new state file, a lost state file, or a repository
change — and is sized for reading every byte: `RESTIC_DEADLINE_FIRST_LOCAL` or
`RESTIC_DEADLINE_FIRST_R2`, tried `RESTIC_ATTEMPTS_FIRST` times. The state file
already says which happened; nothing calls `restic stats`, `df` or the network
to guess the size. A first attempt that used its whole window is followed by the
next scheduled run, which resumes from what restic already wrote instead of
re-reading it.

Cleanup is best effort by design. On normal exit and on TERM/INT the job
destroys its own staging snapshot; after SIGKILL or power loss the next
invocation reconciles it. Reconciliation happens *after* the lock is acquired
and destroys only `<dataset>@<backend>` for its own unit — never another job's
snapshot.

## Watching a run

`smortress-restic-progress` reads the run; it never drives it.

```sh
smortress-restic-progress                  # redraw until interrupted
smortress-restic-progress --once           # one frame, for a log or a paste
smortress-restic-progress --all            # every unit's last result
smortress-restic-progress --backend r2 --interval 2
```

One screen, per destination: the timer's own next run (an inactive timer is
shown as having none, because a plane that stopped being scheduled looks exactly
like a plane with nothing due), the unit in flight with restic's `--json`
progress — percent, transferred bytes, files, rate and ETA — and, when nothing
is running, the last result per unit. Restic's `seconds_remaining` is
authoritative but reads 0 while it scans and again at the end; the watcher
derives a rate from successive records and an ETA from that.

The backup driver publishes what a reader needs to a tree the operator account
can read, so watching needs no sudo and no restic query of its own:

| Path | Contents | Mode |
| --- | --- | --- |
| `current-<backend>.json` | the unit in flight: start, epoch, deadline, attempt, legal window | `0644` |
| `<backend>-<unit>.jsonl` | restic's `--json` status and summary records for the attempt in flight | `0644` |
| `last/<backend>-<unit>.json` | the same line the journal recorded when the unit ended | `0644` |

That tree is `/var/lib/homelab/restic-progress` by default
(`RESTIC_PROGRESS_ROOT`), a sibling of the `0700` state tree that stays
root-only. One marker per backend, not one for the plane: the hourly `ssd` and
`hdd` units fire at the same minute and run concurrently, and a manual
single-unit run shares the backend; a driver clears the marker only when it still
names the run that wrote it, so the one that finishes first cannot blank the
other's live attempt.

The marker and the status stream exist only while an attempt is running. The
marker carries the window its attempt is legal for — the lock wait, every
bounded attempt and the post-upload `cat`/`tag`/`snapshots` calls, each of which
gets a fresh deadline — and a marker past that window is a run that died without
clearing it: the watcher calls it stale instead of showing a backup that stopped
moving as live. A TERM removes both the marker and the stream; after a SIGKILL
the next attempt truncates the stream and the marker expires on its own.

Nothing published here carries a credential. A status record is reduced to byte
and file counters: `current_files` is dropped and only `status`/`summary`
records are kept, because restic's error and verbose records name the file that
failed or was being read, and this tree is world-readable. A result record is
the journal line verbatim, so it names the unit's staging paths and its
repository URL; neither is a credential. The restic password and the R2 key pair
never leave the root-only state tree and the decrypted secrets.

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
bounded retries, and checks every backend/unit pair from the same table (ten
units, three destinations, thirty checks today). It fails closed on anything it
cannot prove.

**The join.** For each pair it reads the durable state and the repository:

1. `state/<backend>-<unit>.json` and the journal must exist and parse.
2. The latest recorded attempt is authoritative:
   - `running` and younger than the run expiry → still in flight, not a fail;
   - `running` and older than the run expiry → fail (SIGKILL/power loss);
   - `failure` → fail, regardless of any older success;
   - `success` → the attempt's snapshot must equal `final.snapshot` and
     `last_success.snapshot`.
3. `last_success.end` must be no older than the maximum age for the backend.
4. `restic snapshots --json --host smortress --tag unit:<unit>` must return
   exactly one snapshot with the recorded final ID, and that snapshot must:
   - carry `verified`, `unit:<unit>` and `host:smortress`;
   - report `hostname == smortress`;
   - have the unit's whole path array;
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
| `ssd`, `hdd`, first upload | — | 14400 s | 1 (+60 s sleep) | 15060 s | 8400 s |
| `ssd`, `hdd`, `agent-local` | 3600 s | 14400 s | 2 (+60 s sleep) | 29520 s | 33600 s |
| `r2` | 86400 s | 14400 s | 2 (+600 s sleep) | 31800 s | 118800 s |
| `r2`, first upload | 86400 s | 32400 s | 1 (+600 s sleep) | 34800 s | 118800 s |

Run expiry is `attempts × (deadline + sleep) + grace` (600 s local, 1800 s r2);
max age adds the schedule interval and a grace of 1080 s (local) or 2400 s
(r2): `8400 = 3600 + 2×1860 + 1080` and `118800 = 86400 + 2×15000 + 2400`. The
first-upload run expiry uses the first-upload bound and its single attempt:
`15060 = 1×14460 + 600` and `34800 = 1×33000 + 1800`. Max snapshot age is
unchanged: it counts from a first success, which a first upload does not have,
so the fail-closed "no persisted successful snapshot" verdict covers that window
instead of an age budget.

The agent's local state outgrew the hourly window (2026-11-24), so
`agent-local` alone takes the long local bound on `ssd` and `hdd`
(`RESTIC_DEADLINE_LOCAL_LONG`, 14400 s) while every other unit keeps 1800 s.
Both budgets are derived from the deadline a unit actually gets, so they widen
with it: `33600 = 3600 + 2×14460 + 1080` and `29520 = 2×14460 + 600`.

The unit's `TimeoutStartSec=50400` is the safety net, and it is above the worst
single group rather than below it: `50400 = 32400 (one first r2 attempt) +
14400 (repository maintenance) + 3600 (per-command slack)`, and
`attempts_first × deadline_first_r2 = 32400 < 50400` strictly. It also stays
under the 86400 s daily r2 schedule, so a run the net kills is retried by the
next daily timer instead of losing a day.

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
| `/run/smortress/secrets/restic-password.yaml` | `["restic"]["password"]` | `RESTIC_PASSWORD_FILE` for all three repositories |
| `/run/smortress/secrets/r2-credentials.yaml` | `["r2"]["r2_access_key_id"]`, `["r2"]["r2_secret_access_key"]` | exported as `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` for `r2` only |
| `/run/smortress/secrets/healthchecks.yaml` | `["healthchecks"]["restic-ping-url"]` | verifier ping URL |

All three outputs are extracted from one ciphertext, `secrets/boot.json`.
`restic-password.yaml` is decrypted with `format=value` in
`bootc/server/rootfs/usr/share/smortress/secrets.manifest`, so the file contains only the
password; restic cannot read a YAML document with a key. Credentials reach
restic through the environment, never argv, and are never printed.
`r2-credentials.yaml` is derived into `boot.json` from the Cloudflare bundle and is listed in the manifest.
`healthchecks.yaml` carries the ping URL the operator creates in section 38 step 3,
and the verifier treats an empty URL as a failed check rather than pinging a
placeholder.

## Restore by hand

On the host (or any machine with restic and the password):

```sh
export RESTIC_PASSWORD_FILE=/run/smortress/secrets/restic-password.yaml

# What exists, newest last, verified only:
sudo /usr/libexec/smortress-restic-restore-drill ssd photos --list

# Restore the newest verified snapshot of one unit into the default drill root:
sudo /usr/libexec/smortress-restic-restore-drill ssd photos

# A specific snapshot, into a target of your choosing:
sudo /usr/libexec/smortress-restic-restore-drill r2 books --snapshot <id> \
  --target /var/lib/restic/hdd/drill/books
```

The helper restores every path in the unit under
`<target>/<mountpoint>/.zfs/snapshot/<backend>/` because those are the absolute
paths the backup recorded. It refuses a non-empty target, only accepts
`verified` snapshots, and fails when the snapshot does not carry one of the
unit's paths. The exit status is a gate, not evidence: open a known file and
compare ownership and mode.

The default target is `<drill root>/<backend>-<unit>-<time>`, where the drill
root is the first mounted of `/var/lib/restic/hdd` and `/var/lib/restic/ssd`
(`RESTIC_DRILL_ROOT` overrides it). It is **not** `/var/tmp`: the root
filesystem carries the system and the container images, and a media unit
restores more than root can spare, so a drill there can only end in ENOSPC
after filling a disk other services need. `scripts/agent-runtime-drill.sh` makes
the same choice for its own default target (`SMORTRESS_AGENT_DRILL_ROOT`
overrides it). Before writing
anything the helper asks restic for the snapshot's restore size and refuses a
target whose filesystem cannot hold it plus a 2 GiB margin, naming `--target`
and `RESTIC_DRILL_ROOT` in the message.

`agent-local` did not fit the old method's deadline, and the method rather than
the bytes was the reason. The helper used to pipe `restic dump` into `tar`, and
`dump` emits no hardlink entries, so a tree that is 519.8 GB summed per path but
36.8 GB unique arrived as 519.8 GB of distinct files: on 2026-11-22 the drill
wrote 39 GiB and 383,794 of 4,592,084 files in 24 minutes before it was stopped,
and the 43.8 GB of unique bytes it had already written was 118 % of the 36.8 GB
the whole source occupies. The restored portion held zero multi-link files
against 4,365,676 in the source — the arithmetic proof that the links were
expanded.

The default is now `restic restore`, which preserves hardlinks and loads packs in
parallel; `dump` stays behind `RESTIC_DRILL_METHOD=dump` for an older restic.
Over S3 the difference is larger than the parallelism: `dump` walks the tree one
node at a time, and a single stalled read hangs the whole drill until
`RESTIC_DEADLINE_DRILL` (14400 s) kills it — on 2026-11-22 an `r2/music` drill
spent 25 minutes and wrote nothing, and an `ssd/agent-local` drill did the same.
SELinux labels are excluded (`--exclude-xattr security.selinux`): applying or
removing the label needs privileges the drill does not have, and the real dataset
gets its label back when the data is copied home.

Two things the new default has not proved. It is **unmeasured** on `agent-local`:
no completed `ssd/agent-local` restore has been timed, so there is no figure
here to quote. And the deadline is now one window for the whole unit — `photos`
has three datasets, which used to be three separate 14400 s budgets and is now
one — so raise `RESTIC_DEADLINE_DRILL` for the media units and budget the
target, not the deadline.

The owner canceled the `agent-local` measurement on 2026-11-22: no timing or
restored-bytes figure is claimed, and the offline tests plus the runbook are the
evidence.

The raw equivalent, for any machine:

```sh
export RESTIC_PASSWORD_FILE=<file with only the password>
restic -r /var/lib/restic/ssd/restic snapshots --host smortress \
  --tag unit:photos --tag verified
restic -r /var/lib/restic/ssd/restic restore <id> --target /var/lib/restic/hdd/drill/pick-a-name --verify
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
- A cold first upload of all ten units fitting the 14 h `TimeoutStartSec` in
  one `r2` run. Each group is bounded by `RESTIC_DEADLINE_FIRST_R2` (9 h) with a
  single attempt, so a first `r2` run that outlives the net records a failure
  for the groups it did not reach and the next daily run resumes from what
  restic already uploaded.
- Healthchecks.io delivery through Pushover, and the `/fail` ping path.
- Prune/check runtimes, restic lock contention between a prune and the hourly
  jobs, and `read-data-subset` cost on the 5 TB repository.
- A cold restore of every group from each destination (the T6 gate), including
  ownership and database recovery.

`scripts/legacy/retirement-gate.sh` is the matrix runner for #709's gate: run it on the
host as root and it restores every unit from every destination with the drill
helper, checks one sample file per restored dataset against the live tree, and
prints the evidence table. It cannot prove database recovery or application
startup; those remain #716's operator rows.

## Local proof

`tests/core/restic-plane.bats` stubs restic,
zfs, curl and sops and asserts: exit-code handling for 0/1/3, the verified-tag
gate, `pending_reap` for failed IDs, stale-staging reconciliation before
creation, readiness and mount gates that prevent any backup, retention carrying
both tags, no wildcard retention or bulk deletion, the fail-closed freshness
join (missing state, newer failure over an older success, expired running
attempt, missing repository snapshot, unverified tag/wrong path), first-upload
sizing (one attempt and the longer deadline with no recorded success, routine
retries and deadline afterwards, a slow first run neither timed out nor expired,
a success against another repository not counting), repository
init refusing an unmounted or non-empty directory, and `format=value` in
`sops-decrypt`. `scripts/check-server-image.sh` asserts the static shape: mount
units present with the right UUIDs, every restic unit enabled, the driver
ordered after every readiness instance, and both tags on every retention
command.

`tests/core/agent-recovery.bats` covers the two agent groups: it runs the real
driver against stubs and requires a successful snapshot of each group on `ssd`,
`hdd` and `r2` with exactly its own dataset as the path; then it breaks the tree
in eleven ways — a dropped group, a general unit carrying personal data, one
dataset in two units, a general unit mounting the personal state, a collector
writing to the general group, a unit mounting agent state without naming its side,
a writable model mount, a dropped destination timer, missing readiness ordering, a
retention skip and a drill root inside a live dataset — and requires the finding
each one names before the unbroken tree is allowed to pass.

## Bringing the plane up

Prerequisites: the age identity is staged and `secrets/boot.json` decrypts
(`scripts/secret.sh verify` is keyless and proves the policy, the index and the
bundles agree). The 5 TB HDD is already formatted `LABEL=restic-hdd`; the 970 carries
`LABEL=restic-ssd` once fitted. Destinations, retention and readiness are
`docs/core/restic-plane.md`.

```sh
sudo blkid -L restic-ssd
sudo systemctl start var-lib-restic-ssd.mount var-lib-restic-hdd.mount
sudo systemctl list-timers 'smortress-restic-*'    # ssd, hdd, r2, verify at :40
sudo systemctl restart sops-decrypt.service
sudo /usr/libexec/smortress-restic-init            # refuses to re-initialise
sudo /usr/libexec/smortress-restic-backup ssd
sudo /usr/libexec/smortress-restic-backup hdd
sudo /usr/libexec/smortress-restic-backup r2
sudo /usr/libexec/smortress-restic-verify
sudo /usr/libexec/smortress-restic-restore-drill ssd photos --list
sudo /usr/libexec/smortress-restic-restore-drill ssd photos
sudo /usr/libexec/smortress-restic-restore-drill hdd books
sudo /usr/libexec/smortress-restic-restore-drill r2 notes
```

`restic-init` never re-initialises an existing repository and refuses one under an
unmounted mountpoint; a second run prints "already initialised" for each backend.
Every snapshot must carry `unit:<name>`, `host:smortress` and `verified`. Open a
file from each restored tree under
`<target>/<mountpoint>/.zfs/snapshot/<backend>/`, compare it against the live path,
then remove the target — a drill is evidence only once a restored file was opened
and matched, and a bare `restic check` proves nothing about restorability.

```sh
sudo rm -rf /etc/systemd/system/smortress-restic-backup@.service.d
sudo systemctl daemon-reload
```

Prove the failure boundaries: with the HDD unmounted the job prints `failure
repo-not-mounted`, the verifier exits non-zero, and the SSD jobs still succeed. The
Healthchecks.io check `smortress restic freshness` (1 hour, 30 minute grace,
Pushover) pages on that, and its ping URL is `restic-ping-url` in
`secrets/boot.json` (`["healthchecks"]["restic-ping-url"]`). Record the three
repository URIs, the shared password, the R2 write token and the check name in the
kit.
