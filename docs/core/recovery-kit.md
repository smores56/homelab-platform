# Offline recovery kit

The kit is the only thing that has to survive every machine. If the host, its
disks and the password manager were all unavailable at once, this is what
rebuilds access. Two copies, both offline-capable: one item in Bitwarden
(fields and small files) and one printed copy stored with the YubiKey PUK.

Rules that make it a kit rather than a list:

- No backup contains the only copy of anything needed to read that backup.
- Every value is recorded once, in one place, and referenced here rather than
  duplicated into chat, issues or `manual-steps`.
- An item is only "in the kit" after a cold restore used it. Adding a row
  without the drill is the same as not having it.

The drill has to be possible on a machine with nothing installed, so the kit
also says how to get the tools: restic 0.19.1, the version that wrote the
legacy repositories, or the distro package, and `postgresql-client` when a dump
needs `pg_restore`.

## Items

| Item | Why recovery needs it | In the kit since | Verified |
| --- | --- | --- | --- |
| Restic password — legacy repositories | opens `/var/backup/restic` and `restic-backup` in R2; the same password protects the `trees/*` repositories | 2026-11-15 (T0) | — |
| Legacy repository URIs | `/var/backup/restic` on the HDD, and `s3:https://385f7d47e2e8438fbda5d6f76d760434.r2.cloudflarestorage.com/restic-backup` including its `trees/{immich,opdshelf,navidrome,graphiti}` sub-repositories | 2026-11-15 (T0) | — |
| R2 access key id + secret — legacy | reads the offsite repository without smortress | 2026-11-15 (T0) | — |
| HDD LUKS passphrase | opens `/var/backup` on a replacement host | 2026-11-15 (T0) | — |
| 980 root LUKS passphrase (current install) | reads the legacy OS disk before it is wiped | 2026-11-15 (T0) | — |
| 970 LUKS passphrase (current rollback disk) | opens the old-generation rollback before it is converted into the SSD repository | 2026-11-15 (T0) | — |
| smortress SSH host private key | the host's SOPS age identity and what `provision/smortress/build-seed.sh` carries into a reinstall | 2026-11-15 (T0) | — |
| SOPS admin age identity | decrypts the versioned secret files; passphrase-encrypted copy per machine | existing | — |
| YubiKey restore bundle (FIDO2 credential records) | FIDO2 credential handles; PIV keys cannot be exported and are unaffected | existing | — |
| New 980 root LUKS passphrase | offline unlock of the new OS disk (Tang + TPM2 is the unattended path) | T2 | — |
| New 980 data LUKS passphrase | offline unlock of the data pool | T2 | — |
| cosign signing key | re-signs a derived image when CI is unavailable | T2 | — |
| Restic password — new repositories | one password for `ssd`, `hdd`, `r2` | T3 | — |
| Repository URIs — new | `ssd`, `hdd`, `r2` locations, including the R2 bucket | T3 | — |
| R2 read-only recovery token | Backrest's only credential; cannot delete offsite data | T4 | — |
| Backrest login | recovery UI at `recovery.sammohr.dev` (replaces the static letter). No Cloudflare account or login: the URL opens in any browser, the username is `operator`, and a local password is the only credential | T4 | — |
| RackNerd ctrl login + 2FA recovery codes | the only way to reinstall the edge VPS or open its console; without them a dead edge is a support ticket | T1 | — |
| Tailscale admin login + 2FA recovery codes | a reinstall destroys the edge's node identity, and rejoining needs a new preauthorized `tag:vps` key minted in that console | T1 | — |
| Edge SSH host private key | pins the VPS identity across a reinstall; `provision/edge/bootstrap.sh` installs it when `EDGE_HOST_KEY` names it | T1 | — |
| Edge Caddy data directory | `/var/lib/caddy/.local/share/caddy`: the ACME account key and the two certificates, so a rebuild re-issues nothing (`docs/core/public-edge.md`) | T1 | — |
| This runbook | printed `docs/core/` set: gate, kit, backrest, public edge, manual steps | T0 | — |

Bitwarden item: **homelab core recovery**. Custom fields for short values;
attachments for files (age identity, host key, cosign key). The paper copy
carries the passphrases and the item name, not the files.

The current and the new root passphrases are separate rows on purpose: the old
one unlocks the disk being wiped, the new one is generated at T2 and only
reaches the new disk when the operator adds it with `cryptsetup luksAddKey`
after the install (section 37 step 8.1). The data passphrase is added the same
way, with the data key file as the existing key.

## Drill

Run after the kit changes and before T6 retires the legacy stack:

1. On a machine that is not smortress, with only kit material, install restic
   from the kit's tool line and open the legacy HDD repository; list snapshots.
2. Restore one file from `/var/lib/data/books` and one from
   `/var/lib/data/vault` from each of the HDD and R2 repositories.
3. Confirm the restored file contents, not just the exit status.
4. Record the date in the table above and on the paper copy.

The new repositories get the same drill in T6, using only the new kit items:
one restore per destination, one Backrest download, no smortress involvement.

## Rotation

Rotating a value means: update Bitwarden, rewrite the paper copy, run the
drill, then update this table. Rotating the Restic password protects nothing
unless the old repository is re-keyed or retired, so the password changes with
the repository, not on a calendar.
