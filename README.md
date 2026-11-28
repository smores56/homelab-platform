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
| `bootc/server/` | The server image: Containerfile, rootfs and pins (`hosts/server/runbook.md`) |
| `lib/` | The artifacts every host shares, once: the containers policy with its per-host registry table, the cosign public key, `registries.d`, the sudoers gate and the greenboot required check with per-host assertions (`scripts/check-lib-drift.sh`) |
| `units/systemd/` | systemd units baked into the image: gates, backup timers, mounts (Quadlets are below) |
| `units/quadlet/` | Podman Quadlet workloads: the agents, Immich, OPDShelf, Syncthing and their networks |
| `ignition/` | First-boot Ignition for the bootc deployment |
| `scripts/deploy-platform.sh` | The platform deploy path: image change plus a maintenance-window reboot |
| `scripts/deploy-apps.sh` | The `homelab-apps` tenant deploy path: schemas in, rootless Quadlets out (`docs/core/apps-tenant.md`) |
| `libs/data_plane/` | The portable replica library the collectors run: provider bytes into one transactional state per source (`libs/data_plane/README.md`) |
| `backrest/` | The Backrest reader Worker: source, TypeScript typecheck and static tests (`docs/core/backrest.md`) |
| `images/` | Container image sources: agent egress, agent mail, agent runtime, agent WebUI, brave, tuta-calendar |
| `tofu/` | Cloudflare OpenTofu (provider v5): the zone's DNS, the CAA pin (`bootc/edge/runbook.md`), tailnet policy |
| `bootc/edge/` | The edge image: Caddyfile, firewalld zones, sshd drop-in and deploy units (`bootc/edge/runbook.md`) |
| `hosts/laptop/` | The laptop image: Containerfile, rootfs, pins, its checker and runbook; merged in with `smorespro-image`'s history (`hosts/laptop/README.md`) |
| `secrets/` | SOPS+age ciphertext, decrypted at boot or by the operator; CI references none |
| `tests/core/` | Offline checks for the core gate, the Restic plane, the apps tenant and the Serve routes |
| `tests/deploy/` | Offline checks for the deploy receiver: listener, verification, gates, apps apply, CI notify |
| `tests/tofu/` | Static assertions on the Cloudflare config (`tests/tofu/check.bats`) |
| `tests/fleet/` | Offline checks for the fleet probe (`tests/fleet/check.bats`) |
| `scripts/` | CI helpers, shellchecked |
| `docs/` | Core image, apps tenant, Restic plane, backrest, public edge, recovery kit, runbook, manual steps |

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

Every path is owned by `@smores56`. `*.tf`, `.github/` and `hosts/` are
Kanbei-critical: a change there can publish a name in the zone, expose the
Cloudflare token, or ship in the OS on a host.
See `CODEOWNERS` and `docs/kanbei-critical.md`.
