#!/usr/bin/env bats
# bats file_tags=core
# The Restic plane, offline: the freshness verifier, part 4 of 5 (a seeded plane, its one Healthchecks ping, and the runs that are not a ping).
#
# One file of the suite that was tests/core/restic-plane.bats, split so bats
# can run the sections as parallel files (a file is one job). The stubs, the
# storage table, the scratch tree, the drivers and the case helpers are in
# tests/core/restic-plane_lib.bash.
#
#   bats tests/core/restic-plane-fresh4.bats
load ../helpers
load ./restic-plane_lib

setup_file() { rp_setup_file; }
setup() { rp_setup; }

@test "missing status state fails closed" {
    seed_all_healthy
    rm -f "$work/state/state/r2-files.json"
    drive scripts/smortress-restic-verify.sh --no-ping
    assert_not_equal "$rc" 0
}
@test "a recorded snapshot missing from the repository fails" {
    seed_all_healthy
    export STUB_SNAPSHOTS_JSON='[]'
    drive scripts/smortress-restic-verify.sh --no-ping
    assert_not_equal "$rc" 0
}
@test "an unverified tag or wrong source path fails" {
    seed_all_healthy
    STUB_SNAPSHOTS_JSON=$(jq -cn '[{id: "strepo", time: "2026-01-01T00:00:00Z", hostname: "smortress", paths: ["x"], tags: ["group:photos", "host:smortress"]}]')
    export STUB_SNAPSHOTS_JSON
    drive scripts/smortress-restic-verify.sh --no-ping
    assert_not_equal "$rc" 0
}
