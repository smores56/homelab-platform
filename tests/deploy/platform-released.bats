#!/usr/bin/env bats
# bats file_tags=deploy
# A released digest passes the gate without a backup, and the
# operator's status view (§8, §9).
#
# One file of the suite that was tests/deploy/platform.bats, split so bats can
# run the sections in parallel (a single file is one job); the fakes, the
# fixture, the drivers and the assertions are in platform_lib.bash.
#
#   bats tests/deploy/platform-released.bats
load ../helpers
load ./platform_lib

setup_file() { pt_setup_file; }
setup() { pt_setup; }

# --- 8. a released digest passes the gate without a backup ------------------
release_already_released() {
    seed_held "$digest_index" true
    cli_as alice uid0 release --force
}

released_hold_gated() {
    release_already_released
    : >"$log/verify-calls"
    : >"$log/backup-calls"
    run_platform prepare --commit "$commit" --digests "$digests"
}

@test "releasing an already released hold is idempotent" {
    release_already_released
    assert_equal "$rc" 0
}

@test "a released hold passes the gate" {
    released_hold_gated
    assert_equal "$rc" 0
}

@test "the waive is journaled as gate-released" {
    released_hold_gated
    assert_equal "$(journal_field gate-released '.digest')" "$digest_index"
}

@test "a released hold writes no backup" {
    released_hold_gated
    assert_empty "$log/backup-calls"
}

@test "a released hold queries no repository" {
    released_hold_gated
    assert_empty "$log/verify-calls"
}

# A release is good for one digest only: a different image must earn its own.
other_digest_gated() {
    release_already_released
    : >"$log/verify-calls"
    : >"$state_dir/journal.jsonl"
    run_platform prepare --commit "$commit" --digests "$other_digests"
}

@test "a different digest runs the gate with a fresh plane" {
    other_digest_gated
    assert_equal "$rc" 0
}

@test "a release is never reused for a different digest" {
    other_digest_gated
    assert_equal "$(count_in "$state_dir/journal.jsonl" gate-released)" 0
}

@test "the gate records the digest it actually cleared" {
    other_digest_gated
    assert_equal "$(journal_field gate-green '.digest')" "$other_index"
}

@test "the other digest is gated on its own" {
    other_digest_gated
    assert_equal "$(count_in "$log/verify-calls" '--local --json')" 1
}

# A hold the gate has now satisfied is cleared: leaving it would make `status`
# report a deploy that is no longer held.
satisfied_hold() {
    seed_held "$digest_index" false
    run_platform prepare --commit "$commit" --digests "$digests"
}

@test "a previously held digest passes once its units are fresh" {
    satisfied_hold
    assert_equal "$rc" 0
}

@test "a satisfied hold is cleared" {
    satisfied_hold
    assert_absent "$state_dir/held.json"
}

# --- 9. the operator's status view -----------------------------------------
# One of each document `status` reads: the record, a released hold, a denylisted
# digest and a staged request.
status_view() {
    printf '%s' "$(jq -nc --arg c "$commit" --arg i "$digest_index" \
        '{schema:1,
    repos:{"homelab-platform":{commit:$c,indexDigest:$i}},
    apps:{unitsHash:"u",secretsHash:"s",apps:{alpha:{unit:"unit-hash",secrets:"secret-hash"}}},
    updated:"2026-11-20T00:00:00Z"}')" |
        atomic_write "$state_dir/state.json"
    seed_held "$digest_index" true
    jq -nc --arg d "$other_index" '{schema:1,commits:{},digests:{($d):{reason:"boot-gate",at:"2026-11-20T01:00:00Z"}}}' |
        atomic_write "$state_dir/denylist.json"
    jq -nc --arg c "$commit" --arg i "$digest_index" \
        '{phase:"staged",commit:$c,digest:$i}' | pending_write
    run_cli status
    status=$out
}

@test "status runs" {
    status_view
    assert_equal "$rc" 0
}

@test "status reports the deployed commit" {
    status_view
    json_is "$status" '.repos["homelab-platform"].commit' "$commit"
}

@test "status reports the held record" {
    status_view
    json_is "$status" '.held.digest' "$digest_index"
}

@test "status reports the pending record" {
    status_view
    json_is "$status" '.pending.phase' staged
}

@test "status reports the denylist" {
    status_view
    json_is "$status" ".denylist.digests[\"$other_index\"].reason" boot-gate
}

@test "status reports both denylist tables" {
    status_view
    json_is "$status" '.denylist.commits | type' object
}

# The apps table is what the next apply diffs against and what an operator reads
# to see which app runs which unit and secret revision; a status without it hides
# the half of the host an apps deploy owns.
@test "status reports the apps table" {
    status_view
    json_is "$status" '.apps.apps.alpha.unit' unit-hash
}

@test "status reports the whole-set unit hash" {
    status_view
    json_is "$status" '.apps.unitsHash' u
}
