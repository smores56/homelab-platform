#!/usr/bin/env bats
# bats file_tags=deploy
# Pull-all-then-change, and the plan before the quota restart (§6).
#
# One file of the suite that was tests/deploy/apps.sh, split so bats can run the
# sections in parallel (a single file is one job). The fakes, the published
# commits, the fixture, the drivers and the assertions are in apps_lib.bash.
#
#   bats tests/deploy/apps-install-change.bats
load ../helpers
load ./apps_lib

setup_file() { apps_setup_file; }
setup() { apps_setup; }

# --- 6. pull-all-then-change, and the plan before the quota restart ----------
apply_a_changed_commit() {
    fixture
    run_apply "$c_v1"
    : >"$state_dir/journal.jsonl"
    : >"$log/pulls"
    : >"$log/actions"
    : >"$log/sequence"
    run_apply "$c_changed"
    last_pull=$(grep -n 'apps-pulled' "$state_dir/journal.jsonl" | tail -n 1 | cut -d: -f1)
    plan_at=$(line_of "$state_dir/journal.jsonl" '"event":"apps-plan-installed"')
    quota_at=$(line_of "$state_dir/journal.jsonl" '"event":"apps-quota-applied"')
    # The command log's own order: every pull is a child of this apply, and the
    # first thing it changes is the plan's consumer.
    last_pull_cmd=$(grep -n '^pull ' "$log/sequence" | tail -n 1 | cut -d: -f1)
    quota_cmd=$(line_of "$log/sequence" 'restart smortress-apps-quota.service')
}

@test "a changed commit applies" {
    apply_a_changed_commit
    assert_equal "$rc" 0
}

@test "the changed image is pulled" {
    apply_a_changed_commit
    assert [ -s "$log/pulls" ]
}

@test "every pull completes before the first mutation" {
    apply_a_changed_commit
    assert_before "$last_pull" "$plan_at" "every pull completes before the first mutation"
}

@test "the plan is installed before the quota reads it" {
    apply_a_changed_commit
    assert_before "$plan_at" "$quota_at" "the plan is installed before the quota reads it"
}

@test "the quota applier reads the new plan" {
    apply_a_changed_commit
    assert_equal "$(sha "$log/quota-plan" 2>/dev/null)" "$(sha "$APPS_PLAN")"
}

@test "the command log shows every pull before the quota restart" {
    apply_a_changed_commit
    assert_before "$last_pull_cmd" "$quota_cmd" \
        "the command log shows every pull before the quota restart"
}

@test "Serve is regenerated from the new plan" {
    apply_a_changed_commit
    assert_equal "$(sha "$log/serve-plan" 2>/dev/null)" "$(sha "$APPS_PLAN")"
}

@test "a changed unit is restarted" {
    apply_a_changed_commit
    assert grep -qF 'user restart alpha.service' "$log/actions"
}
