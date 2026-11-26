# agent facade

The MCP surface the two agent deployments read their sources and their memory
through (`apps/agent_facade/`). The design decision it belongs to is SDLC #702:
per-session taint was replaced by two deployments split by authority, so this
document describes two tables and two identities rather than one process with a
label.

## Identity rule

One facade process is one deployment, and the deployment is decided at startup,
never by a request:

| Transport | Where the identity comes from | A missing or wrong identity |
| --- | --- | --- |
| stdio | `AGENT_FACADE_TOKEN`, or the file named by `--token-file` / `AGENT_FACADE_TOKEN_FILE` | every `tools/call` is an `isError` result, refused before the tool name is read |
| Streamable HTTP (`POST /mcp` only) | `X-Deployment-Token` must equal the configured token | `401` with a JSON-RPC error, answered before the body is read, so no tool ran |

The token is compared with `hmac.compare_digest`, read once, held in memory, and
never logged, echoed or returned. Only `POST /mcp` is served: any other path is
`404`, any other method `405`. A notification is `202` with no body, `initialize`,
`tools/list`, `tools/call` and `ping` are the supported methods, and anything else
is `-32601`.

There is no per-session identity. A session cannot acquire another deployment's
reach because it cannot reach another deployment's process.

## Contract table

Every source belongs to exactly one deployment, and the table is the whole of the
reach. A source that appears in no row has no adapter in either deployment, and
one deployment's source is not refused by the other -- it is absent from its
table.

| Source | Deployment | Kind | `sources.read` | `sources.search` |
| --- | --- | --- | --- | --- |
| `notes` | personal | notes | yes | yes |
| `tasks` | personal | tasks | yes | yes |
| `mail` | personal | mail | yes | yes |
| `calendar` | personal | calendar | yes | yes |
| `finance` | personal | finance | yes | yes |
| `brave` | personal | search index | no | yes |
| `photos` | personal | photos | yes | yes |
| `music` | personal | music | yes | yes |
| `workspace` | personal | workspace | yes | yes |
| `repos` | general | repository | yes | yes |
| `books` | general | book | yes | yes |

The table is `sources.SOURCES_BY_DEPLOYMENT`, a module constant keyed by
deployment. Each entry carries a `SourceContract` whose `visibility` must match
its table; `Catalog` raises `ContractError` when it does not, and `Facade` refuses
a catalog or memory profile of another deployment. A registry where the tables
share a name is a startup failure.

## Fixtures, and the replica that replaces them

The table's adapters are fixtures: deterministic in-process records, no network,
no filesystem walk. They exist so the tool surface is complete and provable before
any provider plumbing runs, and every tool test uses them.

A committed raw replica state can answer for a source instead. `--replica
SOURCE=DIR` (repeatable) builds a `ReplicaAdapter` over the state at `DIR`, and
`Catalog.for_deployment(deployment, replacements=...)` puts it in the table. The
adapter re-resolves the state at most once per two seconds and discards its
projection when the snapshot changes, so a commit is visible without a restart;
before the first one the source answers
`unavailable` instead of failing startup. Three properties make that safe:

- The replacement may only take the place of a source the deployment's table
  already names, and it must carry **that table's contract**. Visibility is
  therefore the table's decision, never the caller's: a personal facade cannot
  gain `books` by being pointed at a directory, and the general facade cannot
  gain `mail`.
