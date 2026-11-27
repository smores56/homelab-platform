#!/usr/bin/env bats
# bats file_tags=deploy
# An exhausted budget holds, and a backup is bounded by the unit's
# own deadline (§5, §5b).
#
# One file of the suite that was tests/deploy/platform.bats, split so bats can
# run the sections in parallel (a single file is one job); the fakes, the
# fixture, the drivers and the assertions are in platform_lib.bash.
#
#   bats tests/deploy/platform-budget.bats
load ../helpers
load ./platform_lib

setup_file() { pt_setup_file; }
setup() { pt_setup; }

# --- 5. an exhausted budget holds instead of running on ---------------------
# The ping secret is deliberately absent here: a host mid-bootstrap has none, and
# a missing page must not turn a hold into a crash. files and books are stale and
# a backup of books outlives the 2 s budget the gate is given.
exhausted_budget() {
    seed_doc true true "$(fresh_without files)"
    jq -c '.ssd.units.books.fresh = false | .hdd.units.books.fresh = false' \
        "$STUB_VERIFY_DOC" >"$STUB_VERIFY_DOC.tmp" && mv "$STUB_VERIFY_DOC.tmp" "$STUB_VERIFY_DOC"
    rc=0
    out=$(STUB_BACKUP_SLEEP=3 STUB_BACKUP_SLEEP_UNIT=books DEPLOY_GATE_BUDGET=2 bash "$platform" \
        prepare --commit "$commit" --digests "$digests" 2>&1) || rc=$?
    held=$(cat "$state_dir/held.json" 2>/dev/null) || held='{}'
}

@test "an exhausted gate budget holds" {
    exhausted_budget
    assert_equal "$rc" 5
}

@test "the hold names the exhausted budget" {
    exhausted_budget
    json_is "$held" .reason budget-exhausted
}

@test "the hold names the unit it could not back up" {
    exhausted_budget
    json_is "$held" '.missingUnits | join(",")' books
}

@test "the first unit was backed up before the budget ran out" {
    exhausted_budget
    assert_matches "$(cat "$log/backup-calls")" '^ssd\|lock=900\|ssd --unit files'
}

@test "a hold with no ping secret is journaled as a skipped notification" {
    exhausted_budget
    assert_equal "$(journal_field notify-skipped '.kind')" fail
}

@test "no notification is sent without a ping secret" {
    exhausted_budget
    assert_empty "$log/curl-urls"
}

# --- 5b. a backup is bounded by the unit's own deadline ---------------------
# A unit that legitimately needs hours must not be cut at a flat 1800 s: the
# gate hands each backup the deadline the plane gives that unit.
per_unit_deadlines() {
    seed_doc true true "$(fresh_without books)"
    jq -c '.ssd.units["agent-local"].fresh = false
      | .hdd.units["agent-local"].fresh = false' "$STUB_VERIFY_DOC" >"$STUB_VERIFY_DOC.tmp" &&
        mv "$STUB_VERIFY_DOC.tmp" "$STUB_VERIFY_DOC"
    : >"$log/timeouts"
    rc=0
    out=$(RESTIC_DEADLINE_LOCAL_LONG=40 bash "$platform" prepare \
        --commit "$commit" --digests "$digests" 2>&1) || rc=$?
    timeouts=$(cat "$log/timeouts")
}

@test "the gate is green after backing up both units" {
    per_unit_deadlines
    assert_equal "$rc" 0
}

@test "an ordinary unit keeps the 1800 s deadline" {
    per_unit_deadlines
    assert_matches "$timeouts" '^1860\|.*--unit books'
}

@test "agent-local gets its long local deadline" {
    per_unit_deadlines
    assert_matches "$timeouts" '^100\|.*--unit agent-local'
}
