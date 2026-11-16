# T0 gate: freeze, inventory, and a proven way back

Part of the core-systems feature (#701), task #703. Nothing in T1–T6 may
repartition a disk, wipe a host, or retire a repository until every section here
is PASS. This document supersedes `docs/migration-gates.md` and the #660
data-plane checklist for the new core; those describe the stack being retired.

The gate exists because the replacement core keeps data and nothing else: the
NixOS host, the k3s guest, Flux, the timers and the old repositories are
disposable, and the data inside them is not.

## Baseline captured 2026-11-15 (read-only)

| Fact | Value |
| --- | --- |
| Host | `smortress`, NixOS, k3s guest running Flux + the four data apps |
| OS disk | `nvme0n1` 931.5G: `p1` vfat `/boot`, `p2` LUKS → ext4 `/` (79% full) |
| 970 | `nvme1n1` 931.5G: `p1` vfat, `p2` LUKS ext4, unmounted — the old-system rollback disk, and the future SSD repository |
| Backup disk | `sda` 4.5T LUKS → ext4 `/var/backup` (11% used) |
| Legacy host job | `restic-backups-local.service` → `/var/backup/restic`; `restic-backups-r2.service` → `s3:https://385f7d47e2e8438fbda5d6f76d760434.r2.cloudflarestorage.com/restic-backup` |
| Legacy schedule | daily 03:30 + up to 15 min jitter, restic 0.19.1 |
| Legacy retention | `--keep-daily 14 --keep-weekly 8 --keep-monthly 12` |
| Legacy config | NixOS 26.11.20260719.241313f; `nix-config` 80b47abc, `homelab-platform` 88776a2 |
| Live Immich dump | `/var/lib/data/immich/db-dumps/immich.dump`, written nightly by the in-cluster CronJob (99.6 MB on 2026-11-14 20:45) |
| Stale Immich dump | `/var/lib/data/db/immich.dump` — the host-side `restic-db-dump` writer was retired with #509 and no longer exists as a unit |

The host job walks `/var/lib/data` plus the assistant state paths in
`nix-config`'s `modules/nixos/restic-backup.nix`; the four cluster jobs walk one
virtiofs share each, so `trees/*` holds subsets of what the host job already
holds — redundant copies, not independent backups, which is why T0 verifies the
two host repositories and not the four cluster ones.

**Evidence.** The figures above came from `lsblk`, `findmnt`, `du -sbx`,
`systemctl show` and `stat` run on the host on 2026-11-15; the audit script
reproduces every one of them and its output is what the gate is signed off
against. Nothing here is quoted from an older document.

## 1. Freeze the legacy graph

Freeze means *stop reconciling*, not stop serving: Flux stops applying git,
repairing Helm drift and pushing image-automation commits, while the
applications keep running and the nightly restic jobs keep running.

```
sudo scripts/core/freeze-legacy.sh --check     # record what is suspended today
sudo scripts/core/freeze-legacy.sh --apply     # writes /var/lib/freeze-legacy/<ts>.state
```

`--apply` records every object's previous `spec.suspend` before patch and then
verifies the observed value; any unreadable kind, rejected patch or mismatch
exits non-zero. `--resume` restores the recorded state, not a hard-coded
`false`. Evidence: the `--apply` output pasted into #703.

## 2. Inventory: what survives

Every mutable tree on the host lives under `/var/lib/data` on one filesystem,
except the state listed separately below. The disposition is the whole
contract: a tree is either in one new recovery group, rescued by hand, or
explicitly disposable.

### Recovery groups (retained)

| Legacy tree | Bytes | New group | Note |
| --- | --- | --- | --- |
| `/var/lib/data/immich` | 116G | `photos` | library + PostgreSQL + Valkey + `db-dumps`; the physical snapshot and the logical dump are both kept |
| `/var/lib/data/photos` | root-only, uid 999 | `photos` | pre-cutover media; T6 must prove it is a subset of `immich/library` before it is dropped, so it is retained until then |
| `/var/lib/data/books` | 363M | `books` | OPDShelf content, `.opdshelf` metadata, Calibre library |
| `/var/lib/data/music` | 78G | `music` | music library; Navidrome is not part of the initial core, the data is |
| `/var/lib/data/wallpapers` | 2.4G | `wallpapers` | wallpaper library |
| `/var/lib/data/vault` | root-only | `notes` | Syncthing vault tree (contents) |
| `/var/lib/data/todo` | root-only | `notes` | the mounted `todo.txt` tree; `/var/lib/todo.img` is only its container, so the image is not retained separately |
| `/var/lib/syncthing` | root-only | `notes` | Syncthing **identity and database**. Not in any backup today: losing it re-pairs every device |
| `/var/lib/syncthing-versions` | root-only | `notes` | staggered/trash version history of the vault folder; `vault-sync.nix` says explicitly it lands outside both the synced tree and restic's source path, so it is in no backup |

The last three rows are the trap: the vault *contents* are backed up, but the
identity and the version history are not. They must be copied off the 980
before it is wiped (manual step 36.2) or declared disposable by the owner.

### Disposable (owner decision, 2026-11-15)

| Legacy tree | Why it goes |
| --- | --- |
| `/var/lib/data/graphiti`, `/var/lib/data/memory-export`, `~/.local/state/letta` | old agent memory; the owner does not want it migrated or archived |
| `/var/lib/data/radicale` | old CalDAV data; explicitly dropped |
| `/var/lib/data/phone-untrusted` | receive-encrypted phone staging; explicitly dropped |
| `/var/lib/data/open-webui` | chat history |
| `/var/lib/data/navidrome` | play counts and playlists |
| `/var/lib/data/db` | stale host Immich dump from before #509; the live dump lives inside the `immich` tree |
| `/var/lib/data/inbox`, `/var/lib/data/cluster-digest` | ingest dropbox and derived digest |
| `/var/lib/data/github-mirrors` | re-fetchable mirrors |
| `/var/backup/{Photos,Music,Calibre,GitHub,MemoryExport,LobeChat,CloudflareTofu}` | pre-Restic rsync leftovers |
| `~/ghq`, `~/wip` | source trees, excluded everywhere by owner decision |

Disposable does not mean "delete now": the freeze keeps them readable until T6
retires the legacy stack, so a mistake here is recoverable until the explicit
retirement gate.

## 3. Prove the old repositories

The old HDD and R2 repositories are the only copies of the retained trees until
the new three-destination plane exists.

```
# refresh both repositories. The unit's ExecStart is backup, then retention
# (forget --prune with the configured policy), then check: starting it prunes
# by policy, which is why the verifier runs afterwards and not instead.
sudo systemctl start restic-backups-local.service
sudo systemctl start restic-backups-r2.service

# prove: metadata, sampled pack reads, presence of every retained tree,
# a restore of the small trees and the live Immich dump
sudo scripts/core/verify-legacy-backups.sh --keep
```

The verifier changes nothing that matters: no snapshot is added, no retention
changes, nothing is deleted. Metadata reads use `--no-lock`; `check
--read-data-subset` takes its normal lock, which is why the script refuses to
start while a backup is active or within two hours of a restic timer
(`--force` overrides the latter). It derives the repository URL, the password
file and the R2 credentials from the systemd units.

It fails on: a snapshot older than 36 h, a pack read error, a retained tree
absent from the snapshot, a restore whose file count disagrees with the
snapshot listing, a missing or older-than-24 h Immich dump, or a dump that
`pg_restore --list` cannot parse (`pg_restore` absent is a failure, not a
pass — `nix shell nixpkgs#postgresql --command pg_restore --list <file>` is
the one-off). The restore target is a directory the script creates under
`/var/tmp` with 8 GiB of headroom; `--keep` leaves it in place, otherwise the
script deletes only what it created. A plaintext restore of the vault under
`/var/tmp` is destroyed with it.

Evidence: the `--keep` report pasted into #703, with both repositories PASS.

## 4. Secrets that exist today

T0 also decides what happens to every credential, so nothing that is still
needed disappears with the old configuration. Values stay in SOPS, Bitwarden
and the cluster; this table names locations, not secrets.

| Secret | Today | In the new core |
| --- | --- | --- |
| SOPS admin age identity | `~/.config/sops/keys.age`, passphrase-encrypted per machine | kept: SOPS stays the versioned secret format (T2) |
| smortress SSH host key | `/etc/ssh/ssh_host_ed25519_key`; also the host's SOPS age identity | kept in the kit: `provision/smortress/build-seed.sh` needs it, and it decrypts the old secrets |
| Restic password | sops `restic-password` → `/run/secrets/restic-password` | kept until the legacy repositories are retired; the three new repositories share a new password (T3) |
| R2 access key pair | sops `r2-access-key-id` / `r2-secret-access-key` → `/run/secrets/restic-r2.env` | kept for legacy reads; T3 creates a new write token, T4 a read-only recovery token |
| Cloudflare API token | sops `cloudflare-api-token` (tofu) | rotated for the T4 objects; scope narrowed to R2, Access and DNS |
| cloudflared tunnel credentials | sops `cloudflared-credentials` | retired: no host tunnel in the core |
| `cloudflare-access-ssh-token` | sops, the `ssh.sammohr.dev` path | retired: SSH moves to Tailscale |
| k3s cluster token | sops `k3s-cluster-token` | retired with the guest |
| ntfy reader token | sops `ntfy-reader-token` | retired: Healthchecks + Pushover replace it |
| OpenAI API key | sops `openai-api-key` | not used by the core; belongs to the later agent feature |
| `smores-password-hash` | sops, host account | retired: Fedora manages the laptop account |
| GitHub App keys, installation id, PATs | Bitwarden + broker config | unchanged; existing GitHub RBAC stays the enforcement boundary |
| YubiKey restore bundle | `nix run .#key-backup` output, Bitwarden | kept, and re-run on smorespro before T1 wipes it |
| Cluster Secrets created by hand in etcd (`restic-backup-sops`, `ntfy-auth-sops`, `broker-credentials`) | k3s etcd on the 980 | not recoverable after the wipe; the new core recreates what it needs from SOPS and the kit, the rest is retired |

`legacy-audit.sh` lists `/run/secrets.d/<generation>/` (names, owners, modes)
so the table can be checked against the host rather than trusted.

## 5. Publish the offline recovery kit

See [`recovery-kit.md`](recovery-kit.md). T0 seeds the Bitwarden item with the
credentials needed to read the *legacy* repositories — Restic password, legacy
repository URIs, R2 access keys, HDD LUKS passphrase, root passphrase, and the
host SSH key — because without them the verification above cannot be repeated
after the host is wiped. T2–T4 add their own items as they create the keys, each
with the date it was verified.

## 6. The 970: converting rollback into a repository

The approved design makes the 970 the new SSD repository, which ends the
old-system rollback path that `docs/migration-gates.md` and
`provision/smortress/README.md` still describe. That conversion is part of T3,
and it is irreversible, so it has its own gate row:

- the 970's LUKS is opened read-only by the operator and its contents listed;
- the old-generation boot files needed for a rollback are copied somewhere the
  migration keeps (or the owner declares the rollback path disposable);
- its passphrase is in the kit;
- the owner confirms in #706.

Until those four are true, nothing formats the 970.

## 7. Exit criteria

- [ ] Flux Kustomizations, HelmReleases and ImageUpdateAutomations report the
      requested `suspend` value; `--resume` restores a recorded non-default
      state (tested on one object).
- [ ] `legacy-audit.sh --out` output is attached to #703, every `root-only` row
      in the retained table has a measured size, and the physical disk serials
      are recorded.
- [ ] Both legacy repositories pass `verify-legacy-backups.sh --keep`.
- [ ] The Syncthing identity and version history are rescued or declared
      disposable, with the decision in #703.
- [ ] The recovery-kit items exist in Bitwarden, the paper copy is written, and
      a cold restore has been performed using only kit material.
- [ ] The owner has re-read the disposable list above and confirmed it.

Only then do T1 (#704), T2 (#705) and T4 (#707) proceed.
