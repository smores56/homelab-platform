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
  exception: read-only plan credentials only, with the guard markers
  `scripts/check-pr-secret-boundary.sh` requires. Never use
  `pull_request_target` (blocked by default in public repos from 2026-12-02).
- `*.tf` and `.github/` are Kanbei-critical (`docs/kanbei-critical.md`). Keep
  `CODEOWNERS`, that document, and `scripts/check-codeowners.sh` in sync.
- Anything an operator must do by hand goes in `docs/manual-steps.md` with the
  exact commands; no TODO/TBD placeholders.

## Platform conventions

- One immutable uCore bootc host, configured by this repository alone: `bootc/server/`
  builds it, `units/` and `bootc/server/rootfs/` are what boots (`docs/core/server-image.md`).
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
  (`docs/cloudflare.md`), and the VPS runs this repository's own signed image,
  `bootc/edge/` (`docs/core/public-edge.md`).
- `apps/` holds the source and unit tests of what ships; `deploy/` holds trees
  an operator applies rather than the image. Two deploy paths exist and never
  overlap: `scripts/deploy-platform.sh` for the platform plane, and
  `scripts/deploy-apps.sh` for the unprivileged `homelab-apps` tenant
  (`docs/core/apps-tenant.md`).

## Before you commit

```sh
# every suite, tracked or not
git ls-files -z --cached --others --exclude-standard \
    'tests/*.bats' 'tests/*/*.bats' |
    xargs -0 bats --jobs "$(nproc)" --no-parallelize-within-files
# the suites this branch touches -- and what the pre-push hook runs
tests/tags.sh --changed
```

`git config core.hooksPath .githooks` installs the pre-push hook, which runs the
suites `tests/tags.sh --changed` prints.
`tests/tags.tsv` maps changed paths to suites and is the only selector: a path
no row claims selects every suite, so a new file cannot fall through to a green
run that tested nothing. `tests/tags.bats` holds the table to the tree, and its
area tests hold every suite's `# bats file_tags=` to a job in `ci.yml`, so a
suite that no area job claims fails instead of running nowhere.

The suites need the tools CI installs: on a fresh host run
`scripts/install-ci-tools.sh ~/.local/bin` and put it on PATH; it also fills
`$XDG_DATA_HOME/bats` with the assertion libraries the `.bats` suites load.

Run the formatters only where the repository defines them; this repo has no
formatter beyond `tofu fmt -check -recursive tofu`.

Behavioural suites are `.bats` files run by bats; a new one needs a row in
`tests/tags.tsv` (the tag is its path under `tests/`), which `tests/tags.bats`
holds to the tree.
