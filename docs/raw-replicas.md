# Raw portable replicas

Seven collectors turn one provider's own output into one live replica state:
mail (a Tuta Maildir or the IMAP bridge), calendar (Tuta SDK entities), finance
(a SimpleFIN AccountSet), browsing history (a Brave `History` copy), notes (a
Markdown vault), tasks (a todo.txt directory), photos and music (media
libraries). `libs/data_plane/
collectors/raw/` holds them; `tests/data-plane/test_collectors_raw.py` is the
whole contract without a provider.

Everything here is **personal**. None of these sources exists in the general
deployment, and no collector may run there.

Mail has a second collector, `data_plane.collectors.stream.imap`, which reads the
bridge over IMAP instead of a Maildir ("Mail over IMAP" below). It is the one the
host runs; the Maildir collector remains the fixture-shaped contract.

## Why raw, and why a live state

A derived index is a claim about somebody else's data. Re-encoding a MIME
attachment, flattening a recurrence rule or projecting `visits JOIN urls` throws
away exactly the parts that turn out to matter, and nothing can rebuild them
afterwards. So the collector stores the provider's bytes, and the projections
that the agent actually queries (a search index, a ledger view) are marked
derived and rebuilt from those bytes.

A replica holds the latest state only: content-addressed bytes under
`objects/<2hex>/<sha256>` and one `state.sqlite` beside them. There is no
history and no per-pass tree -- Restic keeps the history. `ReplicaState` checks
every object's size and sha256 on read, so a replica that was damaged or
hand-edited fails loudly instead of quietly serving different data than it
recorded.

One pass is one transaction. It writes only the bytes the replica does not hold,
records the rows it enumerated, and commits rows, tombstones, absence markers,
the cursor and the version together. A crash therefore leaves unreferenced
bytes, never a row whose object is missing, and a refused pass commits nothing.
`commit(complete=True)` refuses a pass that does not account for every live row
it did not see: that refusal is the whole reason deletion cannot be inferred
from silence.

The version counts committed changes, not passes: it moves when the pass wrote a
row, tombstoned one, or marked one absent for the first time, and it stays put
when the enumeration matched what the replica already held. The cursor still
advances, because it is the provider's position rather than the state. The
`snapshot` (`<state_id>-v<version>`) is what names a derived artifact, so an
unchanged pass is also a pass that does not invalidate the facade's index;
silence is reported as `"changed": false` in the pass's JSON line rather than as
a version that moved for nothing (`null` on a dry run, which committed nothing).
A source that has never changed is version 0.

