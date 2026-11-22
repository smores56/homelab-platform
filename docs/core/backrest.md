# Backrest recovery reader (T4, moved to the edge in T2)

Backrest is the browser recovery path for the R2 repository. It is a *reader*:
one repository, a read-only credential, no plans, and no scheduling. It replaced
the static recovery letter on `recovery.sammohr.dev`; the old Pages project is
kept but serves nothing.

**The reader runs on the edge VPS now (#725 T2), not on Cloudflare.** The Worker
and its container were deleted; `recovery.sammohr.dev` is a grey A record and
Caddy on `smoresnet` terminates TLS in front of the guard. The guard
(`backrest/container/guard.py`) reproduces the Worker's policy inside the image —
read-only RPC allowlist, JSON and protobuf redaction of the repository password
and the restic environment, verified-only listing and downloads, and the
10-per-10-s login budget the Cloudflare rule used to provide. It owns the port
and starts Backrest on loopback, so a host cannot expose an unguarded reader.

```
browser -- Backrest password -- Caddy (LE cert) -- guard -- Backrest (loopback) -- R2 (read-only token)
```

`provision/edge/backrest-watchdog.timer` restarts the reader when it stops
answering and pings Healthchecks if a ping URL is written to
`/etc/backrest/healthcheck-url`.

- `backrest/` builds the image, the guard, and the Worker (now retired).
- `backrest/scripts/deploy.sh` is the only deploy path: it refuses to run
  without the repository id, URI and GUID, which deliberately do not live in
  `wrangler.json`.
- `backrest/scripts/gate.sh` runs the acceptance matrix against a deployment.
- `recovery.sammohr.dev` has **no Cloudflare Access gate** (design #701,
  re-affirmed 2026-11-20). The name is in `local.public_apps` in `tofu/access.tf`,
  so Access lets it through to the Worker, and family can use it with nothing
  set up in advance. The reader's own password is the only login, and
  `tofu/rate-limit.tf` rate limits the login endpoint at 10 requests per 10 s per
  IP with a 10 s mitigation window. That rule holds the zone's only rate-limit
  slot, and the media rule it displaced is a recorded residual (below). There is
  no `backrest` Access application, no email policy on the name and no service
  token in the path; a service token header from `gate.sh` is simply an unused
  header now.
- `deploy.sh` builds the image, pushes it with `wrangler containers build -p`,
  asks the registry for the digest it stored, and deploys a config whose image
  reference is that digest. Two podman quirks are why it does not simply call
  `wrangler deploy`: wrangler passes Docker-only flags (`--provenance`) and a
  Dockerfile on stdin, and it reads a *local* digest after a podman push while
  the registry stores a different one — Cloudflare then rejects the image with
  "does not exist in this account".

### Why `durable_object`

The `default` scheduling policy is deprecated, and it applies image changes as
an application-wide rollout — a deploy would kill a four-hour stream. The
Durable Object policy lets the Worker decide when an instance restarts, passes
the environment in at `start()`, and allows a six-hour inactivity timeout.

## What the platform actually promises

| Limit | Value | Consequence here |
| --- | --- | --- |
| HTTP request duration | no wall-clock limit while streaming; 30 s CPU (raisable to 5 min) | a long download is allowed |
| Response body size | none enforced | 100 GiB streams are not capped |
| 100 MiB body cap | container → *external service* uploads only | irrelevant to downloads |
| Instance disk | `standard-2` = 12 GB; account maximum 20 GB; ephemeral | cache stays off (`--no-cache`) |
| Inactivity timeout | at most 6 h | idle instances stop; streams keep the object active |
| Instance lifetime | no fixed maximum, **no uptime guarantee** | a host restart can kill a stream mid-flight |

Sources: `developers.cloudflare.com/containers/platform/limits/`,
`.../containers/faq/`, `.../workers/platform/limits/`,
`.../containers/concepts/architecture/`.

Two documented ambiguities are exactly what the gate must settle: Durable Object
eviction prevention is described as "up to 15 minutes per operation", while the
Workers limits table says a streaming response keeps the object active; and a
runtime update gives in-flight requests 30 s on one page and 20 minutes on
another. A four-hour stream is the only honest test.

## Backrest facts that shape the design

- `/download/<jwt>/` streams `restic dump --archive tar` for **files and
  directories** through an `io.Pipe`; nothing is staged on disk. The dump runs
  on the request context, so a dropped client tears the restic process down.
- The config file must be **writable** (load-time migration rewrites it), so the
  image renders it from the environment on every start and never treats it as
  state. The renderer lives in the image, so a Cloudflare run and a VPS run use
  the same rules.
- Authentication lives in the config as `base64(bcrypt)`. There is no password
  environment variable and auth is disabled by default, so the image always
  renders `disabled: false` with two users: the operator (hash supplied as a
  secret) and a bootstrap user used only by the Worker to index snapshots.
- There is no health endpoint; readiness is "any HTTP response" on port 9898.
- `GetConfig` returns the repository password and the restic environment (the
  R2 key pair) to every authenticated caller — its sanitizer masks only user
  hashes. The Worker strips both.
- Nothing is indexed at startup, and `TASK_INDEX_SNAPSHOTS` creates no operation
  of its own, so its task id is useless. Readiness is the indexed snapshot set
  catching up with the live `restic snapshots` list, and `GetDownloadURL` only
  works once that has happened. Listing snapshots while awake also schedules a
  bounded, single-flight refresh, so a backup that lands mid-session becomes
  downloadable instead of waiting for the next wake.
- `restic dump`, `ls`, `snapshots`, `stats`, and `cat` all take read locks, so
  `--no-lock` must be a repository-wide flag for a write-denied token.

## The read-only boundary

**Why an internet-facing reader needs no identity gate.** Access is an
availability tax on the one workflow that must work when nothing else does:
family members would need a Cloudflare login set up before a disaster, and the
recovery kit is paper. Exposing the UI without that gate is acceptable only
because of the boundary below: **write RPCs are denied at the Backrest layer by
the Worker and at the R2 layer by the token**, so what is exposed is a read-only
browser over one repository. The absent gate is not the control; the write
denial is. If that denial ever weakens — a Backrest release the proxy does not
recognise, or an R2 token with write scope — re-adding the Access application is
the documented fallback, and the `write denial` row of the gate matrix is what
detects it.

### The single rate-limit slot

The zone plan allows one `http_ratelimit` rule, so the login budget above spends
the only slot the ruleset has. The rule it displaced covered `photos`, `music`
and `opds` at 1000 requests per 10 s per IP with the same 10 s mitigation, sized
for an Immich timeline scroll.

That rule was live, which is why losing it is a residual and not a cleanup: all
three names are in `local.public_apps` (`tofu/access.tf`) and each resolves
through a proxied CNAME to the cluster tunnel (`tofu/dns.tf`), with `photos`
fronting `immich-server.immich.svc.cluster.local` (`tofu/cluster.tf`). Immich is
not tailnet-only — the name has a public bypass application precisely because
mobile clients cannot complete an Access login — so the phase saw that traffic
and the budget applied to it.

The cost is bandwidth: one IP in one colo can now burst past 1000 requests per
10 s against those hosts without the edge blocking it, and each media app's own
login is the only thing behind that burst. The bandwidth itself is already paid
for — the zone's request allowance and the tunnel carry the same traffic either
way, and the rule never gated access, only rate. For `opds` the loss is sharpest,
because the per-IP budget was its only request-rate control.

Revisit the choice on observed abuse: a sustained burst from one IP or one colo in
the `photos`, `music` or `opds` logs, or egress past what the tunnel already
carries, is the evidence that the media budget is worth more than the login one.
Until then the slot stays with the reader, because it is the only public surface
in the zone with no Access gate in front of it.

Backrest has no read-only role, and its admin API is one request away from
`auth.disabled: true`. The Worker is therefore the boundary, not a pass-through:

- It refuses every RPC except `GetConfig`, `GetOperations`,
  `GetOperationEvents`, `GetLogs`, `GetSummaryDashboard`, `GetDownloadURL`,
  `ListSnapshots`, `ListSnapshotFiles`, and `Authentication/Login`. `SetConfig`,
  `AddRepo`, `DoRepoTask`, `Backup`, `Forget`, `Restore`, `RunCommand`, `Cancel`
  and the rest return 403 even for an authenticated session.
- It refuses non-GET/HEAD requests outside those RPCs, so `/metrics` and any
  future mutating route are closed by default.
- It removes `repos[].password` and `repos[].env` from `GetConfig` in both
  wire formats: JSON for `curl` and `gate.sh`, protobuf for the Web UI (which
  negotiates the Connect protocol in `application/proto`). It then re-checks
  the result against the real secrets in `env` and fails closed if either
  survives, so a Backrest release that adds a credential field is refused
  rather than leaked.
- It filters `ListSnapshots` to `verified` snapshots for JSON callers, and
  refuses `GetDownloadURL` for an operation whose snapshot is not verified in
  both formats (the op id is read from the protobuf request too). The Web UI's
  protobuf listing is not filtered — its response is passed through — so the
  operator rule "only `verified` counts" is enforced at download time.
- A non-2xx response is passed through untouched with its own content type.
  Backrest's `401` is `text/plain`, which Connect maps to `unauthenticated` and
  turns into the login form; relabelling it `application/json` made the client
  `JSON.parse` "Unauthorized" and fail the page before login.

The bootstrap user exists only so the Worker can mint those index operations;
it is a machine credential, not a human login. The operator's password never
reaches Cloudflare — only its bcrypt hash does.

## Readiness

A wake is: start the container with the environment, wait for port 9898, read
the live snapshot list, run `TASK_INDEX_SNAPSHOTS`, and wait until every live
snapshot has an index operation. A container survives a deployment with the
config it was started with, so the Worker compares the running config with the
deployment and replaces a stale container instead of indexing the wrong
repository. Concurrent requests share one bootstrap
promise. The whole sequence is bounded (3 min to listen, 10 min to index), and
every internal call carries its own `AbortSignal` so one hung request cannot
stretch the deadline. Failure is a 503 with a generic message; the detail goes
to the Worker log unless `BACKREST_DEBUG=1`.

## Gate matrix

Every row must pass on Cloudflare. The VPS fallback is preauthorized and must
pass the same matrix if Cloudflare fails.

| Check | Command / evidence |
| --- | --- |
| automated redeploy | `backrest/scripts/deploy.sh` twice; the second run serves without manual steps |
| cold start without binary egress | image ships `/bin/restic`; `BACKREST_RESTIC_COMMAND` set; no restic download in `wrangler tail` |
| reindex before readiness | first request after a wake lists snapshots and can mint a download URL |
| authentication | `gate.sh verify`: an anonymous request is refused by Backrest with its own login form, with no Access redirect in front of it; the login endpoint is rate limited at the edge (`tofu/rate-limit.tf`) |
| redaction | `gate.sh verify`: no repo password or R2 key in `GetConfig`, JSON and protobuf |
| verified-only | `gate.sh verify`: `ListSnapshots` returns only `verified` tags |
| small file and small directory | `gate.sh verify` |
| 100 GiB file | `gate.sh stream <path> sha` with the seeded hash |
| 100 GiB directory | `gate.sh stream <path> tar` — the stream is parsed as a tar |
| cancellation | `gate.sh cancel <path>`, then a follow-up request must answer |
| interruption is visible | operator kills the container's main process mid-stream; the client sees a truncated, failed download, never a silent success |
| write denial | `gate.sh denial`: restic init/backup/forget/prune/unlock all fail with the read-only token and leave the snapshot list unchanged; the proxy also refuses every write RPC with 403 |
| smortress powered off | the whole matrix runs with the server down; only R2 and Cloudflare are involved |

Record the run, byte counts, durations and failure text on issue #707. An
interruption during the four-hour stream fails that attempt; the documented
behaviour is "restart from the beginning", not resume.

## Operating rules

- Pause R2 forget/prune while a browsing session runs on the host; ordinary
  backups may continue. `--no-lock` is not declared safe during a destructive
  prune.
- Only `verified`-tagged snapshots count as complete. The proxy enforces it for
  this UI; plain restic still does not, so the runbook rule stands.
- The restic password lives in the ephemeral container config (mode 0600), in
  the Worker secret, and in Bitwarden/on paper. Nothing durable on Cloudflare
  keeps it.
- Plain restic remains the documented fallback when Backrest or Cloudflare is
  unavailable.

## VPS fallback (preauthorized)

Same image and same environment contract, so nothing about the repository,
token, `--no-lock`, or "verified only" changes. The differences are hosting
only:

- `/data` and `/cache` are persistent volumes; the config is still re-rendered
  from `/etc/backrest/env` on every start, so no drift is possible;
- the hostname reaches it through a Cloudflare Tunnel instead of a Worker route,
  with the same absence of an Access gate and the same edge rate limit;
- the same `gate.sh` matrix runs against the same hostname.

Exact commands are in `docs/manual-steps.md` §39.8.
