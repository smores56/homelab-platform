#!/usr/bin/env bats
# bats file_tags=deploy
# The apps apply and its revert: the settle window, the retries and the not-loaded unit (§9e-§9j).
#
# One file of the suite that was tests/deploy/apps.sh, split so bats can run the
# sections in parallel (a single file is one job). The fakes, the published
# commits, the fixture, the drivers and the assertions are in apps_lib.bash.
#
#   bats tests/deploy/apps-settle.bats
load ../helpers
load ./apps_lib

setup_file() { apps_setup_file; }
setup() { apps_setup; }
# --- 9e. an app that crashes after it starts is not committed ----------------
# Restart= brings a crashed container back fast enough that every sample can
# still read `active`; NRestarts moving past its baseline is the evidence.
apply_an_app_that_restarts() {
    fixture
    run_apply "$c_v1"
    same "$rc" 0 "the two-app revision applies"
    set_secrets "$secrets_v1b"
    export FAKE_UNIT_RESTART=alpha.service APPS_HEALTH_SETTLE=2
    run_apply "$c_v2"
    unset FAKE_UNIT_RESTART
}

@test "an app restarted inside the settle window exits 5" {
    apply_an_app_that_restarts
    assert_equal "$rc" 5
}

@test "the restarted unit is journaled" {
    apply_an_app_that_restarts
    assert_equal "$(journal_field apps-unhealthy '.unit')" alpha.service
}

@test "the restart is journaled as the verdict" {
    apply_an_app_that_restarts
    assert_equal "$(journal_field apps-unhealthy '.state')" restarted
}

# --- 9f. a slow start is not a crash ----------------------------------------
apply_a_slow_start() {
    fixture
    run_apply "$c_v1"
    set_secrets "$secrets_v1b"
    export FAKE_UNIT_SLOW=alpha.service
    run_apply "$c_v2"
    unset FAKE_UNIT_SLOW
}

@test "an app that comes up late still applies" {
    apply_a_slow_start
    assert_equal "$rc" 0
}

# --- 9g. a transport blip is asked again, not judged -------------------------
apply_through_a_probe_blip() {
    fixture
    run_apply "$c_v1"
    set_secrets "$secrets_v1b"
    export FAKE_SHOW_TRANSPORT_ONCE=1
    run_apply "$c_v2"
    unset FAKE_SHOW_TRANSPORT_ONCE
}

@test "one unreachable probe does not fail the apply" {
    apply_through_a_probe_blip
    assert_equal "$rc" 0
}

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
