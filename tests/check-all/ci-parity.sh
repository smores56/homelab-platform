#!/usr/bin/env bash
# Every check-all group must be reachable from a workflow, unless it is named
# here as local-only, and every job that runs the gate must install the runner
# the gate calls. Keeps the driver and CI from drifting apart.
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

# The groups' commands are bats-backed, so a job that runs the gate without the
# pinned tools fails on the runner as `bats: command not found` instead of on
# the branch. That is how thirteen jobs went red when the last shell groups
# converted (2026-11-26): the table changed and the job steps did not. A job
# that already installs the tools itself (tofu, secrets, gates) says so by
# calling the same script, which is why this needs no exemption list.
awk '
  FNR == 1 { in_jobs = 0; job = "" }
  /^[^[:space:]#]/ { in_jobs = ($0 ~ /^jobs:/); job = ""; next }
  in_jobs && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
    job = FILENAME " " $1
    sub(/:$/, "", job)
    next
  }
  in_jobs && job != "" {
    if ($0 ~ /scripts\/check-all\.sh/) gate[job] = 1
    if ($0 ~ /scripts\/install-ci-tools\.sh/) tools[job] = 1
  }
  END {
    bad = 0
    for (j in gate) {
      if (j in tools) continue
      printf "FAIL %s runs the gate without scripts/install-ci-tools.sh\n", j > "/dev/stderr"
      bad = 1
    }
    exit bad
  }
' .github/workflows/*.yml || exit 1
printf 'ok   every job that runs the gate installs the pinned tools\n'
