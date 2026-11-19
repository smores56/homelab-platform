# Core applications: Immich, OPDShelf, Syncthing (T5), agent deployments (T6)

The three applications that carry real data on smortress run as Podman Quadlets
from the derived image. A fourth Serve route, `/wallpapers`, publishes a dataset
as static files and has no container behind it at all. Six more containers run
the agent deployments: a pinned local model server, two Hermes gateways, one
hosted-model proxy and one source facade per deployment, split by authority
(section "Agent deployments" below). This
document covers what each container is allowed to read and write, how its image
reaches the host, how it is reached from the tailnet, and what its restore
actually consists of. Operator steps are in `docs/manual-steps.md` section 40;
the Restic units they rely on are in `docs/core/restic-plane.md`. Agent-managed
tenant apps from `homelab-apps` are a separate, unprivileged plane: see
`docs/core/apps-tenant.md`.

There is no second control plane: a deployment change is an image change plus a
maintenance-window reboot, and `podman-auto-update.timer` is masked. A Quadlet
never auto-updates an image that holds a database.

## Image trust: mirrored, then signed by us

The host runs `/etc/containers/policy.json` with `reject` as the default, and the
only application-capable entry is `ghcr.io/smores56/homelab-platform` signed by
`/etc/pki/containers/smortress.pub`. Upstream registries cannot be trusted for
this: Immich, Valkey, OPDShelf and Syncthing publish no cosign signature, and
adding `insecureAcceptAnything` for them would delete the boundary to make a pull
succeed.

`scripts/app-images.sh` is the single pin table. Two kinds of row live in it.

A row whose reference is an upstream image is copied by
`scripts/mirror-app-images.sh` into our namespace by digest (`skopeo copy --all
--preserve-digests`), proved to have kept the digest, signed, and proved to have
legacy `.sig` lookaside tag — that tag, not the OCI 1.1 referrer bundle, is what
`containers/image` reads. CI runs it as
`.github/workflows/publish-app-images.yml` on a pin change and on dispatch.

A row whose reference is `built:<Containerfile>` is an image this repository
builds and signs itself; there is no upstream digest to preserve because the
bytes are ours. `.github/workflows/publish-agent-webui.yml` builds it, signs it
and proves a policy-checked anonymous pull, then prints the row to commit with
the digest that run produced.

| Quadlet | Pinned image | Upstream |
| --- | --- | --- |
| `immich-server` | `ghcr.io/smores56/homelab-platform/immich-server@sha256:c716dc20…` | `ghcr.io/immich-app/immich-server:v3.0.3` |
| `immich-machine-learning` | `…/immich-machine-learning@sha256:d76fe88b…` | `ghcr.io/immich-app/immich-machine-learning:v3.0.3` |
| `immich-postgres` | `…/immich-postgres@sha256:79b95b79…` | `ghcr.io/immich-app/postgres:17-vectorchord0.4.3-pgvector0.8.1` |
| `immich-valkey` | `…/immich-valkey@sha256:3add1a33…` | `docker.io/valkey/valkey:9` |
| `opdshelf` | `…/opdshelf@sha256:b82f94f7…` | `docker.io/koalilla/opds-server@sha256:b82f94f7…` |
| `syncthing` | `…/syncthing@sha256:2b71da7c…` | `docker.io/syncthing/syncthing:2.1.7` |
| `agent-model` | `…/agent-model@sha256:ae96e52f…` | `ghcr.io/ggml-org/llama.cpp:server-cuda` |
| `agent-runtime` | `…/agent-runtime@sha256:276d4468…` | `docker.io/nousresearch/hermes-agent:v0.23.1` |

A built row appears here once a publish run has produced its digest. It is the
same trust story with one difference: the digest is the last build's, so the row
and the run that printed it are the record of what is deployed.

`agent-runtime` is drawn by five Quadlets: the two gateways, the hosted proxy and
the two source facades. The proxy and the facades are Python programs in this
repository (`apps/agent_proxy/`, `apps/agent_facade/`), so they need
no image of their own and no package manager, and a third pin would be a third thing
to mirror for no gain.

Immich stays on v3.0.3 until the cutover restore has passed: the existing
database was written by that version, and moving a major version belongs in its
own window, not inside a data migration. OPDShelf is pinned at the digest the
legacy deployment ran; it has no database, so a version change is a reader
change.

