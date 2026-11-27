#!/usr/bin/env bats
# bats file_tags=deploy
# Only this deploy's work trees are swept, and a foreign schema is refused (§14-§15).
#
# One file of the suite that was tests/deploy/apps.sh, split so bats can run the
# sections in parallel (a single file is one job). The fakes, the published
# commits, the fixture, the drivers and the assertions are in apps_lib.bash.
#
#   bats tests/deploy/apps-guard-sweep.bats
load ../helpers
load ./apps_lib

setup_file() { apps_setup_file; }
setup() { apps_setup; }
# --- 14. only this deploy's own work trees are removed ----------------------
# The path a sweep or a revert removes is named by `apply.json`, which an operator
# can edit, and by a glob over the work directory. The shape is checked on the
# canonical path: a symlink out of the tree, a name that is not a commit, and a
# traversal that resolves elsewhere all survive.
sweep_foreign_work_trees() {
    fixture
    run_apply "$c_v1"
    outside=$work/outside
    mkdir -p "$outside/render.prev" "$state_dir/work/apps-notacommit"
    printf 'keep\n' >"$outside/render.prev/plan.json"
    printf 'keep\n' >"$state_dir/work/apps-notacommit/keep"
    ln -s "$outside" "$state_dir/work/apps-$c_changed"
    touch -h -d '3 days ago' "$state_dir/work/apps-notacommit" "$state_dir/work/apps-$c_changed"
    run_sweep
}

@test "the sweep survives the trees it refuses" {
    sweep_foreign_work_trees
    assert_equal "$rc" 0
}

@test "a symlinked work tree is not followed out of the work directory" {
    sweep_foreign_work_trees
    assert [ -d "$outside/render.prev" ]
}

@test "the refused symlink itself stays" {
    sweep_foreign_work_trees
    assert [ -L "$state_dir/work/apps-$c_changed" ]
}

@test "a directory that is not a commit tree stays" {
    sweep_foreign_work_trees
    assert [ -d "$state_dir/work/apps-notacommit" ]
}

@test "the sweep removes nothing it refused" {
    sweep_foreign_work_trees
    assert_equal "$(journal_field apps-work-swept '.removed')" 0
}

@test "the sweep journals the trees it refused" {
    sweep_foreign_work_trees
    assert_equal "$(journal_field apps-work-kept '.dir' | wc -l)" 2
}

# The same check behind a traversal in the record: apply.json names a path that
# resolves outside the work directory, and the revert's own cleanup refuses it
# even after it has restored everything else.
revert_a_traversal_record() {
    sweep_foreign_work_trees
    traversal=$work/state/work/../../outside
    jq -nc --arg work "$traversal" \
        '{schema:1,phase:"installing",commit:"'"$c_v2"'",work:$work,
          previousUnits:[],intendedUnits:[],previousPlan:false,previousState:false,
          previousSecrets:{},intendedSecrets:[],startedAt:"2026-11-21T00:00:00Z"}' | apply_write
    run_revert
}

@test "a traversal in apply.json removes nothing outside the work directory" {
    revert_a_traversal_record
    assert [ -f "$outside/render.prev/plan.json" ]
}

# --- 15. a revert refuses a state document of another schema ----------------
# The saved state.json is what a revert puts back, and it comes from a snapshot of
# whatever revision was running: a document of another schema is not this
# library's truth, so the revert refuses it, journals, pages and keeps its record
# rather than silently rewriting what the host is recorded as running.
revert_a_foreign_schema_state() {
    fixture
    run_apply "$c_v1"
    stage_interrupted "$c_v2" "$trees/$c_v2/homelab-apps-$c_v2"
    state_staged=$(sha "$state_dir/state.json")
    jq -c '.schema = 2' "$state_dir/work/apps-$c_v2/render.prev/state.json" |
        atomic_write "$state_dir/work/apps-$c_v2/render.prev/state.json"
    : >"$log/notify-urls"
    run_revert
}

@test "a revert refuses a state document of another schema" {
    revert_a_foreign_schema_state
    assert_equal "$rc" 1
}

@test "the refused restore leaves the state alone" {
    revert_a_foreign_schema_state
    assert_equal "$(sha "$state_dir/state.json")" "$state_staged"
}

@test "the refused restore is journaled with its reason" {
    revert_a_foreign_schema_state
    assert_equal "$(journal_field apps-revert-failed '.reason' | head -n 1)" state-schema-mismatch
}

@test "the refused restore pages the deploy check" {
    revert_a_foreign_schema_state
    assert_equal "$(tail -n 1 "$log/notify-urls")" "$ping_url/fail"
}

@test "the refused revert keeps the record" {
    revert_a_foreign_schema_state
    assert [ -s "$state_dir/apply.json" ]
}
