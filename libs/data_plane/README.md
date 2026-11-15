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
| `collectors.staging` | Staging generation, atomic publish, cursors, tombstones, fidelity limits |
| `memory.file_memory` | Portable per-profile file memory with provenance and tombstones |
| `recovery.manifest` | Public per-group manifest (strongest tier first) with an atomic write |
| `migration` | Ordered migration phases and the plan-driven backup gate |
| `github.backup` | Safe argv for mirror/bundle capture and a verifiable manifest |
| `cli` | Offline validation and inspection commands |

## Invariants

- **Authority is per field.** No database is called disposable because its media survives.
- **Personal is local-only.** `IdentityIssuer` rejects a personal scope on the external profile.
- **Destructive, bulk, irreversible, and local-to-general writes need a human.**
  The gate binds a token to the operation hash, intent id, and source epoch; it is
  single-use and expires.
- **No blind replay.** An `outcome_unknown` intent is reconciled by reading the
  source; it never returns to `applying`.
- **A run has one snapshot.** One recursive ZFS snapshot feeds every group; restic reads
  the staged path, so no group can observe a different point in time.
- **A repository exists only after an operator creates it.** A missing repository
  fails closed and names the `backup-init` command; nothing auto-initializes.

## Commands

```sh
# host Python is fine in CI; locally use nix-shell for python3
PYTHONPATH=libs python3 -m unittest discover -s tests/data-plane -t tests/data-plane
tests/data-plane/check.sh

PYTHONPATH=libs python3 -m data_plane validate-catalog catalog.json
PYTHONPATH=libs python3 -m data_plane render-confirmation operation.json
PYTHONPATH=libs python3 -m data_plane backup-manifest --plan /etc/homelab/backup.json
PYTHONPATH=libs python3 -m data_plane backup-freshness --plan /etc/homelab/backup.json --json
PYTHONPATH=libs python3 -m data_plane.migration preflight --plan /etc/homelab/backup.json --json
```

Everything except the `backup-*` commands and `migration preflight` is
fixture-only. `backup-manifest` reads the plan and never contacts a repository;
`migration preflight` only reads each repository (`restic snapshots` and
`restic check`); `backup-run`, `backup-init`, `backup-freshness`, and
`backup-check` shell out to `zfs`/`restic` through the subprocess runner unless
`--dry-run` records the argv instead.

## Integration

- The platform's SQLite journal is the single source for intent state; the
  broker reaches it through `broker_journal.BrokerJournal`.
- The services that wrap these libraries still need OCI images and manifests;
  see `deploy/data-plane/` and `ansible/` in this repository.
- The `libs/` tree is not yet covered by `scripts/kustomize-build-all.sh`; the
  new tree is validated by `deploy/data-plane/tests/check.sh`.
