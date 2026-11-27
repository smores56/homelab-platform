#!/usr/bin/env bats
# bats file_tags=deploy
# A crash, a slow start and a probe blip (§9e-§9g).
#
# One file of the suite that was tests/deploy/apps.sh, split so bats can run the
# sections in parallel (a single file is one job). The fakes, the published
# commits, the fixture, the drivers and the assertions are in apps_lib.bash.
#
#   bats tests/deploy/apps-settle-crash.bats
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
