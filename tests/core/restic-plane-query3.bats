#!/usr/bin/env bats
# bats file_tags=core
# The Restic plane, offline: the deploy gate's local query, part 3 of 4 (no Healthchecks, no network).
#
# One file of the suite that was tests/core/restic-plane.bats, split so bats
# can run the sections as parallel files (a file is one job). The stubs, the
# storage table, the scratch tree, the drivers and the case helpers are in
# tests/core/restic-plane_lib.bash.
#
#   bats tests/core/restic-plane-query3.bats
load ../helpers
load ./restic-plane_lib

setup_file() { rp_setup_file; }
setup() { rp_setup; }

@test "an untagged snapshot is not fresh" {
    unverified_snapshot
    assert_equal "$(jq -r '.ssd.units.photos.reason' <<<"$out")" unverified
}
@test "an absent SSD does not break the local query" {
    absent_ssd
    assert_equal "$rc" 0
}
@test "an absent SSD is reported unusable" {
    absent_ssd
    assert_equal "$(jq -r '.ssd.usable' <<<"$out")" false
}
@test "the HDD stays usable" {
    absent_ssd
    assert_equal "$(jq -r '.hdd.usable' <<<"$out")" true
}
@test "no unit is fresh on an unusable repository" {
    absent_ssd
    assert_equal "$(jq -r '.ssd.units.photos.fresh' <<<"$out")" false
}
@test "an uncreatable cache is a verdict, not a crash" {
    uncreatable_cache
    assert_equal "$rc" 0
}
