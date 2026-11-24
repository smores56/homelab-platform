#!/usr/bin/env bash
# Every check-all group must be reachable from a workflow, unless it is named
# here as local-only. Keeps the driver and CI from drifting apart.
#
#   tests/check-all/ci-parity.sh
set -euo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root" || exit 1

local_only="edge actionlint"
fail=0

groups=$(scripts/check-all.sh --list | awk '{print $1}' | sort)
referenced=$(
  grep -rhoE 'check-all\.sh --only [A-Za-z0-9_,-]+' .github/workflows |
    sed 's/.*--only //' | tr ',' '\n' | sort -u
)

while IFS= read -r g; do
  [[ -n $g ]] || continue
  if grep -Fqx -- "$g" <<<"$referenced"; then
    continue
  fi
  case " $local_only " in
    *" $g "*) continue ;;
  esac
  printf 'FAIL %s is neither called by a workflow nor local-only\n' "$g" >&2
  fail=1
done <<<"$groups"

for g in $local_only; do
  if ! grep -Fqx -- "$g" <<<"$groups"; then
    printf 'FAIL local-only group %s does not exist\n' "$g" >&2
    fail=1
  fi
  if grep -Fqx -- "$g" <<<"$referenced"; then
    printf 'FAIL %s is now called by a workflow; drop it from local_only\n' "$g" >&2
    fail=1
  fi
done

if ((fail)); then
  exit 1
fi
printf 'ok   every group is called by a workflow or explicitly local-only\n'
