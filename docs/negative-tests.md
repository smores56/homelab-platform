# Negative tests

## fork PR cannot read the `cloudflare` environment secret

SDLC #576. Property under test: a pull request opened from a fork reaches no
secret, so an agent that can open a fork PR cannot exfiltrate the Cloudflare
token or run tofu against the real account.

### What runs automatically

Job `fork-pr-secret-boundary` in `.github/workflows/ci.yml`:

- Trigger: `pull_request` only (fork and same-repo PRs alike).
- Job-level `environment` is absent, so the job has no environment secrets.
- Step `fork PRs receive no secrets` asserts that `CLOUDFLARE_API_TOKEN` is
  unset in the job environment (`test -z "${CLOUDFLARE_API_TOKEN:-}"`). A fork
  PR passes only because the variable is never injected.
- Step `no pull_request workflow references a secret` runs
  `scripts/check-pr-secret-boundary.sh`, which statically asserts:
  - every `pull_request` workflow except `tofu-plan-pr.yml` references no
    `secrets.<NAME>` other than `secrets.GITHUB_TOKEN`;
  - `tofu-plan-pr.yml` may reference only the read-only plan pair
    (`CLOUDFLARE_PLAN_API_TOKEN`, `R2_STATE_READONLY_*`) and the plan's own
    read-only Tailscale client (`TAILSCALE_PLAN_OAUTH_CLIENT_*`: design #841
    grants it `policy_file:read`, the two `devices` reads and `services:read`,
    and the job proves a write answers 403 before it plans) from the
    `cloudflare-plan` environment, and must carry the guard markers (fork-only,
    CI-change refusal, executable-HCL refusal, JSON-config refusal, provider
    allowlist, read-only credentials, read-only probe), so deleting a guard
    fails CI on the same diff;
  - no workflow uses `pull_request_target`, which runs with base-repo secrets and
    is blocked by default in public repositories from 2026-12-02 anyway.

Both checks run on every PR, so they also guard the invariant over time: adding
`secrets.CLOUDFLARE_API_TOKEN` to a `pull_request` workflow fails CI on that PR.
The #622 exemption is the one deliberate relaxation: the pre-merge plan is what
makes the merge an informed approval, and read-only credentials are what make the
relaxation survivable. The Tailscale OAuth client is the one credential that
cannot be read-only, and the CI-change and executable-HCL guards, not its scope,
are what bound it. A provider or remote module is the other way code reaches the
runner with that credential in the environment, so the plan job runs
`scripts/check-tofu-providers.py` before `tofu init`: `required_providers` may
name only the providers in the committed `.terraform.lock.hcl`, and no `module`
may name a non-local source. The exemption depends on the `cloudflare` environment allowing
only `main` and `smores/*` (`docs/manual-steps.md#environments-and-their-branch-policies`), because the workflow
that holds those credentials on a PR is the PR head's.

