#!/usr/bin/env bats
# bats file_tags=core
# The Restic plane, offline: the deploy gate's local query, part 4 of 4 (no Healthchecks, no network).
#
# One file of the suite that was tests/core/restic-plane.bats, split so bats
# can run the sections as parallel files (a file is one job). The stubs, the
# storage table, the scratch tree, the drivers and the case helpers are in
# tests/core/restic-plane_lib.bash.
#
#   bats tests/core/restic-plane-query4.bats
load ../helpers
load ./restic-plane_lib

setup_file() { rp_setup_file; }
setup() { rp_setup; }

@test "the verdict stays JSON without a cache" {
    uncreatable_cache
    if ! jq -e . >/dev/null 2>&1 <<<"$out"; then
        fail "the verdict was not JSON" "$out"
    fi
}
@test "an uncreatable cache makes the repository unusable" {
    uncreatable_cache
    assert_equal "$(jq -r '.ssd.usable' <<<"$out")" false
}
@test "the uncreatable cache is named on stderr" {
    uncreatable_cache
    assert_logged 'cannot create the restic cache' "$log/cache-stderr"
}
# Nothing to join against is the one thing the query cannot answer.
@test "missing plane state fails the local query" {
    rm -rf "${work:?}/state"
    drive scripts/smortress-restic-verify.sh --local --json
    assert_not_equal "$rc" 0
}
@test "the aggregate mode takes no --json" {
    seed_all_healthy
    drive scripts/smortress-restic-verify.sh --json
    assert_equal "$rc" 2
}
@test "the local mode requires --json" {
    seed_all_healthy
    drive scripts/smortress-restic-verify.sh --local
    assert_equal "$rc" 2
}