`tests/core/app-quadlets.sh` fails if any Quadlet names a reference the pin table
does not produce, if a pin already points at our namespace, if an upstream
registry appears in the policy, or if a built row names a Containerfile that is
not in the tree.

## Where the Quadlets come from

`units/quadlet/*.container` and `immich.network` are installed into
`/usr/share/containers/systemd`, one of the directories the rootful Quadlet
generator scans. A Quadlet is a *generated* unit: `systemctl enable` does not
apply, so each file carries `[Install] WantedBy=multi-user.target` and the
generator wires it at boot. The image never copies a placeholder anywhere a
generator would start it; `pattern.container` stays under
`/usr/share/smortress/quadlet` as the base for the next application.

Every unit keeps the pattern's invariants:

- `Requires=`/`After=` on the readiness instance of every dataset it mounts, plus
  `sops-decrypt.service` (and `smortress-app-secrets.service`) when it reads a
  secret;
- `ReadOnly=true`, `NoNewPrivileges=true`, `DropCapability=ALL`;
- loopback-only publication, fronted by Tailscale Serve;
- no `AutoUpdate=`, no `Pull=always`, no image tag without a digest.

## Storage mapping

Data is split by kind: `/srv` holds raw data and `/var/lib` holds the service
state that no raw file can regenerate. A restore unit is the application, and
one Restic snapshot names every dataset the unit restores.

| Application | Raw dataset | Backed-up state | Container paths |
| --- | --- | --- | --- |
| Immich | `raw/photos` — `/srv/photos`, the asset library | `state/immich-postgres` — `/var/lib/immich/postgres` (the dataset root is `PGDATA`); `state/immich-dumps` — `/var/lib/immich/dumps` | `/data/library`; Postgres `/data`; the dump writes into the dump dataset |
| OPDShelf | `raw/books` — `/srv/books`, the catalog | `state/opdshelf` — `/var/lib/opdshelf`, edits, annotations and covers | `/books`; `DATA_DIR=/state` |
| Personal agent | none — no personal source is mounted | `state/agent-local` — `/var/lib/agent/local`, sessions, memory, skills | `/opt/data` |
| General agent | none — no repository or book tree is mounted | `state/agent-general` — `/var/lib/agent/general`, same shape | `/opt/data` |
| Personal facade | none — its adapters are in-process fixtures | `state/agent-local` — `/var/lib/agent/local/memory`, the `local` memory profile and its derived index; the rest of that dataset is the gateway's | `/memory` (writable) |
| General facade | none | `state/agent-general` — `/var/lib/agent/general/memory`, the `external` profile | `/memory` (writable) |
| Local model | none | none: `state/agent-model` — `/var/lib/agent/model` is the GGUF file, and it is in no backup | `/models` (read-only) |
| Syncthing | `raw/files` — `/srv/files`, the vault | `state/syncthing-config` — `/var/lib/syncthing/config`, identity and configuration | `/srv/files`; `/var/syncthing/config` |

`photos` is therefore one snapshot over `/srv/photos`,
`/var/lib/immich/postgres` and `/var/lib/immich/dumps`: media, cluster files and
the logical dump at one point in time. `books` pairs its catalog with the
`.opdshelf` state, and `files` pairs the vault with the Syncthing identity.

Three directories are deliberately outside every dataset and every backup,
because rebuilding them costs time and nothing else: `/var/lib/immich/ml-cache`
(the model cache), `/var/lib/immich/valkey` (the AOF, which only holds in-flight
jobs) and `/var/lib/syncthing/versions` (the version history). They are created
by tmpfiles with uid 1000 and survive a restore as empty directories.

Every core dataset root is owned by uid 1000 and mode 0750, because that is the
uid the applications run as and the tenant user must not read it; `raw/apps` is
owned by the tenant (1001:1001) at 0700. The pool unit sets both at dataset
creation, which is what lets a restore write a tree without a manual `chown`. A dataset restored by
Restic is root-owned, so the restore runbook chowns it back before the
application starts: root restoring files is correct, and serving them as root
is not.

The Syncthing identity is restorable without rolling the vault back to the same
second: a restore brings the identity back, pauses the peers, and only then
designates a primary. That is why its configuration is its own dataset even
though it belongs to the `files` unit.

