#!/usr/bin/env bats
# bats file_tags=core
# The Restic plane, offline: the freshness verifier, part 3 of 5 (a seeded plane, its one Healthchecks ping, and the runs that are not a ping).
#
# One file of the suite that was tests/core/restic-plane.bats, split so bats
# can run the sections as parallel files (a file is one job). The stubs, the
# storage table, the scratch tree, the drivers and the case helpers are in
# tests/core/restic-plane_lib.bash.
#
#   bats tests/core/restic-plane-fresh3.bats
load ../helpers
load ./restic-plane_lib

setup_file() { rp_setup_file; }
setup() { rp_setup; }

@test "a run that died without completing expires" {
    seed_all_healthy
    jq '.last_attempt.n = 2 | .last_attempt.result = "running" | .last_attempt.start = "2000-01-01T00:00:00Z"' \
        "$work/state/state/hdd-books.json" >"$work/state/state/hdd-books.json.tmp" &&
        mv "$work/state/state/hdd-books.json.tmp" "$work/state/state/hdd-books.json"
    drive scripts/smortress-restic-verify.sh --no-ping
    assert_not_equal "$rc" 0
}
@test "a first upload inside its own window is not called dead" {
    seed_all_healthy
    first_running ssd photos 6000
    drive scripts/smortress-restic-verify.sh --no-ping
    if grep -q 'never completed' <<<"$out"; then
        fail "a legal first upload was called dead" "$out"
    fi
}
@test "a first upload past its own window still expires" {
    seed_all_healthy
    first_running ssd photos 20000
    drive scripts/smortress-restic-verify.sh --no-ping
    assert_contains "$out" 'never completed'
}
