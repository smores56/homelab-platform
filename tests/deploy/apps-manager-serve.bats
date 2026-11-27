#!/usr/bin/env bats
# bats file_tags=deploy
# A Serve failure after the commit does not revert (§10).
#
# One file of the suite that was tests/deploy/apps.sh, split so bats can run the
# sections in parallel (a single file is one job). The fakes, the published
# commits, the fixture, the drivers and the assertions are in apps_lib.bash.
#
#   bats tests/deploy/apps-manager-serve.bats
load ../helpers
load ./apps_lib

setup_file() { apps_setup_file; }
setup() { apps_setup; }
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
