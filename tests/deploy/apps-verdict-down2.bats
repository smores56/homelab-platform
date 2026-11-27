#!/usr/bin/env bats
# bats file_tags=deploy
# An app that does not come up is not committed (§9c, tests 7-12).
#
# One file of the suite that was tests/deploy/apps.sh, split so bats can run the
# sections in parallel (a single file is one job). The fakes, the published
# commits, the fixture, the drivers and the assertions are in apps_lib.bash.
#
#   bats tests/deploy/apps-verdict-down2.bats
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

@test "the revert restores the previous plan (§9c)" {
    apply_an_app_that_stays_down
    assert_equal "$(sha "$APPS_PLAN")" "$plan_before"
}

@test "the revert restores the previous unit (§9c)" {
    apply_an_app_that_stays_down
    assert_equal "$(sha "$APPS_UNIT_DIR/alpha.container")" "$unit_before"
}

@test "the revert restores the previous secret" {
    apply_an_app_that_stays_down
    assert_equal "$(cat "$secret_store/app-alpha-api-key")" one
}

@test "the revert restores the previous state (§9c)" {
    apply_an_app_that_stays_down
    assert_equal "$(sha "$state_dir/state.json")" "$state_before"
}

@test "the revert clears the crash record (§9c)" {
    apply_an_app_that_stays_down
    assert [ ! -e "$state_dir/apply.json" ]
}

@test "the unhealthy apply pages the deploy check" {
    apply_an_app_that_stays_down
    assert_equal "$(tail -n 1 "$log/notify-urls")" "$ping_url/fail"
}
