#!/usr/bin/env bats
# bats file_tags=deploy
# Stage: the exact `bootc switch` argv, the finalize poll and the pending record (§1).
#
# One file of the suite that was tests/deploy/boot.bats, split so bats can run
# the sections in parallel; the fakes, the fixture, the drivers and the
# assertions are in boot_lib.bash.
#
#   bats tests/deploy/boot-stage.bats
load ../helpers
load ./boot_lib

setup_file() { bt_setup_file; }
setup() { bt_setup; }

# --- 1. stage: the exact switch argv, then the staged-digest check ----------
# The host is running the previous deployment and bootc staged the new one: if
# booted already equalled the verified digest, stage would (correctly) record an
# already-running image and never reboot.
stage_verified() {
    printf 'staged=%s\nbooted=%s\n' "$digest_manifest" "$digest_prev_manifest" >"$STUB_BOOTC_STATE"
    run_stage --commit "$commit" --digests "$digests"
}

@test "a stage whose digest bootc reports passes" {
    stage_verified
    assert_equal "$rc" 0
}

@test "stage switches to the verified manifest digest and enforces the signature policy" {
    stage_verified
    assert_equal "$(grep '^switch ' "$log/bootc-calls" | head -n 1)" \
        "switch --enforce-container-sigpolicy $image_ref@$digest_manifest"
}

@test "stage never applies the deployment" {
    stage_verified
    refute grep -qF -- '--apply' "$log/bootc-calls"
}

@test "stage reads the staged entry back" {
    stage_verified
    assert grep -qF -- 'status --json' "$log/bootc-calls"
}

@test "pending.json records a staged deploy" {
    stage_verified
    assert_equal "$(jq -r '.phase' <<<"$(cat "$state_dir/pending.json")")" staged
}

@test "pending.json records the commit" {
    stage_verified
    assert_equal "$(jq -r '.commit' <<<"$(cat "$state_dir/pending.json")")" "$commit"
}

@test "pending.json records the index digest" {
    stage_verified
    assert_equal "$(jq -r '.digests.index' <<<"$(cat "$state_dir/pending.json")")" "$digest_index"
}

@test "pending.json records the manifest digest" {
    stage_verified
    assert_equal "$(jq -r '.digests.manifest' <<<"$(cat "$state_dir/pending.json")")" "$digest_manifest"
}

@test "pending.json carries no unused boot budget" {
    stage_verified
    assert_equal "$(jq -r 'has("budget")' <<<"$(cat "$state_dir/pending.json")")" false
}

@test "pending.json is on disk before the reboot is requested" {
    stage_verified
    assert grep -qF -- 'reboot pending=yes' "$log/systemctl-calls"
}

@test "the stage is journaled" {
    stage_verified
    assert_equal "$(journal_field stage-pending '.digest')" "$digest_index"
}

@test "staging records no landed deployment" {
    stage_verified
    assert [ ! -e "$state_dir/state.json" ]
}

@test "a clean stage notifies nothing" {
    stage_verified
    refute grep -qF -- "$ping_url" "$log/curl-urls"
}

# A switch returns before ostree-finalize-staged writes the entry. The poll must
# wait for the verified digest instead of accepting the stale staged entry.
stage_waits_for_finalize() {
    printf 'staged=%s\nbooted=%s\n' "$digest_other" "$digest_prev_manifest" >"$STUB_BOOTC_STATE"
    export STUB_BOOTC_STAGE_ON_SWITCH=$digest_manifest
    export STUB_BOOTC_STAGE_AFTER=2
    export STUB_BOOTC_STAGE_OLD=$digest_other
    run_stage --commit "$commit" --digests "$digests"
    unset STUB_BOOTC_STAGE_ON_SWITCH STUB_BOOTC_STAGE_AFTER STUB_BOOTC_STAGE_OLD
}

@test "a stage waits for the finalize to publish the verified digest" {
    stage_waits_for_finalize
    assert_equal "$rc" 0
}

@test "the waited-for stage writes its pending record" {
    stage_waits_for_finalize
    assert_equal "$(jq -r '.phase' <<<"$(cat "$state_dir/pending.json" 2>/dev/null)")" staged
}

@test "the waited-for stage reaches the reboot" {
    stage_waits_for_finalize
    assert grep -qF -- 'reboot' "$log/systemctl-calls"
}

# A restore that leaves the pre-switch entry unchanged must not claim success:
# the switch may not have overridden a pending finalize.
stage_restore_unchanged() {
    state_record_verified homelab-platform "$prev_commit" "$digest_prev_index" "$digest_prev_manifest"
    printf 'staged=%s\nbooted=%s\n' "$digest_prev_manifest" "$digest_other" >"$STUB_BOOTC_STATE"
    export STUB_BOOTC_STAGE_ON_SWITCH=$digest_prev_manifest
    run_stage --commit "$commit" --digests "$digests"
    unset STUB_BOOTC_STAGE_ON_SWITCH
}

@test "a restore that did not change the staged entry refuses" {
    stage_restore_unchanged
    assert_equal "$rc" 5
}

@test "the unchanged restore is journaled as a failure" {
    stage_restore_unchanged
    assert_equal "$(journal_field stage-restore-failed '.staged')" "$digest_prev_manifest"
}

@test "the unchanged restore writes no pending record" {
    stage_restore_unchanged
    assert [ ! -e "$state_dir/pending.json" ]
}

# bootc may report the index form for the same staged image, and a host that
# reports the form the reference did not use must still pass.
stage_index_form() {
    printf 'staged=%s\nbooted=%s\n' "$digest_index" "$digest_prev_manifest" >"$STUB_BOOTC_STATE"
    run_stage --commit "$commit" --digests "$digests"
}

@test "a staged image reported as the index form passes" {
    stage_index_form
    assert_equal "$rc" 0
}

@test "the index form still reaches the reboot" {
    stage_index_form
    assert grep -qF -- 'reboot' "$log/systemctl-calls"
}
