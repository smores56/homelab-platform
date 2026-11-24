# homelab-platform

Human-owned platform for `smortress`: one immutable uCore bootc server image, the
Podman Quadlets and systemd units baked into it, ZFS recovery groups backed by the
host Restic plane, Tailscale Serve for reachability, Cloudflare OpenTofu for the
public edge, and the offline checks that guard all of it.

Agents never push here. They work in
[`homelab-apps`](https://github.com/smores56/homelab-apps) and propose platform
changes by pull request from a fork, so no PR workflow can read a secret.

## Layout

| Path | Contents |
| --- | --- |
| `image/` | The server image: Containerfile, rootfs, pins and the cosign public key (`docs/core/server-image.md`) |
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
| `apps/agent_facade/` | MCP source facades and portable memory for the two agent deployments (`docs/agent-facade.md`) |
| `apps/data_plane/` | CLI entry points for the data-plane library |
| `backrest/` | The Backrest reader Worker: source, TypeScript typecheck and static tests (`docs/core/backrest.md`) |
| `images/` | Container image sources: agent egress, agent mail, agent WebUI, data-plane, brave, tuta-calendar |
| `tofu/` | Cloudflare OpenTofu (provider v5), Access default-deny, CAA (`docs/cloudflare.md`), tailnet policy |
| `provision/edge/` | The public edge VPS bootstrap, Caddyfile, firewall and on-box verify (`docs/core/public-edge.md`) |
| `provision/smortress/` | Autoinstall user-data for the bootc host |
| `secrets/` | SOPS+age ciphertext, decrypted at boot or by the operator; CI references none |
| `tests/core/` | Offline checks for the core gate, the Restic plane, the apps tenant and the Serve routes |
| `tests/data-plane/` | Data-plane unit tests: contracts, backup plan, migration gates, restore planning |
| `tests/deploy/` | Offline checks for the deploy receiver: listener, verification, gates, apps apply, CI notify |
| `tests/tofu/` | Static assertions on the Cloudflare config (`tests/tofu/check.sh`) |
| `tests/edge/` | Offline checks for the public-edge probe (`tests/edge/check.sh`) |
| `scripts/` | CI helpers, shellchecked |
| `docs/` | Core image, apps tenant, Restic plane, backrest, public edge, recovery kit, broker, webhook, agent facade, runbook, manual steps |

## Local checks

```sh
scripts/check-all.sh                     # every group, in parallel
scripts/check-all.sh --changed           # only the groups this branch touches
scripts/check-all.sh --list              # the groups and their commands

scripts/install-ci-tools.sh ~/.local/bin # the pinned tool the tofu group needs
tests/tofu/check.sh                      # Cloudflare config shape, no credentials
tests/data-plane/check.sh                # data-plane unit tests, no host
tests/core/check.sh                      # core gate, apps tenant, Restic plane and deploy docs
tests/deploy/*.sh                        # deploy receiver, verification, gates, apps apply, notification
scripts/render-recovery-groups.py --check # the recovery manifest matches its source
```

`scripts/check-all.sh` is the source of truth for what runs; CI
(`.github/workflows/ci.yml`) calls it once per shard with `--only <group>`.
`.github/workflows/tofu-plan-pr.yml` and `tofu-apply.yml` own the `cloudflare`
environment: `tofu-plan` is a read-only drift check on `main`, and `tofu-apply`
is `workflow_dispatch` only and applies a reviewed plan (SDLC #622).

## Ownership

Every path is owned by `@smores56`. `*.tf` and `.github/` are Kanbei-critical:
a change there can repoint `kanbei.sammohr.dev` or expose the Cloudflare token.
See `CODEOWNERS` and `docs/kanbei-critical.md`.