## Secrets

| Value | Ciphertext | Decrypted as | Consumed as |
| --- | --- | --- | --- |
| Immich database password | `secrets/server/immich-db-password.yaml` | `/run/smortress/secrets/immich-db-password.yaml` (`value`, root 0400) | Podman secret `immich-db-password`, mounted at uid 1000 mode 0400; the server reads `DB_PASSWORD_FILE`, Postgres reads `POSTGRES_PASSWORD_FILE` |
| OPDShelf admin password | `secrets/server/opdshelf-admin-password.yaml` | `/run/smortress/secrets/opdshelf-admin-password.yaml` (`value`, root 0400) | Podman secret `opdshelf-admin-password`, `type=env` as `ADMIN_PASSWORD` (the image has no `_FILE` variant) |
| Personal gateway key | `secrets/server/agent-local-api-key.yaml` | `/run/smortress/secrets/agent-local-api-key.yaml` (`value`, root 0400) | Podman secret `agent-local-api-key`, also mounted at uid 1000 mode 0400; `smortress-agent-config.service` writes it into `/var/lib/agent/local/.env` as `API_SERVER_KEY` (the runtime has no `_FILE` variant, and Podman's `type=env` keeps the file's trailing newline) |
| General gateway key | `secrets/server/agent-general-api-key.yaml` | `/run/smortress/secrets/agent-general-api-key.yaml` (`value`, root 0400) | Same shape, `agent-general-api-key`, `/var/lib/agent/general/.env` |
| Hosted provider key | `secrets/server/agent-hosted-key.yaml` | `/run/smortress/secrets/agent-hosted-key.yaml` (`value`, root 0400) | Podman secret `agent-hosted-key`, mounted read-only at `/run/secrets/agent-hosted-key` in `agent-proxy` only. Never in an environment, never in a config file, never in argv |
| Personal facade token | `secrets/server/agent-facade-personal-token.yaml` | `/run/smortress/secrets/agent-facade-personal-token.yaml` (`value`, root 0400) | Podman secret `agent-facade-personal-token`, mounted at uid 1000 mode 0400 as `/run/secrets/agent-facade-personal-token` in `agent-facade-personal` only, which reads it through `--token-file`. The personal gateway holds the same value in its seeded `config.yaml` as `X-Deployment-Token` (section "Source facades") |
| General facade token | `secrets/server/agent-facade-general-token.yaml` | `/run/smortress/secrets/agent-facade-general-token.yaml` (`value`, root 0400) | Same shape for `agent-facade-general` and the general gateway |

`smortress-app-secrets.service` creates all seven Podman secrets with
`--replace` on every boot, before any container that declares one. The values
never appear in a unit file, in argv, in the image, or in this repository.

The provider key is the one credential here that is not self-issued: it comes from
the hosted account, and only `agent-proxy` may hold it. That is the whole reason
the proxy exists -- a gateway runs a broad tool surface (browser, terminal, file)
and would otherwise sit next to the credential (see the next section).

Both containers run as uid 1000, which is what the legacy data is owned by and
what Immich's own rootless compose uses. That is why the secrets are mounted per
container with an explicit uid instead of being written world-readable.

## Immich

Four containers on the `immich.network` bridge plus one timer:

- `smortress-immich-postgres` — the cluster in `/data` (the dataset root is `PGDATA`). The image
  entrypoint rewrites its config template into `/etc/postgresql` on every start,
  so that path is a tmpfs on an otherwise read-only root filesystem.
- `smortress-immich-valkey` — append-only queue in `/data/appendonlydir`,
  snapshots off; Restic is the history. The AOF sits in the dataset root
  because valkey refuses to start when its `--dir` is missing, and a dataset
  restored from the logical dump has only the library. The `--save ""`
  argument has to go through a shell: Quadlet drops an empty `Exec`
  argument, which turns it into `--save --appendfsync …` and a fatal config
  error.
- `smortress-immich-machine-learning` — CPU only, the only container in the set
  that needs egress (models download from Hugging Face on first use).
- `smortress-immich-server` — API and web UI, `127.0.0.1:2283`, served at the
  root of an HTTPS port because Immich does not support a subpath.

