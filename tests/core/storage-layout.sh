#!/usr/bin/env bash
# Offline checks for the storage table (SDLC #701, data plane).
#
# The host half — real devices, a real pool, real mounts — is the install in
# docs/manual-steps.md. This proves the half that does not need root: the table
# is the single source of truth, every mountpoint is in the two allowed roots,
# every raw dataset belongs to exactly one restore unit, readiness maps an
# instance back to its dataset, and --print-plan has no side effects.
#
#   tests/core/storage-layout.sh
# shellcheck disable=SC2154  # the table and its helpers come from storage-layout.sh
set -uo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root" || exit 1

pass=0
fail=0
ok() {
  pass=$((pass + 1))
  printf 'ok   %s\n' "$1"
}
bad() {
  fail=$((fail + 1))
  printf 'FAIL %s\n' "$1"
  [[ -n ${2:-} ]] && printf '     %s\n' "${2//$'\n'/$'\n'     }"
  return 0
}
eq() {
  if [[ $1 == "$2" ]]; then ok "$3"; else bad "$3" "got '$1' want '$2'"; fi
}

# shellcheck source=/dev/null
source scripts/storage-layout.sh

eq "$pool" smortress 'the pool is smortress'
eq "${#dataset_order[@]}" "${#dataset_mount[@]}" 'every dataset in the table is in the creation order'

foreign=0
for key in "${dataset_order[@]}"; do
  mountpoint=$(mountpoint_for "$key")
  case $mountpoint in
    /var/srv/* | /var/lib/*) ;;
    *) foreign=$((foreign + 1)) && printf '     outside both roots: %s -> %s\n' "$key" "$mountpoint" ;;
  esac
  [[ $key == raw/* || $key == state/* ]] || foreign=$((foreign + 1))
done
eq "$foreign" 0 'every mountpoint is under /var/srv or /var/lib'

# One raw dataset, one unit: a dataset restored by two units would be
# snapshotted twice with two retention histories.
declare -A seen=()
duplicates=0
for unit in "${units[@]}"; do
  while IFS= read -r key; do
    if [[ -n ${seen[$key]:-} ]]; then
      duplicates=$((duplicates + 1))
      printf '     %s in %s and %s\n' "$key" "${seen[$key]}" "$unit"
    fi
    seen[$key]=$unit
  done < <(unit_keys "$unit")
done
eq "$duplicates" 0 'no dataset belongs to two units'

missing=0
for key in "${dataset_order[@]}"; do
  if [[ -z ${seen[$key]:-} ]]; then
    missing=$((missing + 1))
    printf '     no unit restores %s\n' "$key"
  fi
done
eq "$missing" 0 'every dataset is restored by a unit'

eq "$(unit_keys files)" $'raw/files\nstate/syncthing-config' 'files pairs the vault with Syncthing state'
eq "$(unit_keys photos)" $'raw/photos\nstate/immich-postgres\nstate/immich-dumps' \
  'photos pairs the library with its database and dumps'
eq "$(unit_keys repo-archive)" 'raw/repo-archive' 'repo-archive restores without state'

# Readiness instances are reversible, because a unit file cannot carry a slash.
mapping=0
for key in "${dataset_order[@]}"; do
  instance=$(readiness_instance "$key")
  [[ $(readiness_key "$instance") == "$key" ]] || mapping=$((mapping + 1))
done
eq "$mapping" 0 'readiness instance names map back to their dataset'
eq "$(readiness_key 'photos' || true)" '' 'a slashless instance is rejected'
eq "$(readiness_key 'data-files' || true)" '' 'an unknown kind is rejected'

# The old layout is gone from everything the image ships or the tests read.
# `ansible/`, `provision/` and the retired `apps/data_plane` tests keep their
# historical wording until those paths are deleted.
leftover=$(grep -rl --exclude=storage-migration.md -- '/var/tank\|tank/' \
  scripts units image docs 2>/dev/null || true)
leftover+=$(grep -rl --exclude=storage-layout.sh -- '/var/tank\|tank/' \
  tests/core tests/apps tests/backrest tests/access tests/backup 2>/dev/null || true)
eq "$leftover" '' 'no script, unit, image file, test or doc names /var/tank'

# --print-plan is the plan init-zpool executes, and it must stay side-effect
# free: stub zfs/zpool/blkid fail loudly if anything runs them.
trap 'rm -rf "${tmp:-}"' EXIT
tmp=$(mktemp -d)
for bin in zfs zpool blkid; do
  printf '#!/bin/sh\necho "unexpected %s called" >&2\nexit 99\n' "$bin" >"$tmp/$bin"
  chmod 0755 "$tmp/$bin"
done
if plan=$(PATH="$tmp:$PATH" ZPOOL_DEVICE=/nonexistent scripts/init-zpool.sh --print-plan 2>&1); then
  expected=$(for key in "${dataset_order[@]}"; do printf '%s %s\n' "$(dataset_name "$key")" "$(mountpoint_for "$key")"; done)
  eq "$plan" "$expected" '--print-plan matches the table and runs nothing'
else
  bad '--print-plan matches the table and runs nothing' "$plan"
fi

printf '\n%s checks, %s failed\n' "$((pass + fail))" "$fail"
((fail == 0))
