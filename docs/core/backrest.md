# Hosted Backrest recovery reader (T4)

Backrest is the browser recovery path for the R2 repository. It is a *reader*:
one repository, a read-only credential, no plans, and no scheduling. The
existing recovery page stays live until this gate passes.

## Deployment

```
browser -- Access (owner identity) -- Worker -- Durable Object -- container (Backrest, restic 0.19.1)
                                                                  |
                                                                  +-- R2 (read-only token)
```

- `backrest/` builds the image, the Worker, and the Durable Object.
- `backrest/scripts/gate.sh` runs the acceptance matrix against a deployment.
- Cloudflare Access is the wildcard application (`tofu/access.tf`); the
  `backrest` application adds a service-auth policy so the gate can run without
  a browser. The hostname is `backrest.sammohr.dev` until T6.
- `wrangler deploy` builds the container image locally and uploads it to the
  Cloudflare registry. Podman works through `WRANGLER_DOCKER_BIN` plus
  `DOCKER_HOST`; the docs still call this unsupported, so a failed build is a
  tooling problem, not a design problem.

### Why `durable_object`

The `default` scheduling policy is deprecated, and it applies image changes as
an application-wide rollout — a deploy would kill a four-hour stream. The
Durable Object policy lets the Worker decide when an instance restarts, passes
the config in at `start()`, and allows a six-hour inactivity timeout.

## What the platform actually promises

| Limit | Value | Consequence here |
| --- | --- | --- |
| HTTP request duration | no wall-clock limit while streaming; 30 s CPU (raisable to 5 min) | a long download is allowed |
| Response body size | none enforced | 100 GiB streams are not capped |
| 100 MiB body cap | container → *external service* uploads only | irrelevant to downloads |
| Instance disk | 20 GB max, ephemeral, fresh from the image each start | cache must stay off (`--no-cache`) |
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
- The config file must be **writable** (load-time migration rewrites it), so it
  is regenerated from Worker secrets on every wake and never treated as state.
- Authentication lives in the config as `base64(bcrypt)`. There is no password
  environment variable and auth is disabled by default, so the Worker always
  seeds `disabled: false` with two users: the operator (hash supplied as a
  secret) and a bootstrap user used only by the Worker to index snapshots.
- There is no health endpoint; readiness is "any HTTP response" on port 9898.
- Nothing is indexed at startup. Every wake runs `TASK_INDEX_SNAPSHOTS` before
  serving, because a download URL can only be minted from an index operation.
- `restic dump`, `ls`, `snapshots`, `stats`, and `cat` all take read locks, so
  `--no-lock` must be a repository-wide flag for a write-denied token.

## Gate matrix

Every row must pass on Cloudflare. The VPS fallback is preauthorized and must
pass the same matrix if Cloudflare fails.

| Check | Command / evidence |
| --- | --- |
| automated redeploy | `wrangler deploy` twice; second run serves without manual steps |
| cold start without binary egress | image ships `/bin/restic`; `BACKREST_RESTIC_COMMAND` set; no restic download in logs |
| reindex before readiness | first request after a wake lists snapshots without touching the UI |
| authentication | `GetConfig` with the bootstrap user returns the config; no anonymous access |
| verified snapshot selection | gate refuses to select a snapshot without the `verified` tag |
| small file and small directory | `gate.sh matrix` |
| 100 GiB file | `gate.sh stream /gate/100g.bin <sha256>` |
| 100 GiB directory | `gate.sh stream /gate/100g-tree` (tar integrity, four-hour budget) |
| cancellation | `gate.sh cancel /gate/100g.bin`, then a follow-up request must answer |
| interruption is visible | operator restarts the instance mid-stream; the client sees a truncated, failed download, never a silent success |
| write denial | `gate.sh denial`: init, prune, unlock, forget all fail and the snapshot list does not move |
| smortress powered off | the whole matrix runs with the server down; only R2 and Cloudflare are involved |

Record the run, the byte counts, the durations, and the failure text on issue
#707. The gate is a failure only when a check fails; a platform interruption
during the four-hour stream is a failure of that attempt, and the documented
behaviour is "restart from the beginning", not resume.

## Operating rules

- Pause R2 forget/prune while a browsing session runs on the host; ordinary
  backups may continue. `--no-lock` is not declared safe during a destructive
  prune.
- Only `verified`-tagged snapshots count as complete. Backrest's UI does not
  enforce this; the operator does.
- Backrest holds the R2 Restic password in memory only, and the password
  recovery copies live in Bitwarden and on paper. The Worker never stores the
  operator password, only its bcrypt hash.
- Plain restic remains the documented fallback when Backrest or Cloudflare is
  unavailable.

## VPS fallback (preauthorized)

Same image, same config bootstrap, same Access and R2 policy; only the hosting
changes:

- persistent `/config` and `/cache` on the VPS, so a wake is a process start,
  not a rebuild;
- the same `gate.sh` matrix, run against the same hostname;
- no Cloudflare-container dependency, at the cost of a patched host.

Nothing else in the design moves: the repository, the read-only token, the
`--no-lock` rule, and the "verified only" runbook all stay identical.
