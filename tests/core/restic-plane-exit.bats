#!/usr/bin/env bats
# bats file_tags=core
# The Restic plane, offline: the backup driver's exit codes, its locks, and the daily maintenance.
#
# One file of the suite that was tests/core/restic-plane.bats, split so bats
# can run the sections as parallel files (a file is one job). The stubs, the
# storage table, the scratch tree, the drivers and the case helpers are in
# tests/core/restic-plane_lib.bash.
#
#   bats tests/core/restic-plane-exit.bats
load ../helpers
load ./restic-plane_lib

setup_file() { rp_setup_file; }
setup() { rp_setup; }

# --- 1. exit codes -------------------------------------------------------


@test "exit 1 is a failed run" {
    backup_exit_1
    assert_not_equal "$rc" 0
}

@test "failed run is recorded as failure" {
    backup_exit_1
    assert_equal "$(state_json ssd-photos '.last_attempt.result')" failure
}

@test "failure reason records the exit code" {
    backup_exit_1
    assert_equal "$(state_json ssd-photos '.last_attempt.reason')" exit-1
}

@test "no verified tag after exit 1" {
    backup_exit_1
    refute_logged '^tag ' "$log/restic"
}


@test "exit 3 is a failed run" {
    backup_exit_3
    assert_not_equal "$rc" 0
}

@test "exit 3 keeps its own reason" {
    backup_exit_3
    assert_equal "$(state_json ssd-photos '.last_attempt.reason')" exit-3
}

@test "an incomplete snapshot ID is recorded for reaping" {
    backup_exit_3
    assert_equal "$(state_json ssd-photos '.pending_reap[0]')" incomplete1
}

@test "an exit-3 snapshot is never tagged verified" {
    backup_exit_3
    refute_logged '^tag ' "$log/restic"
}


@test "exit 0 succeeds" {
    backup_exit_0
    assert_equal "$rc" 0
}

@test "success is recorded" {
    backup_exit_0
    assert_equal "$(state_json ssd-photos '.last_attempt.result')" success
}

@test "the final snapshot ID is persisted" {
    backup_exit_0
    assert_equal "$(state_json ssd-photos '.final.snapshot')" complete1
}

@test "the successful snapshot is tagged verified" {
    backup_exit_0
    assert_logged 'tag --add verified complete1' "$log/restic"
}


@test "a run succeeds when an older verified snapshot has a different tree" {
    backup_with_two_verified_snapshots
    assert_equal "$rc" 0
}

@test "the tree selects the snapshot this attempt wrote" {
    backup_with_two_verified_snapshots
    assert_equal "$(state_json ssd-photos '.final.snapshot')" newer2
}

@test "the staging snapshot was destroyed" {
    backup_with_two_verified_snapshots
    staged=$(mount_for raw/photos)/.zfs/snapshot/ssd
    [[ ! -e $staged || -z $(ls -A "$staged" 2>/dev/null) ]] ||
        fail "the staging snapshot survived the run"
}


@test "a tagged snapshot succeeds" {
    backup_with_retagged_snapshot
    assert_equal "$rc" 0
}

@test "the post-tag snapshot ID is the one recorded" {
    backup_with_retagged_snapshot
    assert_equal "$(state_json ssd-photos .final.snapshot)" tagged1
}

@test "the tag is applied to the pre-tag snapshot" {
    backup_with_retagged_snapshot
    assert_logged 'tag --add verified pretag1' "$log/restic"
}


@test "tagging failure fails the run" {
    backup_with_failing_tag
    assert_not_equal "$rc" 0
}

@test "tagging failure is its own reason" {
    backup_with_failing_tag
    assert_equal "$(state_json ssd-photos '.last_attempt.reason')" tag-failed
}

@test "an untagged snapshot is reaped by recorded ID" {
    backup_with_failing_tag
    assert_equal "$(state_json ssd-photos '.pending_reap[0]')" complete2
}


@test "a stale lock is retried after unlocking" {
    backup_with_stale_lock
    assert_equal "$rc" 0
}

@test "stale locks are removed before the retry" {
    backup_with_stale_lock
    assert_logged ' unlock' "$log/restic"
}

# The wait is the other half: a lock a stopped or still-running writer holds is
# waited on, not failed on, so a stop does not make the repository unusable for
# the next attempt (#138).
@test "a write waits for a live lock instead of failing on it" {
    export STUB_BACKUP_EXIT=0 STUB_BACKUP_ID="waits1"
    drive "$driver" ssd --unit photos --no-maintenance
    assert_logged '--retry-lock 2m backup' "$log/restic"
}


@test "the first run maintains the repository" {
    maintenance_twice
    assert_equal "$prunes_first" 1
    assert_equal "$checks_first" 1
}

@test "a second run inside the day prunes nothing" {
    maintenance_twice
    assert_equal "$(grep -c ' prune' "$log/restic")" "$prunes_first"
}

@test "a second run inside the day reads no data subset" {
    maintenance_twice
    assert_equal "$(grep -c ' check ' "$log/restic")" "$checks_first"
}

@test "the second run says why it skipped" {
    maintenance_twice
    assert grep -qF 'ssd: maintenance not due' <<<"$out"
}
