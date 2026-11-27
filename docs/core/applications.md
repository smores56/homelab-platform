# Core applications: Immich, OPDShelf, Syncthing, Navidrome, agent deployments (T6)

The four applications that carry real data on smortress run as Podman Quadlets
from the derived image. A fifth Serve route, `/wallpapers`, publishes a dataset
as static files and has no container behind it at all. Six more containers run
the agent deployments: a pinned local model server, two Hermes gateways, one
hosted-model proxy, split by authority
(section "Agent deployments" below). This
document covers what each container is allowed to read and write, how its image
reaches the host, how it is reached from the tailnet, and what its restore
actually consists of. Operator steps are in `docs/manual-steps.md#applications-and-agents`;
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

That boundary covers the Quadlets this repository ships. It does not cover the
unprivileged `homelab-apps` tenant: its units name
`--signature-policy=/usr/share/smortress/apps-policy.json`, and that policy is
`insecureAcceptAnything`, so a tenant image is never signature-checked — the
digest pin in its schema and the reviewed commit are what bound it
(`docs/core/apps-tenant.md`).

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
| `navidrome` | `…/navidrome@sha256:38dc2727…` | `docker.io/navidrome/navidrome:0.64.2` |
| `agent-model` | `…/agent-model@sha256:26f89ebd…` | `ghcr.io/ggml-org/llama.cpp:server-cuda` (b12602) |
| `agent-runtime` | `…/agent-runtime@sha256:4ea73e6d…` | built from `images/agent-runtime/Containerfile` (base `docker.io/nousresearch/hermes-agent@sha256:276d4468…`) |
| `agent-webui` | `…/agent-webui@sha256:fb50509e…` | built from `images/agent-webui/Containerfile` |

`agent-runtime`, `agent-webui`, `tuta-calendar`, `brave` and `agent-egress` are
built rows. They are the same trust story with one difference: the digest is the
last build's, so the row and the run that printed it are the record of what is
deployed. Upstream's image cannot be mirrored into
service, because its entrypoint installs the dependencies from PyPI at container
start and the personal deployment has no route off the host; the Containerfile
moves that install to build time.

`agent-runtime` is drawn by three Quadlets (the two gateways and the hosted
proxy) and by the collector and mail units. The proxy and the collectors are Python
programs in this repository (`apps/agent_proxy/`,
`apps/brave_ingest/`), and they are built into this image: the
derived Containerfile COPYs them onto the base at the paths the units already name.
They used to ride the bootc image instead and be bind-mounted into the container,
which made an agent-code change an OS rebuild and a reboot; now it rebuilds one
container image and moves one pin.

Immich stays on v3.0.3 until the cutover restore has passed: the existing
database was written by that version, and moving a major version belongs in its
own window, not inside a data migration. OPDShelf is pinned at the digest the
legacy deployment ran; it has no database, so a version change is a reader
change.

The `tests/core/app-quadlets-*.bats` suite fails if any Quadlet names a reference
the pin table does not produce, if a pin already points at our namespace, if an
upstream registry appears in the policy, or if a built row names a Containerfile that is
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
| Personal gateway | `/srv/files` (read-write), `/srv/files/vault` (read-only) | `state/agent-local` — `/var/lib/agent/local/memory`, the `local` memory profile, the collectors' derived index, and `/watch`, the source watcher's feed | `/opt/data` (writable), `/srv/files` (writable), `/srv/files/vault` (read-only) |
| General gateway | `/srv/git` (read-write), `/srv/books` (read-write) | `state/agent-general` — `/var/lib/agent/general/memory`, the `external` profile | `/opt/data` (writable), `/srv/git` and `/srv/books` (writable) |
| Local model | none | none: `state/agent-model` — `/var/lib/agent/model` is the GGUF file, and it is in no backup | `/models` (read-only) |
| Syncthing | `raw/files` — `/srv/files`, the vault | `state/syncthing-config` — `/var/lib/syncthing/config`, identity and configuration | `/srv/files`; `/var/syncthing/config` |
| Navidrome | `raw/music` — `/srv/music`, the library | `state/navidrome` — `/var/lib/navidrome`, playlists, play counts, users and shares | `/music` (read-only); `ND_DATAFOLDER=/data` |

`photos` is therefore one snapshot over `/srv/photos`,
`/var/lib/immich/postgres` and `/var/lib/immich/dumps`: media, cluster files and
the logical dump at one point in time. `books` pairs its catalog with the
`.opdshelf` state, `files` pairs the vault with the Syncthing identity, and
`music` pairs the library with Navidrome's database.

Three directories are deliberately outside every dataset and every backup,
because rebuilding them costs time and nothing else: `/var/lib/immich/ml-cache`
(the model cache), `/var/lib/immich/valkey` (the AOF, which only holds in-flight
jobs) and `/var/lib/syncthing/versions` (the version history). They are created
by tmpfiles with uid 1000 and survive a restore as empty directories.

