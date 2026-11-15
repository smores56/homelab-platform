# Migration gates and the rollback boundary

Source of truth: SDLC #660, "Migration and retirement gates" and "Ordered
migration". The gate implementation lives in
`libs/data_plane/migration/`; the rescue-access implementation lives in
`ansible/roles/rescue/` and `ansible/playbooks/rescue.yml`.

Two operator constraints outrank every other migration concern:

1. **SSH to smortress stays available** for the longest feasible window before
   and after the migration. Service downtime is acceptable; loss of SSH is not.
2. **No data may be lost.** A source is not retired, a route is not switched,
   and the 970 is not converted until a verified copy and a verified restore
   exist.

`preflight` is read-only but online: it opens each restic repository to prove
the backup chain and never writes, copies, prunes, or initializes anything.
`verify` and `rollback-plan` stay offline and read one JSON document. No
command runs a destructive step.

## Gate sequence

The operator prerequisites — the R2 account id, the host secret root, the
repositories, the real copy/restore drill and the cluster Secrets — are step 35
of `docs/manual-steps.md`. The gates below assume that proof exists; no gate
creates a repository, a credential or a snapshot.

The phases are ordered and each one is exited only through its gate.

| # | Phase | Gate | Required evidence | Irreversible | Operator confirmation |
| --- | --- | --- | --- | --- | --- |
| 1 | `inventory` | `inventory-complete` | `machine_inventory`, `source_inventory`, `git_inventory` | no | no |
| 2 | `protect_old` | `old-system-protected` | `gate_ready` (the plan-driven backup gate's `ok`) | no | no |
| 3 | `pilot` | `pilot-signed-off` | `pilot_client_signed_off` | no | no |
| 4 | `scratch_stack` | `scratch-stack-verified` | `scratch_stack_verified`, `recovery_spike_passed` | no | no |
| 5 | `shadow_backfill` | `shadow-reconciled` | `shadow_reconciled`, `fidelity_gaps_recorded` | no | no |
| 6 | `cutover` | `cutover-ready` | `gate_ready`, plus `cutover_rehearsal_passed` | no (rollback window open) | **yes** |
| 7 | `retire_old` | `retirement-approved` | `retired_writers_stopped`, `new_generation_verified`, `rollback_no_longer_required` | **yes** | **yes** |

`protect_old` and `cutover` are the hard gates. The plan refuses to advance
past either without every listed fact; `cutover` additionally refuses without a
recorded human confirmation. `retire_old` is irreversible and therefore also
requires a confirmation by construction: the gate type rejects an irreversible
gate that does not require one.

A phase is not a script step. The operator performs the work, runs the
plan-driven backup gate, and only then advances. The implementation is pure:
`advance(phase, evidence)` returns the next phase or raises `GateBlocked` with
every missing fact. The gate report publishes its verdict under the single key
`gate_ready`, which is what the `protect_old` and `cutover` gates consume; the
operator-confirmation mappings remain separate.

## Backup gate

`preflight` proves the backup chain from the host plan, against the real
repositories. There is no separate evidence artefact to sign or carry: the plan
is the only input, and the report is the record of what restic answered.

```sh
export PYTHONPATH="$PWD/libs"
python3 -m data_plane.migration inventory --out /tmp/inventory.json
python3 -m data_plane.migration preflight --plan /etc/homelab/backup.json
python3 -m data_plane.migration preflight --plan /etc/homelab/backup.json --json
```

`inventory` is the read-only T0 collector. It queries the machine, block
devices, source-tree sizes, credential metadata and local Git state, and writes
one JSON document. It never opens a credential, never writes to the host, and
records an unreadable path or missing tool under `gaps` instead of failing. Run
it once as the login user and once with `sudo` for the ZFS and private-tree
sections; the two reports are meant to be compared.

The Ansible gate runs the same command on the data-plane host, where the backup
role installs the library at `/opt/data-plane/lib` and the plan at
`backup_config_file`; it proves freshness, path coverage, and repository
structure by default, and takes `-e homelab_migration_read_data=true` to add the
primary read-data pass before a cutover.

The plan names every recovery group, its staged path, its cadence, and its
ordered tiers; the first tier is the primary. For every group the gate proves:

| Check | Passes only when |
| --- | --- |
| freshness and path coverage | Every tier holds a snapshot under the group's staged path, the newest is within the cadence limit (nvme/hdd 0.25 h on `fast` and 1 h on `media`; `r2` 1 h on `fast` and 6 h on `media`), and that newest snapshot covers the whole staged path. |
| structural `restic check` | Every tier of every group runs `restic check` and exits 0. This reads repository structure and pack integrity, not the data payload. |
| `restic check --read-data` | Each group's **primary** tier (the first one) reads every pack and exits 0. Lower tiers get only the structural check. |

A missing repository never becomes an exception: the runner reports that tier
as failed with its message (`repository is not initialized`, or the restic
stderr) and the gate keeps checking the other groups and tiers, so one run
shows every gap. `--no-read-data` skips only the primary read-data pass; use it
for a quick structural sweep, never for the cutover gate.

Read failures from the lines after the verdict:

```text
preflight: FAILED
  photos/hdd: newest snapshot is 40.00h old, over the 6.0h limit
  notes/nvme: check: restic check failed with 1: ...
  photos/nvme: read-data: restic check failed with 1: ...
```

- `<group>/<tier>: <reason>` is freshness or path coverage: run
  `backup-run --plan …` and confirm the group's staged path is fully covered.
- `<group>/<tier>: check: …` is structural repository damage: stop and inspect
  that repository before copying or pruning anything.
- `<group>/<tier>: read-data: …` is payload damage on the primary: treat it as
  data loss until proven otherwise.
- `repository is not initialized` means the operator has not created that
  repository yet; `backup-init --plan … --group <group>` creates it, and nothing
  auto-initializes.

Exit codes: `0` the gate holds; `1` a check failed and the report names every
failure; `2` an unreadable or invalid plan, or a usage error.

## Data-loss verification

`python -m data_plane.migration verify` compares a source snapshot and its
replica record by record. A pass requires all of:

- every source stable ID exists in the replica;
- the count matches exactly (no extra or missing IDs);
- every shared ID has the same lowercase SHA-256;
- every tombstone is audited and propagated;
- no tombstoned ID was resurrected in the replica;
- no ID was deleted only in the replica.

Missing IDs, count drift, hash mismatch, duplicate IDs, invalid hashes, and
unaudited tombstones all fail. `assert_no_data_loss` raises `DataLossError` with
the structured comparison attached. The comparison is deterministic: inputs are
sorted before reporting, so a repeated run produces the same failure list.

## Irreversible actions

These are the only actions in the migration that cannot be undone by booting
the old system:

| Action | Boundary | Requirement |
| --- | --- | --- |
| Converting the 970 from old-system rollback disk to a Restic destination | **Ends the old-system rollback path.** | `retire_old` gate, `rollback_no_longer_required`, explicit operator confirmation, and a passing plan-driven backup gate on every group and tier. |
| Deleting retired application data and personal Graphiti state | Data is gone after retention expires | Approved `retire_old` confirmation plus the source-specific migration evidence (books/photos/music/notes/memory). Graphiti needs a restored new memory backup first. |
| Deleting or pruning old HDD/R2 snapshots | Old recovery points disappear | Reviewed retention process, not an ad-hoc `forget`/`prune`. |
| Reclassifying a source from personal to general | Prior external processing cannot be recalled | Confirmed bulk export and a new source epoch, per the #660 design. |

Everything else — route switches, writer pauses, re-enabling an old service —
stays reversible during the rollback window and must be reverted on failure.

## Rollback boundary

**Before the 970 is converted:**

1. Stop the new writers (`systemctl disable --now <units>`); SSH is not one of
   those units.
2. Make the old boot entry the default (`bootctl set-default <entry>`).
3. Restore the latest **verified** old generation with the rollback plan's
   legacy-repository step:
   `restic restore <snapshot_id> --repo <repo> --password-file <file>
   --target <target> --verify`. Its `old_generation` evidence must carry
   `generation_id`, `repo`, `snapshot_id`, `password_file`, an absolute
   `target`, and `verified: true`; the target is a scratch path, never `/`, so
   the current tree stays untouched. This restore is the irreversible step, so
   an unverified generation is refused outright.
4. Re-enable the independent SSH unit and re-verify **both** declared SSH
   paths before declaring rollback complete.

`rollback.py` renders exactly that order and is a dry run by default. A plan is
executable only with `dry_run=False`, and `apply_rollback` still needs the
literal confirmation `rollback`. The planner refuses a generation that is not
`verified: true`, and refuses outright once `rollback_disk.converted` or
`rollback_disk.wiped` is true.

**After the 970 is converted:** rollback as described above no longer exists.
Recovery depends solely on the new system's independent tiers (local NVMe,
HDD, and R2, all fed from the same fenced snapshot), which the backup gate
keeps proving. This transition is a separate human approval, not a consequence
of finishing cutover.

