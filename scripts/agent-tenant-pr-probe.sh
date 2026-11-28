#!/usr/bin/env bash
# Proves the tenant's agent path (SDLC #710 follow-up).
#
# The default mode is read-only: it checks the token identity, the collaborator
# role, the live ruleset, auto-merge, and that the machine user cannot push
# `main`. `--merge` additionally pushes an app-only branch, opens a pull
# request as the machine user, enables auto-merge, and waits for the required
# `apps-schema` check to land it. That mode mutates `homelab-apps`, so it is
# manual and never part of CI: CI must not carry the token.
#
# The token is `~/.config/smores56-agent/token` (classic `repo` PAT, mode 0600),
# documented in hosts/server/runbook.md,
# "The machine user and its scoped token". The probe never prints it and
# never lets the owner's credential helper authenticate as `smores56`.
#
# usage: scripts/agent-tenant-pr-probe.sh [--merge]
# Exit status: 0 when every check passed, 1 on a failed check, 2 on usage.
set -euo pipefail

repo=smores56/homelab-apps
token_file=${SMORES56_AGENT_TOKEN_FILE:-$HOME/.config/smores56-agent/token}
merge=false

usage() {
  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
}

die() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

case ${1:-} in
  '') ;;
  --merge) merge=true ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

[[ -r $token_file ]] || die "token not readable: $token_file (hosts/server/runbook.md, "The machine user and its scoped token")"
[[ $(stat -c %a "$token_file") == 600 ]] || die "token mode is not 0600: $token_file"
token=$(<"$token_file")
[[ -n $token ]] || die "token file is empty: $token_file"

for tool in gh jq git; do
  command -v "$tool" >/dev/null || die "$tool not on PATH"
done

work=$(mktemp -d "${TMPDIR:-/tmp}/agent-tenant-pr-probe.XXXXXX")
cat >"$work/askpass.sh" <<EOF
#!/bin/sh
cat "$token_file"
EOF
chmod 700 "$work/askpass.sh"
mkdir -p "$work/home"
trap 'rm -rf -- "$work"' EXIT

gitm() {
  env -i PATH=/usr/bin:/bin HOME="$work/home" GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null GIT_ASKPASS="$work/askpass.sh" \
    GIT_TERMINAL_PROMPT=0 git -c credential.helper= \
    -c user.name='smores56 agent' \
    -c user.email='smores56-agent@users.noreply.github.com' "$@"
}

ghm() {
  GH_TOKEN=$token gh "$@"
}

say() {
  printf 'ok   %s\n' "$*"
}

# Identity and role.
login=$(ghm api user --jq .login)
[[ $login == smores56-agent ]] || die "token authenticates as $login, not smores56-agent"
say "token identity is smores56-agent"

# role_name is authoritative: GitHub omits the `permissions` object when the
# collaborator reads their own permission, and an admin would read `admin`.
perm=$(ghm api "repos/$repo/collaborators/smores56-agent/permission")
role=$(jq -r .role_name <<<"$perm")
[[ $role == write ]] || die "collaborator role is $role, not write"
say "collaborator role is write (not admin or maintain)"

# Ruleset: a pull request with the apps-schema check, on the default branch.
ruleset=$(ghm api "repos/$repo/rulesets/27783878")
[[ $(jq -r .enforcement <<<"$ruleset") == active ]] || die "ruleset 27783878 is not active"
jq -e '[.rules[].type] | index("pull_request") != null' >/dev/null <<<"$ruleset" ||
  die "ruleset does not require a pull request"
jq -e '.rules[] | select(.type=="required_status_checks") |
  .parameters.required_status_checks[] | select(.context=="apps-schema")' >/dev/null <<<"$ruleset" ||
  die "ruleset does not require apps-schema"
jq -e '.conditions.ref_name.include | index("~DEFAULT_BRANCH") != null' >/dev/null <<<"$ruleset" ||
  die "ruleset does not target the default branch"
say "ruleset requires a PR and the apps-schema check"

settings=$(ghm api "repos/$repo")
auto=$(jq -r .allow_auto_merge <<<"$settings")
[[ $auto == true ]] || die "auto-merge is disabled on $repo"
say "auto-merge is enabled"

# Direct push to main is the control. The push is refused, so it creates
# nothing remote; run it with every owner credential helper disabled.
(
  cd "$work"
  gitm clone --quiet --depth 1 "https://x-access-token@github.com/$repo.git" probe
  cd probe
  gitm commit --quiet --allow-empty -m 'agent tenant direct-push probe'
  if out=$(gitm push origin HEAD:main 2>&1); then
    die "push to main succeeded; the tenant main ruleset is not enforcing"
  fi
  grep -q 'push declined due to repository rule violations' <<<"$out" ||
    die "push to main failed for an unexpected reason: $out"
)
say "direct push to main is refused by the repository rules"

if ! $merge; then
  printf '\nread-only checks passed; rerun with --merge for the PR and auto-merge proof\n'
  exit 0
fi

# The full proof: an app-only change, pushed and merged by the machine user.
stamp=$(date -u +%Y%m%dT%H%M%SZ)
branch="smores/agent-pr-probe-$stamp"
(
  cd "$work"
  rm -rf -- probe
  gitm clone --quiet --depth 1 "https://x-access-token@github.com/$repo.git" probe
  cd probe

  app=apps/smoke/app.toml
  marker='# agent-tenant-pr-probe'
  if grep -q "^$marker" "$app"; then
    sed -i "s|^$marker.*|$marker $stamp|" "$app"
  else
    printf '\n%s %s\n' "$marker" "$stamp" >>"$app"
  fi
  gitm add "$app"
  gitm commit --quiet -m "chore(apps): agent tenant PR probe $stamp"
  gitm push origin "HEAD:refs/heads/$branch"
)

pr_url=$(ghm pr create --repo "$repo" --head "$branch" --base main \
  --title "chore(apps): agent tenant PR probe $stamp" \
  --body "App-only probe from \`scripts/agent-tenant-pr-probe.sh\`; no \`.github/**\` change.")
pr=${pr_url##*/}
say "opened $pr_url as smores56-agent"

ghm pr merge "$pr" --repo "$repo" --squash --auto >/dev/null
say "enabled squash auto-merge as smores56-agent"

state=''
for _ in $(seq 1 60); do
  state=$(ghm pr view "$pr" --repo "$repo" \
    --json state,mergedAt,statusCheckRollup,autoMergeRequest)
  [[ $(jq -r .state <<<"$state") == MERGED ]] && break
  sleep 10
done

if [[ $(jq -r .state <<<"$state") != MERGED ]]; then
  ghm pr close "$pr" --repo "$repo" --delete-branch >/dev/null 2>&1 || true
  die "PR $pr did not auto-merge within 600s: $(jq -c '{state,statusCheckRollup}' <<<"$state")"
fi

jq -e '.statusCheckRollup[] | select(.name=="apps-schema" and .conclusion=="SUCCESS")' \
  >/dev/null <<<"$state" || die "apps-schema did not pass: $state"
[[ $(jq -r '.autoMergeRequest.enabledBy.login' <<<"$state") == smores56-agent ]] ||
  die "auto-merge was not enabled by smores56-agent: $state"
say "apps-schema passed and auto-merge landed PR $pr at $(jq -r .mergedAt <<<"$state")"

# The squash merge leaves the head branch unless the repository deletes on
# merge; remove it either way so the probe is repeatable.
ghm api -X DELETE "repos/$repo/git/refs/heads/$branch" >/dev/null 2>&1 || true
say "deleted probe branch $branch"
