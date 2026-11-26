#!/usr/bin/env bats
# bats file_tags=core
# Offline checks for the storage table (SDLC #701, data plane).
#
# The host half — real devices, a real pool, real mounts — is the install in
# docs/manual-steps.md. This proves the half that does not need root: the table
# is the single source of truth, every mountpoint is in the two allowed roots,
# every raw dataset belongs to exactly one restore unit, readiness maps an
# instance back to its dataset, and --print-plan has no side effects.
load ../helpers

# bats sources a test file, and runs setup, inside a function, so the table's
# `declare -A` arrays would be local to it and gone by the test body. Every test
# sources the table itself, which also names the dependency it exercises.

@test "the pool is smortress" {
    # shellcheck source=/dev/null
    source scripts/storage-layout.sh
    assert_equal "$pool" smortress
}

@test "every dataset in the table is in the creation order" {
    # shellcheck source=/dev/null
    source scripts/storage-layout.sh
    assert_equal "${#dataset_order[@]}" "${#dataset_mount[@]}"
}

@test "core datasets belong to uid 1000" {
    # shellcheck source=/dev/null
    source scripts/storage-layout.sh
    assert_equal "$(dataset_owner_for raw/files)" 1000:1000
}

@test "core datasets are unreadable by the tenant" {
    # shellcheck source=/dev/null
    source scripts/storage-layout.sh
    assert_equal "$(dataset_mode_for raw/files)" 0750
}

@test "a chmod cannot discard an operator ACL" {
    # shellcheck source=/dev/null
    source scripts/storage-layout.sh
    assert_equal "${dataset_acl_mode:-}" passthrough
}

@test "the operator owns the git dataset" {
    # shellcheck source=/dev/null
    source scripts/storage-layout.sh
    assert_equal "$(dataset_owner_for raw/git)" smores:smores
}

@test "the operator owns the repo archive" {
    # shellcheck source=/dev/null
    source scripts/storage-layout.sh
    assert_equal "$(dataset_owner_for raw/repo-archive)" smores:smores
}

@test "the operator owns the wallpapers" {
    # shellcheck source=/dev/null
    source scripts/storage-layout.sh
    assert_equal "$(dataset_owner_for raw/wallpapers)" smores:smores
}

@test "the tenant dataset belongs to the tenant account by name" {
    # shellcheck source=/dev/null
    source scripts/storage-layout.sh
    assert_equal "$(dataset_owner_for raw/apps)" apps:apps
}

@test "the tenant dataset is private to the tenant" {
    # shellcheck source=/dev/null
    source scripts/storage-layout.sh
    assert_equal "$(dataset_mode_for raw/apps)" 0700
}

@test "every ownership override names a known dataset" {
    # shellcheck source=/dev/null
    source scripts/storage-layout.sh
    orphans=''
    for key in "${!dataset_root_owner[@]}" "${!dataset_root_mode[@]}"; do
        [[ -n ${dataset_mount[$key]:-} ]] || orphans="$orphans $key"
    done
    [[ -z $orphans ]] || printf 'override on an unknown dataset:%s\n' "$orphans" >&2
    assert_equal "$orphans" ""
}

@test "every dataset quota is on a known dataset and well formed" {
    # shellcheck source=/dev/null
    source scripts/storage-layout.sh
    orphans=''
    for key in "${!dataset_quota[@]}"; do
        [[ -n ${dataset_mount[$key]:-} ]] || orphans="$orphans $key(unknown)"
        [[ ${dataset_quota[$key]} =~ ^[0-9]+[KMGT]$ ]] || orphans="$orphans $key(${dataset_quota[$key]})"
    done
    [[ -z $orphans ]] || printf 'bad quota:%s\n' "$orphans" >&2
    assert_equal "$orphans" ""
}

@test "the tenant dataset carries its own quota" {
    # shellcheck source=/dev/null
    source scripts/storage-layout.sh
    assert_equal "${dataset_quota[raw/apps]:-}" 200G
}

# The table names the tenant account rather than an id, so init-zpool resolves
# it when it chowns. That only works if the account exists by then, and the pool
# unit sets DefaultDependencies=no, so the ordering has to be explicit.
@test "the pool unit is ordered after the account owner exists" {
    # shellcheck source=/dev/null
    source scripts/storage-layout.sh
    run grep -E '^After=.*systemd-sysusers.service' units/systemd/smortress-zpool.service
    assert_success
    run grep -E '^Wants=.*systemd-sysusers.service' units/systemd/smortress-zpool.service
    assert_success
}

