#!/usr/bin/env bats
# bats file_tags=deploy
# A manager that cannot be asked, and a healthy settle window (§9h-§9i).
#
# One file of the suite that was tests/deploy/apps.sh, split so bats can run the
# sections in parallel (a single file is one job). The fakes, the published
# commits, the fixture, the drivers and the assertions are in apps_lib.bash.
#
#   bats tests/deploy/apps-settle-health.bats
load ../helpers
load ./apps_lib

setup_file() { apps_setup_file; }
setup() { apps_setup; }
# --- 9h. a manager that cannot be asked never reads as healthy ---------------
apply_with_an_unreachable_manager() {
    fixture
    run_apply "$c_v1"
    set_secrets "$secrets_v1b"
    export FAKE_SHOW_DOWN=1
    run_apply "$c_v2"
    unset FAKE_SHOW_DOWN
}

@test "an app whose state cannot be read is not committed" {
    apply_with_an_unreachable_manager
    assert_equal "$rc" 5
}

@test "the unknown state is journaled" {
    apply_with_an_unreachable_manager
    assert_equal "$(journal_field apps-unhealthy '.state')" unknown
}

# --- 9i. a healthy app survives a real settle window ------------------------
apply_through_a_settle_window() {
    fixture
    run_apply "$c_v1"
    set_secrets "$secrets_v1b"
    export APPS_HEALTH_SETTLE=2
    run_apply "$c_v2"
}

@test "a healthy app applies through the settle window" {
    apply_through_a_settle_window
    assert_equal "$rc" 0
}

@test "no health verdict is journaled" {
    apply_through_a_settle_window
    assert_equal "$(journal_field apps-unhealthy '.app')" ""
}
