#!/usr/bin/env bats
# bats file_tags=deploy
# An app the commit did not touch cannot block it (§9d).
#
# One file of the suite that was tests/deploy/apps.sh, split so bats can run the
# sections in parallel (a single file is one job). The fakes, the published
# commits, the fixture, the drivers and the assertions are in apps_lib.bash.
#
#   bats tests/deploy/apps-verdict-untouched.bats
load ../helpers
load ./apps_lib

setup_file() { apps_setup_file; }
setup() { apps_setup; }
# --- 9d. an app the commit did not touch cannot block it ---------------------
# An apply cannot repair a revision it did not write: a stale inactive app is the
# boot gate's business, not a reason to refuse every later commit.
apply_past_an_inactive_app() {
    fixture
    run_apply "$c_v1"
    set_secrets "$secrets_v1b"
    export FAKE_UNIT_INACTIVE=beta.service
    run_apply "$c_secret"
    unset FAKE_UNIT_INACTIVE
}

@test "an inactive app the commit did not change applies" {
    apply_past_an_inactive_app
    assert_equal "$rc" 0
}

@test "the changed app is still checked" {
    apply_past_an_inactive_app
    assert grep -qF 'show -p ActiveState -p NRestarts alpha.service' "$log/systemctl-calls"
}

@test "the untouched app is not judged" {
    apply_past_an_inactive_app
    assert_equal "$(journal_field apps-unhealthy '.app')" ""
}
