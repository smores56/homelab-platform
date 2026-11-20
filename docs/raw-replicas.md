# Raw portable replicas

Four collectors turn one provider's own output into one published generation:
mail (a Tuta Maildir), calendar (Tuta SDK entities), finance (a SimpleFIN
AccountSet) and browsing history (a Brave `History` copy). `libs/data_plane/
collectors/raw/` holds them; `tests/data-plane/test_collectors_raw.py` is the
whole contract without a provider.

Everything here is **personal**. None of these sources exists in the general
deployment, and no collector may run there.

Mail has a second collector, `data_plane.collectors.stream.imap`, which reads the
bridge over IMAP instead of a Maildir ("Mail over IMAP" below). It is the one the
host runs; the Maildir collector remains the fixture-shaped contract.

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
| Maildir expunge, or an IMAP UID that vanished, in a folder whose UIDVALIDITY did not change | tombstone: the provider recorded the deletion |
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
  not a deletion. The caller supplies the value (`--uidvalidity FOLDER=INT`):
  the epoch is the provider's, and a number the collector guessed would
  invalidate the deletion rule the moment it drifted.
- Records an expunge as a tombstone only in a folder whose epoch did not change.
- Refuses a folder that the previous generation had and this one does not.
  Nothing this host does can remove a folder from a provider, so it is a
  replaced or half-mounted source, and tombstoning every message in it would
  record a mass deletion that never happened.

Fidelity limits: Tuta-specific metadata that IMAP does not expose, and the reason
underlying an expunge.

## Mail over IMAP

`collect_mailbox(mailbox, generation, previous, captured_at=...)` in
`data_plane.collectors.stream.imap` is the collector the host runs. The far side
is TutaBridge (`agent-tmail`), the only process that holds a Tuta session: it
serves the mailbox as local IMAP on the collectors' network, TLS with the
certificate it generated, and the collector logs in with the bridge password.

