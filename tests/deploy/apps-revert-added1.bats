#!/usr/bin/env bats
# bats file_tags=deploy
# A revert removes the app the failed apply added (§9b, tests 1-4).
#
# One file of the suite that was tests/deploy/apps.sh, split so bats can run the
# sections in parallel (a single file is one job). The fakes, the published
# commits, the fixture, the drivers and the assertions are in apps_lib.bash.
#
#   bats tests/deploy/apps-revert-added1.bats
load ../helpers
load ./apps_lib

setup_file() { apps_setup_file; }
setup() { apps_setup; }
# --- 9b. a revert removes the app the failed apply added ---------------------
apply_an_added_app_that_fails() {
    fixture
    run_apply "$c_depart"
    same "$rc" 0 "the single-app revision applies"
    : >"$log/actions"
    set_secrets "$secrets_v1"
    export FAKE_SYSTEMCTL_FAIL_ONCE='start beta.service'
    run_apply "$c_v1"
    unset FAKE_SYSTEMCTL_FAIL_ONCE
}

@test "an added app that fails to start rolls back" {
    apply_an_added_app_that_fails
    assert_equal "$rc" 5
}

@test "the revert removes the added unit" {
    apply_an_added_app_that_fails
    assert [ ! -e "$APPS_UNIT_DIR/beta.container" ]
}

@test "the revert removes the added secret" {
    apply_an_added_app_that_fails
    assert [ ! -e "$secret_store/app-beta-beta-key" ]
}

@test "the revert stops the added app" {
    apply_an_added_app_that_fails
    assert grep -qF 'user stop beta.service' "$log/actions"
}
