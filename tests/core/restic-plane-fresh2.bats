#!/usr/bin/env bats
# bats file_tags=core
# The Restic plane, offline: the freshness verifier, part 2 of 5 (a seeded plane, its one Healthchecks ping, and the runs that are not a ping).
#
# One file of the suite that was tests/core/restic-plane.bats, split so bats
# can run the sections as parallel files (a file is one job). The stubs, the
# storage table, the scratch tree, the drivers and the case helpers are in
# tests/core/restic-plane_lib.bash.
#
#   bats tests/core/restic-plane-fresh2.bats
load ../helpers
load ./restic-plane_lib

setup_file() { rp_setup_file; }
setup() { rp_setup; }

@test "a newer failed run fails freshness even with a recent success" {
    failing_destination
    drive scripts/smortress-restic-verify.sh
    assert_not_equal "$rc" 0
}
@test "no success ping while a destination is failing" {
    failing_destination
    drive scripts/smortress-restic-verify.sh
    if grep -qx "$RESTIC_HEALTHCHECK_URL" "$log/curl-urls"; then
        fail "the success check was pinged while a destination is failing"
    fi
}
@test "the failure is reported to the same check" {
    failing_destination
    drive scripts/smortress-restic-verify.sh
    assert_logged '/fail$' "$log/curl-urls"
}