- What is projected is title and body for search and for `sources.read`. The
  bytes stay in the replica state, so a record can be re-read or re-projected;
  nothing is written back. Provenance carries exactly the three fields a memory
  record may cite: `source_id`, `revision` (the sha256 of the object that
  produced the record) and `captured_at` (the collector's stamp).
- A missing state is not a startup failure and a newer one is not a restart:
  the source answers `unavailable` until the first publication, then serves the
  newest state on the next read or search.

Derived objects are not records: the Maildir epoch map, the ICS projection, the
AccountSet summary and the account/connection objects are skipped, and Brave
contributes its `urls` rows only. The raw layer is `docs/raw-replicas.md`.

Search does not have to scan. With `--index-root DIR` (`AGENT_FACADE_INDEX_ROOT`,
`/index` in the personal container) each adapter keeps a derived SQLite FTS5 index
at `DIR/<source>/<snapshot>.sqlite` and answers from it instead of projecting
the state. The file carries the projection it was built from, so a search
over an existing file projects nothing -- a facade restart beside a warm
`/index` answers the first query in the same time as a warm one. Only a
state with no file pays one projection and writes the file; every search
after that is a query. It is disposable: a committed snapshot is immutable, so
the file is named after the snapshot, a new snapshot is a new file, and the
source's other snapshot files are pruned after the build. The tokenizer is `trigram`, so a hit
is a substring hit -- `orld` finds `Hello world`, which is why it is not the word
tokenizer memory uses. Case folding is SQLite's rather than Python's
`casefold()`, so text a word reaches only through a compatibility character (`ﬁ`
for `fi`) is found by the scan and not by the index: the scan stays the
definition, and the index is the fast path over it. A trigram cannot match a word
shorter than three characters, so a query with such a word is answered by the
scan; so is every index failure (an unwritable root, a foreign schema version, a
damaged file). `apps/agent_facade/source_index.py` holds it, and it follows the
same rule as the memory index: query words are quoted and AND-joined by
`contracts.search_expression` and travel as a bound parameter, so FTS5 syntax in a
query stays literal.

The personal Quadlet passes `--replica` for `mail`, `calendar`, `finance`, `brave`,
`notes`, `tasks`, `photos` and `music` and mounts the replica tree read-only.
`photos` and `music` are answered from metadata-only objects: the media bytes
stay on their own datasets, so a search finds a file by its name, its folders,
its format and its size rather than by reading it. `workspace` is the last
personal source that still serves a fixture.

## Tool contract

| Tool | Arguments | Result | Refusals |
| --- | --- | --- | --- |
| `sources.describe` | none | `{deployment, sources: [{name, kind, read, search}]}` | unknown argument |
| `sources.read` | `{source, id}` | `{id, source, title, body, provenance, revision, truncated}` | unknown source, unknown id, no read capability, body clipped (`truncated: true`) at the cap |
| `sources.search` | `{source, query, limit?}` | `{source, hits: [{id, title, snippet}]}` | unknown source, no search capability, `limit` outside `1..50` |
| `memory.read` | `{key}` | `{key, value, tags, provenance, revision, digest}` | unknown key |
| `memory.write` | `{key, value, tags?, provenance}` | `{key, revision, digest}` | value over the cap, missing provenance, unknown provenance field |
| `memory.search` | `{query, limit?}` | `{query, hits: [{key, snippet, revision}]}` | `limit` outside `1..50`, query with no word |
| `memory.rebuild` | none | `{indexed}` | unknown argument |
| `shell.run` | `{command}` | `{status, output, truncated}` | unknown argument, empty command, a control character other than a tab or a newline, a command over 32768 characters, no bridge socket, a bridge error |

`shell.run` is the one tool that is not a typed read of a named source, and it is
the only one whose presence is a deployment fact rather than a registry entry: a
facade appends it to `tools/list` exactly when the process was started with
`--shell-socket`, and refuses the name otherwise. Each deployment's quadlet mounts
exactly its own class's socket directory (`docs/agent-jobs.md`), so `shell.run` on
the general facade runs a job in the general class and on the personal facade a job
with no route and no host mount; a facade started without a socket has no shell
tool at all. The command is
unsupervised YOLO by design, the same doctrine as the dispatcher: there is no
approval, no review and no second submission surface, and what contains it is the
container below the socket, not a check above it. Output is merged and capped at
1 MiB, with `truncated` distinguishing a clipped run from a short one; the exit
status is the job's, not a transport error.

Rules that hold for every tool:

- Arguments are a JSON object with no unknown fields, and every field is a
  bounded string, a bounded integer, or a list of bounded strings. A wrong type,
  an empty string, a control character, or an over-long value is a refusal.
- `source`, `id` and `key` match `[A-Za-z0-9][A-Za-z0-9_-]*`: one path segment,
  never a dot, so an identifier cannot address a file outside the deployment.
- `limit` defaults to 20 and never exceeds 50; `--max-body-bytes` (default
  256 KiB) caps a returned body and a written value.
- A search returns `id`, `title` and a one-line snippet, never a record body.
- A tool refusal is an MCP `isError` result whose text and `structuredContent`
  are the repository's error shape, `{"error": {"code", "message"}}`.

Error codes: `unauthorized`, `unknown_tool`, `validation`, `unknown_source`,
`unsupported`, `not_found`, `unavailable`, `shell_failed`, `internal`,
`data_plane_error`. `unavailable` covers both a source whose replica has not
published and a shell bridge that cannot be reached: in both cases the tool exists
and the thing behind it does not, which is not a refusal of the request.

## Memory and index rules

- Memory is `FileMemory` from `libs/data_plane/memory/`, not a second store:
  one JSON record per key at `<memory-root>/<profile>/<key>.json`, written by
  temporary file and `os.replace`, mode 0600.
- Profile per deployment: `local` for personal, `external` for general. One
  deployment cannot address the other's records or index.
- Provenance is required and travels unchanged; `source_id`, `revision` and
  `captured_at` are the only fields accepted.
- `revision` is the record's `updated_at` and always moves forward: when two
  writes land inside one clock second the second is bumped a second ahead, so the
  library's supersedes rule (`updated_at` string order) always sees the newer
  record.
- The full-text index is `<memory-root>/<profile>/cache/index.sqlite`, SQLite
  FTS5 over the record content and tags. It is derived and disposable: rebuilt
  when missing, when its schema version differs, when the live record set no
  longer matches what it recorded, and on `memory.rebuild`. Builds write a
  temporary database and `os.replace` it, so a search sees one index or the
  other, never half of either.
- It is never authoritative: every candidate is read back through `FileMemory`
  and dropped if it is missing, tombstoned, or different on disk. Deleting the
  index changes nothing but the cost of the next search; deleting a record
  removes it from search.
- Query text is never passed to the FTS5 parser: words are extracted and quoted,
  so `OR`, `-`, `*` or `NEAR(` in a query are literals, not syntax.

## Non-goals

- **No generic filesystem, SQL or URL operation.** There is no tool whose argument
  names a path, a query string or an endpoint: a facade is a typed contract over
  named sources. The one command surface is `shell.run`, and it is not generic: it
  takes one command, has no field for a class or an image, and is reachable only
  where the deployment was given a bridge socket. It exists because a
  coordination server needs to run a command, and the alternative to bounding it
  here is an agent with a Podman socket.
- **No delete tool.** A memory record is superseded, never removed by the facade;
  deletion is a `FileMemory` operation an operator performs on the profile.
- **No cross-deployment import.** Records carry a profile and `import_records`
  refuses a record from another one; the facades have no path that copies from
  one deployment's memory to the other.
- **No deployment wiring here.** Quadlets, image pins and secret delivery are
  described in `docs/core/applications.md` ("Source facades") and
  `docs/manual-steps.md#applications-and-agents`; this document stops at the process.

## Deployment

Two containers, one per deployment, both on `agent-runtime` at the pinned digest
with `Entrypoint=python3` replacing the image's gateway dispatcher:

| Quadlet | Container name | Network | Port | Writable mounts |
| --- | --- | --- | --- | --- |
| `agent-facade-personal` | `smortress-agent-facade-personal` | `agent-local.network` (no default route) | `18004` | `/memory` = `state/agent-local/memory`; `/index` = `state/agent-local/index`; `/run/agent-shell` = the personal bridge's socket directory (rw: `connect(2)` needs the inode's write bit) |
| `agent-facade-general` | `smortress-agent-facade-general` | `agent-general.network` | `18005` | `/memory` = `state/agent-general/memory`; `/run/agent-shell` = the general bridge's socket directory (rw: `connect(2)` needs the inode's write bit) |

