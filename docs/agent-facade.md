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
`unsupported`, `not_found`, `internal`, `data_plane_error`.

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

- **No generic filesystem, SQL, URL or shell operation.** There is no tool whose
  argument names a path, a query string, an endpoint or a command, and none will
  be added: a facade is a typed contract over named sources, not a general-purpose
  command surface.
- **No delete tool.** A memory record is superseded, never removed by the facade;
  deletion is a `FileMemory` operation an operator performs on the profile.
- **No cross-deployment import.** Records carry a profile and `import_records`
  refuses a record from another one; the facades have no path that copies from
  one deployment's memory to the other.
- **No deployment wiring here.** Quadlets, image pins and secret delivery are
  described in `docs/core/applications.md` ("Source facades") and
  `docs/manual-steps.md` section 40; this document stops at the process.

## Deployment

Two containers, one per deployment, both on `agent-runtime` at the pinned digest
with `Entrypoint=python3` replacing the image's gateway dispatcher:

| Quadlet | Container name | Network | Port | Memory root |
| --- | --- | --- | --- | --- |
| `agent-facade-personal` | `smortress-agent-facade-personal` | `agent-local.network` (internal, no egress) | `18004` | `/memory` = `state/agent-local/memory` |
| `agent-facade-general` | `smortress-agent-facade-general` | `agent-general.network` | `18005` | `/memory` = `state/agent-general/memory` |

Neither publishes a port. The only client is that deployment's gateway, which
reaches the facade by container name (`http://smortress-agent-facade-personal:18004/mcp`,
`http://smortress-agent-facade-general:18005/mcp`): a published port would be a
second route in with no consumer, and Tailscale Serve would have to be taught to
skip it.

Code delivery is a bind mount, not an image. The program is not in the upstream
runtime image, so `image/Containerfile` installs it on the host at
`/usr/lib/agent-facade` -- the package at `apps/agent_facade/`, the libraries it
imports at `libs/data_plane/` -- and the units mount that tree read-only and point
`PYTHONPATH` at it. The same pattern as `agent-proxy`, whose unit mounts
`/usr/libexec/agent-proxy` for the same reason; a unit that names a program it does
not mount is a container that cannot start.

Each container runs as uid 1000 with `ReadOnly=true`, `NoNewPrivileges=true` and
`DropCapability=ALL`, holds one token as a mounted file, and writes nowhere but
`/memory`. The gateway's `mcp_servers` entry sends that token as
`X-Deployment-Token`; the image's config template carries the placeholder
`__FACADE_TOKEN__` and `smortress-agent-config.service` substitutes the decrypted
value when it seeds the file, so the token is in no image, no document and no
command line.

## Checks

```sh
python3 -m unittest discover -s apps/agent_facade/tests -t apps/agent_facade
```

No network, no credentials: the fixtures are in process and the HTTP suite binds
a random loopback port.