Garbage is collected by the pass that created it: a pass that writes a row sweeps
unreferenced bytes after it commits. A pass that wrote bytes and then aborted -- a
refused commit, a collector refusal, a kill -- leaves `.gc-pending` in the replica
root, because the pass that follows it may change nothing and would otherwise
never sweep.

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
| `provider-window` | finance | outside the requested window (45 days at most, the provider's recommendation); it was never asked about |
| `provider-supplies-no-tombstone` | calendar | the SDK lists events and never says one was deleted |
| `provider-retention-expiry` | Brave | retention, user deletion and profile recreation look identical |

`absent_since` is written once and never moved, so the state can distinguish
"gone since March" from "gone since this run". This ledger is why a Restic
retention window cannot be the last copy of something the provider stopped
mentioning.

## Mail

`collect_maildir(path, state, uidvalidity=..., captured_at=...)`

- Reads `cur/` and `new/` of the root and of every subdirectory that has them;
  folder names are the on-disk names (`INBOX` for the root, `.Sent` for a
  Maildir++ subfolder).
- Stores the raw RFC822 bytes. Nothing is re-encoded; attachments, charsets and
  header order are the provider's.
- Refuses a non-empty `tmp/`: a file there is a delivery in progress, and the
  state would record half a maildir.
- Refuses two files that map to one object id: that is a duplicated key, and
  last-writer-wins would lose a message while reporting success.
- Requires a UIDVALIDITY for every folder, stores the map as the object
  `mail::_uidvalidity`, and raises `EpochError` when a folder's value changes. A
  renumbering makes "this key is gone" meaningless, so it is a new source epoch,
  not a deletion. The caller supplies the value (`--uidvalidity FOLDER=INT`):
  the epoch is the provider's, and a number the collector guessed would
  invalidate the deletion rule the moment it drifted.
- Records an expunge as a tombstone only in a folder whose epoch did not change.
- Refuses a folder that the last committed state had and this pass does not.
  Nothing this host does can remove a folder from a provider, so it is a
  replaced or half-mounted source, and tombstoning every message in it would
  record a mass deletion that never happened.

Fidelity limits: Tuta-specific metadata that IMAP does not expose, and the reason
underlying an expunge.

## Mail over IMAP

`collect_mailbox(mailbox, state, captured_at=...)` in
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
  `mail::_uidvalidity`, and a value that differs from the recorded state
  raises `EpochError` before a single body is fetched. A renumbering makes every
  UID new, and publishing it as "the old ones vanished, these are new" would
  record a mass deletion that never happened.
- Flags come from one `UID FETCH 1:* (UID FLAGS)` per folder and are stored
  sorted. They are the one metadata field a carried-forward object updates: its
  bytes and its `captured_at` stay the ones that first saw the UID.
- A UID the state held, that the folder no longer lists, and
  that was not re-added, is an expunge -- but only in a folder whose UIDVALIDITY
  did not change. That is the only tombstone this collector writes.
- A folder that disappears is a refusal, not a mass tombstone: nothing this host
  does can remove one, so the mailbox was replaced or is half written.
- A folder name containing `/` or `::` is refused, because it has no unambiguous
  place in an object id; guessing which folder a key meant is how a replica loses
  one.
- Bodies are fetched only for UIDs the state lacks. Everything else keeps its
  row and its bytes, so a steady-state
  pass costs one LIST, one SEARCH and one FLAGS fetch per folder, not a
  re-download.

### How the service runs

`python3 -m data_plane.collectors.stream.imap` makes an initial full pass,
commits that state, then opens one IDLE connection per folder (bounded at
32; Tuta exposes a handful) and lets a publisher thread decide when to run again.
TutaBridge pushes `EXISTS`/`EXPUNGE` only to the session that selected the folder,
which is why there is a connection per folder: a push marks the mailbox dirty and
the publisher runs one full incremental pass after `--events-debounce` (30 s) of
quiet, or at least every 300 s while events keep arriving, so a busy mailbox
cannot starve publication. An hourly reconcile pass covers a dropped notification
and a reconnect.

Every socket error is retried with exponential backoff, because the bridge
restarts during an upgrade and the collector must outlive it. A refusal is
different: `EpochError` and `PublishError` commit nothing and exit
non-zero, because nothing can be published from a mailbox whose epoch moved and
a human has to reconcile it. Each committed pass prints one JSON line with
`source_id`, `version`, `changed`, `objects`, `carried`, `deleted` and
`details.folders`.

## Calendar

`collect_calendar(entities_dir, state, captured_at=...)`

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

`collect_simplefin(accountset, state, accountset_url=..., captured_at=...,
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
  enumeration, and committing it would look like a state in which
  transactions vanished.
- Refuses `include_pending=False`: pending items are only in the response because
  the caller asked, so the request is explicit rather than assumed.
- Bounds the window (`window_days`, default 37; the request plus its 7-day
  overlap is 44 days, one inside SimpleFIN's 45-day recommendation, because a longer read
  puts "Requested date range exceeds recommended range of 45 days" in the
  AccountSet's `errors` and this collector refuses that) and keeps pending items
  regardless. A transaction that falls out of the window is carried forward as
  `provider-window`, never deleted: they are a provider subset, not a statement
  about what exists.

The hledger projection is not here. It is derived from these objects and rebuilt
whenever the accounting format changes; storing it in the replica would make a
projection look like evidence.

### The hledger projection

`render_journal(replica, accounts)` in `libs/data_plane/derived/hledger.py` is a
pure function of one committed state: every
`finance::txn::<account>::<txn>` becomes one journal transaction, `account`
directives are emitted for every name used, and the objects are ordered by
`(date, account id, transaction id)` so the same state always renders the
same bytes. `write_journal` replaces the file in one rename and only when the
bytes differ, so a two-hourly rerun over an unchanged state leaves the
journal's mtime alone. `smortress-agent-collect-finance.service` runs it as its
third stage, after the collector, because a projection needs a state that
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
  `cp -n` and edited by the operator (`docs/manual-steps.md#collector-sign-ins`). A
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

To run it by hand over a replica already on disk:

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

`collect_brave_db(copy_path, state, device=..., profile=..., captured_at=...)`

The input is a **copy**, never the live file: Chromium holds `History` open for
the life of the browser, so a copy taken from a running profile is not a
point-in-time database. Refusing a sibling `-wal` or `-journal` is how that
mistake is caught instead of collected.

- `PRAGMA integrity_check` must answer `ok` before anything is written.
- `brave::db` stores the copy's own bytes, so the replica is the file the browser
  wrote.
- One derived object per table (`brave::table::<name>`) holds every column and
  every row. That is what makes the `visits JOIN urls` projection unnecessary at
  collection time and rebuildable afterwards.
- A database with no user tables publishes nothing.

`device` and `profile` are the observation key, and both are constants of the
deployment rather than anything discovered: `smortress` is this host, the only one
whose history is collected, and `default` is the single headless profile
`agent-brave.container` runs -- Chromium's own directory name is `Default`, and the
label is deliberately the lower-case one so it reads as the deployment's name for
the profile and not as a Chromium path. A second profile on this host would be a
second label, not a second path, and the two would be distinguishable only by that
label.

### The provider half: a browser, not an export

Brave exposes no history API and no CLI, and its Sync engine is the only thing that
can fetch what another device wrote. So the provider half is the browser itself:
`units/quadlet/agent-brave.container` runs a pinned Brave `.deb` from
`images/brave/Containerfile` headless, in a profile that is a member of the
account's Sync chain, and the chain is what fills `History` with the visits made
elsewhere.

The membership is a **seed**, planted rather than joined. `apps/brave_ingest/seed.py`
writes the same three preferences Brave's join UI writes -- `brave_sync_v2.seed`
(the OSCrypt blob), `sync.requested` and `sync.keep_everything_synced`, plus
`sync.has_setup_completed`, without which the engine registers and downloads
nothing -- into `Default/Preferences` before the browser starts, and the browser
runs with `--password-store=basic` so the fixed key that decrypts the blob is the
one it uses. The seed lives in one ciphertext
(`["brave"]["sync_seed"]` in `secrets/agents.json`) and reaches exactly one unit,
as a Podman secret; `docs/manual-steps.md#collector-sign-ins` is the operator's half, including
rotation and removal.

The browser's only egress is the allowlist proxy on `agent-brave.network`, which
tunnels `sync-v2.brave.com:443` and nothing else (`docs/core/applications.md`,
"Collector egress"). That is also the limit of this source: a chain member that
the proxy does not reach contributes nothing, and there is no second path to the
provider.

### The snapshot, and why the copy has a name

`apps/brave_ingest/snapshot.py` takes the quiesced copy into
`state/agent-local/quarantine/brave/History`, and
`smortress-agent-collect-brave.service` runs it as its first stage, with the
collector over the copy as the second. Two steps for the same reason the calendar
pass has two: the collector refuses a database still being written, and only the
snapshot knows how to copy one that is.

It uses SQLite's backup API against a read-only connection first, which is the case
the browser makes normal -- the database is open and being written while the copy
is taken. When that cannot be used it falls back to copying `History` and its
sidecars into a staging directory and folding the log into the main file there, and
it publishes only the folded file. Either way the collector is handed one path with
no sibling, the copy is replaced by rename so a half-written one is never readable,
and it is `0600` in a `0750` directory because it is browsing history.

Which sidecar the pinned artifact writes was checked rather than assumed: Brave
1.100.58 leaves `History` in rollback-journal mode (`PRAGMA journal_mode` answers
`delete`) and creates `History-journal`, while its other databases (`DIPS`,
`segmentation_platform/ukm_db`) are WAL with the lower-case `-wal` SQLite derives
from the name. Both spellings are treated as sidecars, and
`smortress-agent-collect-brave.path` watches `History`, `History-wal` and
`History-journal`, so a later Chromium switching the database to WAL needs no edit.
The path unit is the trigger; the six-hourly `Persistent=true` timer is the
reconcile.

Fidelity limits: retention expiry, a deletion in the browser and a recreated
profile are indistinguishable, so a vanished table is carried forward as
`retention` and never tombstoned; the work Mac is outside agent collection and is a
declared gap; and nothing here says whether a visit was made on this host or
arrived over the chain, because Sync delivers rows, not provenance.

## Notes

`collect_notes(entities_dir, state, *, captured_at=...)`

The input is the Markdown vault itself, mounted read-only. One object per file,
keyed by the URL-quoted vault-relative path: a path is the only identity that
survives an editor rewriting every line, and one object per file makes an edit a
new revision of the same note instead of a delete plus a create.

- The object is the file's text plus its heading (the first ATX heading, else the
  stem), its mtime and the bytes' sha256. Frontmatter is **not** parsed: `tags`
  stays empty and the text stays whole, because a parser bug here would mangle
  the only copy and a derived reader can parse it later.
