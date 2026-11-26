#!/usr/bin/env bats
# bats file_tags=core
# The Restic plane, offline: the freshness verifier, part 1 of 5 (a seeded plane, its one Healthchecks ping, and the runs that are not a ping).
#
# One file of the suite that was tests/core/restic-plane.bats, split so bats
# can run the sections as parallel files (a file is one job). The stubs, the
# storage table, the scratch tree, the drivers and the case helpers are in
# tests/core/restic-plane_lib.bash.
#
#   bats tests/core/restic-plane-fresh1.bats
load ../helpers
load ./restic-plane_lib

setup_file() { rp_setup_file; }
setup() { rp_setup; }

@test "a healthy plane verifies" {
    healthy_plane
    drive scripts/smortress-restic-verify.sh
    assert_equal "$rc" 0
}
@test "exactly one Healthchecks ping on success" {
    healthy_plane
    drive scripts/smortress-restic-verify.sh
    assert_equal "$(wc -l <"$log/curl-urls" | tr -d ' ')" 1
}
@test "the ping goes to the configured check" {
    healthy_plane
    drive scripts/smortress-restic-verify.sh
    assert_equal "$(cat "$log/curl-urls")" "$RESTIC_HEALTHCHECK_URL"
}