`smortress-immich-dump.timer` runs `pg_dump -Fc --no-owner` at 21:00 UTC into
`the dump dataset (`/var/lib/immich/dumps`)`, written to a temporary name and renamed, so a
failed dump leaves the previous one intact. 21:00 UTC puts a same-day dump inside
the midnight R2 snapshot with three hours of margin for a library-sized database.
The dump is root-only (`UMask=0077`): it is the whole database. The dump is its own
unit, not part of the backup driver: a dump failure must not stop the filesystem
snapshot, and the filesystem snapshot must not wait for the database.

The storage template lives in the database, not in a unit file, so the existing
year/day layout survives the dump/restore unchanged.

## OPDShelf

One container and one dataset. The library tree is the catalog: there is no
database and no ingest step, and `.opdshelf/` (edits, covers, thumbnails) sits
inside the library root, so content and metadata are one recovery point.
`WATCH=false` because inotify over a bind-mounted dataset is unreliable;
`SCAN_INTERVAL=600` rescans per request instead. `BASE_URL` is unset on purpose:
the server derives it from the `Host` header, which Tailscale Serve forwards.

The admin password is required even though the service is tailnet-only: it is the
one credential that keeps a compromised tailnet device from rewriting the
library.

## Syncthing

The only container with `Network=host`, because the sync protocol is not HTTP and
cannot be fronted by Tailscale Serve. It publishes no port at all: the boundary
is firewalld, whose default zone is `drop` and whose `tailscale` zone permits
22000/tcp and 22000/udp on `tailscale0` only. A non-Tailscale LAN peer therefore
cannot reach the sync protocol, the GUI, or SSH.

- GUI: `STGUIADDRESS=127.0.0.1:8384`, fronted by Serve on its own HTTPS port.
- Identity and configuration: `/var/lib/syncthing/config` (`state/syncthing-config`).
- Folder content: `/srv/files` (`raw/files`), mounted at the same
  path inside the container so the folder paths in `config.xml` are the host
  paths.
- Version history: `/var/lib/syncthing/versions`, outside every dataset, exactly as
  the legacy host kept it.
- `AddCapability=CHOWN` is the one capability in the set, and it is why the unit
  sets no `User=`: the container starts as root, the image entrypoint chowns
  `HOME` and `su-exec` drops to uid 1000. A `User=` would skip that branch and
  leave the capability inert, so a restored root-owned tree would stay
  unwritable.

`<listenAddress>` is configuration, not a unit directive: it comes from the
restored `config.xml`. It stays at the image default (all addresses on 22000),
which the firewall narrows to the tailnet.

## Agent deployments

Two deployments, split by authority rather than by feature. The split is what makes
the per-session taint question disappear: nothing reachable from one side carries
the other side's sources.

| Deployment | Quadlets | Network | May reach | May not reach |
| --- | --- | --- | --- | --- |
| Personal | `agent-local`, `agent-model`, `agent-facade-personal` | `agent-local.network`, `Internal=true` | each other, by container name | the internet, the LAN, the host, the general deployment -- no default route exists |
| General | `agent-general`, `agent-proxy`, `agent-facade-general` | `agent-general.network`, a plain bridge | the pinned provider, through the proxy; each other, by container name | the personal deployment, every personal source |

The personal gateway publishes `127.0.0.1:18001`; the general one publishes
`127.0.0.1:18002`; the proxy publishes `127.0.0.1:18003`. The two facades publish
nothing at all. A published port is
host-side DNAT *toward* a container, so it adds nothing to what that container can
dial: the personal side still has no route off the host, which is why the sealed
profile is a network property and not a firewall exception.

The model server (`agent-model`) is llama.cpp pinned at
`ghcr.io/ggml-org/llama.cpp:server-cuda`, started with `-c 65536`. That number is a
floor the runtime imposes -- Hermes refuses a model under 64,000 tokens -- and
`image/rootfs/etc/smortress/agent/local-config.yaml` pins the same value as
`model.context_length`. The two are one decision in two files, and changing one
without the other stops the gateway admitting the model. The GGUF itself
(`Qwen2.5-7B-Instruct-Q4_K_M.gguf`, 4,683,074,240 bytes) is fetched into
`state/agent-model` by hand and verified by checksum
(`docs/manual-steps.md` section 40.8); it is the one dataset in no backup unit.