- A symlinked note or directory is refused; a symlinked attachment is skipped
  with the other non-Markdown files.
- A file that vanished is carried forward with `ABSENCE_NO_TOMBSTONE`, not
  tombstoned: a partial mount or a sync still landing is not deletion evidence.

`smortress-agent-collect-notes.timer` runs it hourly, with no network and no
secret; unchanged files keep their row and are not rewritten, so a run
that changes one note costs one object.

The write broker's file effect owner (`libs/data_plane/effects/notes.py`) may
delete a note on a person's behalf, and records each one in
`<vault>/.data-plane/tombstones.jsonl` before unlinking. The collector never
collects that file — it holds no `.md` — and the absence marker above keeps its
meaning: a pass that did not see a note says nothing about who removed it.

## Tasks

`collect_tasks(entities_dir, state, *, captured_at=...)`

The input is a todo.txt directory: `todo.txt` and `done.txt`, each optional. A
todo.txt line carries no id and the tools that write the file rewrite it in
place, so the object id is a digest of the line's bytes.

- An edited line is therefore a new task, and the line it replaced is carried
  forward as absent: a reorder or a rewrite looks exactly like a deletion, so
  absence alone is not deletion evidence. A task that never returns keeps its
  last text as proof it once existed.
- Two identical lines are one task; the collapse is counted in the report rather
  than hidden.
