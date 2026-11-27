# homelab-platform

Human-owned platform for `smortress`: one immutable uCore bootc server image, the
Podman Quadlets and systemd units baked into it, ZFS recovery groups backed by the
host Restic plane, Tailscale Serve for reachability, Cloudflare OpenTofu for the
zone's DNS, and the offline checks that guard all of it.

Agents never push here. They work in
[`homelab-apps`](https://github.com/smores56/homelab-apps) and propose platform
changes by pull request from a fork, so no PR workflow can read a secret.

## Layout

| Path | Contents |
| --- | --- |
| `bootc/server/` | The server image: Containerfile, rootfs, pins and the cosign public key (`docs/core/server-image.md`) |
| `units/systemd/` | systemd units baked into the image: gates, backup timers, mounts (Quadlets are below) |
| `units/quadlet/` | Podman Quadlet workloads: the agents, Immich, OPDShelf, Syncthing and their networks |
| `ignition/` | First-boot Ignition for the bootc deployment |
| `scripts/deploy-platform.sh` | The platform deploy path: image change plus a maintenance-window reboot |
| `scripts/deploy-apps.sh` | The `homelab-apps` tenant deploy path: schemas in, rootless Quadlets out (`docs/core/apps-tenant.md`) |
| `recovery/` | The recovery inventory and the backup policy the manifest and the host plan are rendered from (`scripts/render-recovery-groups.py`) |
| `deploy/data-plane/` | Trees an operator applies rather than the image: relay source schemas and the rendered recovery-group manifest |
| `libs/data_plane/` | The data-plane library: contracts, event log, write broker, backup runner, migration gates |
| `apps/broker/` | Broker source and unit tests (Python stdlib, no dependencies) (`docs/broker.md`) |
| `apps/webhook/` | Webhook receiver source and unit tests (Python stdlib, no dependencies) (`docs/webhook.md`) |
| `backrest/` | The Backrest reader Worker: source, TypeScript typecheck and static tests (`docs/core/backrest.md`) |
| `images/` | Container image sources: agent egress, agent mail, agent WebUI, data-plane, brave, tuta-calendar |
| `tofu/` | Cloudflare OpenTofu (provider v5): the zone's DNS, the CAA pin (`docs/cloudflare.md`), tailnet policy |
| `bootc/edge/` | The edge image: Caddyfile, firewalld zones, sshd drop-in and deploy units (`docs/core/public-edge.md`) |
| `provision/smortress/` | Autoinstall user-data for the bootc host |
| `secrets/` | SOPS+age ciphertext, decrypted at boot or by the operator; CI references none |
| `tests/core/` | Offline checks for the core gate, the Restic plane, the apps tenant and the Serve routes |
| `tests/deploy/` | Offline checks for the deploy receiver: listener, verification, gates, apps apply, CI notify |
| `tests/tofu/` | Static assertions on the Cloudflare config (`tests/tofu/check.bats`) |
| `tests/edge/` | Offline checks for the public-edge probe (`tests/edge/check.bats`) |
| `scripts/` | CI helpers, shellchecked |
| `docs/` | Core image, apps tenant, Restic plane, backrest, public edge, recovery kit, broker, webhook, runbook, manual steps |

## Local checks

```sh
scripts/install-ci-tools.sh ~/.local/bin # bats, GNU parallel, the pinned tools; also fills ~/.local/share/bats

# every suite, tracked or not
git ls-files -z --cached --others --exclude-standard \
    'tests/*.bats' 'tests/*/*.bats' |
    xargs -0 bats --jobs "$(nproc)" --no-parallelize-within-files
# only the suites this branch touches (the pre-push hook runs these)
tests/tags.sh --changed

bats tests/tofu/check.bats               # Cloudflare config shape, no credentials
bats tests/core/                         # core gate, apps tenant, Restic plane, Quadlets
bats tests/deploy/                       # deploy receiver, verification, gates, apps apply
```

`tests/tags.tsv` is the selector: one row per suite maps changed paths to the
suite that covers them, and a path no row claims selects every suite.
`tests/tags.bats` holds the table to the tree and holds every suite's
`# bats file_tags=` to an area job in `.github/workflows/ci.yml`. The pre-push
hook (`git config core.hooksPath .githooks`) runs the selected suites.
`.github/workflows/tofu-plan-pr.yml` and `tofu-apply.yml` own the `cloudflare`
environment: `tofu-plan` is a read-only drift check on `main`, and `tofu-apply`
is `workflow_dispatch` only and applies a reviewed plan (SDLC #622).

## Ownership

Every path is owned by `@smores56`. `*.tf` and `.github/` are Kanbei-critical:
a change there can publish a name in the zone or expose the Cloudflare token.
See `CODEOWNERS` and `docs/kanbei-critical.md`.