- The object id is `mail::<folder>::<uid>` and the body is the RFC822 bytes IMAP
  returned (`BODY.PEEK[]`, so reading the replica never sets `\Seen` on the
  provider's copy). The UID is the provider's key: it never changes and never
  comes back for the life of a folder's UIDVALIDITY, which is exactly the
  lifetime over which "this key is gone" means something.
- The epoch comes from `SELECT`. Each folder's UIDVALIDITY is stored in
  `mail::_uidvalidity`, and a value that differs from the previous generation
  raises `EpochError` before a single body is fetched. A renumbering makes every
  UID new, and publishing it as "the old ones vanished, these are new" would
  record a mass deletion that never happened.
- Flags come from one `UID FETCH 1:* (UID FLAGS)` per folder and are stored
  sorted. They are the one metadata field a carried-forward object updates: its
  bytes and its `captured_at` stay the ones that first saw the UID.
- A UID that the previous generation held, that the folder no longer lists, and
  that was not re-added, is an expunge -- but only in a folder whose UIDVALIDITY
  did not change. That is the only tombstone this collector writes.
- A folder that disappears is a refusal, not a mass tombstone: nothing this host
  does can remove one, so the mailbox was replaced or is half written.
- A folder name containing `/` or `::` is refused, because it has no unambiguous
  place in an object id; guessing which folder a key meant is how a replica loses
  one.
- Bodies are fetched only for UIDs the previous generation lacks. Everything else
  is carried forward from that generation's verified bytes, so a steady-state
  pass costs one LIST, one SEARCH and one FLAGS fetch per folder, not a
  re-download.

### How the service runs

`python3 -m data_plane.collectors.stream.imap` makes an initial full pass,
publishes that generation, then opens one IDLE connection per folder (bounded at
32; Tuta exposes a handful) and lets a publisher thread decide when to run again.
TutaBridge pushes `EXISTS`/`EXPUNGE` only to the session that selected the folder,
which is why there is a connection per folder: a push marks the mailbox dirty and
the publisher runs one full incremental pass after `--events-debounce` (30 s) of
quiet, or at least every 300 s while events keep arriving, so a busy mailbox
cannot starve publication. An hourly reconcile pass covers a dropped notification
and a reconnect.

Every socket error is retried with exponential backoff, because the bridge
restarts during an upgrade and the collector must outlive it. A refusal is
different: `EpochError` and `PublishError` abort the staging generation and exit
non-zero, because nothing can be published from a mailbox whose epoch moved and
a human has to reconcile it. Each published generation prints one JSON line with
`source_id`, `generation_id`, `objects`, `carried`, `deleted` and
`details.folders`.

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

### The provider half: the dumper

Tuta's SDK is not something this host can run, so the entities come from
`python3 -m apps.tuta_calendar` (`apps/tuta_calendar/`, image
`images/tuta-calendar/`, published by `.github/workflows/publish-tuta-calendar.yml`).
It reads the provider's own JSON API -- there is no CalDAV and no supported
alternative -- and it does exactly two things:

- `init --store DIR` signs in once. The address, the password and, only when the
  server answers with a challenge, one TOTP code are typed at a prompt; nothing
  secret can arrive on argv, and the password is never written. What persists is
  the access token, the user id, the KDF-derived passphrase key and the encrypted
  user group key, sealed into `session.gpg` with a passphrase-less GPG key in
  `DIR/gnupg` (mode 0600 and 0700). A seal that cannot be opened is a refusal
  naming `init`, never a partial session: the token it holds is the account.
- `dump --store DIR --out DIR` unseals, walks the account's two event lists
  (`calendarevent` pages of 200, by the last `_id`), and writes one
  `<listId>-<elementId>.json` per event with sorted keys. A `*.json` in `--out`
  that the run did not write is removed, so an event the provider stopped listing
  cannot linger as if it were still there -- absence is the collector's
  carry-forward case, not this layer's.

The document is the entity the collector expects, and the names are its own:
`id`, `uid`, `summary`, `description`, `location`, `dtstart`/`dtend` (UTC,
`2026-03-01T09:00:00Z`; date-only when both ends are midnight UTC, which is how
an all-day event is spelled), `revision`/`sequence`, `recurrence_id`, and
`rrule`. `start`/`end`/`sequence` repeat the same three values under the
provider-facing names, and `recurrence` holds the repeat rule's fields as the
provider sent them (frequency, end type and value, interval, time zone, excluded
dates) beside the single-line `rrule` the collector renders -- the raw copy is
what makes a wrong projection repairable without another fetch. An unknown
frequency or end type is refused rather than dropped: a series exported as one
event is a calendar that looks complete and is wrong.

Deferred, and named as deferred: recurrence is never expanded, altered instances
are not reconciled against their series, and alarms and attendees are not read at
all (an empty attendee list means "not decrypted", not "none"). The provider's
version floor is the failure to expect in the field: HTTP 474 or 412 arrives as a
refusal naming the endpoint and the constants to raise, because a client version
below the minimum is rejected before any other answer (manual-steps 40.16).

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

### The hledger projection

`render_journal(replica, accounts)` in `libs/data_plane/derived/hledger.py` is a
pure function of one published generation: every
`finance::txn::<account>::<txn>` becomes one journal transaction, `account`
directives are emitted for every name used, and the objects are ordered by
`(date, account id, transaction id)` so the same generation always renders the
same bytes. `write_journal` replaces the file in one rename and only when the
bytes differ, so a two-hourly rerun over an unchanged generation leaves the
journal's mtime alone. `smortress-agent-collect-finance.service` runs it as its
third stage, after the collector, because a projection needs a generation that
exists and is published.

- **Sign.** SimpleFIN's `amount` is the provider's own, and it is written
  through unchanged onto the mapped asset account; the counter-account gets the
  exact negation. A debit therefore appears with whatever sign the provider sent,
  and a credit with the other one. This is a refusal to guess, not an oversight:
  the convention differs between institutions, SimpleFIN normalizes nothing, and
  a projection that flipped a sign on a hunch would agree with itself and
  disagree with the bank. Which side is "out" is the operator's mapping, not this
  code. The counter-account is `expenses:unknown` for every transaction for the
  same reason: calling a row income rather than expense is the same guess in
  another place.
- **Accounts.** The mapping is `state/agent-local/index/hledger/accounts.json`,
  `{"<simplefin account id>": "<hledger account name>"}`, seeded as `{}` with
  `cp -n` and edited by the operator (`docs/manual-steps.md` section 40.14). A
  name is trimmed and refused if it is empty or would start a directive, a
  comment or a second line; a file that is not a JSON object of string to string
  is a refusal. An account the file does not name still renders, as
  `assets:unknown:<sanitized id>`: an unmapped account is visible in the ledger
  instead of being dropped from it.
- **Pending and undated.** A pending record carries hledger's `!`, a cleared one
  `*`. The date is the provider's `posted` epoch seconds as a UTC date; a record
  with none falls back to its own `transacted_at`, then its own `posted` (an
  epoch of `0` counts as no date -- it is what the provider writes for a row it
  never dated), and a record with neither is skipped and counted in the report
  rather than dated "today".
- **Money.** The commodity comes from the account object, else from the
  transaction. A transaction that names neither is a refusal: a commodity-less
  posting beside a commodity'd one is a journal that does not balance.

To run it by hand over a generation already on disk:

```sh
PYTHONPATH=libs python3 -m data_plane.derived.hledger \
  --replica /var/lib/agent/local/replica/finance \
  --accounts /var/lib/agent/local/index/hledger/accounts.json \
  --out /var/lib/agent/local/index/hledger/finance.journal
```

It prints one JSON line (`objects`, `skipped`, `accounts`, `path`), exits `0` on
success and `3` on any refusal -- a bad mapping, an unreadable replica, an
unwritable journal. `--dry-run` renders and reports without writing.

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

Search over a replica is served by a derived full-text index
(`apps/agent_facade/source_index.py`): one SQLite FTS5 file under the facade's
index root, per source and per generation, built from those projections. It is
derived and never authoritative -- the generation is the record of what was
collected, the index is a cache of reading it, and deleting the index costs one
rebuild and no data. A generation publishes a new file, a short-word query falls
back to the scan, and nothing outside the facade reads the file.

## Running one

`python3 -m data_plane.collectors.raw --root DIR [--dry-run] <source> ...`
(`PYTHONPATH=libs` on this host) is what a unit runs and what a human runs
against a fixture directory. It prints one JSON report and exits `0` on publish,
`3` on any refusal, with the reason on stderr.

```sh
python3 -m data_plane.collectors.raw --root /var/lib/agent/local/replica/mail \
  mail --maildir /path/to/maildir --uidvalidity INBOX=1
python3 -m data_plane.collectors.raw --root /var/lib/agent/local/replica/finance \
  finance --accountset /run/collector/accountset.json \
  --accountset-url "$(cat /run/secrets/simplefin-url)" --include-pending
```

On the host the same command runs from `smortress-agent-collect-finance.service`,
on `agent-collect.network`, with the access URL as a Podman secret
(`docs/core/applications.md`, "Collectors").

`--uidvalidity FOLDER=INT` is repeatable: the epoch is required for every folder
and is never guessed.

`--dry-run` enumerates and validates, then discards the staging generation: the
first run against a real provider can be read before anything is published. The
generation id defaults to `gen-<UTC timestamp>`, which sorts chronologically and
is what makes "the latest earlier generation" well defined.

## What a collector does not do

- It does not commit. The caller publishes with `commit_next(complete=True)` once
  every folder, entity or table has been enumerated.
- It does not decide deletion from silence. Only the tombstone cases above
  delete anything.
- The raw collectors do not talk to a provider. The sync tool, the SDK dumper
  and the copy timer are the provider-facing half; this layer is what happens to
  their output. The IMAP stream collector is the exception: the bridge is its
  provider-facing half, and it reads it directly.