Every core dataset root is owned by uid 1000 and mode 0750, because that is the
uid the applications run as and the tenant user must not read it; `raw/apps` is
owned by the tenant account by name (`apps:apps`) at 0700. The pool unit sets both at dataset
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
| Immich database password | `secrets/apps.json` `["immich"]["db_password"]` | `/run/smortress/secrets/immich-db-password.yaml` (`value`, root 0400) | Podman secret `immich-db-password`, mounted at uid 1000 mode 0400; the server reads `DB_PASSWORD_FILE`, Postgres reads `POSTGRES_PASSWORD_FILE` |
| OPDShelf admin password | `secrets/apps.json` `["opdshelf"]["admin_password"]` | `/run/smortress/secrets/opdshelf-admin-password.yaml` (`value`, root 0400) | Podman secret `opdshelf-admin-password`, `type=env` as `ADMIN_PASSWORD` (the image has no `_FILE` variant) |
| Personal gateway key | `secrets/agents.json` `["agent"]["local_api_key"]` | `/run/smortress/secrets/agent-local-api-key.yaml` (`value`, root 0400) | Podman secret `agent-local-api-key`, also mounted at uid 1000 mode 0400; `smortress-agent-config.service` writes it into `/var/lib/agent/local/.env` as `API_SERVER_KEY` (the runtime has no `_FILE` variant, and Podman's `type=env` keeps the file's trailing newline) |
| General gateway key | `secrets/agents.json` `["agent"]["general_api_key"]` | `/run/smortress/secrets/agent-general-api-key.yaml` (`value`, root 0400) | Same shape, `agent-general-api-key`, `/var/lib/agent/general/.env` |
| Hosted provider key | `secrets/agents.json` `["agent"]["hosted_key"]` | `/run/smortress/secrets/agent-hosted-key.yaml` (`value`, root 0400) | Podman secret `agent-hosted-key`, mounted read-only at `/run/secrets/agent-hosted-key` in `agent-proxy` only. Never in an environment, never in a config file, never in argv |
| Personal UI password | `secrets/agents.json` `["ui"]["personal_password"]` | `/run/smortress/secrets/agent-ui-personal-password.yaml` (`value`, root 0400) | Not a Podman secret: `smortress-agent-config.service` writes it into `/var/lib/agent/local/webui.env` as `HERMES_WEBUI_PASSWORD`, which `agent-webui-personal` reads through `EnvironmentFile=`. The UI has no `_FILE` variant, and `type=env` would carry the file's trailing newline into a comparison that never matches |
| General UI password | `secrets/agents.json` `["ui"]["general_password"]` | `/run/smortress/secrets/agent-ui-general-password.yaml` (`value`, root 0400) | Same shape, `/var/lib/agent/general/webui.env`. One password per deployment: the two UIs are separate authority domains, so a leak on one must not open the other |
| SimpleFIN access URL | `secrets/agents.json` `["simplefin"]["access_url"]` | `/run/smortress/secrets/simplefin-access-url.yaml` (`value`, root 0400) | Podman secret `simplefin-access-url`, mounted at uid 1000 mode 0400 in `smortress-agent-collect-finance.service` only, which reads it through `--access-url-file` |
| TutaBridge password | `secrets/agents.json` `["tmail"]["bridge_password"]` | `/run/smortress/secrets/tmail-bridge-password.yaml` (`value`, root 0400) | Podman secret `tmail-bridge-password`, mounted at uid 1000 mode 0400 in `smortress-agent-collect-mail.service` only, where isync's `PassCmd` reads it. The bridge generates this password locally; the Tuta account password is never stored in this repository |

`smortress-app-secrets.service` creates all nine Podman secrets with
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

## Navidrome

One container, two datasets: the library (`raw/music`, mounted read-only at
`/music`) and the database (`state/navidrome` at `/data`). The read-only mount is
Navidrome's own contract — it only reads the music folder — and the database holds
playlists, play counts, users and shares, so the `music` unit restores both at one
point in time.

`User=1000:1000` with `ND_ENFORCENONROOTUSER=true`: the upstream image has no
`USER` and runs as root unless told otherwise, and that flag turns a dropped
`User=` into a logged failure instead of root-owned files in a uid-1000 dataset.
The transcode and artwork caches are tmpfs (`/cache`, `/tmp`), so a snapshot never
carries derived files; the first transcode after a restart is slower.

`ND_SCANSCHEDULE=1h` with `ND_SCANNER_WATCHERWAIT=10s`: 0.64.2 always runs the
inotify watcher and that setting is only its debounce, so the scheduled scan is
the reliable path over a bind-mounted dataset. `ND_BASEURL` is unset because Serve
forwards `Host` and sets `X-Forwarded-Host`/`Proto`, which Navidrome uses for the
absolute URLs it emits.

The first visit to `https://smortress.<tailnet>.ts.net:8448/` shows "Create
Admin"; Navidrome has no supported way to pre-create one, so the operator does it
once (`docs/manual-steps.md`). The restore sequence is the `music` unit's: stop
`navidrome.service`, restore `raw/music` and `state/navidrome` from the same
snapshot, `chown`/`chcon` the trees, then start it.

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
| Personal | `agent-local`, `agent-model`, `agent-webui-personal` | `agent-local.network`, `no_default_route=true` | each other, by container name; the host reaches their published ports; the bridge resolver answers names | the internet, the LAN, the general deployment -- no default route exists |
| General | `agent-general`, `agent-proxy`, `agent-webui-general` | `agent-general.network`, a plain bridge | the pinned provider, through the proxy; each other, by container name | the personal deployment, every personal source |

The personal gateway publishes `127.0.0.1:18001`; the general one publishes
`127.0.0.1:18002`; the proxy publishes `127.0.0.1:18003`; the personal web UI
publishes `127.0.0.1:18006` and the general one `127.0.0.1:18007`. Nothing else on
either agent network publishes anything at all.