- Parsed fields are `done`, `priority`, `projects`, `contexts`, `key:value`
  tokens and the first bare `YYYY-MM-DD` as `created`; `text` stays the whole
  line so search sees exactly what the file said.
- A directory holding neither file is refused, so a mistyped path cannot publish
  an empty state that carries every previous task away.

`smortress-agent-collect-tasks.timer` runs it hourly, with no network and no
secret.

A delete through the write broker (`libs/data_plane/effects/tasks.py`) removes
every occurrence of the line — the collector collapsed them into one id, so
removing one would leave the target alive — and writes
`.data-plane/tombstones.jsonl` beside the two files. The collector reads only
`todo.txt` and `done.txt`, so the ledger produces no object.

## Photos

`collect_photos(entities_dir, state, *, captured_at=...)`

The input is the photo library, mounted read-only: the Immich media location
(`raw/photos`, `/srv/photos`). Immich keeps the originals in `library/` there,
beside the trees it derives from them (`thumbs/`, `encoded-video/`, `profile/`,
`upload/`), so the collector walks `library/` when it exists and the given root
otherwise -- a thumbnail or a transcode must never become a second object for one
asset. One object per media file, keyed by the URL-quoted originals-relative path,
so a re-upload is a new revision of the same id.

- The state is **metadata only**: the path, the filename without its suffix
  as the title, the format, the size and the mtime. The media bytes never enter
  the replica; the collector stats each file and never opens it, so a revision is
  `size:mtime_ns` hashed rather than a content hash.
