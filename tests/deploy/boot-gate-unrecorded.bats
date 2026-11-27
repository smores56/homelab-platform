#!/usr/bin/env bats
# bats file_tags=deploy
# A boot nobody recorded is paged, and a failed apps revert still decides the platform (§7b-§7c).
#
# One file of the suite that was tests/deploy/boot.bats, split so bats can run
# the sections in parallel; the fakes, the fixture, the drivers and the
# assertions are in boot_lib.bash.
#
#   bats tests/deploy/boot-gate-unrecorded.bats
load ../helpers
load ./boot_lib

setup_file() { bt_setup_file; }
setup() { bt_setup; }

# --- 7b. a boot nobody recorded is paged, never rolled back ----------------
# A crash between `bootc switch` and the pending record, or a staged entry a
# refused stage left behind, boots an image state.json does not name. It is the
# operator's image -- a hand-run switch is a choice -- but the state the poll
# compares against is wrong, so it is journaled and paged.
gate_unrecorded_boot() {
    state_record_verified homelab-platform "$commit" "$digest_index" "$digest_manifest"
    printf 'staged=\nbooted=%s\n' "$digest_other" >"$STUB_BOOTC_STATE"
    run_gate
}

@test "an unrecorded booted image is not a failure" {
    gate_unrecorded_boot
    assert_equal "$rc" 0
}

@test "the unrecorded boot is journaled with the digest that booted" {
    gate_unrecorded_boot
    assert_equal "$(journal_field booted-unrecorded '.booted')" "$digest_other"
}

@test "an unrecorded boot pages the deploy check" {
    gate_unrecorded_boot
    assert_equal "$(cat "$log/curl-urls")" "$ping_url/fail"
}

@test "an unrecorded boot is never rolled back" {
    gate_unrecorded_boot
    refute grep -qF -- 'rollback' "$log/bootc-calls"
}

# The recorded form, either way round, is silent.
gate_recorded_boot() {
    state_record_verified homelab-platform "$commit" "$digest_index" "$digest_manifest"
    printf 'staged=\nbooted=%s\n' "$digest_manifest" >"$STUB_BOOTC_STATE"
    run_gate
}

@test "a boot that matches the recorded digest passes" {
    gate_recorded_boot
    assert_equal "$rc" 0
}

@test "a recorded boot notifies nothing" {
    gate_recorded_boot
    assert [ ! -s "$log/curl-urls" ]
}

@test "a recorded boot is not journaled as unrecorded" {
    gate_recorded_boot
    assert_equal "$(journal_field booted-unrecorded '.booted')" ''
}

# --- 7c. a failed apps revert still decides the platform -------------------
# With no pending deploy the boot is fine and there is no platform decision: the
# failure is journaled and paged, and the record stays for the next gate or drain.
gate_failed_revert_no_pending() {
    jq -nc '{schema:1,phase:"installing",previousUnits:[],intendedUnits:[]}' | apply_write
    export STUB_APPS_EXIT=1
    run_gate
    unset STUB_APPS_EXIT
}

@test "a failed revert with no pending deploy leaves the boot alone" {
    gate_failed_revert_no_pending
    assert_equal "$rc" 0
}

@test "a failed revert is journaled" {
    gate_failed_revert_no_pending
    assert_equal "$(journal_field apply-revert-failed '.by')" boot-gate
}

@test "a failed revert keeps the record for the next run" {
    gate_failed_revert_no_pending
    assert [ -s "$state_dir/apply.json" ]
}

@test "a failed revert with no pending deploy pages the deploy check" {
    gate_failed_revert_no_pending
    assert_equal "$(cat "$log/curl-urls")" "$ping_url/fail"
}

# With a pending deployment that is what booted, a tenant nobody restored is a
# failed health gate: denylist the digest and roll back.
gate_failed_revert_staged() {
    seed_pending "$digest_index" "$digest_manifest" "$commit" "$digest_manifest"
    jq -nc '{schema:1,phase:"installing",previousUnits:[],intendedUnits:[]}' | apply_write
    export STUB_APPS_EXIT=1
    run_gate
    unset STUB_APPS_EXIT
}

@test "a failed revert on the staged boot fails the gate" {
    gate_failed_revert_staged
    assert_equal "$rc" 1
}

@test "the failed revert names the gate failure" {
    gate_failed_revert_staged
    assert_equal "$(journal_field boot-gate-failed '.reason')" apply-revert-failed
}

@test "a failed revert on the staged boot rolls back" {
    gate_failed_revert_staged
    assert_equal "$(last_bootc_call)" 'rollback --apply'
}

@test "a failed revert on the staged boot pages the deploy check" {
    gate_failed_revert_staged
    assert_equal "$(cat "$log/curl-urls")" "$ping_url/fail"
}

@test "a failed revert on the staged boot denylists the digest" {
    gate_failed_revert_staged
    assert_equal "$(jq -r --arg d "$digest_index" '.digests[$d].reason' <<<"$(denylist_json)")" \
        boot-gate:apply-revert-failed
}

@test "a failed gate keeps the pending record" {
    gate_failed_revert_staged
    assert [ -s "$state_dir/pending.json" ]
}
