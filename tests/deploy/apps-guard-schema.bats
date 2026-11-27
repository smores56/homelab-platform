#!/usr/bin/env bats
# bats file_tags=deploy
# state.json keeps a top-level key it does not know (§16), and an image root is
# not a space floor (the unnumbered tail of the old file).
#
# One file of the suite that was tests/deploy/apps.sh, split so bats can run the
# sections in parallel (a single file is one job). The fakes, the published
# commits, the fixture, the drivers and the assertions are in apps_lib.bash.
#
#   bats tests/deploy/apps-guard-schema.bats
load ../helpers
load ./apps_lib

setup_file() { apps_setup_file; }
setup() { apps_setup; }
# --- 16. state.json keeps a top-level key it does not know -------------------
# state.json has three writers -- the library's state_record_verified, the apps
# apply's state_apps_write and the revert restore -- and four readers. A field a
# newer writer added must survive a round trip through each, or a downgrade
# silently drops it while the readers still expect it.
apply_through_an_unknown_key() {
    fixture
    run_apply "$c_v1"
    jq -c '.future = {added: "by-a-newer-writer"}' "$state_dir/state.json" |
        atomic_write "$state_dir/state.json"
    run_apply "$c_v2"
    kept_rc=$rc
    kept_after_apply=$(jq -r '.future.added' "$state_dir/state.json")
    set_secrets "$secrets_v1b"
    export FAKE_SYSTEMCTL_FAIL_ONCE='restart alpha.service'
    run_apply "$c_v1"
    unset FAKE_SYSTEMCTL_FAIL_ONCE
}

@test "the apply after the unknown key succeeds" {
    apply_through_an_unknown_key
    assert_equal "$kept_rc" 0
}

@test "the apps writer and state_record_verified keep an unknown top-level key" {
    apply_through_an_unknown_key
    assert_equal "$kept_after_apply" by-a-newer-writer
}

@test "the failing apply reverts" {
    apply_through_an_unknown_key
    assert_equal "$rc" 5
}

@test "the revert restore keeps an unknown top-level key" {
    apply_through_an_unknown_key
    assert_equal "$(jq -r '.future.added' "$state_dir/state.json")" by-a-newer-writer
}

# An immutable image root is not a place an apply writes: `df /` there is its own
# 8 MB size, always 0 available, and treating that as a full disk refused every
# apply on a host whose /var had 63G free.
apply_on_a_root() { # <filesystem type> [<mount options>]
    fixture
    printf '/ 0\n' >"$FAKE_DF_MAP"
    printf '/ %s\n' "$1" >"$FAKE_FSTYPE_MAP"
    if [[ -n ${2:-} ]]; then export FAKE_MOUNT_OPTS=$2; fi
    export APPS_FREE_ROOT_PATH=/ APPS_FREE_VAR_PATH=/
    run_apply "$c_v1"
    unset FAKE_MOUNT_OPTS
}

@test "an immutable root is not a space floor" {
    apply_on_a_root composefs
    refute grep -q 'below the' <<<"$out"
}

# On this host `findmnt` reports `overlay` for the composefs root; it is not a
# writable disk and must not refuse an apply.
@test "an overlay root is not a space floor" {
    apply_on_a_root overlay
    refute grep -q 'below the' <<<"$out"
}

# A writable overlay is an ordinary disk; the zero-free floor still applies.
@test "a writable overlay root still refuses the apply" {
    apply_on_a_root overlay rw
    assert grep -q 'below the' <<<"$out"
}

# The same zero free on an ordinary root is still refused.
@test "a full ordinary root refuses the apply" {
    apply_on_a_root ext4
    assert_equal "$rc" 4
}

@test "the refusal names the space floor" {
    apply_on_a_root ext4
    assert grep -q 'below the' <<<"$out"
}
