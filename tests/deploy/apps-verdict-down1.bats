#!/usr/bin/env bats
# bats file_tags=deploy
# An app that does not come up is not committed (§9c, tests 1-6).
#
# One file of the suite that was tests/deploy/apps.sh, split so bats can run the
# sections in parallel (a single file is one job). The fakes, the published
# commits, the fixture, the drivers and the assertions are in apps_lib.bash.
#
#   bats tests/deploy/apps-verdict-down1.bats
load ../helpers
load ./apps_lib

setup_file() { apps_setup_file; }
setup() { apps_setup; }
# --- 9c. an app that does not come up is not committed -----------------------
# The next boot's gate would find the unit inactive and roll back the platform
# image, so an apply may not commit a revision whose apps are not running.
apply_an_app_that_stays_down() {
    fixture
    run_apply "$c_v1"
    same "$rc" 0 "the two-app revision applies"
    plan_before=$(sha "$APPS_PLAN")
    unit_before=$(sha "$APPS_UNIT_DIR/alpha.container")
    state_before=$(sha "$state_dir/state.json")
    : >"$log/actions"
    set_secrets "$secrets_v1b"
    export FAKE_UNIT_INACTIVE=alpha.service
    run_apply "$c_v2"
    unset FAKE_UNIT_INACTIVE
}

@test "an app that stays down exits 5 after the revert" {
    apply_an_app_that_stays_down
    assert_equal "$rc" 5
}

@test "the unhealthy app is named" {
    apply_an_app_that_stays_down
    assert_equal "$(journal_field apps-unhealthy '.app')" alpha
}

@test "the unhealthy unit is journaled" {
    apply_an_app_that_stays_down
    assert_equal "$(journal_field apps-unhealthy '.unit')" alpha.service
}

@test "the state systemd reported is journaled" {
    apply_an_app_that_stays_down
    assert_equal "$(journal_field apps-unhealthy '.state')" inactive
}

@test "the failure names health, not a mutation" {
    apply_an_app_that_stays_down
    assert_equal "$(journal_field apps-failed '.reason' | tail -n 1)" app-unhealthy
}

@test "the down app does not commit its revision" {
    apply_an_app_that_stays_down
    assert_equal "$(jq -r '.repos["homelab-apps"].commit' "$state_dir/state.json")" "$c_v1"
}