GPU access is two directives: `AddDevice=nvidia.com/gpu=all` and
`SecurityLabelType=nvidia_container_t`. The device name resolves through
`/etc/cdi/nvidia.yaml`, generated at boot by `smortress-nvidia-cdi.service`
because the spec pins this host's driver and the cards that are actually present.
Without the label the process gets NVML `Insufficient Permissions` instead of a
GPU; with `label=disable` it works and the container's SELinux confinement is gone.

`smortress-agent-config.service` seeds each deployment's `config.yaml` from the
image's template *once* (`cp -n`): the runtime rewrites that file and an operator
edits the copy in the dataset. It rewrites `.env` on every boot instead, because
the runtime takes its `API_SERVER_KEY` from the environment or from
`$HERMES_HOME/.env`, and neither the image nor Podman's secret plumbing supplies a
key without a trailing newline (a Bearer token that never compares equal). The
`agent` template's `disabled_toolsets` list closes web, search, browser, terminal,
file, memory, code execution, catalog, computer use, cron jobs, delegation,
skills, image generation and connections.

`agent-proxy` is the only container that holds the hosted key and the only one that
may dial the provider: `apps/agent_proxy/proxy.py`, stdlib only, one pinned host,
three OpenAI-compatible paths plus `/healthz`, a 1 MiB request cap, and responses
relayed unbuffered so `stream: true` still streams. The general gateway's model
block has no `api_key` at all, so a compromise of that gateway costs one revocable
gateway key.

Read-only is not available to the two gateways: the runtime writes its SQLite
state, sessions, logs and skills under `HERMES_HOME`, which is their only write
target, so those units say `ReadOnly=false` explicitly instead of inheriting a
hardening they cannot keep. `NoNewPrivileges=true` stays. `DropCapability=ALL`
cannot: the image's supervisor has to reach its own uid (see the uid note under
Residual risks), so the gateways have the same shape as Syncthing -- root inside
the namespace, privileges dropped by the image -- and no host path, Podman socket
or SSH identity is mounted into either one. The proxy is the opposite case: it runs
one file as uid 1000 with every capability dropped, because its unit replaces the
image's entrypoint with `python3`.

### Source facades

Each gateway reads its sources and its memory through one MCP server of its own
deployment (`apps/agent_facade/`, `docs/agent-facade.md`), and that process is a
container: `agent-facade-personal` serves `notes`, `tasks`, `mail`, `calendar`,
`finance`, `brave`, `photos`, `music` and `workspace`; `agent-facade-general`
serves `repos` and `books`. A source outside the table is not refused by a policy
check, it has no adapter in that process at all. Every adapter is still an
in-process fixture (`apps/agent_facade/README.md`), so a deployed facade answers its
own records, not live data: what the split proves today is the reach, not the feed.

Both run the same `agent-runtime` digest as the gateways, with
`Entrypoint=python3` replacing the image's gateway dispatcher, exactly as the proxy
does. The program is not in the upstream image and cannot be, so
`image/Containerfile` installs it and the data-plane libraries it imports under
`/usr/lib/agent-facade` on the host, and each unit bind-mounts that tree
`/usr/lib/agent-facade` read-only. `PYTHONPATH` points at it inside the container,
so the code that runs is the code in the booted deployment -- no image of our own,
no package manager, and no second copy to drift.

Neither facade publishes a port. The gateway is their only client, and it reaches
them by container name (`http://smortress-agent-facade-personal:18004/mcp`,
`http://smortress-agent-facade-general:18005/mcp`) on the deployment's own network.
A published port would be a second way in with no consumer, and it would put an
address in the operator's curl reach that nothing authenticates differently from
the gateway's.

The gateway reaches its facade with `mcp_servers` in the runtime config, sending
`X-Deployment-Token`. That token is the facade's whole identity: one process, one
token, and a request without it is `401` before the body is read. The template in
the image carries the placeholder `__FACADE_TOKEN__`;
`smortress-agent-config.service` replaces it from the deployment's decrypted
ciphertext when the config is first seeded, so no token is in the image, in this
document, or in a command line. Because that file is seeded with `cp -n`, rotating
a token is `sops`, then delete the seeded `config.yaml` and let the unit seed it
again (`docs/manual-steps.md` section 40.11).

