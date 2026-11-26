#!/usr/bin/env bats
# bats file_tags=core
# The Restic plane, offline: stale staging, the mount gates and the retention filter.
#
# One file of the suite that was tests/core/restic-plane.bats, split so bats
# can run the sections as parallel files (a file is one job). The stubs, the
# storage table, the scratch tree, the drivers and the case helpers are in
# tests/core/restic-plane_lib.bash.
#
#   bats tests/core/restic-plane-staging.bats
load ../helpers
load ./restic-plane_lib

setup_file() { rp_setup_file; }
setup() { rp_setup; }

@test "a stale staging snapshot does not block the run" {
    run_with_stale_staging
    assert_equal "$rc" 0
}

@test "reconciliation destroys the stale snapshot before creating a new one" {
    run_with_stale_staging
    destroy_line=$(grep -n '^destroy smortress/raw/photos@ssd' "$log/zfs" | head -n1 | cut -d: -f1)
    snapshot_line=$(grep -n '^snapshot smortress/raw/photos@ssd' "$log/zfs" | head -n1 | cut -d: -f1)
    [[ -n $destroy_line && -n $snapshot_line ]] ||
        fail "expected both a destroy and a snapshot: $(cat "$log/zfs")"
    assert_equal "$((destroy_line < snapshot_line))" 1
}

@test "a job destroys only its own staging snapshot" {
    run_with_stale_staging
    refute_logged 'destroy smortress/raw/photos@hdd\|destroy smortress/raw/books@ssd' "$log/zfs"
}


@test "a stale snapshot that will not destroy fails the job" {
    run_with_busy_stale_snapshot
    assert_not_equal "$rc" 0
}

@test "the failure reason stays symbolic" {
    run_with_busy_stale_snapshot
    assert_equal "$(state_json ssd-photos '.last_attempt.reason')" snapshot-reconcile
}

@test "a failed reconciliation records zfs's own message" {
    run_with_busy_stale_snapshot
    assert_contains "$out" "$busy"
}

@test "a busy destroy is retried once before the attempt fails" {
    run_with_busy_stale_snapshot
    assert_equal "$(grep -c '^destroy smortress/raw/photos@ssd' "$log/zfs" || true)" 2
}


@test "a staging snapshot that will not destroy does not fail a good backup" {
    run_with_failing_cleanup
    assert_equal "$rc" 0
}

@test "a failed end-of-run cleanup names the zfs error" {
    run_with_failing_cleanup
    assert_contains "$out" "$busy"
}


@test "a failed readiness unit fails the job" {
    run_with_failing_readiness
    assert_not_equal "$rc" 0
}

@test "readiness failure is recorded" {
    run_with_failing_readiness
    assert_equal "$(state_json ssd-photos '.last_attempt.reason')" readiness
}

@test "no snapshot or backup happens before readiness" {
    run_with_failing_readiness
    refute_logged 'zfs snapshot\|^backup ' "$log/zfs" "$log/restic"
}


@test "an unmounted repository path fails the job" {
    run_with_unmounted_repository
    assert_not_equal "$rc" 0
}

@test "unmounted repository is recorded" {
    run_with_unmounted_repository
    assert_equal "$(state_json ssd-photos '.last_attempt.reason')" repo-not-mounted
}

@test "nothing is written to an unmounted repository" {
    run_with_unmounted_repository
    refute_logged '^tag ' "$log/restic"
}

# --- 4. retention filter and deletion shape -----------------------------

@test "unit and verified are matched with one AND tag" {
    # Two --tag flags are OR in restic; only one comma-separated flag is AND, and
    # a wrong form makes one unit's forget touch another unit's verified
    # snapshots.
    if grep -nE -- '--tag "unit:\$[a-z]+" --tag verified' scripts/smortress-restic-*.sh; then
        fail "a retention command matches unit and verified with two OR tags"
    fi
}

@test "every retention command requires both unit and verified tags" {
    joined=$(sed -e :a -e '/\\$/N; s/\\\n/ /; ta' "$driver")
    retention_bad=""
    while IFS= read -r line; do
        [[ $line == *--keep-* ]] || continue
        [[ $line == *'--tag "unit:'* && $line == *',verified'* ]] || retention_bad=$line
    done <<<"$joined"
    assert_equal "$retention_bad" ""
}

@test "retention uses no wildcard bucket and no routine unlock" {
    if grep -qE -- '--keep-last|--keep-within|--keep-tag|unlock' scripts/smortress-restic-*.sh; then
        fail "a retention command keeps a wildcard bucket or unlocks routinely"
    fi
}

@test "no restic write bypasses the lock wait" {
    # restic_with_lock is the only place --retry-lock is passed; a write called
    # straight through "$restic_bin" would fail on a lock instead of waiting it
    # out, which is the window that blocked forget and prune on 2026-11-25 (#138).
    if grep -nE -- '"\$(\{restic_bin\}|restic_bin)" (backup|forget|prune|tag|check)\b' \
        scripts/smortress-restic-*.sh; then
        fail "a restic write runs without the lock wait"
    fi
}

@test "no bulk deletion of snapshot sets or repository roots" {
    if grep -qE -- 'forget .*\*|rm -rf[^#]*(/var/lib/restic|/var/lib/homelab/restic)' \
        scripts/smortress-restic-*.sh; then
        fail "something deletes snapshot sets or repository roots in bulk"
    fi
}
