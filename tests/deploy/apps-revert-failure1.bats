#!/usr/bin/env bats
# bats file_tags=deploy
# A failure mid-apply reverts units, plan, secrets and state (§9, tests 1-7).
#
# One file of the suite that was tests/deploy/apps.sh, split so bats can run the
# sections in parallel (a single file is one job). The fakes, the published
# commits, the fixture, the drivers and the assertions are in apps_lib.bash.
#
#   bats tests/deploy/apps-revert-failure1.bats
load ../helpers
load ./apps_lib

setup_file() { apps_setup_file; }
setup() { apps_setup; }
# --- 9. a failure mid-apply reverts units, plan, secrets and state -----------
apply_a_failure_mid_apply() {
    fixture
    run_apply "$c_v1"
    plan_before=$(sha "$APPS_PLAN")
    unit_before=$(sha "$APPS_UNIT_DIR/alpha.container")
    state_before=$(sha "$state_dir/state.json")
    : >"$log/actions"
    set_secrets "$secrets_v1b"
    export FAKE_SYSTEMCTL_FAIL_ONCE='restart alpha.service'
    run_apply "$c_v2"
    unset FAKE_SYSTEMCTL_FAIL_ONCE
}

@test "a failure mid-apply exits 5 after the revert" {
    apply_a_failure_mid_apply
    assert_equal "$rc" 5
}

@test "the revert restores the previous plan" {
    apply_a_failure_mid_apply
    assert_equal "$(sha "$APPS_PLAN")" "$plan_before"
}

@test "the revert restores the previous unit" {
    apply_a_failure_mid_apply
    assert_equal "$(sha "$APPS_UNIT_DIR/alpha.container")" "$unit_before"
}

@test "the revert restores the previous secret value" {
    apply_a_failure_mid_apply
    assert_equal "$(cat "$secret_store/app-alpha-api-key")" one
}

@test "the revert keeps the untouched secret" {
    apply_a_failure_mid_apply
    assert_equal "$(cat "$secret_store/app-beta-beta-key")" beta-one
}

@test "the revert restores the previous state" {
    apply_a_failure_mid_apply
    assert_equal "$(sha "$state_dir/state.json")" "$state_before"
}

@test "the revert clears the crash record" {
    apply_a_failure_mid_apply
    assert [ ! -e "$state_dir/apply.json" ]
}