Neither publishes a port. The only client is that deployment's gateway, which
reaches the facade by container name (`http://smortress-agent-facade-personal:18004/mcp`,
`http://smortress-agent-facade-general:18005/mcp`): a published port would be a
second route in with no consumer, and Tailscale Serve would have to be taught to
skip it.

Code delivery is the image, not a mount. `images/agent-runtime/Containerfile`
derives from the pinned Hermes runtime and installs the package at
`/usr/lib/agent-facade` -- `apps/agent_facade/`, the `libs/data_plane/` it imports --
and the units point `PYTHONPATH` at it. The proxy's program is baked in the same
image at `/usr/libexec/agent-proxy`, and the collector and mail units import the
same tree. Nothing is mounted from the host: the running bytes are the bytes the pin
names, and an agent-code change rebuilds that image instead of the OS.

Each container runs as uid 1000 with `ReadOnly=true`, `NoNewPrivileges=true` and
`DropCapability=ALL`, holds one token as a mounted file, and writes nowhere but
`/memory` and, on the personal side, `/index`. Only the personal facade takes
`--index-root`: the general deployment has no replica source, so it has nothing to
index. Both facades take `--shell-socket` and mount their own class's bridge
directory into `/run/agent-shell`: `agent-shell-general` or
`agent-shell-personal`, each 0710 root:1000 with a 0660 socket. The two
containers share uid 1000, so the mode cannot tell them apart; the mount is the
separation, and each bridge's class is a constant in its unit, so the personal
socket can only ever run a personal job and the general socket a general one.
The mount is not `:ro`: connecting to a Unix socket needs write permission on the
inode. Mounting the directory rather than the socket means a bridge restart is
invisible to this container.

