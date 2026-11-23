#!/usr/bin/env bash
# Runs the pre-commit checks in parallel and can narrow them to the paths a
# branch changed. This table is the source of truth; AGENTS.md points here.
#
# usage: scripts/check-all.sh [--list] [--changed[=BASE] | --paths-from FILE]
#                             [--only a,b] [--jobs N] [--timeout SECS] [--dry-run]
#                             [--check-claims]
#
# --changed selects groups from `git diff BASE` plus untracked files, and runs
# everything when a changed path no group claims. --paths-from reads that file
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
broker|python3 -m unittest discover -s apps/broker/tests -t apps/broker|apps/broker/*
webhook|python3 -m unittest discover -s apps/webhook/tests -t apps/webhook|apps/webhook/*
agent-proxy|python3 -m unittest discover -s apps/agent_proxy/tests -t apps/agent_proxy|apps/agent_proxy/*
agent-facade|python3 -m unittest discover -s apps/agent_facade/tests -t apps|apps/agent_facade/*
backrest|if ! npm --version >/dev/null 2>&1; then d="${XDG_CACHE_HOME:-$HOME/.cache}/check-all/node"; mkdir -p "$d"; for t in node npm npx; do printf '#!/bin/sh\nexec mise x node@22.23.5 -- %s "$@"\n' "$t" > "$d/$t"; chmod +x "$d/$t"; done; PATH="$d:$PATH"; export PATH; fi; npm ci --prefix backrest && npm --prefix backrest run typecheck && npm --prefix backrest test && tests/backrest/check.sh|backrest/*
tofu-check|tests/tofu/check.sh|tests/tofu/*,tofu/*
tofu-fmt|tofu fmt -check -recursive tofu|tofu/*
provision|tests/provision/check.sh|tests/provision/*,provision/*
docs|python3 scripts/check-doc-refs.py|*.md,docs/*,scripts/check-doc-refs.py,scripts/doc-refs-baseline.txt
secrets|tests/secrets/policy.sh && tests/secrets/migration.sh && tests/secrets/decrypt.sh && tests/secrets/bundles.sh && tests/secrets/rotate.sh && python3 scripts/sops-policy.py check --repo . && python3 scripts/secrets-check.py --shadow && python3 scripts/secrets-check.py|secrets/*,.sops.yaml,scripts/sops-policy.py,tests/secrets/*
server-image|scripts/check-server-image.sh && scripts/render-ignition.sh --synthetic --check && tests/core/ignition-boundary.sh && scripts/render-ignition.sh --synthetic --stock --check|scripts/lib/*,image/*,ignition/*,units/*,images/*,tests/fixtures/*,docs/core/server-image.md,scripts/check-server-image.sh
edge|tests/edge/check.sh|tests/edge/*,scripts/verify-public-edge.sh
core|tests/core/check.sh && tests/core/storage-layout.sh && tests/core/restic-drill.sh && tests/core/tailscale-serve.sh && tests/core/apps-egress.sh && tests/core/apps-user.sh && tests/core/agent-drill.sh|tests/core/*,scripts/core/*,scripts/access-*
apps|tests/apps/check.sh && tests/apps/render.sh && tests/apps/quota.sh && tests/apps/ingress.sh|tests/apps/*,scripts/apps-*
recovery-page|deno=deno; if ! deno --version >/dev/null 2>&1; then deno="mise x deno@2.9.8 -- deno"; fi; cd apps/recovery-page && $deno task typecheck && $deno task test|apps/recovery-page/*
deploy|tests/deploy/state.sh && tests/deploy/receiver.sh && tests/deploy/verify.sh && tests/deploy/platform.sh && tests/deploy/boot.sh && tests/deploy/apps.sh && tests/deploy/apps-health.sh && tests/deploy/notify.sh && tests/deploy/poll.sh && tests/deploy/heartbeat.sh|tests/deploy/*,scripts/deploy-*,scripts/smortress-boot-gate.sh,scripts/smortress-apps-health.sh
data-plane|scripts/render-source-schemas.py --check && tests/data-plane/check.sh|tests/data-plane/*,apps/data_plane/*,libs/data_plane/*,scripts/render-source-schemas.py,recovery/*,deploy/data-plane/*
tuta-calendar|venv="${XDG_CACHE_HOME:-$HOME/.cache}/check-all/tuta-calendar"; if [ ! -x "$venv/bin/python" ]; then python3 -m venv "$venv" && "$venv/bin/pip" install -q --disable-pip-version-check -r images/tuta-calendar/requirements.lock; fi; PATH="$venv/bin:$PATH" tests/tuta-calendar/check.sh|tests/tuta-calendar/*,apps/tuta_calendar/*
agent-egress|tests/agent-egress/check.sh|tests/agent-egress/*,apps/agent_egress/*
brave|tests/brave/check.sh|tests/brave/*,apps/brave_ingest/*
lint|yamllint -c .yamllint.yaml $(git ls-files '*.yaml' '*.yml') provision/smortress/user-data && shellcheck scripts/*.sh tests/tofu/*.sh tests/access/*.sh tests/tuta-calendar/*.sh tests/agent-egress/*.sh tests/brave/*.sh provision/*/*.sh tests/provision/*.sh scripts/lib/*.sh scripts/legacy/*.sh tests/core/*.sh backrest/scripts/*.sh backrest/container/entrypoint.sh tests/backrest/*.sh tests/apps/*.sh tests/deploy/*.sh tests/edge/*.sh tests/check-all/*.sh .githooks/* && scripts/check-action-pins.sh && scripts/check-pr-secret-boundary.sh && scripts/check-codeowners.sh && tests/check-all/ci-parity.sh && git diff --check "${BASE:-origin/main}"|.github/*,CODEOWNERS,.sops.yaml,.yamllint.yaml,scripts/*,tests/*,provision/*,backrest/*,.githooks/*,recovery/*
actionlint|actionlint|.github/*
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
