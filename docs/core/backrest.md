# Backrest recovery reader (T4; on smortress since SDLC #953)

Backrest is the browser recovery path for the R2 repository. It is a *reader*:
one repository, a read-only credential, no plans, and no scheduling. It replaced
the static recovery letter on `recovery.sammohr.dev`. That letter, its Pages
project and the R2 browser policy it needed are deleted (SDLC #833), so the
repository is read server-side only.

**The reader runs on smortress, not on the public edge.** It ran on the VPS from
#725 T2 until #953, which is where the corpus-read credential would have sat on a
box anybody can reach; the edge now holds one Caddy route and no credential at
all. `recovery.sammohr.dev` is still a grey `A` record to the edge, Caddy there
terminates TLS, and the request crosses the tailnet to the reader's own Service
(`svc:recovery`). The guard (`backrest/container/guard.py`) reproduces the
Worker's policy — read-only RPC allowlist, JSON and protobuf redaction of the
repository password and the restic environment, verified-only listing and
downloads, and the 10-per-10-s login budget the Cloudflare rule used to provide.
It owns the port and starts Backrest on loopback, so a host cannot expose an
unguarded reader.

```
browser -- Backrest password -- Caddy on the edge (LE cert)
        -- tailnet -- svc:recovery -- guard -- Backrest (loopback) -- R2 (read-only token)
```

`scripts/smortress-backrest-watchdog.sh` (unit
`smortress-backrest-watchdog.timer`) restarts the reader when it stops answering
and pings Healthchecks if a ping URL is written to `/etc/backrest/healthcheck-url`.

- `backrest/` builds the image, the guard, and the Worker (now retired).
- `backrest/scripts/deploy.sh` is the only deploy path: it refuses to run
  without the repository id, URI and GUID, which deliberately do not live in
  `wrangler.json`.
- `backrest/scripts/gate.sh` runs the acceptance matrix against a deployment.
- `recovery.sammohr.dev` has **no Cloudflare Access gate** (design #701,
  re-affirmed 2026-11-20). No Access object exists in the zone at all (SDLC
  #833): the name answers from the edge VPS, and family can use it with nothing
  set up in advance. The reader's own password is the only login, and the guard
  enforces the login budget itself — 10 requests per 10 s per IP with a 10 s
  mitigation window — because no Cloudflare phase sees this traffic any more;
  `tofu/rate-limit.tf` keeps its single slot empty, and the media rule that slot
  displaced is a recorded residual (below). There is no `backrest` Access
  application, no email policy on the name and no service token in the path; a
  service token header from `gate.sh` is simply an unused header now.
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

The limits below are the Cloudflare Containers limits the design was written
against, kept as the record of why the shape is what it is: the reader left
Cloudflare in #725 T2 and the Worker-era sections after this point describe code
that is no longer deployed. The parts that still bind are the read-only boundary,
the gate matrix and the operator order.

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

That rule was live, which is why losing it is a residual and not a cleanup. In
the tunnel era all three names were served by the zone's cluster tunnel, since
retired by SDLC #833, with `photos` fronting
`immich-server.immich.svc.cluster.local`. Immich was not tailnet-only: the name
carried a public Access bypass application, because mobile clients cannot
complete an Access login. That application and that tunnel are both gone with
the rest of the zone's Access objects and tunnels (SDLC #833), and the names are
grey `A` records at the edge VPS, so nothing in Cloudflare sits in their path to
rate-limit at all.

The surviving residual is the VPS: it has no per-IP request budget in front of
`photos` or `opds` beyond Caddy's own limits, so one IP in one colo can burst
past 1000 requests per 10 s against the box and each media app's own login is
the only thing behind that burst. The bandwidth is already paid for — the ctrl
panel's transfer allowance in `bootc/edge/runbook.md` carries that traffic
whichever layer meters it, and the displaced rule never gated access, only rate.
`opds` had no other request-rate control before, and has none now.

Revisit the choice on observed abuse: a sustained burst from one IP or one colo in
the `photos` or `opds` logs, or transfer past the VPS plan's allowance, is the
evidence that the media budget is worth more than the login one. Until then the
slot stays with the reader, which has no identity gate at all — Backrest's own
password is the only login.

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

Every row must pass against the deployed reader, which is smortress behind
`svc:recovery` since SDLC #953 (the edge VPS before that). The Cloudflare column of
this document is history; nothing about the matrix loses a row because the hosting
changed, and the hosting-only rows are marked.

| Check | Command / evidence |
| --- | --- |
| automated redeploy | `backrest/scripts/deploy.sh` twice; the second run serves without manual steps |
| cold start without binary egress | image ships `/bin/restic`; `BACKREST_RESTIC_COMMAND` set; no restic download in `wrangler tail` |
| reindex before readiness | first request after a wake lists snapshots and can mint a download URL |
| authentication | `gate.sh verify`: an anonymous request is refused by Backrest with its own login form, with no Access redirect in front of it; the login endpoint is bounded by the guard's 10-per-10-s budget |
| redaction | `gate.sh verify`: no repo password or R2 key in `GetConfig`, JSON and protobuf |
| verified-only | `gate.sh verify`: `ListSnapshots` returns only `verified` tags |
| small file and small directory | `gate.sh verify` |
| 100 GiB file | `gate.sh stream <path> sha` with the seeded hash |
| 100 GiB directory | `gate.sh stream <path> tar` — the stream is parsed as a tar |
| cancellation | `gate.sh cancel <path>`, then a follow-up request must answer |
| interruption is visible | operator kills the container's main process mid-stream; the client sees a truncated, failed download, never a silent success |
| write denial | `gate.sh denial`: restic init/backup/forget/prune/unlock all fail with the read-only token and leave the snapshot list unchanged; the proxy also refuses every write RPC with 403 |
| edge box down | the public name is unreachable and nothing else is: the reader is on smortress, so `gate.sh` against the Service still passes — that is the hosting change #953 made, and it is the reason the corpus-read credential left the public box |
| smortress powered off | the reader is unreachable with it: `gate.sh` fails at the edge (502 from Caddy) and passes against nothing else. The edge no longer holds a copy, so the recovery path has the host's availability and no second reader |

Record the run, byte counts, durations and failure text on issue #707. An
interruption during the four-hour stream fails that attempt; the documented
behaviour is "restart from the beginning", not resume.

## Operating rules

- Pause R2 forget/prune while a browsing session runs on the host; ordinary
  backups may continue. `--no-lock` is not declared safe during a destructive
  prune.
- Only `verified`-tagged snapshots count as complete. The proxy enforces it for
  this UI; plain restic still does not, so the runbook rule stands.
- The restic password lives in the reader's rendered config on smortress
  (`/var/lib/backrest/config.json`, 0600 root, rendered from `/etc/backrest/env`)
  and in Bitwarden/on paper. Nothing on Cloudflare keeps it, no Cloudflare account
  can read it, and nothing on the public edge has ever seen it since SDLC #953.
- Plain restic remains the documented fallback when Backrest or the host is
  unavailable.

## Where it runs

Smortress, since SDLC #953; the edge VPS before that (#725 T2), and Cloudflare
before that. The environment contract is unchanged, so nothing about the
repository, token, `--no-lock` or "verified only" moves with the host:

- `units/systemd/smortress-backrest.service` runs the renderer
  (`backrest/container/entrypoint.sh`), which writes the config from
  `/etc/backrest/env` at every start and then execs the guard, which starts the
  pinned Backrest binary on `127.0.0.1:9899` and owns `127.0.0.1:9898`. The binary
  is a hash-pinned release artifact in the image (`bootc/lib/pins.env`), like
  restic, sops and age: the guard is python3 and the renderer needs jq, and the
  host already carries both, so the reader needs no container image of its own.
- `/var/lib/backrest` holds the rendered config and the snapshot index. The index
  is a cache — it is rebuilt by listing the repository — so it is in no recovery
  group.
- `svc:recovery` is the tailnet name `scripts/tailscale-serve.sh` advertises on
  `127.0.0.1:9898`, `tofu/tailscale.tf` creates it and grants it to `tag:vps` and
  `group:owner` — two sources, no probe and no tagged host — and the edge's
  Caddyfile proxies `recovery.sammohr.dev` to
  `$RECOVERY_UPSTREAM` (`https://recovery.<tailnet>.ts.net`).
- `smortress-backrest-watchdog.timer` restarts the reader when it stops answering
  and pings Healthchecks from `/etc/backrest/healthcheck-url`, which is why it is
  one secret to seed rather than two.

What the reader deploys from is still `backrest/container`: the guard and the
renderer are that directory's files, shipped in the host image. The Worker
sources, the `wrangler` path and the Cloudflare secrets below are retired. Exact
commands are in `docs/manual-steps.md#hosted-backrest`.

## Operator order

The gate repository is a separate path under the bucket, so a failed matrix run
cannot touch production snapshots. The read-only boundary, the readiness rules and
the failure modes are `docs/core/backrest.md`.

```sh
export GATE=/var/tmp/backrest-gate
export RESTIC_REPOSITORY="s3:https://385f7d47e2e8438fbda5d6f76d760434.r2.cloudflarestorage.com/homelab-restic/gate"
export AWS_DEFAULT_REGION=auto
export AWS_ACCESS_KEY_ID=$(mise x -- sops -d --extract '["restic-backup-ro-access-key-id"]' secrets/cloudflare.yaml)
export AWS_SECRET_ACCESS_KEY=$(mise x -- sops -d --extract '["restic-backup-ro-secret-access-key"]' secrets/cloudflare.yaml)
read -rsp 'gate restic password: ' RESTIC_PASSWORD && export RESTIC_PASSWORD
restic init
truncate -s 100G "$GATE/big.bin"; head -c 1M /dev/urandom >"$GATE/small.bin"
mkdir -p "$GATE/small-tree"; head -c 256K /dev/urandom >"$GATE/small-tree/a.bin"
restic backup --host backrest-gate --tag verified "$GATE"
export REPO_GUID=$(restic cat config --json | jq -r .id)
export BIG_SHA256=$(sha256sum "$GATE/big.bin" | cut -d' ' -f1)
```

The small checks use `small.bin` and `small-tree` and are capped at 64 MiB. Create a
read-only R2 token (Object Read only, scoped to `homelab-restic`) — Backrest's only
credential. The block below is the retired Cloudflare deployment: the `put_secret`
calls write Worker secrets and `deploy.sh` deploys the Worker, and neither exists
any more (#725 T2). The reader's environment is `/etc/backrest/env` on smortress,
written by hand as `docs/manual-steps.md#hosted-backrest` gives, and the password
hash is what goes into it (`backrest/scripts/hash-password.sh`):

```sh
put_secret() { (cd backrest && mise x node@22 -- npx wrangler secret put "$1"); }
(cd backrest && mise x node@22 -- npm ci)
systemctl --user start podman.socket
printf '%s' "$RESTIC_PASSWORD" | put_secret RESTIC_PASSWORD
printf '%s' "$R2_READ_ACCESS_KEY_ID" | put_secret R2_ACCESS_KEY_ID
printf '%s' "$R2_READ_SECRET_ACCESS_KEY" | put_secret R2_SECRET_ACCESS_KEY
read -rsp 'backrest operator password: ' pw
printf '%s' "$pw" | backrest/scripts/hash-password.sh | put_secret BACKREST_OPERATOR_BCRYPT
unset pw
BACKREST_REPO_ID=r2 BACKREST_REPO_URI="$RESTIC_REPOSITORY" BACKREST_REPO_GUID="$REPO_GUID" \
  mise x node@22 -- backrest/scripts/deploy.sh
export BACKREST_URL=https://recovery.sammohr.dev BACKREST_BOOTSTRAP_USER=bootstrap
read -rsp 'bootstrap password: ' BACKREST_BOOTSTRAP_PASSWORD && export BACKREST_BOOTSTRAP_PASSWORD
export BACKREST_REPO_ID=r2 RESTIC_REPOSITORY RESTIC_PASSWORD
export BACKREST_GATE_SMALL_FILE=$GATE/small.bin BACKREST_GATE_SMALL_DIR=$GATE/small-tree
backrest/scripts/gate.sh matrix
backrest/scripts/gate.sh stream "$GATE/big.bin" sha "$BIG_SHA256"
```

The first request after a start is the cold start; watch it in the unit's journal
(`journalctl -u smortress-backrest.service` on smortress), where a restic write
attempt is a gate failure. On a pass, redeploy with the production repository URI and GUID and
delete the `/gate` path. Where the reader runs, and the watchdog that keeps it
answering, is "Where it runs" above.
