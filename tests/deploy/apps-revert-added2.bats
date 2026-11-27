#!/usr/bin/env bats
# bats file_tags=deploy
# A revert removes the app the failed apply added (§9b, tests 5-7).
#
# One file of the suite that was tests/deploy/apps.sh, split so bats can run the
# sections in parallel (a single file is one job). The fakes, the published
# commits, the fixture, the drivers and the assertions are in apps_lib.bash.
#
#   bats tests/deploy/apps-revert-added2.bats
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

@test "the revert stops the added app's ingress" {
    apply_an_added_app_that_fails
    assert grep -qF 'system stop smortress-app-ingress@beta' "$log/actions"
}

@test "the revert keeps the previous commit recorded" {
    apply_an_added_app_that_fails
    assert_equal "$(jq -r '.repos["homelab-apps"].commit' "$state_dir/state.json")" "$c_depart"
}

@test "the previous app's unit stays" {
    apply_an_added_app_that_fails
    assert [ -s "$APPS_UNIT_DIR/alpha.container" ]
}