@test "every mountpoint is under /var/srv or /var/lib" {
    # shellcheck source=/dev/null
    source scripts/storage-layout.sh
    foreign=''
    for key in "${dataset_order[@]}"; do
        mountpoint=$(mountpoint_for "$key")
        case $mountpoint in
            /var/srv/* | /var/lib/*) ;;
            *) foreign="$foreign $key->$mountpoint" ;;
        esac
        [[ $key == raw/* || $key == state/* ]] || foreign="$foreign $key"
    done
    [[ -z $foreign ]] || printf 'outside both roots:%s\n' "$foreign" >&2
    assert_equal "$foreign" ""
}

@test "every dataset key has a declared parent dataset" {
    # shellcheck source=/dev/null
    source scripts/storage-layout.sh
    orphans=''
    for key in "${dataset_order[@]}"; do
        parent=${key%%/*}
        [[ " ${dataset_parents[*]} " == *" $parent "* ]] || orphans="$orphans $key"
    done
    [[ -z $orphans ]] || printf 'no declared parent:%s\n' "$orphans" >&2
    assert_equal "$orphans" ""
}

# One raw dataset, one unit: a dataset restored by two units would be
# snapshotted twice with two retention histories.
@test "no dataset belongs to two units" {
    # shellcheck source=/dev/null
    source scripts/storage-layout.sh
    declare -A seen=()
    duplicates=''
    for unit in "${units[@]}"; do
        while IFS= read -r key; do
            [[ -z ${seen[$key]:-} ]] || duplicates="$duplicates $key"
            seen[$key]=$unit
        done < <(unit_keys "$unit")
    done
    [[ -z $duplicates ]] || printf 'in two units:%s\n' "$duplicates" >&2
    assert_equal "$duplicates" ""
}

# A dataset in no unit is a declared decision, not an omission: state/agent-model
# holds a 4.7 GiB model blob that section 40.7 of the manual re-downloads and
# verifies by checksum. It must be listed in dataset_unrestored and nowhere else.
@test "every dataset is restored by a unit or declared unrestorable" {
    # shellcheck source=/dev/null
    source scripts/storage-layout.sh
    declare -A seen=()
    for unit in "${units[@]}"; do
        while IFS= read -r key; do
            seen[$key]=$unit
        done < <(unit_keys "$unit")
    done
    missing=''
    for key in "${dataset_order[@]}"; do
        [[ " ${dataset_unrestored[*]:-} " == *" $key "* ]] && continue
        [[ -n ${seen[$key]:-} ]] || missing="$missing $key"
    done
    [[ -z $missing ]] || printf 'no unit restores:%s\n' "$missing" >&2
    assert_equal "$missing" ""
}

@test "a dataset in no unit is known and in no unit" {
    # shellcheck source=/dev/null
    source scripts/storage-layout.sh
    declare -A seen=()
    for unit in "${units[@]}"; do
        while IFS= read -r key; do
            seen[$key]=$unit
        done < <(unit_keys "$unit")
    done
    orphans=''
    for key in "${dataset_unrestored[@]}"; do
        [[ -n ${dataset_mount[$key]:-} ]] || orphans="$orphans $key"
        [[ -z ${seen[$key]:-} ]] || orphans="$orphans $key"
    done
    [[ -z $orphans ]] || printf 'unrestorable but restored or unmounted:%s\n' "$orphans" >&2
    assert_equal "$orphans" ""
}

@test "the model blob and the name service state carry no restore unit" {
    # shellcheck source=/dev/null
    source scripts/storage-layout.sh
    assert_equal "${dataset_unrestored[0]:-}" state/agent-model
}

@test "files pairs the vault with Syncthing state" {
    # shellcheck source=/dev/null
    source scripts/storage-layout.sh
    assert_equal "$(unit_keys files)" $'raw/files\nstate/syncthing-config'
}

@test "photos pairs the library with its database and dumps" {
    # shellcheck source=/dev/null
    source scripts/storage-layout.sh
    assert_equal "$(unit_keys photos)" $'raw/photos\nstate/immich-postgres\nstate/immich-dumps'
}

@test "repo-archive restores without state" {
    # shellcheck source=/dev/null
    source scripts/storage-layout.sh
    assert_equal "$(unit_keys repo-archive)" raw/repo-archive
}

# Readiness instances are reversible, because a unit file cannot carry a slash.
@test "readiness instance names map back to their dataset" {
    # shellcheck source=/dev/null
    source scripts/storage-layout.sh
    mapping=''
    for key in "${dataset_order[@]}"; do
        instance=$(readiness_instance "$key")
        [[ $(readiness_key "$instance") == "$key" ]] || mapping="$mapping $key"
    done
    [[ -z $mapping ]] || printf 'does not map back:%s\n' "$mapping" >&2
    assert_equal "$mapping" ""
}

@test "a slashless instance is rejected" {
    # shellcheck source=/dev/null
    source scripts/storage-layout.sh
    run readiness_key 'photos'
    assert_output ""
}

@test "an unknown kind is rejected" {
    # shellcheck source=/dev/null
    source scripts/storage-layout.sh
    run readiness_key 'data-files'
    assert_output ""
}

# The old layout is gone from everything the image ships or the tests read.
# `provision/` and the retired `apps/data_plane` tests keep their historical
# wording until those paths are deleted.
@test "no script, unit, image file, test or doc names /var/tank" {
    # shellcheck source=/dev/null
    source scripts/storage-layout.sh
    leftover=$(grep -rl --exclude=storage-migration.md -- '/var/tank\|tank/' \
        scripts units image docs 2>/dev/null || true)
    leftover+=$(grep -rl --exclude=storage-layout.bats -- '/var/tank\|tank/' \
        tests/core tests/apps tests/backrest 2>/dev/null || true)
    assert_equal "$leftover" ""
}

# The declared ACL mode must reach both pool-creation paths, or it is decorative.
@test "init-zpool creates the pool with the declared ACL mode" {
    # shellcheck source=/dev/null
    source scripts/storage-layout.sh
    run grep -cF -- '-O aclmode="$dataset_acl_mode"' scripts/init-zpool.sh
    assert_output "1"
}

@test "init-zpool re-asserts the ACL mode on an imported pool" {
    # shellcheck source=/dev/null
    source scripts/storage-layout.sh
    run grep -cF 'zfs set "aclmode=$dataset_acl_mode" "$pool"' scripts/init-zpool.sh
    assert_output "1"
}

# --print-plan is the plan init-zpool executes, and it must stay side-effect
# free: stub zfs/zpool/blkid fail loudly if anything runs them.
@test "--print-plan matches the table and runs nothing" {
    # shellcheck source=/dev/null
    source scripts/storage-layout.sh
    for bin in zfs zpool blkid; do
        printf '#!/bin/sh\necho "unexpected %s called" >&2\nexit 99\n' "$bin" >"$BATS_TEST_TMPDIR/$bin"
        chmod 0755 "$BATS_TEST_TMPDIR/$bin"
    done
    expected=$(for key in "${dataset_order[@]}"; do
        printf '%s %s\n' "$(dataset_name "$key")" "$(mountpoint_for "$key")"
    done)
    run env PATH="$BATS_TEST_TMPDIR:$PATH" ZPOOL_DEVICE=/nonexistent \
        scripts/init-zpool.sh --print-plan
    assert_success
    assert_output "$expected"
}

# init-zpool must create the collection datasets before any child: a child
# cannot exist without its parent, and the failure is a bare
# "parent does not exist" on a host that is already in the window.
@test "init-zpool creates the collection datasets before their children" {
    # shellcheck source=/dev/null
    source scripts/storage-layout.sh
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    touch "$BATS_TEST_TMPDIR/device"
    cat >"$BATS_TEST_TMPDIR/bin/zfs" <<'SH'
#!/bin/sh
echo "zfs $*" >>"$STUB_LOG"
case $1 in
  list) exit 1 ;;
  *) exit 0 ;;
esac
SH
    cat >"$BATS_TEST_TMPDIR/bin/zpool" <<'SH'
#!/bin/sh
echo "zpool $*" >>"$STUB_LOG"
case $1 in
  list) exit 1 ;;
  *) exit 0 ;;
esac
SH
    for bin in blkid install chown chmod; do
        printf '#!/bin/sh\nexit 0\n' >"$BATS_TEST_TMPDIR/bin/$bin"
    done
    printf '#!/bin/sh\nexit 0\n' >"$BATS_TEST_TMPDIR/bin/mountpoint"
    chmod 0755 "$BATS_TEST_TMPDIR/bin"/*

    run env STUB_LOG="$BATS_TEST_TMPDIR/log" PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
        ZPOOL_DEVICE="$BATS_TEST_TMPDIR/device" scripts/init-zpool.sh
    assert_success
    raw_parent=$(grep -n '^zfs create -o mountpoint=none -o canmount=off smortress/raw$' "$BATS_TEST_TMPDIR/log" | cut -d: -f1)
    state_parent=$(grep -n '^zfs create -o mountpoint=none -o canmount=off smortress/state$' "$BATS_TEST_TMPDIR/log" | cut -d: -f1)
    first_child=$(grep -n '^zfs create -o canmount=on .* smortress/raw/files$' "$BATS_TEST_TMPDIR/log" | cut -d: -f1)
    if [[ -n $raw_parent && -n $state_parent && -n $first_child ]] &&
        ((raw_parent < first_child && state_parent < first_child)); then
        ordered=true
    else
        cat "$BATS_TEST_TMPDIR/log" >&2
        ordered=false
    fi
    assert "$ordered"
}
