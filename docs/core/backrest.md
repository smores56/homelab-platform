# Hosted Backrest recovery reader (T4)

Backrest is the browser recovery path for the R2 repository. It is a *reader*:
one repository, a read-only credential, no plans, and no scheduling. It replaced
the static recovery letter on `recovery.sammohr.dev`; the old Pages project is
kept but serves nothing.

## Deployment

```
browser -- Access (owner identity) -- Worker -- Durable Object -- container (Backrest, restic 0.19.1)
                                                                  |
                                                                  +-- R2 (read-only token)
```

- `backrest/` builds the image, the Worker, and the Durable Object.
- `backrest/scripts/deploy.sh` is the only deploy path: it refuses to run
  without the repository id, URI and GUID, which deliberately do not live in
  `wrangler.json`.
- `backrest/scripts/gate.sh` runs the acceptance matrix against a deployment.
- Cloudflare Access is the wildcard application (`tofu/access.tf`); the
  `backrest` application adds the `service auth` policy so the matrix can run
  without a browser. That policy is account-wide — any service token in the
  account is accepted, which `docs/cloudflare.md` already documents.
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

Backrest has no read-only role, and its admin API is one request away from
`auth.disabled: true`. The Worker is therefore the boundary, not a pass-through:

- It refuses every RPC except `GetConfig`, `GetOperations`,
  `GetOperationEvents`, `GetLogs`, `GetSummaryDashboard`, `GetDownloadURL`,
  `ListSnapshots`, `ListSnapshotFiles`, and `Authentication/Login`. `SetConfig`,
  `AddRepo`, `DoRepoTask`, `Backup`, `Forget`, `Restore`, `RunCommand`, `Cancel`
  and the rest return 403 even for an authenticated session.
- It refuses non-GET/HEAD requests outside those RPCs, so `/metrics` and any
  future mutating route are closed by default.
- It removes `repos[].password` and `repos[].env` from `GetConfig`.
- It filters `ListSnapshots` to `verified` snapshots and refuses
  `GetDownloadURL` for an operation whose snapshot is not verified.

The bootstrap user exists only so the Worker can mint those index operations;
it is a machine credential, not a human login. The operator's password never
reaches Cloudflare — only its bcrypt hash does.

## Readiness

A wake is: start the container with the environment, wait for port 9898, read
the live snapshot list, run `TASK_INDEX_SNAPSHOTS`, and wait until every live
snapshot has an index operation. Concurrent requests share one bootstrap
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
| authentication | `gate.sh verify`: Access-only request is refused by Backrest; config shape asserted |
| redaction | `gate.sh verify`: no repo password or R2 key in `GetConfig` |
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
- Access reaches it through a Cloudflare Tunnel instead of a Worker route;
- the same `gate.sh` matrix runs against the same hostname.

Exact commands are in `docs/manual-steps.md` §39.8.