Publishing is the reason `agent-local.network` is not `Internal=true`. Netavark
creates no port-forwarding DNAT rules for an internal network and adds
bidirectional isolation drops, so a published port on one is silently dead: the
container listens, the unit is green, and the host cannot connect. Worse, with
firewalld as the netavark backend an internal network is never trusted for host
access, so the container cannot reach the bridge's own resolver either: name
resolution fails and every container-name call, MCP included, times out.

Egress is denied by the route instead (`Options=no_default_route=true`): the
bridge still forwards, so the network is trusted for the bridge resolver and for
published ports, while the container has no route off its own subnet. That is
still a network property, not a firewall exception. `NetworkDeleteOnStop=true`
is on the unit because `podman network create --ignore` never updates a network
that already exists: without it an option change here is silently ignored until
someone deletes the network by hand, which is how the first attempt at this fix
survived a reboot with the old config. The accepted residual is
that a container on a forwarding-enabled network can reach services the host
binds on the bridge address; the personal boundary is that it cannot route
anywhere else, and no host credential, socket or dataset is on that bridge.

### Collectors

The raw collectors and the IMAP stream collector (`docs/raw-replicas.md`) are
not part of a deployment. A collector is the one process that talks to a
provider, and the deployment that consumes the result must not: the personal side
has no route off the host.

| Unit | Network | Writes | Credential |
| --- | --- | --- | --- |
| `smortress-agent-collect-finance.timer` → `.service` | `agent-collect.network`, a plain bridge of its own (the projection stage has no network at all) | `state/agent-local/replica/finance`, and `state/agent-local/index/hledger` (the projection) | Podman secret `simplefin-access-url`, uid 1000 mode 0400 |
| `smortress-agent-mail-stream.service` | `agent-collect.network` | `state/agent-local/replica/mail` | Podman secret `tmail-bridge-password`, uid 1000 mode 0400 |
| `smortress-agent-collect-calendar.timer` → `.service` | `agent-collect.network` | `state/agent-local/quarantine/calendar` (the dump) and `state/agent-local/replica/calendar` (the collection) | none: the exporter authenticates with the sealed session on `state/agent-local/quarantine/tuta-calendar`, mounted only into the dump stage |
| `agent-tmail` (Quadlet; it serves, no timer) | `agent-collect.network` | `state/agent-local/quarantine/tmail`, its own session volume | none: its credential is the session on that volume |
| `smortress-agent-collect-brave.path` → `.service`, plus a six-hourly `.timer` reconcile | `agent-brave.network` for the browser (`agent-brave`); neither collection stage has a network | `state/agent-local/quarantine/brave` (the snapshot) and `state/agent-local/replica/brave` (the collection) | Podman secret `brave-sync-seed`, uid 1000 mode 0400, held by the seed unit only |
| `smortress-agent-collect-notes.timer` → `.service` | none: it reads `/srv/files/vault` and needs no address | `state/agent-local/replica/notes` | none: the vault is already on this host |
| `smortress-agent-collect-tasks.timer` → `.service` | none: it reads `/srv/files/notes` | `state/agent-local/replica/tasks` | none |
| `smortress-agent-collect-photos.timer` → `.service` | none: it reads `/srv/photos` and needs no address | `state/agent-local/replica/photos` (metadata only; the media stays on `raw/photos`) | none |
| `smortress-agent-collect-music.timer` → `.service` | none: it reads `/srv/music` | `state/agent-local/replica/music` (metadata only; the audio stays on `raw/music`) | none |

Tuta serves no IMAP at all, so `agent-tmail` -- TutaBridge, mirrored and pinned
like every other application image -- is the mail provider half: it holds the
account session, decrypts in process and presents the mailbox as local IMAP with
`IDLE`, which pushes new-mail and expunge events to a connected client. Its
volume is a copy of the login and belongs in the same Restic snapshot as the
replica it feeds (`docs/manual-steps.md#collector-sign-ins`). It shares
`agent-collect.network` with the finance collector: both are personal-authority
processes writing into the personal dataset, and neither can reach a deployment.

`smortress-agent-collect-calendar.service` is two stages like the finance
collector: the pinned `tuta-calendar` image signs in with its sealed session and
rewrites the dump, then the collector commits the replica state. The session is the
account's access, so it is mounted read-write only into the first stage; the
collector reads the dump read-only and never sees it.

The finance collector has a third stage that no other unit has: after the
collection is committed, the same pinned image renders the newest state as
an hledger journal at `state/agent-local/index/hledger/finance.journal`
(`docs/raw-replicas.md`, "The hledger projection"). It is one `ExecStart` in the
same oneshot for a reason: the projection reads a *committed* state, so it
must not be able to run before one exists, and a collection that refuses exits 3
and stops the unit there. It is given `--network none` -- the exact opposite of
the collector's egress -- no secret, the replica read-only and the index
read-write, because its whole input is the replica and its whole output is one
derived file. An operator's `accounts.json` beside it is seeded once and never
rewritten; an unmapped account renders as `assets:unknown:<id>` instead of
vanishing.

`smortress-agent-mail-stream.service` is the collector itself: it logs in to the
bridge, publishes a full pass, then holds one IDLE connection per folder and
republishes after 30 seconds of quiet, with an hourly reconcile pass. The bridge
pushes only to the session that selected a folder, so IDLE is per folder: latency
is exact for an idled folder, and sweep-driven for anything the bridge does not
push -- a folder past the 32-connection cap, or a message that arrived while the
socket was down. A changed UIDVALIDITY or a vanished folder commits nothing and
exits non-zero instead of recording a state that looks like mass deletion.

