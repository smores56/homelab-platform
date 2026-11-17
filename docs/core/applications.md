# Core applications: Immich, OPDShelf, Syncthing (T5)

The three applications that carry real data on smortress run as Podman Quadlets
from the derived image. This document covers what each container is allowed to
read and write, how its image reaches the host, how it is reached from the
tailnet, and what its restore actually consists of. Operator steps are in
`docs/manual-steps.md` section 40; the Restic units they rely on are in
`docs/core/restic-plane.md`. Agent-managed tenant apps from `homelab-apps` are a
separate, unprivileged plane: see `docs/core/apps-tenant.md`.

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

`scripts/app-images.sh` is the single pin table. `scripts/mirror-app-images.sh`
copies each upstream image into our namespace by digest (`skopeo copy --all
--preserve-digests`), proves the digest survived, signs it, and proves the legacy
`.sig` lookaside tag exists — that tag, not the OCI 1.1 referrer bundle, is what
`containers/image` reads. CI runs it as
`.github/workflows/publish-app-images.yml` on a pin change and on dispatch.

| Quadlet | Pinned image | Upstream |
| --- | --- | --- |
| `immich-server` | `ghcr.io/smores56/homelab-platform/immich-server@sha256:c716dc20…` | `ghcr.io/immich-app/immich-server:v3.0.3` |
| `immich-machine-learning` | `…/immich-machine-learning@sha256:d76fe88b…` | `ghcr.io/immich-app/immich-machine-learning:v3.0.3` |
| `immich-postgres` | `…/immich-postgres@sha256:79b95b79…` | `ghcr.io/immich-app/postgres:17-vectorchord0.4.3-pgvector0.8.1` |
| `immich-valkey` | `…/immich-valkey@sha256:3add1a33…` | `docker.io/valkey/valkey:9` |
| `opdshelf` | `…/opdshelf@sha256:b82f94f7…` | `docker.io/koalilla/opds-server@sha256:b82f94f7…` |
| `syncthing` | `…/syncthing@sha256:2b71da7c…` | `docker.io/syncthing/syncthing:2.1.7` |

Immich stays on v3.0.3 until the cutover restore has passed: the existing
database was written by that version, and moving a major version belongs in its
own window, not inside a data migration. OPDShelf is pinned at the digest the
legacy deployment ran; it has no database, so a version change is a reader
change.

`tests/core/app-quadlets.sh` fails if any Quadlet names a reference the pin table
does not produce, if a pin already points at our namespace, or if an upstream
registry appears in the policy.

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

Every dataset root is owned by uid 1000, because that is the uid the
applications run as. The pool unit sets it at dataset creation, which is what
lets a restore write a tree without a manual `chown`. A dataset restored by
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

`smortress-app-secrets.service` creates both Podman secrets with
`--replace` on every boot, before any container that declares one. The values
never appear in a unit file, in argv, in the image, or in this repository.

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

## Access paths

| Application | Direct listener | Tailnet URL |
| --- | --- | --- |
| Immich | `127.0.0.1:2283` | `https://smortress.<tailnet>.ts.net/` |
| OPDShelf | `127.0.0.1:8083` | `https://smortress.<tailnet>.ts.net:8443/` |
| Syncthing GUI | `127.0.0.1:8384` | `https://smortress.<tailnet>.ts.net:10000/` |

`smortress-tailscale-serve.service` re-declares these three routes at every boot.
Serve state lives in tailscaled's state file, which is not a dataset and
not worth backing up; re-applying the same route is idempotent. Nothing here is
Funnel, and no public hostname serves an application.

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
- The machine learning container needs egress on first use and caches models
  outside the backup. A cold restore re-downloads them; smart search degrades
  until it finishes.
