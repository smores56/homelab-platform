#!/usr/bin/env bats
# bats file_tags=deploy
# A manager that is gone is not already stopped (§9k).
#
# One file of the suite that was tests/deploy/apps.sh, split so bats can run the
# sections in parallel (a single file is one job). The fakes, the published
# commits, the fixture, the drivers and the assertions are in apps_lib.bash.
#
#   bats tests/deploy/apps-manager-gone.bats
load ../helpers
load ./apps_lib

setup_file() { apps_setup_file; }
setup() { apps_setup; }
# --- 9k. a manager that is gone is not "already stopped" --------------------
# The other side of the same mapping: an unreachable manager must fail the
# revert and keep the record, or the next boot believes the host is consistent.
revert_through_a_dead_manager() {
    fixture
    run_apply "$c_depart"
    set_secrets "$secrets_v1"
    export FAKE_SYSTEMCTL_FAIL_ONCE='start beta.service'
    export FAKE_SYSTEMCTL_TRANSPORT='stop beta.service'
    run_apply "$c_v1"
    unset FAKE_SYSTEMCTL_FAIL_ONCE FAKE_SYSTEMCTL_TRANSPORT
}

@test "an unreachable manager still exits 5" {
    revert_through_a_dead_manager
    assert_equal "$rc" 5
}

@test "a failed revert keeps the record" {
    revert_through_a_dead_manager
    assert [ -s "$state_dir/apply.json" ]
}

@test "the failed revert says why" {
    revert_through_a_dead_manager
    assert_equal "$(journal_field apps-revert-failed '.reason' | tail -n 1)" restore-incomplete
}

@test "the failed revert pages the deploy check" {
    revert_through_a_dead_manager
    assert_equal "$(tail -n 1 "$log/notify-urls")" "$ping_url/fail"
}
