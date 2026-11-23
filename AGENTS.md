# Agent rules for homelab-platform

## Hard rules

- This repository is human-merge only. Agents push to `smores56/homelab-apps`;
  platform changes arrive as pull requests from a fork, which never receive the
  `cloudflare` environment or any secret.
- No secrets in git, in manifests, or in workflow files. Secrets are SOPS+age
  ciphertext under `secrets/` and are decrypted at boot or by the operator; CI
  references none.
- Every GitHub Action reference is pinned to a 40-character commit SHA. CI fails
  otherwise (`scripts/check-action-pins.sh`).
- A workflow triggered by `pull_request` must not reference `secrets.*` other
  than `secrets.GITHUB_TOKEN`. `tofu-plan-pr.yml` is the single, checked
  exception: read-only plan credentials only, with the four guard markers
  `scripts/check-pr-secret-boundary.sh` requires. Never use
  `pull_request_target` (blocked by default in public repos from 2026-12-02).
- `*.tf` and `.github/` are Kanbei-critical (`docs/kanbei-critical.md`). Keep
  `CODEOWNERS`, that document, and `scripts/check-codeowners.sh` in sync.
- Anything an operator must do by hand goes in `docs/manual-steps.md` with the
  exact commands; no TODO/TBD placeholders.

## Platform conventions

- One immutable uCore bootc host, configured by this repository alone: `image/`
  builds it, `units/` and `image/rootfs/` are what boots (`docs/core/server-image.md`).
  There is no configuration-management layer beside the image.
- Podman Quadlets are the only container control plane. A deployment change is
  an image change plus a maintenance-window reboot; stateful Quadlets never
  auto-update.
- Data lives on ZFS recovery datasets under `/var/srv` and `/var/lib`, each with
  a readiness unit that proves the mount. Backup is the host Restic plane —
  three repositories, one job per restore unit per destination
  (`docs/core/restic-plane.md`).
- Reachability is Tailscale Serve on the tailnet; nothing binds a public port.
  Cloudflare OpenTofu (`tofu/`) owns the public edge and Access
  (`docs/cloudflare.md`), and `provision/edge/` bootstraps that VPS.
- `apps/` holds the source and unit tests of what ships; `deploy/` holds trees
  an operator applies rather than the image. Two deploy paths exist and never
  overlap: `scripts/deploy-platform.sh` for the platform plane, and
  `scripts/deploy-apps.sh` for the unprivileged `homelab-apps` tenant
  (`docs/core/apps-tenant.md`).

## Before you commit

```sh
scripts/check-all.sh             # every group, in parallel
scripts/check-all.sh --changed   # only the groups this branch touches
scripts/check-all.sh --list      # the groups and their commands
```

The driver is the source of truth: CI invokes it once per shard with
`--only <group>`, and `tests/check-all/ci-parity.sh` fails when a group is
neither called by a workflow nor declared local-only. `--changed` runs every
group when a changed path no group claims, and `--check-claims` proves every
tracked file is covered.

`tests/check-all/check.sh` is the driver's own test. Run it with any
`scripts/check-all.sh` change.

Run the formatters only where the repository defines them; this repo has no
formatter beyond `tofu fmt -check -recursive tofu`.

`git config core.hooksPath .githooks` installs the pre-push gate, which runs
`scripts/check-all.sh --changed`. Groups need the tools CI installs: on a
fresh host run `scripts/install-ci-tools.sh ~/.local/bin` and put it on PATH.