The 970 is inventory-only during the migration. It is never formatted, and its
contents are not modified, before the `retire_old` gate passes. The 5 TB HDD is
never formatted during migration; new repositories are namespaced alongside the
old ones.

## SSH invariant

- `sshd` is enabled independently of k3s, ZFS, and every `homelab-*` data-plane
  unit. The rescue role starts and enables it before any optional path.
- The optional `migration-breakglass` account is SSH-public-key only, has a
  locked password, and receives no sudo unless
  `rescue_breakglass_sudo: true`. Its authorized-keys file is operator-supplied;
  a missing file fails the run.
- The optional `cloudflared-rescue.service` uses its own token file, distinct
  from the data-plane tunnel and outside the data-plane secret root. A missing
  or non-root-only token file fails the run. The token is passed to the service
  as a systemd credential, never in argv or the journal.
- The optional Tailscale or WireGuard path is `rescue_vpn: none` by default.
  Enabling it without its root-only auth-key/config file fails the run. The
  Tailscale unit uses `--auth-key=file:<path>` so the key never enters argv.
- `PasswordAuthentication yes` is never written; password authentication stays
  off from the base hardening drop-in.

## Ansible enforcement

The gates above are not advisory: the operator runs the plan-driven backup
gate before the corresponding host actions, and Ansible gates the destructive
ones on its own flags:

