#!/usr/bin/env bats
# bats file_tags=core
# The Restic plane, offline: the deploy gate's local query, part 2 of 4 (no Healthchecks, no network).
#
# One file of the suite that was tests/core/restic-plane.bats, split so bats
# can run the sections as parallel files (a file is one job). The stubs, the
# storage table, the scratch tree, the drivers and the case helpers are in
# tests/core/restic-plane_lib.bash.
#
#   bats tests/core/restic-plane-query2.bats
load ../helpers
load ./restic-plane_lib

setup_file() { rp_setup_file; }
setup() { rp_setup; }

@test "the local query covers only the two local repositories" {
    local_query
    assert_equal "$(jq -r 'has("r2")' <<<"$out")" false
}
@test "the local query never pings Healthchecks" {
    local_query
    if [[ -s $log/curl-urls ]]; then
        fail "the local query pinged Healthchecks" "$(cat "$log/curl-urls")"
    fi
}
@test "the local query needs no Healthchecks URL" {
    seed_all_healthy
    unset RESTIC_HEALTHCHECK_URL
    drive scripts/smortress-restic-verify.sh --local --json
    assert_equal "$rc" 0
}
@test "a stale snapshot is a verdict, not a failure of the query" {
    stale_snapshot
    assert_equal "$rc" 0
}
@test "a snapshot past the max age is not fresh" {
    stale_snapshot
    assert_equal "$(jq -r '.ssd.units.photos.fresh' <<<"$out")" false
}
@test "a stale snapshot says why" {
    stale_snapshot
    assert_equal "$(jq -r '.ssd.units.photos.reason' <<<"$out")" stale
}
