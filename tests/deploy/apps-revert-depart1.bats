#!/usr/bin/env bats
# bats file_tags=deploy
# A departed app loses its unit, secret and Serve route (§8, tests 1-5).
#
# One file of the suite that was tests/deploy/apps.sh, split so bats can run the
# sections in parallel (a single file is one job). The fakes, the published
# commits, the fixture, the drivers and the assertions are in apps_lib.bash.
#
#   bats tests/deploy/apps-revert-depart1.bats
load ../helpers
load ./apps_lib

setup_file() { apps_setup_file; }
setup() { apps_setup; }
# --- 8. a departed app loses its unit, its secret and its Serve route --------
apply_a_departed_app() {
    fixture
    run_apply "$c_v1"
    : >"$log/actions"
    run_apply "$c_depart"
}

@test "a commit that removes an app applies" {
    apply_a_departed_app
    assert_equal "$rc" 0
}

@test "the departed unit is removed" {
    apply_a_departed_app
    assert [ ! -e "$APPS_UNIT_DIR/beta.container" ]
}

@test "the remaining unit stays" {
    apply_a_departed_app
    assert [ -s "$APPS_UNIT_DIR/alpha.container" ]
}

@test "the departed app's secret is removed" {
    apply_a_departed_app
    assert [ ! -e "$secret_store/app-beta-beta-key" ]
}

@test "the remaining secret stays" {
    apply_a_departed_app
    assert [ -s "$secret_store/app-alpha-api-key" ]
}
