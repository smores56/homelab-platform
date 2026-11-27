#!/usr/bin/env bats
# bats file_tags=deploy
# The host drift refusal and the fresh plane: green, nothing written
# (§1a, §1).
#
# One file of the suite that was tests/deploy/platform.bats, split so bats can
# run the sections in parallel (a single file is one job); the fakes, the
# fixture, the drivers and the assertions are in platform_lib.bash.
#
#   bats tests/deploy/platform-gate.bats
load ../helpers
load ./platform_lib

setup_file() { pt_setup_file; }
setup() { pt_setup; }

# --- 1a. a host-local manager drop-in refuses the stage ----------------------
# The image ships none, and one carrying `Requires=` stops the tenant manager
# whenever the apps apply restarts the quota applier, which is how six applies
# reverted (#152). Nothing else inspects the host, so the gate does.
drifted_host() {
    install -d -m 0755 "$work/etc/user@972.service.d"
    printf '[Unit]\nRequires=smortress-apps-quota.service\n' \
        >"$work/etc/user@972.service.d/50-smortress-apps.conf"
    run_platform prepare --commit "$commit" --digests "$digests"
}

@test "a host manager drop-in refuses the deploy" {
    drifted_host
    assert_equal "$rc" 6
}

@test "the refusal names the file" {
    drifted_host
    assert_contains "$out" "user@972.service.d"
}

@test "the drift is journaled with its path" {
    drifted_host
    assert_matches "$(jq -c 'select(.event == "deploy-drift")' "$state_dir/journal.jsonl")" \
        'user@972\.service\.d'
}

@test "a drifted host is never queried for snapshots" {
    drifted_host
    assert_empty "$log/verify-calls"
}

@test "a drifted host stages nothing" {
    drifted_host
    assert_absent "$state_dir/pending.json"
}

# --- 1. a fresh plane is green and writes nothing ----------------------------
fresh_plane() {
    run_platform prepare --commit "$commit" --digests "$digests"
}

@test "an entirely fresh plane passes the gate" {
    fresh_plane
    assert_equal "$rc" 0
}

@test "a fresh plane is not backed up again" {
    fresh_plane
    assert_empty "$log/backup-calls"
}

@test "the gate asks the local verifier once" {
    fresh_plane
    assert_equal "$(count_in "$log/verify-calls" '--local --json')" 1
}

@test "the green gate journals the per-unit backend" {
    fresh_plane
    assert_equal "$(journal_field gate-green '.units.photos')" ssd
}

@test "the green gate journals the digest" {
    fresh_plane
    assert_equal "$(journal_field gate-green '.digest')" "$digest_index"
}

@test "the green gate journals the commit" {
    fresh_plane
    assert_equal "$(journal_field gate-green '.commit')" "$commit"
}

@test "a green gate writes no hold" {
    fresh_plane
    assert_absent "$state_dir/held.json"
}

@test "the gate never stages, so it writes no pending record" {
    fresh_plane
    assert_absent "$state_dir/pending.json"
}

@test "a green gate notifies nothing" {
    fresh_plane
    assert_empty "$log/curl-urls"
}
