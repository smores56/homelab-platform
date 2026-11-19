# agent_facade

One MCP server that runs as **one deployment** and reaches only that deployment's
sources and memory. The personal deployment reaches personal sources from a local
model with zero egress; the general deployment reaches general sources from a
hosted model. The split is two processes with two tokens and two source tables,
not a policy check inside one process.

## Why there is no taint layer

Per-session taint was replaced by a deployment split (SDLC #702). A taint label
inside one process is a value a handler can be talked out of; a separate process
cannot be talked into reading a source table it does not have. So there is no
session identity, no label, and no untrusted-to-trusted transition to police:
the personal facade has no `repos` or `books` adapter to consult at all, and the
general facade has no `mail`, `notes` or `brave` adapter. A source name outside
the deployment is a missing key in that table, not a branch a later edit can
invert.

`Catalog` refuses to be constructed from an adapter whose `SourceContract`
declares the other visibility, and `Facade` refuses a catalog or a memory profile
for another deployment, so "the personal facade holds a books adapter" is not a
state the service can be started in. Memory follows the same rule: personal
memory is the `local` profile, general memory the `external` profile, so one
deployment's keys are not even visible to the other.

## What a deployment may reach

| Deployment | Model | Sources |
| --- | --- | --- |
| `personal` | local llama.cpp, no egress | `notes`, `tasks`, `mail`, `calendar`, `finance`, `brave`, `photos`, `music`, `workspace` |
| `general` | hosted model through `agent_proxy` | `repos`, `books` |

`brave` is search-only (a web index is read through hits, not records); every
other source answers both reads and searches. `sources.describe` reports the
same table, so a client can discover the boundary without guessing.

## Tools

| Tool | Arguments | Result |
| --- | --- | --- |
| `sources.describe` | none | `{deployment, sources: [{name, kind, read, search}]}` |
| `sources.read` | `{source, id}` | one record `{id, source, title, body, provenance, revision, truncated}` |
| `sources.search` | `{source, query, limit?}` | `{source, hits: [{id, title, snippet}]}` |
| `memory.read` | `{key}` | `{key, value, tags, provenance, revision, digest}` |
| `memory.write` | `{key, value, tags?, provenance}` | `{key, revision, digest}` |
| `memory.search` | `{query, limit?}` | `{query, hits: [{key, snippet, revision}]}` |
| `memory.rebuild` | none | `{indexed}` |

There is no filesystem, SQL, URL or shell operation, no delete tool, and no way
to name another deployment. Every argument is a bounded string or a bounded
integer; an unknown tool, an unknown argument, a wrong type, an over-long string,
a `limit` outside `1..50`, or a `value` over the cap is refused rather than
clipped or ignored. A tool refusal is an MCP `isError` result carrying
`{"error": {"code", "message"}}`; a transport refusal is the same JSON shape.

Caps: `--max-body-bytes` (default 256 KiB) bounds a returned `body` and a written
`value`; a returned body is clipped to it and says so with `truncated: true`, a
written value over it is refused. `limit` defaults to 20 and never exceeds 50.
A search hit is `id`, `title` and a one-line excerpt — never a record body.

## Identity

One token per process, checked with `hmac.compare_digest`:

- **stdio**: the token arrives in `AGENT_FACADE_TOKEN`, or in the file named by
  `AGENT_FACADE_TOKEN_FILE` (`--token-file`), which is the container form. A
  missing token refuses every tool call before the tool name is looked at.
- **Streamable HTTP**: `POST /mcp` only; `X-Deployment-Token` must equal the
  configured token. A missing or wrong token is `401` with a JSON-RPC error,
  answered before the body is read, so no tool can have run. A notification is
  `202` with no body, an unknown method is `-32601`.

The token is read once, held in memory, never logged, never echoed in an error
and never placed in a response; log lines carry the method, the path and the
status only, never a header.

## Memory and the derived index

Records are `FileMemory` records at `<memory-root>/<profile>/<key>.json`,
imported rather than reimplemented: provenance requires `source_id`, `revision`
and `captured_at`, ids are one flat path segment, and the supersedes rule is the
library's. `revision` in a result is the record's `updated_at`, and a write always
moves it forward (by at least a second when the clock has not), so a second write
to the same key genuinely supersedes the first.

`<memory-root>/<profile>/cache/index.sqlite` is a SQLite FTS5 index, and it is
derived and disposable:

- rebuilt from the record files when it is missing, when its schema version
  differs, or when the live record set no longer matches what it recorded;
- rebuilt by `memory.rebuild`;
- never authoritative: a hit is returned only after its record has been read
  back from disk and found alive, so a row the index still lists but the disk no
  longer holds is dropped, and a tombstone removes the record from results.

Deleting the index changes nothing but the cost of the next search.

## Run

```sh
# personal deployment, Streamable HTTP
PYTHONPATH=libs AGENT_FACADE_TOKEN_FILE=/run/secrets/agent-facade-personal \
  python3 -m apps.agent_facade --deployment personal --transport http \
  --host 127.0.0.1 --port 18004 --memory-root /var/lib/agent-facade

# general deployment, stdio MCP child
PYTHONPATH=libs AGENT_FACADE_TOKEN=... AGENT_FACADE_DEPLOYMENT=general \
  python3 -m apps.agent_facade --transport stdio
```

Every flag also has an `AGENT_FACADE_*` environment variable:
`AGENT_FACADE_TRANSPORT`, `AGENT_FACADE_DEPLOYMENT`, `AGENT_FACADE_TOKEN`,
`AGENT_FACADE_TOKEN_FILE`, `AGENT_FACADE_MEMORY_ROOT`, `AGENT_FACADE_HOST`,
`AGENT_FACADE_PORT`, `AGENT_FACADE_MAX_BODY_BYTES`. The HTTP default bind is
`127.0.0.1:18004`; `--transport` defaults to `stdio`, `--deployment` has no
default and is required. Logs go to stderr, so stdout belongs to stdio alone.

## Status: offline fixtures

Every adapter is a `FixtureAdapter`: deterministic records held in process, no
network, no live personal data, no filesystem walk. Nothing here issues or stores
a secret, and no Quadlet, image pin or deployment wiring ships with this code —
that is a separate step.

## Test

```sh
python3 -m unittest discover -s apps/agent_facade/tests -t apps/agent_facade
```

The suite runs the real HTTP handler on a random loopback port and the real stdio
loop over `StringIO`, so there is no network and no credential. It covers the
registry split (personal cannot name `repos` or `books`; general cannot name a
personal source), `401` for a missing or wrong token with no write behind it,
every refused argument shape, a memory write/read round trip with provenance and
a revision that advances, `memory.search` before and after deleting the index,
a record deleted from disk disappearing, a ghost index row never being returned,
and `sources.search` returning snippets without bodies.
