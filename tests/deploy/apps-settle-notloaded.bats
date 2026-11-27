#!/usr/bin/env bats
# bats file_tags=deploy
# A unit that is not loaded is already stopped (§9j).
#
# One file of the suite that was tests/deploy/apps.sh, split so bats can run the
# sections in parallel (a single file is one job). The fakes, the published
# commits, the fixture, the drivers and the assertions are in apps_lib.bash.
#
#   bats tests/deploy/apps-settle-notloaded.bats
load ../helpers
load ./apps_lib

setup_file() { apps_setup_file; }
setup() { apps_setup; }
# --- 9j. a unit that is not loaded is already stopped -----------------------
# The revert stops the apps the failed apply added. systemd exits 5 for a unit it
# never had, and reading that as a failure left the record behind forever.
apply_an_added_app_a_stop_cannot_load() {
    fixture
    run_apply "$c_depart"
    same "$rc" 0 "the single-app revision applies"
    : >"$log/actions"
    set_secrets "$secrets_v1"
    export FAKE_SYSTEMCTL_FAIL_ONCE='start beta.service' FAKE_SYSTEMCTL_NOTLOADED=stop
    run_apply "$c_v1"
    unset FAKE_SYSTEMCTL_FAIL_ONCE FAKE_SYSTEMCTL_NOTLOADED
}

@test "a failed apply still exits 5" {
    apply_an_added_app_a_stop_cannot_load
    assert_equal "$rc" 5
}

@test "the revert stops the added app (§9j)" {
    apply_an_added_app_a_stop_cannot_load
    assert grep -qF 'user stop beta.service' "$log/actions"
}

@test "the revert stops the added app's ingress (§9j)" {
    apply_an_added_app_a_stop_cannot_load
    assert grep -qF 'system stop smortress-app-ingress@beta' "$log/actions"
}

@test "a not-loaded stop completes the revert" {
    apply_an_added_app_a_stop_cannot_load
    assert [ ! -e "$state_dir/apply.json" ]
}

@test "the revert keeps the previous commit recorded (§9j)" {
    apply_an_added_app_a_stop_cannot_load
    assert_equal "$(jq -r '.repos["homelab-apps"].commit' "$state_dir/state.json")" "$c_depart"
}
