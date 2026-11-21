# Agent rules for homelab-platform

## Hard rules

- This repository is human-merge only. Agents (nanobot) push to
  `smores56/homelab-apps`; platform changes arrive as pull requests from a
  fork, which never receive the `cloudflare` environment or any secret.
- No secrets in git, in manifests, or in workflow files. Cluster secrets are
  SOPS+age ciphertext or ESO-generated; CI references none.
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

## Before you commit

```sh
scripts/check-all.sh             # every group, in parallel
scripts/check-all.sh --changed   # only the groups this branch touches
scripts/check-all.sh --list      # the groups and their commands
```

The driver is the source of truth and runs the same commands CI does; CI keeps
its jobs sharded for parallelism. `--changed` runs every group when a changed
path no group claims, so a new directory can never fall through.

Two checks stay outside it: `tests/policies/check.sh --runtime` needs a
throwaway apiserver, and `tests/check-all/check.sh` is the driver's own test.
Run the latter with any `scripts/check-all.sh` change.

Run the formatters only where the repository defines them; this repo has no
formatter beyond `tofu fmt -check -recursive tofu`.

`git config core.hooksPath .githooks` installs the pre-push gate, which runs
`scripts/check-all.sh --changed`. Groups need the tools CI installs: on a
fresh host run `scripts/install-ci-tools.sh ~/.local/bin` and put it on PATH.

## Cluster conventions

- Flux runs with tenancy lockdown: per-controller flags are tabulated in
  `docs/flux.md` and asserted against the rendered args by
  `tests/policies/check.sh` (helm, notification, kustomize, source and
  source-watcher differ in which flags exist at the pinned versions). Per-tenant
  `decryption.secretRef` for age keys; the `--sops-age-secret` global stays
  unset. Never the two insecure kubeconfig flags.
- Namespaces carry `homelab.dev/tenant` and `homelab.dev/tier` labels plus PSA
  labels; non-platform namespaces enforce `restricted`. See `docs/tenancy.md`.
- Kustomization directories are self-contained; CI builds each one directly.
- Provider pin: Cloudflare v5 (`cloudflare_zero_trust_access_application`,
  `_policy`, `_network_hostname_route`, `cloudflare_dns_record`).