Result of the static half: **PASS** locally on the bootstrap commits
(`scripts/check-pr-secret-boundary.sh` → `no pull_request workflow references
secrets beyond GITHUB_TOKEN`), and the same script is green in CI job
`action SHA pins`' sibling checks on run
[43024148131](https://github.com/smores56/homelab-platform/actions/runs/43024148131)
(`ci`, push to `main`, all jobs success). Job `fork-pr-secret-boundary` itself
is skipped on pushes by its `if:` guard; it has not run yet because no pull
request exists on the repository (branch protection is not applied, see
`docs/runbook.md`). Its first PR run URL belongs in "Runtime result" below.

### What did not run here

The machine user now exists (`docs/manual-steps.md#the-machine-user-and-its-scoped-token`) and has Write
on this public repository, so it can fork it and the fork half is executable.
It was not run in this pass; the branch-run half that was run is the next
section. The fork PR's first URL still belongs in "Runtime result".

### Manual runtime test

1. Complete `docs/manual-steps.md#the-machine-user-and-its-scoped-token` (machine user, token, roles) and
   section 2 (environment secret).
2. As the machine user, fork `smores56/homelab-platform` and open a branch
   whose workflow file `probe.yml` under `.github` holds:

   ```yaml
   name: probe
   on: pull_request
   permissions: read-all
   jobs:
     probe:
       runs-on: ubuntu-latest
       steps:
         - run: |
             echo "environment secret: ${CLOUDFLARE_API_TOKEN:-ABSENT}"
             echo "repo secret: ${OTHER_SECRET:-ABSENT}"
   ```

   This is expected to fail CI: the workflow is a `pull_request` workflow that
   references no secret by pattern, so the boundary check passes it, while the
   runtime probe prints `ABSENT` for both. A second variant that writes
   `secrets.CLOUDFLARE_API_TOKEN` into `env` must fail
   `fork-pr-secret-boundary` before it runs.
3. Record the run URL and the printed `ABSENT` lines under "Runtime result"
   below, then close the fork PR.

Approval gate: repo setting `fork-pr-contributor-approval` is intended to be
`all_external_contributors`; the bootstrap token could not apply it (HTTP 403,
`docs/runbook.md`). Until the owner applies it, GitHub's default applies: a
first-time contributor's workflow run on a private repo waits for owner
approval, and every fork run receives a read-only `GITHUB_TOKEN` regardless.

### Runtime result

Not executed: the fork half was not run. The static half passes, and the
branch-run half is recorded in the next section.

## The machine user has Write, not Admin, and no branch run reaches a main-only environment

SDLC #710. Property under test: the general shell's GitHub identity can push
branches and open PRs, and cannot push `main`, force-push, delete a branch,
edit a workflow, merge without the owner, change settings, or read a
`main`-only environment's secret from a branch run. The identity is a classic
`repo` PAT held by `smores56-agent`; it is exfiltratable by design, so the
collaborator role and the repository protections are the controls
(`docs/manual-steps.md#the-machine-user-and-its-scoped-token`).

### What runs automatically

Nothing carries this token in CI, by design: a CI job that could read it would
defeat the boundary. The static half is therefore the existing PR boundary
check, which is independent of the identity:

```sh
scripts/check-pr-secret-boundary.sh
# expect: no pull_request workflow references secrets beyond GITHUB_TOKEN, the
#         read-only plan pair and the Tailscale OAuth client
```

The machine-user probes are manual because the token must never enter a
workflow. The exact commands and isolation are in
`docs/manual-steps.md` 48.5; the results below are from 2026-11-21.

### Manual runtime test

Run every git command with the owner's credential helper disabled
(`-c credential.helper= -c credential.https://github.com.helper=` and
`GIT_CONFIG_GLOBAL=/dev/null`). Otherwise `!gh auth git-credential` authenticates
as `smores56`, the ruleset bypass, and every control looks unenforced.

1. Role read-back: 20 active repositories show `role_name=write` and
   `permissions.admin=false`, `permissions.maintain=false`, `permissions.push=true`;
   `sdlc` is included. The other 60 repositories are archived and GitHub refuses
   the collaborator change with `Repository was archived so is read-only.`
2. Branch push to `homelab-platform` succeeds (`agent/t0-probe`).
3. Push, force-push, and deletion of `main` are rejected on
   `homelab-platform`, `nix-config`, and `kanbei`.
4. A branch push that adds a workflow file `t0-probe.yml` under `.github` is rejected by the
   token scope.
5. A PR from `agent/t0-probe` cannot be merged, with or without `--admin`.
6. `publish-app-images.yml` (server-image), `tofu-apply.yml` (cloudflare), and
   `tofu-plan-pr.yml` (cloudflare-plan) dispatched or triggered on the machine
   user's branch are rejected by the environment policy before any step runs.
7. `PATCH` on the repository, `PUT` on a collaborator, and the classic branch
   protection read return `404`; `admin=false` is unchanged.

### Results

| Probe | Expected | Observed 2026-11-21 |
| --- | --- | --- |
| classic PAT scopes | `repo` only | `X-Oauth-Scopes: repo` |
| collaborator role | Write, no Admin/Maintain | 20 × `write`; `admin=false`, `maintain=false` |
| push `agent/*` | allowed | `* [new branch] agent/t0-probe-machine` |
| push `main` | rejected | `push declined due to repository rule violations` |
| force-push `main` | rejected | same |
| delete `main` | rejected | `refusing to delete the current branch: refs/heads/main` |
| push workflow file | rejected | `refusing to allow a Personal Access Token to create or update workflow ... without workflow scope` |
| merge PR, no admin | rejected | `the base branch policy prohibits the merge` |
| merge PR, `--admin` | rejected | `At least 1 approving review is required`; `Required status check "tofu plan" is failing` |
| `PATCH` repository | refused | `404 Not Found` |
| `PUT` collaborator | refused | `404 Not Found` |
| branch run, `server-image` | refused before steps | `Branch "agent/t0-probe-machine" is not allowed to deploy to server-image due to environment protection rules.` |
| branch run, `cloudflare` | refused before steps | `Branch "agent/t0-probe-machine" is not allowed to deploy to cloudflare due to environment protection rules.` |
| PR run, `cloudflare-plan` (before #841) | refused before steps | `Branch "refs/pull/93/merge" is not allowed to deploy to cloudflare-plan due to environment protection rules.` |
| PR run, `cloudflare-plan` from `smores/*` (before #841) | refused before steps | `Branch "refs/pull/94/merge" is not allowed to deploy to cloudflare-plan due to environment protection rules.` |

Run URLs: [44872248868](https://github.com/smores56/homelab-platform/actions/runs/44872248868)
(server-image), [44872273360](https://github.com/smores56/homelab-platform/actions/runs/44872273360)
(cloudflare), [44872279543](https://github.com/smores56/homelab-platform/actions/runs/44872279543)
(cloudflare-plan). Each job has zero steps and the second annotation `The
deployment was rejected or didn't satisfy other protection rules.` The probe PR
was `smores56/homelab-platform#93`, closed unmerged, and its branch deleted.

### Open gaps

These are failures of the control, not of the probe:

- **`sdlc` cannot have a ruleset or branch protection on the free plan.**
  `GET /repos/smores56/sdlc/rulesets` and the branch-protection endpoint return
  `Upgrade to GitHub Pro or make this repository public` (HTTP 403). The machine
  user has Write there, so it can push `main`; not executed.
- **Only `~DEFAULT_BRANCH` is covered.** The live rulesets on
  `homelab-platform`, `homelab-apps`, `nix-config`, and `kanbei` target the
  default branch only.
  The app-gating ruleset from `docs/manual-steps.md#the-machine-user-and-its-scoped-token` is absent,
  so a non-main branch has no force-push or deletion rule. The machine user's
  own `agent/*` branches are intentionally exempt, but the gate the design
  describes for every other branch is not present.
- **Archived repositories are excluded.** GitHub refuses collaborator changes
  on all 60, so a private archived history is not readable by the machine user.
- **The pre-merge plan's guards are self-policing.** `cloudflare-plan` now also
  admits `refs/pull/*/merge` (#841), so a same-repo PR runs its head workflow
  with the read-only plan pair. A PR that edits that workflow can remove its own
  guard; the plan's credentials are read-only by scope and probed for 403, the
  exec label is gone, and `tofu/` may add only the locked providers and local
  modules. Closing the guard-editing path itself needs an environment required
  reviewer, which #841 rejected for toil.
- **`sdlc approve` has no author check.** It adds `status:approved` and a hash
  comment without comparing the comment author (`sdlc_issues.py:569-593` in
  `dotfiles`). A machine-user approval would be accepted; it was not executed.
- **The token is non-expiring** by owner decision; manual revocation is the
  only kill switch.

The environment half is now correct: `cloudflare` and `server-image` allow
`main` only, and `cloudflare-plan` allows `main`, `smores/*` and
`refs/pull/*/merge` (#841).

## The tenant auto-merges an agent-authored app-only PR

SDLC #710. Property under test: the machine user can push an app-only branch,
open a pull request, and let auto-merge land it, while a direct push to `main`
is refused and no human approval is involved. The credential is the classic
`repo` PAT from `docs/manual-steps.md#the-machine-user-and-its-scoped-token`; the broker is a separate
identity.

### What runs automatically

Nothing: CI must not carry this token. The repeatable probe is
`scripts/agent-tenant-pr-probe.sh`, run by hand with the token at
`~/.config/smores56-agent/token` (mode 0600):

```sh
scripts/agent-tenant-pr-probe.sh           # read-only control checks
scripts/agent-tenant-pr-probe.sh --merge   # opens and auto-merges a probe PR
```

`--merge` changes one app definition in `homelab-apps` only, pushes
`smores/agent-pr-probe-<stamp>`, enables squash auto-merge as `smores56-agent`,
waits for `apps-schema`, and deletes the branch. It never touches `.github/**`.

### Results

| Probe | Expected | Observed 2026-11-22 |
| --- | --- | --- |
| direct push `main` as agent | refused | `GH013 ... Changes must be made through a pull request.` / `Required status check "apps-schema" is expected.` / `push declined due to repository rule violations` |
| branch push as agent | allowed | `* [new branch] smores/agent-pr-proof` |
| open PR as agent | allowed | PR [#4](https://github.com/smores56/homelab-apps/pull/4) |
| CODEOWNERS | no owner review for the tenant tree | PR #4 touched only one app definition; no approval requested or given |
| `apps-schema` | required, success | `COMPLETED / SUCCESS` |
| auto-merge | enabled and merged by agent | `enabledBy=smores56-agent`, squash, merged `2026-11-22T18:38:17Z` |
| repeatable probe | exits 0 | read-only mode 5/5 checks; `--merge` opened and merged PR [#5](https://github.com/smores56/homelab-apps/pull/5) at `18:40:13Z` |
| broker App identity | retired | `github_app` block, `github-apps` enrollment and the minting code removed 2026-11-22; the broker holds no GitHub credential |

The broker-side `pull_requests: write` gap that the App-era enrollment had is
moot: there is no App and no broker-minted token left, and the shell path above
is the only GitHub write.