### Collector egress

A collector whose provider is a browser cannot be given the collectors'
network's general egress and left there. It gets its own network,
`agent-brave.network`: `Internal=true`, so there is no default route and no NAT,
and exactly two peers answer on it.

| Peer | Address | What it does |
| --- | --- | --- |
| `agent-egress-proxy` | `10.89.73.2:3128` | tunnels only the hostnames the `brave` label is granted, and gates `CONNECT` on the TLS SNI inside the first ClientHello so a permitted tunnel cannot be steered at another name |
| `agent-egress-dns` | `10.89.73.3:53` | answers `A`/`AAAA` only for those names and refuses everything else |

Both are `agent-egress` (a signed image this repository builds) and both are
dual-homed onto `agent-collect.network`, which is where their own upstream
traffic leaves. The addresses are static because Chromium's `--proxy-server` and
`--dns` take addresses: a name would have to be resolved by the responder that
exists to refuse names it does not know.

The grants live in `/etc/smortress/agent/egress-policy.json` inside the booted
image, mounted read-only into both containers, so what a collector may reach is a
reviewed fact of the image rather than something a container can edit. Nothing is
published, and the proxy is the only path off the network: a browser that ignored
it would dial an address the network cannot route.

The network is deliberately not `agent-general.network` even though both have
egress: the general side carries the hosted provider key, and a bank collector has
no business on that segment. A collector unit runs the pinned `agent-runtime`
digest with `--read-only --cap-drop=all --user 1000:1000` and imports its program
from `/usr/lib/agent-facade` in that image, so the program that reads an account
or a database is the one the pin names. A refusal exits 3 and publishes no
state; the timers are `Persistent=true`, so a missed run is closed on the next
boot instead of leaving a hole in the replica.

The browsing collector is the one pair where the provider half is a process of its
own. `agent-brave.container` is the only container on `agent-brave.network`, and
therefore the only one with an address to dial: the snapshot and the collection
that follow it read and write local paths, so
`smortress-agent-collect-brave.service` runs both stages with `--network none` and
cannot reach the proxy even if it were asked to. The profile volume it shares with
the seed unit is the chain membership -- the planted seed and the sync engine's
device id live in it -- so it is mounted into the browser and written by exactly
one other process, `smortress-agent-brave-seed.service`, before the browser starts
(`docs/manual-steps.md#collector-sign-ins`).

The model server (`agent-model`) is llama.cpp pinned at
`ghcr.io/ggml-org/llama.cpp:server-cuda` build **b12602**, the first release with
the merged Inkling 2 loop architecture. The GGUF is
`Inkling-2-Mini-AD-Q4_K.gguf` (16,525,559,776 bytes), a GGUF conversion of
Thinking Machines' `thinkingmachines/Inkling-2-Mini` -- 26.4B MoE with 3.4B active
(5.4B with the three loop passes), 1M native context, Apache-2.0. It is fetched
into `state/agent-model` by hand and verified by checksum
(`docs/manual-steps.md#fetch-the-pinned-model`); it is the one dataset in no backup unit.
The Uncensored fine-tune of the same weights is deliberately not used: it costs
fidelity at the same quant and removes a weak tripwire on a profile that reads
attacker-influenced mail and calendar text.

The flags are one measured decision, not defaults: `-c 196608 --parallel 3` is
three 65,536-token slots because llama.cpp divides `-c` across slots, and
`bootc/server/rootfs/etc/smortress/agent/local-config.yaml` pins `model.context_length:
65536`, which is one slot -- not the total. Three slots is also the subagent
bound (`delegation.max_concurrent_children: 2` plus the parent). `-ub 128` keeps
the prompt graph allocatable (the default micro-batch wants a 6.5 GiB compute
buffer and fails `cudaMalloc`), and `-fa on -ctk q8_0 -ctv q8_0` halve the KV
cache while keeping the attention graph small. Measured on this host: 20,834 MiB
resident of 24,576, 57 tok/s generation, 123 tok/s prompt, 33 s load. A fourth
slot, the default micro-batch, or an fp16 cache each put the load back over the
card.

GPU access is two directives: `AddDevice=nvidia.com/gpu=all` and
`SecurityLabelType=nvidia_container_t`. The device name resolves through
`/etc/cdi/nvidia.yaml`, generated at boot by `smortress-nvidia-cdi.service`
because the spec pins this host's driver and the cards that are actually present.
Without the label the process gets NVML `Insufficient Permissions` instead of a
GPU; with `label=disable` it works and the container's SELinux confinement is gone.

The label is necessary and was not sufficient. crun creates the injected device
node in the container's `/dev` tmpfs, where it carries `container_file_t`, and
`nvidia_container_t` had no `map` permission on that type: the open succeeded,
the mmap was denied, CUDA answered "no CUDA-capable device is detected", and the
server ran on CPU with `nvidia-smi` showing no process at all -- for every boot,
silently, until it was measured. `smortress-selinux-nvidia-map.service` loads one
CIL rule (`bootc/server/rootfs/usr/share/selinux/smortress/agent-nvidia-map.cil`) before
`agent-model` starts, on every boot, because a base update recompiles the policy
store. `nvidia-smi --query-compute-apps` listing `llama-server` is the proof that
it took effect; `docs/manual-steps.md#validate-the-units-and-check-the-listeners` checks it.

