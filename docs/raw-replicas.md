# Raw portable replicas

Four collectors turn one provider's own output into one published generation:
mail (a Tuta Maildir), calendar (Tuta SDK entities), finance (a SimpleFIN
AccountSet) and browsing history (a Brave `History` copy). `libs/data_plane/
collectors/raw/` holds them; `tests/data-plane/test_collectors_raw.py` is the
whole contract without a provider.

Everything here is **personal**. None of these sources exists in the general
deployment, and no collector may run there.

## Why raw, and why a generation

A derived index is a claim about somebody else's data. Re-encoding a MIME
attachment, flattening a recurrence rule or projecting `visits JOIN urls` throws
away exactly the parts that turn out to matter, and nothing can rebuild them
afterwards. So the collector stores the provider's bytes, and the projections
that the agent actually queries (a search index, a ledger view) are marked
derived and rebuilt from those bytes.

A generation is written under `.staging/<gen>` and published by one rename into
`published/<gen>`. The manifest records every object's size and sha256, and
`RawReplica` checks both on every read: a replica that was damaged or hand-edited
fails loudly instead of quietly serving different data than it recorded. Partial
pages never appear under `published`, because the rename is the commit.

`StagingGeneration.commit_next(complete=True)` also refuses a generation that
drops a previously published object without naming it. That refusal is the whole
reason deletion cannot be inferred from silence.

## The absence ledger

The provider is not the only thing that makes an object disappear. Ask "why is
this gone?" and there are two very different answers:

| Evidence | What the collector does |
| --- | --- |
| Maildir expunge in a folder whose UIDVALIDITY did not change | tombstone: the provider recorded the deletion |
| Tuta entity with an explicit `deleted` flag | tombstone |
| Everything else | carry the object forward, unchanged, with `absent_since` and `absence_reason` |

The reasons are fixed strings:

| Reason | Used by | Means |
| --- | --- | --- |
| `provider-window` | finance | outside the requested 90-day window; it was never asked about |
| `provider-supplies-no-tombstone` | calendar | the SDK lists events and never says one was deleted |
| `provider-retention-expiry` | Brave | retention, user deletion and profile recreation look identical |

`absent_since` is written once and never moved, so a generation can distinguish
"gone since March" from "gone since this run". This ledger is why a Restic
retention window cannot be the last copy of something the provider stopped
mentioning.

## Mail

`collect_maildir(path, generation, uidvalidity=..., captured_at=...)`

- Reads `cur/` and `new/` of the root and of every subdirectory that has them;
  folder names are the on-disk names (`INBOX` for the root, `.Sent` for a
  Maildir++ subfolder).
- Stores the raw RFC822 bytes. Nothing is re-encoded; attachments, charsets and
  header order are the provider's.
- Refuses a non-empty `tmp/`: a file there is a delivery in progress, and the
  generation would record half a maildir.
- Refuses two files that map to one object id: that is a duplicated key, and
  last-writer-wins would lose a message while reporting success.
- Requires a UIDVALIDITY for every folder, stores the map as the object
  `mail::_uidvalidity`, and raises `EpochError` when a folder's value changes. A
  renumbering makes "this key is gone" meaningless, so it is a new source epoch,
  not a deletion. The value comes from the sync tool's own state
  (`read_uidvalidity`, `--uidvalidity-from-maildir`): mbsync writes the far
  side's UIDVALIDITY into `.mbsyncstate` beside each box, and a number a caller
  supplied would invalidate the deletion rule the moment it drifted. The reader
  refuses a folder it has never synced, a state with a `.journal` or `.new`
  sibling (a crash or a save in flight), and any header key isync does not
  define.
- Records an expunge as a tombstone only in a folder whose epoch did not change.
- Refuses a folder that the previous generation had and this one does not. The
  sync is pull-only with far-side create/remove/expunge disabled, so a folder
  cannot vanish because of anything this host did: it is a replaced or
  half-mounted maildir, and tombstoning every message in it would record a mass
  deletion that never happened.

Fidelity limits: Tuta-specific metadata that IMAP does not expose, and the reason
underlying an expunge.

## Calendar

`collect_calendar(entities_dir, generation, captured_at=...)`

Each `*.json` file is one raw Tuta SDK entity (`id` or `uid` required). Two
objects per event: `calendar::<id>` (the entity, canonically encoded) and
`calendar::<id>::ics`, the derived VEVENT that a calendar client can read.

