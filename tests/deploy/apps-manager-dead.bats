#!/usr/bin/env bats
# bats file_tags=deploy
# A manager that never answers is given up on (§9n).
#
# One file of the suite that was tests/deploy/apps.sh, split so bats can run the
# sections in parallel (a single file is one job). The fakes, the published
# commits, the fixture, the drivers and the assertions are in apps_lib.bash.
#
#   bats tests/deploy/apps-manager-dead.bats
load ../helpers
load ./apps_lib

setup_file() { apps_setup_file; }
setup() { apps_setup; }
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
