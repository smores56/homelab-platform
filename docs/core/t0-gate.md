# T0 gate: freeze, inventory, and a proven way back

Part of the core-systems feature (#701), task #703. Nothing in T1–T6 may
repartition a disk, wipe a host, or retire a repository until every section here
is PASS. The gate exists
because the replacement core keeps data and nothing else: the NixOS host, the
k3s guest, Flux, the timers and the old repositories are disposable, and the
data inside them is not.

## Baseline captured 2026-11-16 (read-only)

| Fact | Value |
| --- | --- |
| Host | `smortress`, NixOS, k3s guest running Flux + the four data apps |
| OS disk | `nvme0n1` 931.5G: `p1` vfat `/boot`, `p2` LUKS → ext4 `/` (915G, 79% full) |
| 970 | `nvme1n1` 931.5G: `p1` vfat, `p2` LUKS, unmounted; becomes the new SSD Restic repository |
| Backup disk | `sda` 4.5T LUKS → ext4 `/var/backup` (4.6T, 11% used) |
| Legacy host job | `restic-backups-local.service` → `/var/backup/restic`, `restic-backups-r2.service` → `s3:https://385f7d47e2e8438fbda5d6f76d760434.r2.cloudflarestorage.com/restic-backup` |
| Legacy schedule | daily 03:30 + up to 15 min jitter, `--keep-daily 14 --keep-weekly 8 --keep-monthly 12`, `restic 0.19.1` |
| Legacy config | NixOS 26.11.20260719.241313f; `nix-config` 80b47abc, `homelab-platform` 88776a2 |
| Legacy cluster jobs | `restic-backup/trees/{immich,opdshelf,navidrome,graphiti}` in the same R2 bucket (SDLC #619) |
| Immich dump | `/var/lib/data/db/immich.dump`, written by `restic-db-dump.service` before each host run |

The host job walks `/var/lib/data` plus the assistant state paths in
`nix-config`'s `modules/nixos/restic-backup.nix`; the cluster jobs walk one
virtiofs share each, so `trees/*` holds subsets of what the host job already
holds — redundant copies, not independent backups, which is why T0 verifies the
two host repositories and not the four cluster ones. `~/ghq` and `~/wip` are
excluded everywhere by owner decision.

## 1. Freeze the legacy graph

Freeze means *stop reconciling*, not stop serving: Flux stops applying git,
repairing Helm drift and pushing image-automation commits, while the
applications keep running and the nightly restic jobs keep running.

```
sudo scripts/core/freeze-legacy.sh --check     # record what is suspended today
sudo scripts/core/freeze-legacy.sh --apply
```

Evidence: the `--apply` output pasted into #703. `--resume` clears every
`suspend` flag again and is the only supported way to undo the freeze.

## 2. Inventory: what survives

Every mutable tree on the host lives under `/var/lib/data` on one filesystem.
The disposition below is the whole contract: a tree is either in one new
recovery group or explicitly disposable.

### Recovery groups (retained)

| Legacy tree | Bytes | New group | Note |
| --- | --- | --- | --- |
| `/var/lib/data/immich` | 116G | `photos` | Immich library + PostgreSQL + Valkey + `db-dumps`; the physical snapshot and the logical dump are both kept |
| `/var/lib/data/photos` | root-only | `photos` | pre-cutover Immich media (uid 999); T6 must prove it is a subset of `immich/library` before it is dropped, so it is retained until then |
| `/var/lib/data/books` | 363M | `books` | OPDShelf content, `.opdshelf` metadata, Calibre library |
| `/var/lib/data/music` | 78G | `music` | music library; Navidrome is not part of the initial core, the data is |
| `/var/lib/data/wallpapers` | 2.4G | `wallpapers` | wallpaper library served by the desktop sync |
| `/var/lib/data/vault` | root-only | `notes` | Syncthing vault tree |
| `/var/lib/data/todo` | root-only | `notes` | `todo.txt` on a size-capped ext4 image; the image is the recovery unit |

Unreadable rows are measured by `scripts/core/legacy-audit.sh`; ownership,
mode, file counts and newest mtime come from the same output.

### Disposable (owner decision, 2026-11-16)

| Legacy tree | Why it goes |
| --- | --- |
| `/var/lib/data/graphiti`, `/var/lib/data/memory-export`, `~/.local/state/letta` | old agent memory; the owner does not want it migrated or archived |
| `/var/lib/data/radicale` | old CalDAV data; explicitly dropped |
| `/var/lib/data/phone-untrusted` | receive-encrypted phone staging; explicitly dropped |
| `/var/lib/data/open-webui` | chat history |
| `/var/lib/data/navidrome` | play counts and playlists |
| `/var/lib/data/db` | derived Immich dump, recreated by the new core |
| `/var/lib/data/inbox`, `/var/lib/data/cluster-digest` | ingest dropbox and derived digest |
| `/var/lib/data/github-mirrors` | re-fetchable mirrors |
| `/var/backup/{Photos,Music,Calibre,GitHub,MemoryExport,LobeChat,CloudflareTofu}` | pre-Restic rsync leftovers, effectively empty |
| `~/ghq`, `~/wip` | source trees, excluded everywhere by owner decision |

Disposable does not mean "delete now": the freeze keeps them readable until T6
retires the legacy stack, so a mistake here is recoverable until the explicit
retirement gate.

## 3. Prove the old repositories

The old HDD and R2 repositories are the only copies of the retained data until
the new three-destination plane exists.

```
# refresh: dump first, then both repositories, in that order
sudo systemctl start restic-db-dump.service
sudo systemctl start restic-backups-local.service
sudo systemctl start restic-backups-r2.service

# prove: metadata, a sampled pack read, a sampled restore, and the Immich dump
sudo scripts/core/verify-legacy-backups.sh --keep
```

The verifier changes nothing that matters: no snapshot is added, no retention
changes, nothing is deleted. `restic check` takes its normal repository lock, so
it must run while no backup is active — the script enforces that. It derives the
repository URL, the password file and the R2 credentials from the systemd units,
and never calls `init`, `forget`, `prune` or `unlock`. It fails on a snapshot
older than 36 h, a pack read error, a restore count that disagrees with the
snapshot listing, or an Immich dump that is not a PostgreSQL custom archive.

Evidence: the `--keep` report pasted into #703, with both repositories PASS.

## 4. Secrets that exist today

T0 also decides what happens to every credential, so nothing that is still
needed disappears with the old configuration. Values stay in SOPS and
Bitwarden; this table names locations, not secrets.

| Secret | Today | In the new core |
| --- | --- | --- |
| SOPS admin age identity | `~/.config/sops/keys.age`, passphrase-encrypted per machine | kept: SOPS stays the versioned secret format (T2) |
| Restic password | sops `restic-password` → `/run/secrets/restic-password` | kept until the legacy repositories are retired; the three new repositories share a new password (T3) |
| R2 access key pair | sops `r2-access-key-id` / `r2-secret-access-key` | kept for legacy reads; T3 creates a new write token, T4 a read-only recovery token |
| Cloudflare API token | sops `cloudflare-api-token` (tofu) | rotated for the T4 objects; scope narrowed to R2, Access and DNS |
| cloudflared tunnel credentials | sops `cloudflared-credentials` | retired: no host tunnel in the core |
| `cloudflare-access-ssh-token` | sops, the `ssh.sammohr.dev` path | retired: SSH moves to Tailscale |
| k3s cluster token | sops `k3s-cluster-token` | retired with the guest |
| ntfy reader token | sops `ntfy-reader-token` | retired: Healthchecks + Pushover replace it |
| OpenAI API key | sops `openai-api-key` | not used by the core; belongs to the later agent feature |
| `smores-password-hash` | sops, host account | retired: Fedora manages the laptop account |
| GitHub App keys, installation id, PATs | Bitwarden + broker config | unchanged; existing GitHub RBAC stays the enforcement boundary |
| YubiKey restore bundle | `nix run .#key-backup` output, Bitwarden | kept, and re-run on smorespro before T1 wipes it |

## 5. Publish the offline recovery kit

See [`recovery-kit.md`](recovery-kit.md). T0 seeds the Bitwarden item with the
credentials needed to read the *legacy* repositories — Restic password, R2
access keys, HDD LUKS passphrase, root passphrase — because without them the
verification above cannot be repeated after the host is wiped. T2–T4 add their
own items as they create the keys, each with the date it was verified.

## 6. Exit criteria

- [ ] Flux Kustomizations, HelmReleases and ImageUpdateAutomations report
      `suspend=true`; `--resume` was tested once on a scratch object.
- [ ] `legacy-audit.sh` output is attached to #703 and every `root-only` row in
      the retained table has a measured size.
- [ ] Both legacy repositories pass `verify-legacy-backups.sh --keep`.
- [ ] The recovery-kit items exist in Bitwarden, the paper copy is written, and
      a cold restore has been performed using only kit material.
- [ ] The owner has re-read the disposable list above and confirmed it.

Only then do T1 (#704), T2 (#705) and T4 (#707) proceed.
