#!/usr/bin/env bats
# bats file_tags=deploy
# An infrastructure failure leaves no hold, and break-glass
# releases one (§6, §7).
#
# One file of the suite that was tests/deploy/platform.bats, split so bats can
# run the sections in parallel (a single file is one job); the fakes, the
# fixture, the drivers and the assertions are in platform_lib.bash.
#
#   bats tests/deploy/platform-break-glass.bats
load ../helpers
load ./platform_lib

setup_file() { pt_setup_file; }
setup() { pt_setup; }

# --- 6. an infrastructure failure leaves no hold ----------------------------
verifier_cannot_run() {
    rc=0
    out=$(STUB_VERIFY_EXIT=4 bash "$platform" prepare --commit "$commit" --digests "$digests" 2>&1) || rc=$?
}

@test "a verifier that cannot run is an infrastructure failure" {
    verifier_cannot_run
    assert_equal "$rc" 4
}

@test "an infrastructure failure writes no hold" {
    verifier_cannot_run
    assert_absent "$state_dir/held.json"
}

@test "an infrastructure failure attempts no backup" {
    verifier_cannot_run
    assert_empty "$log/backup-calls"
}

@test "the infrastructure failure is journaled" {
    verifier_cannot_run
    assert_equal "$(journal_field gate-infra-failure '.commit')" "$commit"
}

# --- 7. break-glass --------------------------------------------------------
# `release --force` is a root action; the uid is faked (a 1000-only `id` on PATH)
# so the test does not need to be root to prove the refusal.
refused_release() {
    seed_held "$digest_index" false
    cli_as smores nonroot release --force
    held=$(cat "$state_dir/held.json")
}

@test "a non-root release is refused" {
    refused_release
    assert_not_green
}

@test "a refused release leaves the hold un-released" {
    refused_release
    json_is "$held" '.released' false
}

@test "a refused release journals nothing" {
    refused_release
    assert_equal "$(count_in "$state_dir/journal.jsonl" gate-released-by-operator)" 0
}

root_release() {
    seed_held "$digest_index" false
    cli_as alice uid0 release --force
    held=$(cat "$state_dir/held.json" 2>/dev/null) || held='{}'
}

@test "root can release a held deploy" {
    root_release
    assert_equal "$rc" 0
}

@test "the release marks the hold released" {
    root_release
    json_is "$held" '.released' true
}

@test "the release records the operator" {
    root_release
    json_is "$held" .releasedBy alice
}

@test "the release is journaled with the operator" {
    root_release
    assert_equal "$(journal_field gate-released-by-operator '.operator')" alice
}

@test "the release is journaled with the held digest" {
    root_release
    assert_equal "$(journal_field gate-released-by-operator '.digest')" "$digest_index"
}

@test "the release is journaled with the missing units" {
    root_release
    assert_equal "$(journal_field gate-released-by-operator '.missingUnits | join(",")')" books
}

@test "the release stages nothing itself" {
    root_release
    assert_empty "$log/backup-calls"
}
