#!/usr/bin/env bats
# bats file_tags=deploy
# Stage refuses a staged digest nobody verified, records nothing and pages the deploy check (§2).
#
# One file of the suite that was tests/deploy/boot.bats, split so bats can run
# the sections in parallel; the fakes, the fixture, the drivers and the
# assertions are in boot_lib.bash.
#
#   bats tests/deploy/boot-stage-refused.bats
load ../helpers
load ./boot_lib

setup_file() { bt_setup_file; }
setup() { bt_setup; }

# --- 2. stage: a staged digest nobody verified refuses, records nothing -----
stage_unverified() {
    printf 'staged=%s\nbooted=%s\n' "$digest_other" "$digest_other" >"$STUB_BOOTC_STATE"
    run_stage --commit "$commit" --digests "$digests"
}

@test "a staged digest that is not the verified one is refused with exit 5" {
    stage_unverified
    assert_equal "$rc" 5
}

@test "a refused stage writes no pending record" {
    stage_unverified
    assert [ ! -e "$state_dir/pending.json" ]
}

@test "a refused stage never reboots" {
    stage_unverified
    refute grep -qF -- 'reboot' "$log/systemctl-calls"
}

@test "the refusal journals the digest bootc reported" {
    stage_unverified
    assert_equal "$(journal_field stage-digest-mismatch '.staged')" "$digest_other"
}

@test "the refusal journals the digest that was verified" {
    stage_unverified
    assert_equal "$(journal_field stage-digest-mismatch '.digest')" "$digest_index"
}

@test "a refused stage pages the deploy check" {
    stage_unverified
    assert_equal "$(head -n 1 "$log/curl-urls")" "$ping_url/fail"
}

# A manual `bootc upgrade` leaves the state naming an older commit. When the
# booted image is the verified one there is nothing to stage, and that must
# record the deployment rather than refuse a null staged entry.
stage_already_booted() {
    printf 'staged=\nbooted=%s\n' "$digest_manifest" >"$STUB_BOOTC_STATE"
    run_stage --commit "$commit" --digests "$digests"
}

@test "an already-booted verified image is recorded, not refused" {
    stage_already_booted
    assert_equal "$rc" 6
}

@test "an already-booted image never reboots" {
    stage_already_booted
    refute grep -qF -- 'reboot' "$log/systemctl-calls"
}

@test "the already-booted image is journaled" {
    stage_already_booted
    assert_equal "$(journal_field stage-already-booted '.commit')" "$commit"
}

@test "the already-booted image is recorded in state" {
    stage_already_booted
    assert_equal "$(jq -r '.repos["homelab-platform"].commit' <<<"$(state_json)")" "$commit"
}

# A stage always names the verified digest, so the tag cannot move underneath it.
# The already-booted case above covers a manual `bootc upgrade` that landed the
# same digest without the deploy.
stage_null_staged() {
    export STUB_BOOTC_NO_STAGED=1
    run_stage --commit "$commit" --digests "$digests"
    unset STUB_BOOTC_NO_STAGED
}

@test "a null staged entry is refused with exit 5" {
    stage_null_staged
    assert_equal "$rc" 5
}

@test "a null staged entry writes no pending record" {
    stage_null_staged
    assert [ ! -e "$state_dir/pending.json" ]
}

@test "a null staged entry never reboots" {
    stage_null_staged
    refute grep -qF -- 'reboot' "$log/systemctl-calls"
}

# The switch is already on disk, so a mismatch that is only refused would leave
# the next boot staging an image nobody verified. The other deployment is put back
# and the read-back has to prove it.
stage_restored() {
    state_record_verified homelab-platform "$prev_commit" "$digest_prev_index" "$digest_prev_manifest"
    printf 'staged=%s\nbooted=%s\n' "$digest_other" "$digest_other" >"$STUB_BOOTC_STATE"
    export STUB_BOOTC_STAGE_ON_SWITCH=$digest_prev_manifest
    run_stage --commit "$commit" --digests "$digests"
    unset STUB_BOOTC_STAGE_ON_SWITCH
}

@test "a refused stage still exits 5 after restoring the deployed image" {
    stage_restored
    assert_equal "$rc" 5
}

@test "the refused stage switches back to the recorded deployed digest" {
    stage_restored
    assert_equal "$(grep '^switch ' "$log/bootc-calls" | tail -n 1)" \
        "switch --enforce-container-sigpolicy $image_ref@$digest_prev_manifest"
}

@test "the restored staged entry is journaled with what bootc had staged" {
    stage_restored
    assert_equal "$(journal_field stage-restored '.from')" "$digest_other"
}

@test "a restored stage is not journaled as a failed restore" {
    stage_restored
    assert_equal "$(journal_field stage-restore-failed '.staged')" ''
}

@test "a restored stage writes no pending record" {
    stage_restored
    assert [ ! -e "$state_dir/pending.json" ]
}

@test "a restored stage never reboots" {
    stage_restored
    refute grep -qF -- 'reboot' "$log/systemctl-calls"
}

# A restore that also fails leaves the host one switch away from an unverified
# boot, which the operator has to hear about.
stage_restore_failed() {
    state_record_verified homelab-platform "$prev_commit" "$digest_prev_index" "$digest_prev_manifest"
    printf 'staged=%s\nbooted=%s\n' "$digest_other" "$digest_other" >"$STUB_BOOTC_STATE"
    run_stage --commit "$commit" --digests "$digests"
}

@test "a stage whose restore does not take still refuses" {
    stage_restore_failed
    assert_equal "$rc" 5
}

@test "the failed restore is journaled with the digest still staged" {
    stage_restore_failed
    assert_equal "$(journal_field stage-restore-failed '.staged')" "$digest_other"
}

@test "a failed restore pages the deploy check" {
    stage_restore_failed
    assert_equal "$(tail -n 1 "$log/curl-urls")" "$ping_url/fail"
}
