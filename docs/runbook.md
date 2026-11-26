# Runbook

The GitHub settings an operator applies by hand. Everything else an operator
runs is `docs/manual-steps.md`; what the host is and why is `docs/README.md`.

## Branch protection on `main` (blocked: 403)

PR required with CODEOWNERS review, required CI checks, linear history, no
force-push, no deletion, conversation resolution. `enforce_admins` stays false so
the owner can bootstrap; the machine user and every other account are bound.

```sh
gh api -X PUT repos/smores56/homelab-platform/branches/main/protection --input - <<'JSON'
{
  "required_status_checks": {
    "strict": true,
    "contexts": [
      "docs",
      "lint",
      "tofu plan",
      "apps-schema",
      "action SHA pins",
      "CODEOWNERS coverage",
      "policy checks",
      "policy admission runtime",
      "fork-pr-secret-boundary"
    ]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": true,
    "required_approving_review_count": 1
  },
  "restrictions": null,
  "required_linear_history": true,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_conversation_resolution": true
}
JSON
```

Recorded response:

```json
{"message":"Resource not accessible by personal access token","documentation_url":"https://docs.github.com/rest/branches/branch-protection#get-branch-protection","status":403}
```

(The GET and PUT endpoints returned the same 403; the PUT was not attempted
after the GET proved the token lacks the scope.)

Verify once an admin token is used:

```sh
gh api repos/smores56/homelab-platform/branches/main/protection --jq \
  '{required_status_checks: .required_status_checks.contexts,
    reviews: .required_pull_request_reviews.require_code_owner_reviews,
    linear: .required_linear_history.enabled,
    force_push: .allow_force_pushes.enabled,
    deletions: .allow_deletions.enabled}'
```

Expected: `require_code_owner_reviews == true`, `linear == true`,
`force_push == false`, `deletions == false`, and the ten contexts above.

## Repo settings (blocked: 403)

Read-only default token for every workflow, forks get no write token, and
private vulnerability reporting on.

```sh
# Actions enabled, only GitHub-owned + verified Marketplace actions allowed.
gh api -X PUT repos/smores56/homelab-platform/actions/permissions --input - <<'JSON'
{"enabled":true,"allowed_actions":"selected","sha_pinning_required":true,
 "selected_actions_url":"https://api.github.com/repos/smores56/homelab-platform/actions/permissions/selected-actions"}
JSON
gh api -X PUT repos/smores56/homelab-platform/actions/permissions/selected-actions --input - <<'JSON'
{"github_owned_allowed":true,"verified_allowed":true}
JSON

# Default GITHUB_TOKEN is read-only and cannot approve PRs.
gh api -X PUT repos/smores56/homelab-platform/actions/permissions/workflow \
  -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false

# Every fork PR run waits for an owner approval; fork runs get a read-only token.
gh api -X PUT repos/smores56/homelab-platform/actions/permissions/fork-pr-contributor-approval \
  -f approval_policy=all_external_contributors

# Private vulnerability reporting.
gh api -X PUT repos/smores56/homelab-platform/private-vulnerability-reporting --input - <<<'{}'
```

Recorded responses:

- `GET /actions/permissions`, `/actions/permissions/workflow`,
  `/actions/permissions/fork-pr-contributor-approval`:
  `{"message":"Resource not accessible by personal access token","documentation_url":"https://docs.github.com/rest/actions/permissions#get-github-actions-permissions-for-a-repository","status":403}`
- `PATCH /repos/smores56/homelab-platform`:
  `{"message":"Resource not accessible by personal access token","documentation_url":"https://docs.github.com/rest/repos/repos#update-a-repository","status":403}`

Current state from the same token: repo is private,
`default_branch == "main"`, `allow_forking == true`, and the owner has `admin`,
so the endpoints above are scope failures, not plan failures.

Verify once an admin token is used:

```sh
gh api repos/smores56/homelab-platform/actions/permissions/workflow
gh api repos/smores56/homelab-platform/actions/permissions/fork-pr-contributor-approval
gh api repos/smores56/homelab-platform/private-vulnerability-reporting
```

Expected: `{"default_workflow_permissions":"read","can_approve_pull_request_reviews":false}`,
`{"approval_policy":"all_external_contributors"}`, and `{"enabled":true}`.

## Scheduled sanity checks

```sh
bats --jobs "$(nproc)" $(git ls-files 'tests/*.bats' 'tests/*/*.bats') # every suite; CI runs them per area
bats tests/lint.bats                # action pins, secret boundary, CODEOWNERS, yamllint, shellcheck
```

All of the above pass on `main`; see `docs/negative-tests.md` for the fork-PR
boundary and `docs/manual-steps.md` for the owner-only steps.