`smortress-agent-config.service` seeds each deployment's `config.yaml` from the
image's template *once* (`cp -n`): the runtime rewrites that file and an operator
edits the copy in the dataset. It rewrites `.env` on every boot instead, because
the runtime takes its `API_SERVER_KEY` from the environment or from
`$HERMES_HOME/.env`, and neither the image nor Podman's secret plumbing supplies a
key without a trailing newline (a Bearer token that never compares equal). The
`agent` template's `disabled_toolsets` list closes web, search, browser, terminal,
file, memory, code execution, catalog, computer use, cron jobs, skills, image
generation and connections. `delegation` is deliberately left on: a child runs in
the same process with the same provider and the same MCP toolsets, so it adds
concurrency and nothing else, and the template caps it at two concurrent children
and one level of depth -- the 3090 serves four llama.cpp slots. The general
template keeps the runtime's default scope but caps it at three concurrent
children, because there every child is metered hosted tokens.

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

### The agent data plane

The personal gateway reads `/srv/files` directly (SDLC #995): `todo.txt` and the
notes are read-write, the vault is a read-only nested bind, and the runtime's own
`terminal` and `file` toolsets are the interface. There is no MCP server, no
adapter table and no policy process, so "a source outside the table is refused"
becomes "a path outside the mount does not exist". The one permission rule that
survives is the vault's mount mode, and the kernel enforces it.

Changes reach the agent through `smortress-source-watch.service`, which appends
inotify events from the mounted roots to a bounded JSONL ring inside the state
dataset (`/var/lib/agent/local/watch/changes.jsonl`). It runs on the host rather
than in the container, so a watch outlives the agent process it serves, and its
`rescan` records are how a reader learns that the feed may have missed something
and that the tree is worth a sweep. The design's rule that the plane keeps no
history is what makes a ring buffer enough: every path in a record is still on
disk to be read.

## Access paths

| Application | Direct listener | Tailnet URL |
| --- | --- | --- |
| Immich | `127.0.0.1:2283` | `https://immich.<tailnet>.ts.net/` (the `svc:immich` Service, which is also the edge's upstream) and `https://smortress.<tailnet>.ts.net/` |
| OPDShelf | `127.0.0.1:8083` | `https://opds.<tailnet>.ts.net/` (the `svc:opds` Service, which is also the edge's upstream) and `https://smortress.<tailnet>.ts.net:8443/` |
| Syncthing GUI | `127.0.0.1:8384` | `https://sync.<tailnet>.ts.net/` and `https://smortress.<tailnet>.ts.net:10000/` |
| Navidrome | `127.0.0.1:4533` | `https://navidrome.<tailnet>.ts.net/` and `https://smortress.<tailnet>.ts.net:8448/` |
| Wallpapers | `/srv/wallpapers` (static files) | `https://smortress.<tailnet>.ts.net/wallpapers/` |
| Personal agent gateway | `127.0.0.1:18001` | `https://smortress.<tailnet>.ts.net/apps/agent-local/v1` |
| General agent gateway | `127.0.0.1:18002` | `https://smortress.<tailnet>.ts.net/apps/agent-general/v1` |
| Hosted proxy | `127.0.0.1:18003` | none, on purpose: a tailnet path would let any device spend the provider key |
| Personal web UI | `127.0.0.1:18006` | `https://assistant.<tailnet>.ts.net/` and `https://smortress.<tailnet>.ts.net:8444/` |
| General web UI | `127.0.0.1:18007` | `https://agent.<tailnet>.ts.net/` and `https://smortress.<tailnet>.ts.net:8445/` |
| zellij web terminal | `127.0.0.1:8082` | `https://terminal.<tailnet>.ts.net/` |

The two agent paths are a second table in `scripts/tailscale-serve.sh`
(`core_path_routes`): the clients that address those APIs already use a path, and
443, 8443 and 10000 were the ports already taken. The browser UIs cannot work that
way -- a web UI emits absolute asset and link URLs, so a path prefix on 443 would
send the browser to the tailnet root, which is Immich -- and they get two more
entries in `core_routes` (8444 and 8445) instead. A tenant
plan that claims either path is refused whole, and the stale-route pruning skips
both, so a run without a plan cannot delete them. A port dropped from `core_routes`
is turned off on the next run of that script, because Serve keeps answering a
handler that nothing declares any more -- and a Service dropped from the script's
`--service=` declarations is cleared on that run for the same reason, so a name no
declaration makes stops advertising itself.

The two UIs answer on a Service each, like every other application behind the
tailnet name service (design #834): `svc:assistant` and `svc:agent` are advertised
over HTTPS, so Tailscale terminates TLS and mints the certificate for the name.
The `*.sammohr.dev` aliases the host's own Caddy answered are gone with that
terminator: no zone record names either UI, the agent UI Service and its VIP are
deleted, and nothing on the host answers those names. The VIPs these Services own
are in `100.64.0.0/10`, so the names resolve anywhere and route only on the
tailnet. Each is granted to the owner and to the scheduled probe, below.

The `:8444` and `:8445` Serve routes stay declared as the rollback: both answer
the same two UIs on the host's own name, so a certificate fault or a Service the
tailnet dropped costs the named URL and not the UI. Nothing is provisioned for
them, one line each in `scripts/tailscale-serve.sh`.

`scripts/verify-tailnet-names.sh` is the probe on that path (task #848), and
`.github/workflows/verify-tailnet-names.yml` runs it daily from a CI node that
joins as `tag:deploy` — the one non-owner client there is. It asserts what a user
would notice rather than a status code: each name resolves into the tailnet on a
VIP of its own and no two names share one, the chain verifies against the public
roots with the name in it, the certificate is not within 14 days of expiry, and
`GET /` answers the status class the application owns -- 2xx for Immich and the
Syncthing GUI, 3xx for the three that redirect a stranger to a login, 4xx for the
catalogue -- rather than a 502 or a 200 from something else. A stopped
application answers 502 or refuses, a drained Service times out, and both are
red. The result pages through Healthchecks via the `NAMES_PING_URL` secret; the
operator commands are in `docs/manual-steps.md`.

Historical: `agent.sammohr.dev` was a proxied CNAME to the dead cluster tunnel,
and Cloudflare refuses two records at one name, so the two applies could not
travel together — PR #120 dropped the `agent` entry from `local.cluster_ingress`
and applied that destroy first, then the zone's own apply created the record
above. Between the two the name fell through to the wildcard, which was the
Access deny then: refused, not served. Both the ingress map and the wildcard are
retired (SDLC #833), so the record is now one apply of `tofu/dns.tf` with
nothing left to order against it.

`svc:immich` and `svc:opds` are a third kind: not for people, but for `tag:vps`
only (`tofu/tailscale.tf`), because the public names proxy to one application
each and never to the host's own 443 — there, 443 also carries the agent paths
and `/wallpapers` (`docs/core/public-edge.md`).

`smortress-tailscale-serve.service` re-declares every route at every boot.
Serve state lives in tailscaled's state file, which is not a dataset and
not worth backing up; re-applying the same route is idempotent. Nothing here is
Funnel, and after #725's cutover the only public hostnames are Caddy's on the
edge, not Serve's.

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
before any of it touches `/srv`. `docs/manual-steps.md#applications-and-agents` has the
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
- **Navidrome** — restore `music` (the library and the database together),
  start the unit against the scratch tree on an alternate publish port and log
  in; a playlist entry proves the database and the files agree. The queue is
  rebuilty empty, so play state is what to check.
- **Syncthing** — restore `syncthing` and `notes`, start with the GUI on an
  alternate port and **all folders paused**, then designate a primary. Peers
  must not be allowed to sync into a tree whose identity was just restored.

A gateway has no drill of its own: its memory records are
`state/agent-local/memory` or `state/agent-general/memory`, so restoring the
`agent-local` or `agent-general` unit brings them back with the gateway's sessions
in the same point in time. What the restore must then prove is that the gateway
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
- Navidrome trusts `X-Forwarded-Host`, so a process that can reach
  `127.0.0.1:4533` can poison the absolute URLs it generates. The listener is
  loopback-only and the tailnet route admits `group:owner`, so there is no wider
  exposure to close.
- The proxy and the collectors are code the *host* image installs and
  the container mounts, so what runs is what the booted deployment carries: that is
  the point, and it is also the one place a container reads a host path. The mounts
  are `:ro` with no `z`, deliberately: `/usr` is a read-only composefs mount, so a
  relabel fails with `EROFS`, and the content is already `bin_t`/`usr_t`, which
  `container_t` may read. Only dataset mounts relabel (`:z`); anything the bootc
  image installs under `/usr` is mounted read-only and unrelabelled.
- The Brave Sync seed is a secret inside a restorable dataset, and therefore in the
  Restic snapshots of it: the planted blob decrypts with Chromium's fixed
  "peanuts" key, which is what `--password-store=basic` buys, so
  `state/agent-local/quarantine/brave-profile` is a copy of the chain's key and a
  restore of it into another host makes that host a chain member. That is what a
  restore is for; a leaked copy is revoked on the chain side by removing the
  device, not by rotating a password (section 40.17, step 7).
- A gateway key is a secret inside a restorable dataset: it sits in the seeded
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
- The personal deployment has no egress at all, which is verified as a route
  property (`Options=no_default_route=true`) rather than as a firewall rule. It
  cannot be `Internal=true`: netavark skips port forwarding for internal
  networks, and firewalld never trusts one for host access, so both the
  published ports and name resolution are dead -- which is exactly what happened
  before the network was changed. A future change that attaches a second network
  to `agent-local` could add a default route with it;
  `tests/core/app-quadlets-agents.bats` asserts the unit declares exactly one network and
  which one, and that no publishing container sits on an internal network. The
  residual of a forwarding-enabled network is host services bound on the bridge
  address; the bridge carries no credential, socket or dataset.
- The runtime's defaults are broad: `computer_use`, `cronjob`, `delegation`,
  `skills`, `image_gen`, `connections` and `session_search` are enabled unless the
  config says otherwise, and disabling is per toolset with no per-tool switch.
  The personal template closes all of them but `delegation`; the general one
  leaves them open. The difference is a decision recorded in each template, not an
  oversight, and subagent concurrency is capped in both because the runtime's
  default of ten is unbounded spend on the hosted side and more parallel streams
  than the local model has slots.
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

## Collector sign-ins

### The Brave sync seed

Brave has no CLI to join a Sync chain, so membership is a **seed**: the OSCrypt blob
a desktop's own join wrote, planted into the profile's `Preferences` before the
browser starts. The seed is the chain's key. Export it from a desktop profile in the
chain, with Brave **closed**; both sides run with `--password-store=basic`, whose
fixed key is what makes the blob portable.

```sh
prefs="$HOME/.config/BraveSoftware/Brave-Browser/Default/Preferences"
seed="v10$(jq -r '.brave_sync_v2.seed' "$prefs" | base64 -d | tail -c +4 | base64 -w0)"
printf '%s\n' "${#seed}"        # hundreds of characters, never 0
scripts/secret.sh edit brave-sync-seed.yaml    # brave.sync_seed, set to $seed
scripts/secret.sh stage brave-sync-seed.yaml
scripts/secret.sh verify
unset seed
```

Commit and push. `smortress-agent-brave-seed.service` replants the seed
idempotently, so `sudo systemctl restart smortress-agent-brave-seed.service` picks
a rotation up without a reboot: the journal line is `{"event": "seed",
"planted": true, …}` on the first run and `… "unchanged": true …` after, and a
`{"event": "refused", …}` line means the seeder wrote nothing — fix the ciphertext
and restart, not the unit.

```sh
sudo journalctl -u smortress-agent-brave-seed.service -n 5 --no-pager
sudo podman logs --tail 40 smortress-agent-brave
sudo journalctl -u agent-egress-proxy.service --since '-30 min' --no-pager | tail -40
object=$(sudo python3 - <<'EOF'
import sqlite3
connection = sqlite3.connect("/var/lib/agent/local/replica/brave/state.sqlite")
print(connection.execute(
    "select sha256 from object where id = 'brave::table::urls'").fetchone()[0])
EOF
)
sudo jq -r '.rows[] | "\(.[1]) \(.[2])"' \
  "/var/lib/agent/local/replica/brave/objects/${object:0:2}/$object"
```

The proxy's journal names `sync-v2.brave.com:443` and nothing else, because
`bootc/server/rootfs/etc/smortress/agent/egress-policy.json` grants the `brave` label
exactly that hostname, and the resolver refuses every other name Chromium tries. A
visit on a phone in the same chain appears in that `urls` object. `deleted` is
always `0`: retention expiry, a deletion in the browser and a recreated profile all
look the same from here (`docs/raw-replicas.md`).

Rotating the seed is the same two steps with a new chain. The real revocation is
removing the `smortress` device in Brave's Sync settings on a desktop; to remove it
here, stop the browser, delete the profile and replace the ciphertext with a value
that is not a `v10` blob, which the seeder refuses.

### The Tuta mail bridge

Tuta serves no IMAP, so `agent-tmail` talks to Tuta's API in process and presents
the mailbox as local IMAP. It needs a Tuta session, created interactively with the
account password and a TOTP code; the Tuta password is never stored here.

```sh
sudo systemctl start agent-tmail.service
sudo podman exec -it smortress-agent-tmail init      # address, password, code; echoes nothing
sudo podman healthcheck run smortress-agent-tmail
sudo podman exec smortress-agent-tmail tutabridge health
```

`is-active` alone proves nothing: the container stays `active` while it waits for
`init`, after a rejected session, and when Tuta refuses this client version. The
session lands in `/var/lib/agent/local/quarantine/tmail`. Read the local IMAP
password the bridge generated into ciphertext, and deploy it before the collector
can use it:

```sh
sudo podman exec smortress-agent-tmail password
```

A fresh `init` regenerates that password, so the ciphertext must be rewritten
before the collector starts. `edit` runs on the operator machine, where the YubiKey
is; `stage` writes the ciphertext into `/var/lib/smortress/secrets`, which only the
host has, so it needs a checkout of this repository there:

```sh
scripts/secret.sh edit tmail-bridge-password.yaml   # tmail.bridge_password
scripts/secret.sh verify
git commit -am 'chore(agent): set the TutaBridge password'
git push
sudo scripts/secret.sh stage tmail-bridge-password.yaml   # from a checkout on the host
```

Without a checkout on the host, copy the bundle `edit` rewrote, keep the root-only
ownership, and restart the units that read it:

```sh
scp secrets/agents.json smortress:/tmp/agents.json
sudo install -m 0600 -o root -g root /tmp/agents.json /var/lib/smortress/secrets/agents.json
rm -f /tmp/agents.json
sudo systemctl restart sops-decrypt.service smortress-app-secrets.service
```

`stage` restarts `sops-decrypt.service` itself; `smortress-app-secrets.service` is
`RemainAfterExit`, so only a restart recreates the Podman secret.

The password therefore travels three hops and a stale middle one looks like a
bridge that will not sign in: `stage` rewrites the ciphertext, `sops-decrypt`
re-renders `/run/smortress/secrets/tmail-bridge-password.yaml`,
`smortress-app-secrets` copies that file into the Podman secret, and the stream
mounts the secret when its container is created. Skip the copy or the restart and
`init`'s new password sits in the ciphertext while the old one stays in the secret:
LOGIN fails with `AUTHENTICATIONFAILED` and the restarts then park the unit in
`start-limit-hit`. Prove the two copies agree first (`tr` drops the newline, which
is not part of the password, and the bare `inspect` would hash its JSON envelope):

```sh
sudo podman exec smortress-agent-tmail password | tr -d '\n' | sha256sum
sudo podman secret inspect --showsecret -f '{{.SecretData}}' \
  tmail-bridge-password | tr -d '\n' | sha256sum
```

An `init` that exits `Login failed: ApiCall: ServerResponseError: Not
authenticated` before it asks for a code saved nothing; run it again and keep the
transcript (`-e RUST_LOG=debug` with `2>&1 | tee /tmp/tb-init.log`) so a repeat
failure names the step it died on.

```sh
sudo systemctl start smortress-agent-mail-stream.service
sudo journalctl -u smortress-agent-mail-stream.service -f
```

`smortress-agent-mail-stream.service` is long-running, not a timer: it commits an
initial pass whose `details.folders` must contain `INBOX` with a non-zero count,
then holds one IDLE connection per folder. Sending yourself a message produces a
second JSON line within a minute, whose `version` is one higher than the first and
whose `objects` grew by one. `uidvalidity changed` or `folders
disappeared` is a refusal: the service has exited and needs a fresh sign-in or the
restore rule below.

The volume holds the session, the per-folder UID counters, the GPG key and the
password. The IMAP server always reports `UIDVALIDITY 1`, so a restore that returns
the replica but not the volume gives every message a new UID: restore
`/var/lib/agent/local/quarantine/tmail` and
`/var/lib/agent/local/replica/mail` from the same snapshot, or neither. If the
volume is genuinely lost, move the replica aside too and let the bridge resync.

### The Tuta calendar exporter

`apps/tuta_calendar/` ships in `images/tuta-calendar/`;
`smortress-agent-collect-calendar.service` runs the exporter and then the collector
every two hours, and skips the run while the seal is missing
(`ConditionPathExists=`), so a start that leaves nothing in the journal means the
sign-in has not run.

The image is the one the unit will run, read out of the installed unit, so the
sign-in and the collector cannot disagree about the seal. (With a checkout of this
repository at hand, `image=$(bash -c 'source scripts/app-images.sh; app_image_ref
tuta-calendar')` names the same reference.)

```sh
image=$(grep -o 'ghcr\.io/smores56/homelab-platform/tuta-calendar@sha256:[0-9a-f]*' \
  /usr/lib/systemd/system/smortress-agent-collect-calendar.service | head -1)
sudo podman run --rm -it \
  -v /var/lib/agent/local/quarantine/tuta-calendar:/data:z \
  "$image" init --store /data          # prints: session for <address> sealed at /data/session.gpg
sudo find /var/lib/agent/local/quarantine/tuta-calendar -maxdepth 1 -printf '%u:%g %m %p\n'
sudo grep -c accessToken /var/lib/agent/local/quarantine/tuta-calendar/session.gpg   # 0
```

The seal must be `1000:1000 600` and the keyring directory `700`; a grep hit means
the seal is not encrypted, so treat the store as compromised. A refusal instead of a
session is the run refusing to store something it could not prove.

```sh
sudo podman run --rm \
  -v /var/lib/agent/local/quarantine/tuta-calendar:/data:z \
  -v /var/lib/agent/local/quarantine/calendar:/out:z \
  "$image" dump --store /data --out /out      # one JSON line, exit 0; exit 3 writes nothing
sudo systemctl start smortress-agent-collect-calendar.service
```

Run the dump only when you want the entity directory without a commit; the unit's
second stage is what turns that directory into the replica state, and it runs the
repository's own collector out of the pinned agent-runtime image, so a manual pass
needs no checkout on the host.

The report's `objects` must equal the dump's count and `deleted` must be `0`: this
source has no tombstone, so a missing event is carried forward as absent-unknown.
Expect the version floor: `HTTP 474 InvalidSoftwareVersionError` means
`CLIENT_VERSION` in `apps/tuta_calendar/api.py` is below the server minimum (read
`versionNumber` from the web client and republish); `HTTP 412` means the model
version moved; `HTTP 401`/`403` means the session was revoked, so sign in again.

### The SimpleFIN access URL

The finance collector needs the access URL SimpleFIN issues for your account; the
ciphertext ships seeded with a random value, which fails at the first request
rather than silently. Claim the setup token in the SimpleFIN dashboard (base64
decode it for the claim URL, `curl -X POST <claim-url>` answers with the access URL
— it embeds the account credentials, so do not paste it into a shell that logs),
then deploy it:

```sh
scripts/secret.sh edit simplefin-access-url.yaml   # simplefin.access_url
scripts/secret.sh stage simplefin-access-url.yaml
git commit -am 'chore(core): claim the SimpleFIN access URL'
git push
sudo systemctl start smortress-agent-collect-finance.service
sudo journalctl -u smortress-agent-collect-finance.service -n 20 --no-pager
```

The run is good when `published` names the replica's `state.sqlite` and
`objects` counts the transactions; a refusal exits 3, commits nothing, and names
the endpoint by host and path, never the credential. The replica's state and its
objects must be owned by uid 1000.

The third stage renders the newest state as an hledger journal and needs to
know which hledger account each SimpleFIN account is. The file is seeded as `{}`
and never overwritten, so the edit is one-time per account; an unmapped entry
renders as `assets:unknown:<id>`:

```sh
sudo python3 - <<'EOF'
import sqlite3
connection = sqlite3.connect("/var/lib/agent/local/replica/finance/state.sqlite")
for (object_id,) in connection.execute(
    "select id from object where present = 1 and id like 'finance::account::%' order by id"
):
    print(object_id)
EOF
sudo vi /var/lib/agent/local/index/hledger/accounts.json   # {"<id>": "assets:bank:checking"}
sudo systemctl start smortress-agent-collect-finance.service
```

A mapping that is not a JSON object of string to string, or a name that is empty or
starts with `-`, `!` or `;`, is refused with exit 3. The journal follows the
provider's sign, `expenses:unknown` carries the negation, and an unchanged journal
is not rewritten.
