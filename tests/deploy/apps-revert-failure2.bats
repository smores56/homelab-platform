#!/usr/bin/env bats
# bats file_tags=deploy
# A failure mid-apply reverts units, plan, secrets and state (§9, tests 8-13).
#
# One file of the suite that was tests/deploy/apps.sh, split so bats can run the
# sections in parallel (a single file is one job). The fakes, the published
# commits, the fixture, the drivers and the assertions are in apps_lib.bash.
#
#   bats tests/deploy/apps-revert-failure2.bats
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

@test "the failed apply is journaled" {
    apply_a_failure_mid_apply
    assert_equal "$(journal_field apps-failed '.commit')" "$c_v2"
}

@test "the revert is journaled" {
    apply_a_failure_mid_apply
    assert_equal "$(journal_field apps-reverted '.commit')" "$c_v2"
}

@test "the restored app is restarted" {
    apply_a_failure_mid_apply
    assert grep -qF 'user restart alpha.service' "$log/actions"
}

@test "Serve is regenerated for the restored plan" {
    apply_a_failure_mid_apply
    assert grep -qF 'system restart smortress-tailscale-serve.service' "$log/actions"
}

@test "a reverted apply pages the deploy check" {
    apply_a_failure_mid_apply
    assert_equal "$(tail -n 1 "$log/notify-urls")" "$ping_url/fail"
}

@test "the restore ran as the tenant" {
    apply_a_failure_mid_apply
    assert grep -qF 'user restart alpha.service' "$log/actions"
}
