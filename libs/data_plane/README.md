# data_plane

Portable, stdlib-only libraries for the Nix-free personal data system in #660.
They are service-independent: nothing here imports Kubernetes, Nix, or a
provider SDK. The same code runs in the local and external planes.

## Modules

| Module | Responsibility |
| --- | --- |
| `model` | Source contracts, per-field authority, capabilities, recovery groups |
| `identity` | Signed workload claims; external profiles cannot reach personal sources |
| `confirmation` | Normalized operation, hash binding, single-use/expiry/epoch gate, plain-text render |
| `event_log` | SQLite single-writer log, epochs, durable cursors, idempotency, long-poll |
| `intents` | SQLite intent/effect journal with a closed transition table; no blind replay |
| `broker` | Scoped reads and confirmed, revision-checked writes; outcome reconciliation |
| `broker_journal` | Adapter that persists the broker's full operation in the one journal |
| `backup.plan` | Host backup plan: one restic repository per group and tier, first tier is primary |
| `backup.restic` | Argv-only restic commands and snapshot parsing; no tags, no shell |
| `backup.runner` | One recursive ZFS snapshot, staged backup, copies, prune, freshness, check |
| `collectors.relay` | Authenticated, schema-validated, rate-limited, idempotent ingest |
| `collectors.state` | The replica store: content-addressed objects and one `state.sqlite` per source; commit, tombstones, cursors, GC (`docs/raw-replicas.md`) |
| `collectors.raw` | Raw mail, calendar, finance, Brave, notes and tasks replicas; the absence ledger (`docs/raw-replicas.md`) |
| `collectors.stream` | Push-based collectors: an IMAP event updates the mail state in place (`docs/raw-replicas.md`) |
| `derived.hledger` | The finance replica as one hledger journal: the operator's mapping, the provider's own sign, an atomic no-churn write (`docs/raw-replicas.md`) |
| `memory.file_memory` | Portable per-profile file memory with provenance and tombstones |
| `migration` | Ordered migration phases and the plan-driven backup gate |
| `github.backup` | Safe argv for mirror/bundle capture and a verifiable manifest |
| `cli` | Offline validation and inspection commands |

## Invariants

- **Authority is per field.** No database is called disposable because its media survives.
- **Raw first.** A replica stores the provider's bytes; an index, a ledger view or an
  ICS projection is derived and rebuildable, never the evidence. Absence is carried
  forward with a reason, not read as deletion (`docs/raw-replicas.md`).
- **Personal is local-only.** `IdentityIssuer` rejects a personal scope on the external profile.
- **Destructive, bulk, irreversible, and local-to-general writes need a human.**
  The gate binds a token to the operation hash, intent id, and source epoch; it is
  single-use and expires.
- **No blind replay.** An `outcome_unknown` intent is reconciled by reading the
  source; it never returns to `applying`.
- **A run has one snapshot.** One recursive ZFS snapshot feeds every group; restic reads
  the staged path, so no group can observe a different point in time. A group marked
  `live` (host paths such as Secure Boot keys) is read from its live path instead.
- **A repository exists only after an operator creates it.** A missing repository
  fails closed and names the `backup-init` command; nothing auto-initializes.
- **An empty stage is never backed up.** `run_group` refuses a group path that is
  missing, not a directory, or has no entries: an unmounted mount must fail before
  restic turns it into a fresh-looking empty snapshot.
- **Freshness trusts only the real past.** Snapshots dated ahead of now (beyond a
  five-minute clock-skew tolerance) are ignored; when only future snapshots remain,
  the tier is reported as "dated in the future". The newest snapshot must be written
  by the host running the check, and a tier freshness does not know is reported as
  an unknown tier instead of a permanent NOT OK.
- **Every copy is confirmed.** After each `restic copy` the target repository is read
  back; a snapshot within two seconds of the primary's time, covering the group path
  and carrying the same host name, must be present or the run fails with
  "copy did not land".
- **One prune budget per host and path.** `restic forget --group-by host,paths` keeps
  a repository that holds several paths or hosts from sharing one 14/8/12 window.
- **Nothing here publishes group metadata.** The recovery-group manifest, the inventory it
  was rendered from and its renderer all went with the k3s tree; a group's repository URL
  is what the host's own restic units carry and nothing exposes it offsite.
- **The restic binary is environment-pinned.** Builders take an explicit binary;
  the runner resolves `DATA_PLANE_RESTIC` (default `restic`) so the role can pin
  `/usr/local/bin/restic` without changing argv construction.

## Commands

```sh
# host Python is fine in CI; locally use nix-shell for python3

PYTHONPATH=libs python3 -m data_plane validate-catalog catalog.json
PYTHONPATH=libs python3 -m data_plane render-confirmation operation.json
PYTHONPATH=libs python3 -m data_plane backup-freshness --plan /etc/homelab/backup.json --host "$(hostname)" --json
PYTHONPATH=libs python3 -m data_plane.derived.hledger --replica REPLICA/finance \
  --accounts INDEX/hledger/accounts.json --out INDEX/hledger/finance.journal
PYTHONPATH=libs python3 -m data_plane.migration inventory --out /tmp/inventory.json
PYTHONPATH=libs python3 -m data_plane.migration preflight --plan /etc/homelab/backup.json --json
```

Everything except the `backup-*` commands, `migration preflight` and
`migration inventory` is fixture-only. `migration preflight` only reads each
repository (`restic snapshots` and
`restic check`); `backup-run`, `backup-init`, `backup-freshness`, and
`backup-check` shell out to `zfs`/`restic` through the subprocess runner unless
`--dry-run` records the argv instead.

## Integration

- The platform's SQLite journal is the single source for intent state; the
  broker reaches it through `broker_journal.BrokerJournal`.
- The services that wrap these libraries still need OCI images and manifests;