- A destructive run needs **all** of `--tags destructive` and a per-host
  `homelab_destructive_device_ids` allow-list of `/dev/disk/by-id/` paths. The
  retired global boolean is rejected, not ignored. Operator confirmations stay
  with the phase gates.
- LUKS resolves every target to one canonical disk and refuses the root disk,
  the 970 unless the run names it as the declared rollback device, and any
  device with an existing filesystem or pool unless the volume sets
  `allow_existing: true`. A second keyslot (offline passphrase) and a root-only
  header backup are required before any inner filesystem or pool is created.
  The managed `/etc/crypttab` block never repeats an autoinstall-owned name.
- ZFS imports only with `zpool import -N -d <pinned mapper>`, and only when the
  mapper's by-id device is allow-listed and the pool is absent. Both
  `zfs-import-cache.service` and `zfs-import-scan.service` require
  `systemd-cryptsetup@…`.
- A plain `site.yml` never starts `homelab-write-broker.service` or the backup
  timers (`homelab-backup-fast.timer`, `homelab-backup-media.timer`);
  `--tags writers` and `--tags backup` are separate, gated steps.
- `recover.yml` fences every writer and backup timer first, then restores each
  group's newest covering snapshot from nvme→hdd→r2 onto a dedicated scratch
  mount. Backups record the staged path `/run/data-plane/current/<path>`, so the
  entrypoint restores that staged subtree into a temporary directory and moves
  it to `<scratch>/<path>`, printing the real destination and its entry count. A
  destination that already holds data is refused unless `--overwrite` is
  passed. The scratch mount must be its own mount and must have room for the
  newest covering snapshots (times 1.1, plus a `homelab_recovery_min_free_gb`
  estimate for a snapshot restic recorded no size for). Restoring into `/`
  requires `--allow-live` and the `/run/homelab/writers-fenced` fence file that
  `recover.yml` creates; `--allow-live` never bypasses the non-empty refusal.
  `--verify-only` proves repository reachability and path coverage only; it does
  not inspect a restored tree. Writers stay disabled until
  `homelab_recovery_resume_writers=true` is set after a verified live restore.
  `zfs receive` never uses `-F` on the default path. The recovery portal is not
  a prerequisite; a missing backup mount or a stopped portal is only a warning.

## Commands

Run from the repository root with `libs` on `PYTHONPATH` (the test runner does
this):

```sh
export PYTHONPATH="$PWD/libs"
python3 -m data_plane.migration preflight --plan /etc/homelab/backup.json
python3 -m data_plane.migration verify replica.json
python3 -m data_plane.migration rollback-plan rollback.json
```

Exit codes: `0` all gates hold; `1` a check failed (the report names every
failure); `2` an unreadable or invalid plan, malformed evidence, or usage.

There is no bypass flag. The Ansible tree forbids `ignore_errors`, and the
Python gate has no "force" or "skip" switch; `--no-read-data` only skips the
primary read-data pass and is visible in the report. Fixing the failed
condition is the only way to change a result.

## Exact pre-migration sequence

1. Complete the inventory and record it outside this repository.
2. Provision rescue access before touching production:

   ```sh
   cd ansible
   # Fill rescue_verify_paths in group_vars/all.yml or inventory/hosts.yml first.
   ansible-playbook -i inventory/hosts.yml playbooks/rescue.yml
   ```

   This installs/enables `sshd`, configures any optional path, and refuses to
   pass unless two independent paths authenticate from the controller.
3. Complete the old system's HDD/R2 backups, back up Cloudflare/OpenTofu state
   and GitHub artifacts, and populate the Bitwarden recovery kit.
4. Restore the latest old-system generation onto scratch storage and record the
   generation id in the recovery kit.
5. Boot the 970 rollback disk and record that it boots. Do not modify it.
6. Create the new repositories and prove one real cycle before the gate can
   mean anything (`docs/manual-steps.md` step 35, items 3-7): `backup-init` per
   group, one `homelab-backup` run, `backup-check`, then the plan-driven gate:

   ```sh
   python3 -m data_plane backup-init --plan /etc/homelab/backup.json
   /usr/local/sbin/homelab-backup --config /etc/homelab/backup.json --cadence fast
   python3 -m data_plane.migration preflight --plan /etc/homelab/backup.json --json
   ```

   Fix every reported failure. Re-run `playbooks/rescue.yml` and verify both
   SSH paths again immediately before any destructive step.
7. Only when `gate_ready` is true may the pilot, scratch stack, shadow
   backfill, and cutover begin. Cutover still needs the confirmation.
8. `retire_old` (including the 970 conversion) is last and needs its own
   confirmation. Until then, the rollback plan above stays valid.
