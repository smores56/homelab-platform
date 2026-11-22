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
# shellcheck disable=SC2154,SC2016  # the table and its helpers come from storage-layout.sh; source text is matched literally
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

quota_orphan=0
for key in "${!dataset_quota[@]}"; do
  [[ -n ${dataset_mount[$key]:-} ]] || {
    quota_orphan=$((quota_orphan + 1))
    printf '     quota on an unknown dataset: %s\n' "$key"
  }
  [[ ${dataset_quota[$key]} =~ ^[0-9]+[KMGT]$ ]] || quota_orphan=$((quota_orphan + 1))
done
eq "$(dataset_owner_for raw/files)" 1000:1000 'core datasets belong to uid 1000'
eq "$(dataset_mode_for raw/files)" 0750 'core datasets are unreadable by the tenant'
eq "${dataset_acl_mode:-}" passthrough 'a chmod cannot discard an operator ACL'
eq "$(dataset_owner_for raw/git)" smores:smores 'the operator owns the git dataset'
eq "$(dataset_owner_for raw/repo-archive)" smores:smores 'the operator owns the repo archive'
eq "$(dataset_owner_for raw/wallpapers)" smores:smores 'the operator owns the wallpapers'
eq "$(dataset_owner_for raw/apps)" apps:apps 'the tenant dataset belongs to the tenant account by name'
eq "$(dataset_mode_for raw/apps)" 0700 'the tenant dataset is private to the tenant'
owner_orphan=0
for key in "${!dataset_root_owner[@]}" "${!dataset_root_mode[@]}"; do
  [[ -n ${dataset_mount[$key]:-} ]] || owner_orphan=$((owner_orphan + 1))
done
eq "$owner_orphan" 0 'every ownership override names a known dataset'
eq "$quota_orphan" 0 'every dataset quota is on a known dataset and well formed'
eq "${dataset_quota[raw/apps]:-}" 200G 'the tenant dataset carries its own quota'

# The table names the tenant account rather than an id, so init-zpool resolves
# it when it chowns. That only works if the account exists by then, and the pool
# unit sets DefaultDependencies=no, so the ordering has to be explicit.
if grep -q '^After=.*systemd-sysusers.service' units/systemd/smortress-zpool.service &&
  grep -q '^Wants=.*systemd-sysusers.service' units/systemd/smortress-zpool.service; then
  ok 'the pool unit is ordered after the account owner exists'
else
  bad 'the pool unit is ordered after the account owner exists' \
    "$(cat units/systemd/smortress-zpool.service)"
fi

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

orphan=0
for key in "${dataset_order[@]}"; do
  parent=${key%%/*}
  [[ " ${dataset_parents[*]} " == *" $parent "* ]] || {
    orphan=1
    printf '     %s has no parent in dataset_parents\n' "$key"
  }
done
eq "$orphan" 0 'every dataset key has a declared parent dataset'

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

# A dataset in no unit is a declared decision, not an omission: state/agent-model
# holds a 4.7 GiB model blob that section 40.7 of the manual re-downloads and
# verifies by checksum. It must be listed in dataset_unrestored and nowhere else.
missing=0
for key in "${dataset_order[@]}"; do
  if [[ " ${dataset_unrestored[*]:-} " == *" $key "* ]]; then
    continue
  fi
  if [[ -z ${seen[$key]:-} ]]; then
    missing=$((missing + 1))
    printf '     no unit restores %s\n' "$key"
  fi
done
eq "$missing" 0 'every dataset is restored by a unit or declared unrestorable'
unrestored_orphan=0
for key in "${dataset_unrestored[@]}"; do
  [[ -n ${dataset_mount[$key]:-} ]] || unrestored_orphan=$((unrestored_orphan + 1))
  [[ -n ${seen[$key]:-} ]] && unrestored_orphan=$((unrestored_orphan + 1))
done
eq "$unrestored_orphan" 0 'a dataset in no unit is known and in no unit'
eq "${dataset_unrestored[0]:-}" state/agent-model 'only the model blob is outside every unit'

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
  tests/core tests/apps tests/backrest tests/access 2>/dev/null || true)
eq "$leftover" '' 'no script, unit, image file, test or doc names /var/tank'

# The declared ACL mode must reach both pool-creation paths, or it is decorative.
eq "$(grep -cF -- '-O aclmode="$dataset_acl_mode"' scripts/init-zpool.sh)" 1 \
  'init-zpool creates the pool with the declared ACL mode'
eq "$(grep -cF 'zfs set "aclmode=$dataset_acl_mode" "$pool"' scripts/init-zpool.sh)" 1 \
  'init-zpool re-asserts the ACL mode on an imported pool'

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

# init-zpool must create the collection datasets before any child: a child
# cannot exist without its parent, and the failure is a bare
# "parent does not exist" on a host that is already in the window.
tmp2=$(mktemp -d)
mkdir -p "$tmp2/bin"
touch "$tmp2/device"
cat >"$tmp2/bin/zfs" <<'SH'
#!/bin/sh
echo "zfs $*" >>"$STUB_LOG"
case $1 in
  list) exit 1 ;;
  *) exit 0 ;;
esac
SH
cat >"$tmp2/bin/zpool" <<'SH'
#!/bin/sh
echo "zpool $*" >>"$STUB_LOG"
case $1 in
  list) exit 1 ;;
  *) exit 0 ;;
esac
SH
for bin in blkid install chown chmod; do
  printf '#!/bin/sh\nexit 0\n' >"$tmp2/bin/$bin"
done
printf '#!/bin/sh\nexit 0\n' >"$tmp2/bin/mountpoint"
chmod 0755 "$tmp2/bin"/*
if STUB_LOG=$tmp2/log PATH="$tmp2/bin:$PATH" ZPOOL_DEVICE=$tmp2/device \
  scripts/init-zpool.sh >/dev/null 2>&1; then
  raw_parent=$(grep -n '^zfs create -o mountpoint=none -o canmount=off smortress/raw$' "$tmp2/log" | cut -d: -f1)
  state_parent=$(grep -n '^zfs create -o mountpoint=none -o canmount=off smortress/state$' "$tmp2/log" | cut -d: -f1)
  first_child=$(grep -n '^zfs create -o canmount=on .* smortress/raw/files$' "$tmp2/log" | cut -d: -f1)
  if [[ -n $raw_parent && -n $state_parent && -n $first_child ]] &&
    ((raw_parent < first_child && state_parent < first_child)); then
    ok 'init-zpool creates the collection datasets before their children'
  else
    bad 'init-zpool creates the collection datasets before their children' "$(cat "$tmp2/log")"
  fi
else
  bad 'init-zpool creates the collection datasets before their children' 'init-zpool failed under stubs'
fi
rm -rf "$tmp2"

printf '\n%s checks, %s failed\n' "$((pass + fail))" "$fail"
((fail == 0))
