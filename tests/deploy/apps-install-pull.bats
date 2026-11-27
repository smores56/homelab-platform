#!/usr/bin/env bats
# bats file_tags=deploy
# A failed pull changes nothing and leaves no crash record (§5).
#
# One file of the suite that was tests/deploy/apps.sh, split so bats can run the
# sections in parallel (a single file is one job). The fakes, the published
# commits, the fixture, the drivers and the assertions are in apps_lib.bash.
#
#   bats tests/deploy/apps-install-pull.bats
load ../helpers
load ./apps_lib

setup_file() { apps_setup_file; }
setup() { apps_setup; }

# --- 5. a failed pull changes nothing and leaves no crash record -------------
# Every check in a section below reads one aftermath, so each of its tests
# replays the section's own sequence: the same drivers in the same order, with
# nothing between them that a check depends on.
apply_a_failed_pull() {
    fixture
    run_apply "$c_v1"
    plan_before=$(sha "$APPS_PLAN")
    unit_before=$(sha "$APPS_UNIT_DIR/alpha.container")
    secret_before=$(cat "$secret_store/app-alpha-api-key")
    : >"$log/pulls"
    : >"$log/actions"
    : >"$log/systemctl-calls"
    export FAKE_PULL_FAIL=$d_c
    run_apply "$c_pull"
    unset FAKE_PULL_FAIL
}

@test "a failed pull exits 4 for a retry" {
    apply_a_failed_pull
    assert_equal "$rc" 4
}

@test "a failed pull leaves the plan untouched" {
    apply_a_failed_pull
    assert_equal "$(sha "$APPS_PLAN")" "$plan_before"
}

@test "a failed pull leaves the units untouched" {
    apply_a_failed_pull
    assert_equal "$(sha "$APPS_UNIT_DIR/alpha.container")" "$unit_before"
}

@test "a failed pull leaves the secrets untouched" {
    apply_a_failed_pull
    assert_equal "$(cat "$secret_store/app-alpha-api-key")" "$secret_before"
}

@test "a failed pull leaves no crash record" {
    apply_a_failed_pull
    assert [ ! -e "$state_dir/apply.json" ]
}

@test "a failed pull removes its work tree" {
    apply_a_failed_pull
    assert [ ! -e "$state_dir/work/apps-$c_pull" ]
}

@test "the failed pull is journaled" {
    apply_a_failed_pull
    assert_equal "$(journal_field apps-pull-failed '.commit')" "$c_pull"
}

@test "the changed image is the one pulled" {
    apply_a_failed_pull
    assert grep -qF -- "ghcr.io/example/alpha@$d_c" "$log/pulls"
}

@test "a failed pull happens before any mutation" {
    apply_a_failed_pull
    assert [ ! -s "$log/actions" ]
}

@test "a failed pull pages the deploy check" {
    apply_a_failed_pull
    assert_equal "$(tail -n 1 "$log/notify-urls")" "$ping_url/fail"
}