Memory is the one write target each facade has: `/memory` is
`state/agent-local/memory` and `state/agent-general/memory`, the `local` and
`external` profiles. It is a directory inside the dataset, not the dataset root, so
the gateway's sessions, skills and `.env` stay out of reach. A facade therefore has no
recovery unit of its own -- its records restore with `agent-local` or
`agent-general`, which is exactly what those units name -- and the SQLite FTS index
beside them is derived, so a restore that loses it costs one rebuild.

## Access paths

| Application | Direct listener | Tailnet URL |
| --- | --- | --- |
| Immich | `127.0.0.1:2283` | `https://smortress.<tailnet>.ts.net/` |
| OPDShelf | `127.0.0.1:8083` | `https://smortress.<tailnet>.ts.net:8443/` |
| Syncthing GUI | `127.0.0.1:8384` | `https://smortress.<tailnet>.ts.net:10000/` |
| Wallpapers | `/srv/wallpapers` (static files) | `https://smortress.<tailnet>.ts.net/wallpapers/` |
| Personal agent gateway | `127.0.0.1:18001` | `https://smortress.<tailnet>.ts.net/apps/agent-local/v1` |
| General agent gateway | `127.0.0.1:18002` | `https://smortress.<tailnet>.ts.net/apps/agent-general/v1` |
| Hosted proxy | `127.0.0.1:18003` | none, on purpose: a tailnet path would let any device spend the provider key |
| Source facades | nothing published | none: each gateway reaches its own facade by container name, and no device outside the deployment has any reason to |

The two agent paths are a second table in `scripts/tailscale-serve.sh`
(`core_path_routes`) rather than a fourth and fifth core *port*: 443, 8443 and
10000 are the only root-path HTTPS ports Serve has, and they are taken. A tenant
plan that claims either path is refused whole, and the stale-route pruning skips
both, so a run without a plan cannot delete them.

`smortress-tailscale-serve.service` re-declares these six routes at every boot.
Serve state lives in tailscaled's state file, which is not a dataset and
not worth backing up; re-applying the same route is idempotent. Nothing here is
Funnel, and no public hostname serves an application.

`/wallpapers` is the fourth route and the only one with no application behind
it: `/srv/wallpapers` is the `raw/wallpapers` dataset, one directory of image
files, and an absolute path is Serve's static-file target where a URL would be a
proxy. Serve appends the trailing slash to the mount itself, so the route is
`/wallpapers/`; that is the URL the wallpaper client fetches, and it carries no
credential because Serve authenticates the device. A missing dataset therefore
costs an empty listing, not a 404, which is why the Serve unit is ordered after
`zfs-ready@raw-wallpapers.service` and the script refuses to declare the route
when the directory is absent.

Prerequisites, once per tailnet: MagicDNS on, HTTPS certificates enabled for the
tailnet, and this host's TLS certificate provisioned (`tailscale cert` happens
automatically on first Serve). Without them Serve fails and the unit says so.

## Restore paths

The acceptance for T5 is that each application restores *on scratch storage*,
before any of it touches `/srv`. `docs/manual-steps.md` section 40 has the
commands; the shape is:

- **Immich, logical** — restore `photos` to scratch, take `db-dumps/immich.dump`,
  restore it into a throwaway Postgres container, start a throwaway server
  against the scratch library, and fetch an asset. This is the path that survives
  a version change and is the one the cutover uses.
- **Immich, physical** — restore the same unit, point a throwaway cluster at
  `postgres/`, and fetch an asset. A restored cluster carries the password that
  was current when the snapshot was taken: after a physical restore either set
  the password from the decrypted secret
  (`ALTER USER immich WITH PASSWORD ...`) or rotate the ciphertext, otherwise the
  server cannot log in.
- **OPDShelf** — restore `books`, serve the scratch tree on an alternate port,
  fetch the catalog and one file. Nothing stateful to rebuild.
- **Syncthing** — restore `syncthing` and `notes`, start with the GUI on an
  alternate port and **all folders paused**, then designate a primary. Peers
  must not be allowed to sync into a tree whose identity was just restored.

