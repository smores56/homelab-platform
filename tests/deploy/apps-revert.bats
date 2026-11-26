#!/usr/bin/env bats
# bats file_tags=deploy
# The apps apply and its revert: a departure and the revert of a failed apply (§8-§9b).
#
# One file of the suite that was tests/deploy/apps.sh, split so bats can run the
# sections in parallel (a single file is one job). The fakes, the published
# commits, the fixture, the drivers and the assertions are in apps_lib.bash.
#
#   bats tests/deploy/apps-revert.bats
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

@test "the departed app is stopped" {
    apply_a_departed_app
    assert grep -qF 'user stop beta.service' "$log/actions"
}

@test "the departed app's ingress is stopped" {
    apply_a_departed_app
    assert grep -qF 'system stop smortress-app-ingress@beta' "$log/actions"
}

@test "Serve is regenerated so the departed route is pruned" {
    apply_a_departed_app
    assert grep -qF 'system restart smortress-tailscale-serve.service' "$log/actions"
}

@test "the plan keeps only the remaining app" {
    apply_a_departed_app
    assert_equal "$(jq -r '.apps | keys | join(" ")' "$APPS_PLAN")" alpha
}

@test "state keeps only the remaining app" {
    apply_a_departed_app
    assert_equal "$(jq -r '.apps.apps | keys | join(" ")' "$state_dir/state.json")" alpha
}

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
