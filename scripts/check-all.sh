#!/usr/bin/env bash
# Runs the pre-commit checks in parallel and can narrow them to the paths a
# branch changed. This table is the source of truth; AGENTS.md points here.
#
# usage: scripts/check-all.sh [--list] [--changed[=BASE] | --paths-from FILE]
#                             [--only a,b] [--jobs N] [--timeout SECS] [--dry-run]
#                             [--check-claims]
#
# --changed selects groups from `git diff BASE` plus untracked files, and runs
# everything when a changed path no group claims. A converted suite passes
# --jobs 4 so one file uses the same four slots a group does. --paths-from reads that file
# list from a file instead, which the self-test uses.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

list=false
dry_run=false
check_claims=false
changed=false
paths_from=''
base=origin/main
only=''
jobs=4
limit=900

while (($#)); do
  case $1 in
    --list) list=true ;;
    --dry-run) dry_run=true ;;
    --check-claims) check_claims=true ;;
    --changed) changed=true ;;
    --changed=*) changed=true; base=${1#*=} ;;
    --paths-from) paths_from=${2:?--paths-from needs a file}; shift ;;
    --paths-from=*) paths_from=${1#*=} ;;
    --only) only=${2:?--only needs a value}; shift ;;
    --only=*) only=${1#*=} ;;
    --jobs) jobs=${2:?--jobs needs a value}; shift ;;
    --jobs=*) jobs=${1#*=} ;;
    --timeout) limit=${2:?--timeout needs a value}; shift ;;
    --timeout=*) limit=${1#*=} ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'check-all: unknown option %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

names=()
cmds=()
paths=()
while IFS='|' read -r name cmd pathlist; do
  [[ -n $name ]] || continue
  names+=("$name")
  cmds+=("$cmd")
  paths+=("$pathlist")
done <<'EOF'
broker|bats --jobs 4 tests/python/broker.bats|apps/broker/*
webhook|bats --jobs 4 tests/python/webhook.bats|apps/webhook/*
agent-proxy|bats --jobs 4 tests/python/agent-proxy.bats|apps/agent_proxy/*
agent-facade|bats --jobs 4 tests/python/agent-facade.bats|apps/agent_facade/*
agent-shell-bridge|bats --jobs 4 tests/agent-shell-bridge/check.bats|tests/agent-shell-bridge/*,scripts/agent-shell-bridge.py
backrest|if ! npm --version >/dev/null 2>&1; then d="${XDG_CACHE_HOME:-$HOME/.cache}/check-all/node"; mkdir -p "$d"; for t in node npm npx; do printf '#!/bin/sh\nexec mise x node@22.23.5 -- %s "$@"\n' "$t" > "$d/$t"; chmod +x "$d/$t"; done; PATH="$d:$PATH"; export PATH; fi; npm ci --prefix backrest && npm --prefix backrest run typecheck && npm --prefix backrest test && bats --jobs 4 tests/backrest/check.bats|backrest/*
tofu-check|bats --jobs 4 tests/tofu/check.bats|tests/tofu/*,tofu/*,scripts/check-tofu-providers.py
tofu-fmt|bats --jobs 4 tests/tofu-fmt.bats|tofu/*
provision|bats --jobs 4 tests/provision/check.bats|tests/provision/*,provision/*
docs|bats --jobs 4 tests/docs.bats|*.md,docs/*,scripts/check-doc-refs.py,scripts/doc-refs-baseline.txt
secrets|bats --jobs 4 tests/secrets/policy.bats && bats --jobs 4 tests/secrets/migration.bats && bats --jobs 4 tests/secrets/decrypt.bats && bats --jobs 4 tests/secrets/bundles.bats && bats --jobs 4 tests/secrets/rotate.bats && bats --jobs 4 tests/secrets/cloudflare-derive.bats && python3 scripts/sops-policy.py check --repo . && python3 scripts/secrets-check.py --shadow && python3 scripts/secrets-check.py|secrets/*,.sops.yaml,scripts/sops-policy.py,scripts/secrets-check.py,scripts/secrets-index.py,scripts/secrets-bundle.py,scripts/secrets-bundles.json,scripts/secret.sh,scripts/cloudflare-derive.sh,scripts/smortress-secrets-seed.sh,bootc/server/rootfs/usr/share/smortress/secrets.manifest,tests/secrets/*
server-image|bats --jobs 4 tests/image/server-image.bats && bats --jobs 4 tests/image/ignition-boundary.bats && bats --jobs 4 tests/image/edge-image.bats|scripts/lib/*,scripts/check/server/*,bootc/server/*,bootc/edge/*,bootc/lib/*,ignition/*,units/*,images/*,tests/fixtures/*,docs/core/server-image.md,scripts/check-server-image.sh,tests/image/*
edge|bats --jobs 4 tests/edge/check.bats|tests/edge/*,scripts/verify-public-edge.sh,scripts/verify-caa.sh
tailnet-names|bats --jobs 4 tests/tailnet-names/check.bats|tests/tailnet-names/*,scripts/verify-tailnet-names.sh
core|bats --jobs 4 tests/core/check.bats && bats --jobs 4 tests/core/storage-layout.bats && bats --jobs 4 tests/tags.bats && bats --jobs 4 tests/core/restic-drill.bats && bats --jobs 4 tests/core/tailscale-serve.bats && bats --jobs 4 tests/core/apps-egress.bats && bats --jobs 4 tests/core/apps-user.bats && bats --jobs 4 tests/core/agent-drill.bats && bats --jobs 4 tests/core/operator-access.bats && bats --jobs 4 tests/core/restic-plane.bats && bats --jobs 4 tests/core/app-quadlets.bats && bats --jobs 4 tests/core/smortress-restic-progress.bats && bats --jobs 4 tests/core/agent-recovery.bats && bats --jobs 4 tests/core/agent-jobs.bats|tests/core/*,tests/tags.*,tests/helpers.bash,scripts/core/*,scripts/access-*,scripts/storage-layout.sh,scripts/init-zpool.sh,units/systemd/smortress-zpool.service,units/*,bootc/server/*
apps|bats --jobs 4 tests/apps/check.bats && bats --jobs 4 tests/apps/render.bats && bats --jobs 4 tests/apps/quota.bats && bats --jobs 4 tests/apps/ingress.bats && bats --jobs 4 tests/apps/ingress-reconcile.bats|tests/apps/*,scripts/apps-*
deploy|bats --jobs 4 tests/deploy/state.bats && bats --jobs 4 tests/deploy/atomic.bats && bats --jobs 4 --no-parallelize-within-files tests/deploy/receiver.bats && bats --jobs 4 tests/deploy/apps.bats && bats --jobs 4 tests/deploy/verify.bats && bats --jobs 4 tests/deploy/platform.bats && bats --jobs 4 tests/deploy/boot.bats && bats --jobs 4 tests/deploy/apps-health.bats && bats --jobs 4 tests/deploy/notify.bats && bats --jobs 4 tests/deploy/poll.bats && bats --jobs 4 tests/deploy/heartbeat.bats|tests/deploy/*,scripts/deploy-*,scripts/deploy/apps/*,bootc/server/rootfs/usr/libexec/deploy-verify.py,bootc/server/rootfs/usr/libexec/deploy-receiver.py,scripts/smortress-boot-gate.sh,scripts/smortress-apps-health.sh
data-plane|bats --jobs 4 tests/data-plane/check.bats|tests/data-plane/*,apps/data_plane/*,libs/data_plane/*,scripts/render-source-schemas.py,recovery/*,deploy/data-plane/*
tuta-calendar|bats --jobs 4 tests/tuta-calendar/check.bats|tests/tuta-calendar/*,apps/tuta_calendar/*
agent-egress|bats --jobs 4 tests/agent-egress/check.bats|tests/agent-egress/*,apps/agent_egress/*
brave|bats --jobs 4 tests/brave/check.bats|tests/brave/*,apps/brave_ingest/*
lint|bats --jobs 4 tests/lint.bats|.github/*,CODEOWNERS,.sops.yaml,.yamllint.yaml,scripts/*,tests/*,provision/*,backrest/*,.githooks/*,recovery/*
actionlint|bats --jobs 4 tests/actionlint.bats|.github/*
EOF

if $list; then
  for i in "${!names[@]}"; do
    printf '%-16s %s\n' "${names[i]}" "${cmds[i]}"
  done
  exit 0
fi

tmp=''
claim_file=''
BASE=$base
export BASE
cleanup() {
  [[ -n $tmp ]] && rm -rf "$tmp"
  [[ -n $claim_file ]] && rm -f "$claim_file"
  return 0
}
trap cleanup EXIT

if [[ -n $paths_from ]]; then
  [[ -r $paths_from ]] || { printf 'check-all: cannot read %s\n' "$paths_from" >&2; exit 2; }
  claim_file=$paths_from
elif $changed; then
  git rev-parse --verify -q "$base^{commit}" >/dev/null || {
    printf 'check-all: no such base %s\n' "$base" >&2
    exit 2
  }
  # The merge base, not the tip: a branch behind main must not select the
  # groups for commits it does not contain.
  compare=$(git merge-base "$base" HEAD) || {
    printf 'check-all: %s has no merge base with HEAD\n' "$base" >&2
    exit 2
  }
  BASE=$compare
  claim_file=$(mktemp)
  { git diff --name-only "$compare"
    git ls-files --others --exclude-standard; } >"$claim_file"
fi

group_matches() {  # group_matches <index>: does any changed path match its set?
  local i=$1
  local f p
  local -a pats
  IFS=, read -ra pats <<<"${paths[i]}"
  while IFS= read -r f; do
    for p in "${pats[@]}"; do
      # shellcheck disable=SC2254 # the patterns are globs by design
      case $f in $p) return 0 ;; esac
    done
  done <"$claim_file"
  return 1
}

claimed() {  # claimed <path>: does any group or the doc exemption cover it?
  local f=$1 p
  local -a pats=('*.md' 'docs/*' 'README.md' '*.mdx' '.gitignore' 'LICENSE')
  for i in "${!names[@]}"; do
    local -a extra
    IFS=, read -ra extra <<<"${paths[i]}"
    pats+=("${extra[@]}")
  done
  for p in "${pats[@]}"; do
    # shellcheck disable=SC2254 # the patterns are globs by design
    case $f in $p) return 0 ;; esac
  done
  return 1
}

unclaimed() {
  local f
  while IFS= read -r f; do
    claimed "$f" || { printf '%s\n' "$f"; return 0; }
  done <"$claim_file"
  return 1
}

# --check-claims proves the other direction: every tracked file is covered by
# a group (or the doc exemption), so a new tree cannot fall through silently.
if $check_claims; then
  claim_file=$(mktemp)
  git ls-files >"$claim_file"
  bad=0
  while IFS= read -r f; do
    claimed "$f" || { printf 'unclaimed: %s\n' "$f"; bad=1; }
  done <"$claim_file"
  exit "$bad"
fi

selected=()
if [[ -n $claim_file ]]; then
  if stray=$(unclaimed) && [[ -n $stray ]]; then
    printf 'check-all: %s is unclaimed; running every group\n' "$stray" >&2
    for i in "${!names[@]}"; do selected+=("$i"); done
  else
    for i in "${!names[@]}"; do
      group_matches "$i" && selected+=("$i")
    done
  fi
else
  for i in "${!names[@]}"; do selected+=("$i"); done
fi

if [[ -n $only ]]; then
  filtered=()
  for i in "${selected[@]}"; do
    [[ ",$only," == *",${names[i]},"* ]] && filtered+=("$i")
  done
  selected=("${filtered[@]}")
fi

if $dry_run; then
  for i in "${selected[@]}"; do printf '%s\n' "${names[i]}"; done
  exit 0
fi

if ((${#selected[@]} == 0)); then
  printf 'check-all: no group covers the changed paths\n'
  exit 0
fi

tmp=$(mktemp -d)
start=$(date +%s)
printf 'check-all: %d group(s), %d job(s)\n' "${#selected[@]}" "$jobs"

run_group() {
  local i=$1
  local name=${names[i]}
  local log=$tmp/${name}.log
  local rc=0
  local began
  began=$(date +%s)
  if command -v timeout >/dev/null 2>&1; then
    timeout "$limit" bash -c "${cmds[i]}" >"$log" 2>&1 || rc=$?
  else
    bash -c "${cmds[i]}" >"$log" 2>&1 || rc=$?
  fi
  printf '%s %s\n' "$rc" "$(( $(date +%s) - began ))" >"$tmp/$name.status"
}

running=0
for i in "${selected[@]}"; do
  run_group "$i" &
  running=$((running + 1))
  if ((running >= jobs)); then
    wait -n || true
    running=$((running - 1))
  fi
done
wait || true

failed=0
for i in "${selected[@]}"; do
  name=${names[i]}
  read -r rc secs <"$tmp/$name.status" || { rc=1; secs=0; }
  if ((rc == 0)); then
    printf 'ok   %-16s %ss\n' "$name" "$secs"
  else
    failed=$((failed + 1))
    printf 'FAIL %-16s %ss\n' "$name" "$secs"
    tail -n 40 "$tmp/$name.log" | sed 's/^/     /'
  fi
done
printf '\n%d group(s) in %ss, %d failed\n' \
  "${#selected[@]}" "$(( $(date +%s) - start ))" "$failed"
((failed == 0))
