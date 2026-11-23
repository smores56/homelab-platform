#!/usr/bin/env bash
# The pre-commit driver's selection logic: no cluster, no credentials.
#   tests/check-all/check.sh
set -uo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root" || exit 1

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$*"; }
no() { fail=$((fail + 1)); printf 'FAIL %s\n' "$*" >&2; }
expect() {
  if [[ $2 == "$3" ]]; then ok "$1"; else no "$1 (want '$2', got '$3')"; fi
}

groups=$(scripts/check-all.sh --list | wc -l | tr -d ' ')
selected() {
  printf '%s\n' "$@" >"$work/paths"
  scripts/check-all.sh --paths-from "$work/paths" --dry-run
}

expect "a broker change selects the broker tests" "broker" \
  "$(selected apps/broker/server.py)"
expect "a data-plane change selects its check and lint" $'data-plane\nlint' \
  "$(selected tests/data-plane/check.sh)"
expect "a recovery-inventory change selects the data-plane tests and lint" \
  $'data-plane\nlint' "$(selected recovery/inventory.yml)"
expect "a rendered recovery-group manifest change selects the data-plane tests" \
  "data-plane" "$(selected deploy/data-plane/config/recovery-groups.json)"
expect "a deployed source schema change selects the data-plane tests" \
  "data-plane" "$(selected deploy/data-plane/config/sources/brave.json)"
expect "a data-plane library change selects the data-plane tests" \
  "data-plane" "$(selected libs/data_plane/collectors/raw/mail.py)"
expect "a schema renderer change selects the data-plane tests and lint" \
  $'data-plane\nlint' "$(selected scripts/render-source-schemas.py)"
expect "a workflow change selects lint and actionlint" $'lint\nactionlint' \
  "$(selected .github/workflows/ci.yml)"
expect "a docs change selects the docs group" "docs" \
  "$(selected README.md docs/broker.md)"
expect "an image change selects the server-image group" "server-image" \
  "$(selected image/Containerfile)"
expect "a unit change selects the server-image group" "server-image" \
  "$(selected units/quadlet/pattern.container)"
expect "a secret change selects the secrets group" "secrets" \
  "$(selected secrets/boot.json)"
expect "a recovery-page change selects its group" "recovery-page" \
  "$(selected apps/recovery-page/src/main.ts)"
expect "a config change selects secrets and lint" $'secrets\nlint' \
  "$(selected .sops.yaml)"
expect "every tracked file is claimed" "0" \
  "$(scripts/check-all.sh --check-claims >/dev/null; echo $?)"
expect "an unclaimed path selects every group" "$groups" \
  "$(selected brand/new-thing | wc -l | tr -d ' ')"
expect "--list names each group once" "$groups" \
  "$(scripts/check-all.sh --list | cut -f1 | sort -u | wc -l | tr -d ' ')"
expect "--only keeps one group" "broker" \
  "$(printf 'apps/broker/x\n' >"$work/paths"; \
     scripts/check-all.sh --paths-from "$work/paths" --only broker,webhook --dry-run)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