- Recurrence is never expanded. `RRULE` is written verbatim and an exception is
  its own `RECURRENCE-ID` line, so a `COUNT` boundary or a moved instance stays
  correct and remains what the provider said.
- `deleted: true` tombstones both objects. Nothing else does: a missing entity is
  carried forward as absent-unknown.

Fidelity limits: the SDK supplies no tombstone, and expansion would be lossy.

## Finance

`collect_simplefin(accountset, generation, accountset_url=..., captured_at=...,
include_pending=True)`

Observations are keyed by `(accountset_url, conn_id, account_id,
transaction_id)`, and each carries the sha256 of its complete record. A pending
transaction that posts is therefore the same key with a different hash: the
transition is visible instead of being hidden by a new row.

- Stores the complete AccountSet document (`finance::accountset`), each connection,
  each account as the provider sent it (including `extra`), and each transaction
  verbatim.
- Refuses publication on a non-empty document `errlist`, on any account-level
  error list, and on `act.missingdata` anywhere. A partial account is a partial
  enumeration, and publishing it would look like a generation in which
  transactions vanished.
- Refuses `include_pending=False`: pending items are only in the response because
  the caller asked, so the request is explicit rather than assumed.
- Bounds the window (`window_days`, default 90) and keeps pending items
  regardless. A transaction that falls out of the window is carried forward as
  `provider-window`, never deleted: they are a provider subset, not a statement
  about what exists.

The hledger projection is not here. It is derived from these objects and rebuilt
whenever the accounting format changes; storing it in the replica would make a
projection look like evidence.

Fidelity limits: statement PDFs, institution history SimpleFIN never exposes, and
deletion.

## Brave

`collect_brave_db(copy_path, generation, device=..., profile=..., captured_at=...)`

The input is a **copy** taken while no Brave process holds the profile: Chromium
locks `History` and keeps recent writes in the WAL, so a copy taken from a running
browser is not a point-in-time database. Refusing a sibling `-wal` or `-journal`
is how that mistake is caught instead of collected.

- `PRAGMA integrity_check` must answer `ok` before anything is written.
- `brave::db` stores the copy's own bytes, so the replica is the file the browser
  wrote.
- One derived object per table (`brave::table::<name>`) holds every column and
  every row. That is what makes the `visits JOIN urls` projection unnecessary at
  collection time and rebuildable afterwards.
- A database with no user tables publishes nothing.

Fidelity limits: retention expiry, user deletion and profile recreation are
indistinguishable; the work Mac is a declared gap; the headless Sync profile and
its seed are removed, so there is no sync history.

## Who reads a generation

`apps/agent_facade/replica_sources.py` projects a published generation into the
facade's record shape, so `sources.read` and `sources.search` answer from the raw
objects instead of the fixtures. The projection is deliberately thin -- title and
body -- and the adapter inherits its contract from the deployment's own source
table, so pointing a facade at a directory cannot widen what it may reach
(`docs/agent-facade.md`).

## Running one

`python3 -m data_plane.collectors.raw --root DIR [--dry-run] <source> ...`
(`PYTHONPATH=libs` on this host) is what a unit runs and what a human runs
against a fixture directory. It prints one JSON report and exits `0` on publish,
`3` on any refusal, with the reason on stderr.

```sh
python3 -m data_plane.collectors.raw --root /var/lib/agent/local/replica/mail \
  mail --maildir /var/lib/agent/local/quarantine/mail --uidvalidity-from-maildir
python3 -m data_plane.collectors.raw --root /var/lib/agent/local/replica/finance \
  finance --accountset /run/collector/accountset.json \
  --accountset-url "$(cat /run/secrets/simplefin-url)" --include-pending
```

On the host the same command runs from `smortress-agent-collect-finance.service`,
on `agent-collect.network`, with the access URL as a Podman secret
(`docs/core/applications.md`, "Collectors").

`--uidvalidity FOLDER=INT` remains for a fixture directory that has no sync
state.

`--dry-run` enumerates and validates, then discards the staging generation: the
first run against a real provider can be read before anything is published. The
generation id defaults to `gen-<UTC timestamp>`, which sorts chronologically and
is what makes "the latest earlier generation" well defined.

## What a collector does not do

- It does not commit. The caller publishes with `commit_next(complete=True)` once
  every folder, entity or table has been enumerated.
- It does not decide deletion from silence. Only the two tombstone cases above
  delete anything.
- It does not talk to a provider. The sync tool, the SDK dumper and the copy timer
  are the provider-facing half; this layer is what happens to their output.
