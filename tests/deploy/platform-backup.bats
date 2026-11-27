#!/usr/bin/env bats
# bats file_tags=deploy
# One missing unit is backed up once, on the preferred backend (§2).
#
# One file of the suite that was tests/deploy/platform.bats, split so bats can
# run the sections in parallel (a single file is one job); the fakes, the
# fixture, the drivers and the assertions are in platform_lib.bash.
#
#   bats tests/deploy/platform-backup.bats
load ../helpers
load ./platform_lib

setup_file() { pt_setup_file; }
setup() { pt_setup; }

# --- 2. one missing unit is backed up once, on the preferred backend --------
# books is stale on both backends and the ping secret is present: the gate has
# exactly one unit to back up, and it must take the SSD.
one_missing_unit() {
    seed_doc true true "$(fresh_without books)"
    printf '%s\n' "$ping_url" >"$DEPLOY_PING_SECRET"
    run_platform prepare --commit "$commit" --digests "$digests"
}

@test "a backed-up unit passes the gate" {
    one_missing_unit
    assert_equal "$rc" 0
}

@test "exactly one backup for one missing unit" {
    one_missing_unit
    assert_equal "$(wc -l <"$log/backup-calls" | tr -d ' ')" 1
}

@test "the missing unit is backed up to the SSD first" {
    one_missing_unit
    assert_equal "$(cut -d'|' -f1 "$log/backup-calls")" ssd
}

@test "the backup names the unit and skips maintenance" {
    one_missing_unit
    assert_equal "$(cut -d'|' -f3 "$log/backup-calls")" "ssd --unit books --no-maintenance"
}

@test "the backup waits at most 900s for a unit lock" {
    one_missing_unit
    assert_equal "$(cut -d'|' -f2 "$log/backup-calls")" "lock=900"
}

@test "the gate is green on the backend it just wrote" {
    one_missing_unit
    assert_equal "$(journal_field gate-green '.units.books')" ssd
}

@test "the gate re-verifies after the backups" {
    one_missing_unit
    assert_equal "$(count_in "$log/verify-calls" '--local --json')" 2
}
