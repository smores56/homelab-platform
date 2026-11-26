#!/usr/bin/env bats
# bats file_tags=core
# The Restic plane, offline: the freshness verifier, part 5 of 5 (a seeded plane, its one Healthchecks ping, and the runs that are not a ping).
#
# One file of the suite that was tests/core/restic-plane.bats, split so bats
# can run the sections as parallel files (a file is one job). The stubs, the
# storage table, the scratch tree, the drivers and the case helpers are in
# tests/core/restic-plane_lib.bash.
#
#   bats tests/core/restic-plane-fresh5.bats
load ../helpers
load ./restic-plane_lib

setup_file() { rp_setup_file; }
setup() { rp_setup; }

@test "a missing Healthchecks URL refuses to claim freshness" {
    seed_all_healthy
    unset RESTIC_HEALTHCHECK_URL
    drive scripts/smortress-restic-verify.sh
    assert_not_equal "$rc" 0
}
@test "no ping without a configured URL" {
    seed_all_healthy
    unset RESTIC_HEALTHCHECK_URL
    drive scripts/smortress-restic-verify.sh
    if [[ -s $log/curl-urls ]]; then
        fail "a ping was sent without a configured URL" "$(cat "$log/curl-urls")"
    fi
}
