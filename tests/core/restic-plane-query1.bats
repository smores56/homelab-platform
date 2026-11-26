#!/usr/bin/env bats
# bats file_tags=core
# The Restic plane, offline: the deploy gate's local query, part 1 of 4 (no Healthchecks, no network).
#
# One file of the suite that was tests/core/restic-plane.bats, split so bats
# can run the sections as parallel files (a file is one job). The stubs, the
# storage table, the scratch tree, the drivers and the case helpers are in
# tests/core/restic-plane_lib.bash.
#
#   bats tests/core/restic-plane-query1.bats
load ../helpers
load ./restic-plane_lib

setup_file() { rp_setup_file; }
setup() { rp_setup; }

@test "a healthy plane answers the local query" {
    local_query
    assert_equal "$rc" 0
}
@test "the SSD is reported usable" {
    local_query
    assert_equal "$(jq -r '.ssd.usable' <<<"$out")" true
}
@test "the HDD is reported usable" {
    local_query
    assert_equal "$(jq -r '.hdd.usable' <<<"$out")" true
}
@test "a fresh SSD unit is reported fresh" {
    local_query
    assert_equal "$(jq -r '.ssd.units.photos.fresh' <<<"$out")" true
}
@test "a fresh HDD unit is reported fresh" {
    local_query
    assert_equal "$(jq -r '.hdd.units["repo-archive"].fresh' <<<"$out")" true
}
@test "every restore unit is reported" {
    local_query
    assert_equal "$(jq -r '.ssd.units | length' <<<"$out")" "$(unit_count)"
}