The gateway's `mcp_servers` entry sends that token as `X-Deployment-Token`; the
image's config template carries the placeholder `__FACADE_TOKEN__` and
`smortress-agent-config.service` substitutes the decrypted value when it seeds the
file, so the token is in no image, no document and no command line.

## Live general trees

The general deployment's two sources are live, not replica states
(SDLC #851): `--repo-root /srv/git` and `--books-root /srv/books` mount the two
trees read-only into that one container and the adapters read them on each call.

| Source | Record id | `read` returns | `search` matches |
| --- | --- | --- | --- |
| `repos` | `repos::<host>/<owner>/<repo>::<path>` | the file's text at `HEAD` of that clean-bare clone | files whose `HEAD` content holds every word (`git grep -I`), then paths that do |
| `books` | `books::<author>/<title>` | the `metadata.opf` fields: title, creator, description, date, language | title, author and description |

The revision of a `repos` record is the commit it was read at, and of a `books`
record the SHA-256 of the OPF, so a citation stays reproducible while the tree
moves on. Bounds are the containment: a search walks at most 20000 paths and
4000 books under a 5 s deadline, `git grep -I` never reads a binary blob, a
binary file is refused rather than mangled, and a body is capped at 64 KiB with
`truncated` in its provenance.

Both mounts carry no `:z`/`:Z` and no `label=disable`: the datasets are
`container_file_t` already and keep that label. `/var/srv/books` is `core:core`
0740; `/var/srv/git` is `0770 smores:smores` with an ACL for the general shell
runner, and provisioning adds `u:core:r-x` (plus the default ACL) so this
container's uid 1000 can read it. The personal facade names neither root, and
`tree_adapters_for` takes its contract from the deployment's own table, so a
personal facade naming one fails at startup instead of serving it.

## Checks

```sh
python3 -m unittest discover -s apps/agent_facade/tests -t apps/agent_facade
```

No network, no credentials: the fixtures are in process and the HTTP suite binds
a random loopback port. `shell.run` is proved twice without root: the facade's
mapping against a stub runner (`apps/agent_facade/tests/test_server.py`), and the
runner against a temporary Unix socket (`apps/agent_facade/tests/test_shell.py`). The bridge itself is
`tests/agent-shell-bridge`; a live job needs the host (`docs/manual-steps.md#agent-shell-jobs`).