A source facade has no drill of its own: its memory records are
`state/agent-local/memory` or `state/agent-general/memory`, so restoring the
`agent-local` or `agent-general` unit brings them back with the gateway's sessions
in the same point in time. What the restore must then prove is that the facade
serves them: `memory.search` answers from a restored profile without a rebuild, and
if the derived FTS index did not come back, `memory.rebuild` recreates it from the
record files.

The rule that makes these drills meaningful: only a `verified`-tagged snapshot is
a complete restore point, and a restored application is not proven by a
successful start — it is proven by serving representative data from it.

## Residual risks

- The mirror and the signature are ours, but the bytes are upstream's: a
  compromised upstream release is signed by us. The digest pin and the reviewed
  version are the control, not the signature.
- The Immich database password is one credential for one cluster; a physical
  restore of an older snapshot needs it rotated (see above).
- Syncthing's sync port is opened at the tailnet boundary by firewalld, not by a
  published port, so `podman inspect` alone does not describe the exposure. The
  static checks assert both halves; an operator who changes the zone must
  re-read this document.
- `:z` on a dataset root relabels the live tree on **every** container start,
  and a Restic restore leaves files unlabelled. The restore runbook therefore
  re-applies both ownership and label (`chown` + `chcon`) before the application
  starts, and the unit timeouts are sized for a first start that has to relabel.
  Snapshots are not touched: ZFS keeps `.zfs` hidden from directory walks.
- The proxy, the facades and their libraries are code the *host* image installs and
  the container mounts, so what runs is what the booted deployment carries: that is
  the point, and it is also the one place a container reads a host path. The mounts
  are `:ro` with no `z`, deliberately: `/usr` is a read-only composefs mount, so a
  relabel fails with `EROFS`, and the content is already `bin_t`/`usr_t`, which
  `container_t` may read. Only dataset mounts relabel (`:z`); anything the bootc
  image installs under `/usr` is mounted read-only and unrelabelled.
- A facade token is a secret inside a restorable dataset: it sits in the seeded
  `config.yaml` under `state/agent-*`, so it is in Restic snapshots in R2 exactly as
  the gateway keys in `.env` already are. Both are self-issued and revocable, and
  rotating one is section 40.11.
- The machine learning container needs egress on first use and caches models
  outside the backup. A cold restore re-downloads them; smart search degrades
  until it finishes.
- The general deployment is internet-connected by design. Its containment is the
  container boundary and the proxy, not a network rule: it mounts no personal
  source, holds no credential it could leak beyond its own revocable gateway key,
  and its tool output can still carry whatever the hosted model reads. Treat
  anything it fetches as untrusted input, not as data the personal side may act on.
- The personal deployment has no egress at all, which is verified as a network
  property (`Internal=true`, no default route) rather than as a firewall rule. A
  future change that attaches a second network to `agent-local` would silently
  undo it; `tests/core/app-quadlets.sh` asserts the unit declares exactly one
  network, and which one.
- The runtime's defaults are broad: `computer_use`, `cronjob`, `delegation`,
  `skills`, `image_gen`, `connections` and `session_search` are enabled unless the
  config says otherwise, and disabling is per toolset with no per-tool switch.
  The personal template closes them; the general one deliberately does not, and
  the difference is a decision recorded in the template, not an oversight.
- The two gateways do not set `User=`. The pinned image's entrypoint rejects an
  arbitrary uid outright (`container started with --user 1000 ... not supported`,
  exit 1) and offers `HERMES_UID`/`HERMES_GID` instead, which remap its internal
  account (uid 10000) to the platform uid and chown the data volume at boot. The
  dataset therefore stays owned by uid 1000 and the gateway writes as uid 1000 --
  the platform convention, reached the way the image supports. The costs are
  explicit: the container starts as root *inside its own namespace* and the image's
  supervisor drops privileges itself, so `DropCapability=ALL` is not set (a root
  process that cannot `setuid` never becomes the agent). That is the same shape as
  Syncthing, and the same reason. If the mapping ever fails, section 40.9 of the
  manual shows where it is logged (`[stage2] Changing hermes UID to 1000`).
- The two gateway keys are the one case of a secret inside a restorable dataset:
  the runtime reads `API_SERVER_KEY` from `$HERMES_HOME/.env` in `state/agent-*`,
  so they are in Restic snapshots in R2 exactly as Syncthing's GUI key already is.
  Both are self-issued and revocable. The provider key is in no dataset at all.