- EXIF, albums and dimensions are not collected. They live in Immich's own
  database, and reading a second application's schema would make every Immich
  migration a collector outage; a derived reader can reach for them later
  without changing what was published here.
- Symlinked files and directories are refused, a library over
  `MAX_MEDIA_OBJECTS` (100 000) is refused rather than truncated, and so is an
  empty walk: a silent prefix would publish something that is not the library,
  and an empty state would carry every previous object forward as absent.
  A directory the walk cannot read is a refusal too -- `os.walk` would otherwise
  skip it and publish a partial library with a green unit.
- Files whose suffix is not a photo or video are skipped and counted under
  `skipped` in the report, so a format the allowlist lacks is visible rather
  than silently missing.
- A file that vanished is carried forward with `ABSENCE_NO_TOMBSTONE`: a partial
  mount is not deletion evidence, and Restic is the record of what was deleted.

`smortress-agent-collect-photos.timer` runs it hourly, with no network and no
secret; unchanged objects keep their row and are not rewritten.

## Music

`collect_music(entities_dir, state, *, captured_at=...)`

The input is the music library itself, mounted read-only, the same tree Navidrome
serves from (`raw/music`, `/srv/music`). One object per audio file, keyed by the
URL-quoted library-relative path.

- The state is **metadata only**, for the same reason as photos: title, the
  artist and album the directory layout names, a leading track number, the
  format, the size and the mtime. Tags inside the audio are not read.
- `Artist/Album/Track` is the layout the artist and album come from. A file with
  fewer than two directories above it claims neither, so a `singles/` or
  `Compilations/` folder is not published as an artist. `01 - Title`,
  `02 Title` and `3.Title` yield the title and the track number;
  a name that starts with a bare number (`1979`) keeps its name.
- Symlinks, the object limit and an empty walk are the same refusals as photos;
  files whose suffix is not audio are counted under `skipped`.

`smortress-agent-collect-music.timer` runs it hourly, with no network and no
secret.

## Who reads a state

`apps/agent_facade/replica_sources.py` projects a committed state into the
facade's record shape, so `sources.read` and `sources.search` answer from the raw
objects instead of the fixtures. The projection is deliberately thin -- title and
body -- and the adapter inherits its contract from the deployment's own source
table, so pointing a facade at a directory cannot widen what it may reach
(`docs/agent-facade.md`).

Search over a replica is served by a derived full-text index
(`apps/agent_facade/source_index.py`): one SQLite FTS5 file under the facade's
index root, per source and per snapshot, built from those projections. It is
derived and never authoritative -- the state is the record of what was
collected, the index is a cache of reading it, and deleting the index costs one
rebuild and no data. A new snapshot publishes a new file, a short-word query
falls back to the scan, and nothing outside the facade reads the file. Because
the snapshot is the file's name, a pass that changed nothing leaves the file
where it is: the same state answers from the same index, and only a real change
pays the projection and the write.

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
python3 -m data_plane.collectors.raw --root /var/lib/agent/local/replica/notes \
  notes --entities /srv/files/vault
python3 -m data_plane.collectors.raw --root /var/lib/agent/local/replica/tasks \
  tasks --entities /srv/files/notes
```

On the host the same command runs from `smortress-agent-collect-finance.service`,
on `agent-collect.network`, with the access URL as a Podman secret
(`docs/core/applications.md`, "Collectors").

`--uidvalidity FOLDER=INT` is repeatable: the epoch is required for every folder
and is never guessed.

`--dry-run` enumerates and validates, then publishes nothing: no object bytes
and no database, so a first run against a real provider can be read before
anything is committed. There is no `--generation` flag: a pass advances the
state's version when it changed something, and reports `"changed": false` when
it did not.

## What a collector does not do

- It commits one complete pass. Every collector enumerates its whole provider,
  so every pass accounts for everything it did not see.
- It does not decide deletion from silence. Only the tombstone cases above
  delete anything.
- The raw collectors do not talk to a provider. The sync tool, the SDK dumper
  and the copy timer are the provider-facing half; this layer is what happens to
  their output. The IMAP stream collector is the exception: the bridge is its
  provider-facing half, and it reads it directly.
