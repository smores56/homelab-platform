#!/usr/bin/env bats
# bats file_tags=deploy
# The apps apply and its revert: a manager that is gone, a retried control call, a Serve failure (§9k-§10).
#
# One file of the suite that was tests/deploy/apps.sh, split so bats can run the
# sections in parallel (a single file is one job). The fakes, the published
# commits, the fixture, the drivers and the assertions are in apps_lib.bash.
#
#   bats tests/deploy/apps-manager.bats
load ../helpers
load ./apps_lib

setup_file() { apps_setup_file; }
setup() { apps_setup; }
# --- 9k. a manager that is gone is not "already stopped" --------------------
# The other side of the same mapping: an unreachable manager must fail the
# revert and keep the record, or the next boot believes the host is consistent.
revert_through_a_dead_manager() {
    fixture
    run_apply "$c_depart"
    set_secrets "$secrets_v1"
    export FAKE_SYSTEMCTL_FAIL_ONCE='start beta.service'
    export FAKE_SYSTEMCTL_TRANSPORT='stop beta.service'
    run_apply "$c_v1"
    unset FAKE_SYSTEMCTL_FAIL_ONCE FAKE_SYSTEMCTL_TRANSPORT
}

@test "an unreachable manager still exits 5" {
    revert_through_a_dead_manager
    assert_equal "$rc" 5
}

@test "a failed revert keeps the record" {
    revert_through_a_dead_manager
    assert [ -s "$state_dir/apply.json" ]
}

@test "the failed revert says why" {
    revert_through_a_dead_manager
    assert_equal "$(journal_field apps-revert-failed '.reason' | tail -n 1)" restore-incomplete
}

@test "the failed revert pages the deploy check" {
    revert_through_a_dead_manager
    assert_equal "$(tail -n 1 "$log/notify-urls")" "$ping_url/fail"
}

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

# --- 9n. a manager that never answers is given up on ------------------------
# The retry is for a manager that is starting, which takes seconds. A manager
# that is dead answers instantly and forever, so the count alone is 180 attempts
# per call; one that hangs to its cap on every attempt is hours. The window is
# what bounds both, and it opens at the first transport failure, not at the call.
user_ctl_through_a_dead_manager() {
    fixture
    run_apply "$c_v1"
    same "$rc" 0 "the two-app revision applies"
    set_secrets "$secrets_v1b"
    export APPS_CTL_RETRIES=20 APPS_CTL_RETRY_WINDOW=2
    export FAKE_SYSTEMCTL_TRANSPORT='restart alpha.service'
    run_apply "$c_v2"
    unset FAKE_SYSTEMCTL_TRANSPORT APPS_CTL_RETRY_WINDOW
}

@test "a dead manager is given up on inside the window" {
    user_ctl_through_a_dead_manager
    # Two call sites reach the manager -- the apply's restart and the revert's --
    # so the count a count-only loop would make is 2 x APPS_CTL_RETRIES. Inside a
    # two-second window at `sleep 1` each site stops at three, four with jitter.
    assert [ "$(grep -c 'user restart alpha.service' "$log/actions")" -le 8 ]
}

@test "the give-up names the manager unit" {
    user_ctl_through_a_dead_manager
    assert grep -qF 'user@1001' <<<"$out"
}

@test "the give-up is a failure, not a success" {
    user_ctl_through_a_dead_manager
    assert [ "$rc" -ne 0 ]
}


# --- 10. a Serve failure after the commit does not revert --------------------
apply_with_a_failing_serve() {
    fixture
    run_apply "$c_v1"
    set_secrets "$secrets_v1b"
    export FAKE_SYSTEMCTL_FAIL=smortress-tailscale-serve.service
    run_apply "$c_v2"
    unset FAKE_SYSTEMCTL_FAIL
}

@test "a Serve failure still leaves the commit running" {
    apply_with_a_failing_serve
    assert_equal "$rc" 0
}

@test "the applied commit stays recorded" {
    apply_with_a_failing_serve
    assert_equal "$(jq -r '.repos["homelab-apps"].commit' "$state_dir/state.json")" "$c_v2"
}

@test "the applied secret value stays" {
    apply_with_a_failing_serve
    assert_equal "$(cat "$secret_store/app-alpha-api-key")" two
}

@test "a Serve failure leaves no crash record" {
    apply_with_a_failing_serve
    assert [ ! -e "$state_dir/apply.json" ]
}

@test "the failed Serve restart is journaled" {
    apply_with_a_failing_serve
    assert_equal "$(journal_field apps-serve-failed '.commit')" "$c_v2"
}

@test "a Serve failure does not log a revert" {
    apply_with_a_failing_serve
    assert_equal "$(journal_field apps-reverted '.commit')" ""
}

@test "a Serve failure pages the deploy check" {
    apply_with_a_failing_serve
    assert_equal "$(tail -n 1 "$log/notify-urls")" "$ping_url/fail"
}
