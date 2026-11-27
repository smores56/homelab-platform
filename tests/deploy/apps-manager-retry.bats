#!/usr/bin/env bats
# bats file_tags=deploy
# Transport blips and connection resets are retried (§9l-§9m).
#
# One file of the suite that was tests/deploy/apps.sh, split so bats can run the
# sections in parallel (a single file is one job). The fakes, the published
# commits, the fixture, the drivers and the assertions are in apps_lib.bash.
#
#   bats tests/deploy/apps-manager-retry.bats
load ../helpers
load ./apps_lib

setup_file() { apps_setup_file; }
setup() { apps_setup; }
# --- 9l. a transport blip on a control call is asked again ------------------
apply_through_a_restart_blip() {
    fixture
    run_apply "$c_v1"
    same "$rc" 0 "the two-app revision applies"
    set_secrets "$secrets_v1b"
    export FAKE_SYSTEMCTL_TRANSPORT_ONCE='restart alpha.service'
    run_apply "$c_v2"
    unset FAKE_SYSTEMCTL_TRANSPORT_ONCE
}

@test "a transport blip on restart does not fail the apply" {
    apply_through_a_restart_blip
    assert_equal "$rc" 0
}

@test "the restart is retried once" {
    apply_through_a_restart_blip
    assert_equal "$(grep -c 'user restart alpha.service' "$log/actions")" 2
}

# --- 9m. a connection reset on a control call is asked again ----------------
apply_through_a_reset() {
    fixture
    run_apply "$c_v1"
    same "$rc" 0 "the two-app revision applies"
    set_secrets "$secrets_v1b"
    export FAKE_SYSTEMCTL_RESET_ONCE='restart alpha.service'
    run_apply "$c_v2"
    unset FAKE_SYSTEMCTL_RESET_ONCE
}

@test "a connection reset on restart does not fail the apply" {
    apply_through_a_reset
    assert_equal "$rc" 0
}

@test "the restart is retried after a reset" {
    apply_through_a_reset
    assert_equal "$(grep -c 'user restart alpha.service' "$log/actions")" 2
}
