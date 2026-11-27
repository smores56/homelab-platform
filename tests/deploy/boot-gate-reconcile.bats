#!/usr/bin/env bats
# bats file_tags=deploy
# No pending record: the gate only reconciles an interrupted apps apply (§7).
#
# One file of the suite that was tests/deploy/boot.bats, split so bats can run
# the sections in parallel; the fakes, the fixture, the drivers and the
# assertions are in boot_lib.bash.
#
#   bats tests/deploy/boot-gate-reconcile.bats
load ../helpers
load ./boot_lib

setup_file() { bt_setup_file; }
setup() { bt_setup; }

# --- 7. no pending record: reconcile only ----------------------------------
# An interrupted apps apply is reverted by the gate itself; with no pending
# platform deployment nothing else happens -- no bootc, no health check.
gate_no_pending() {
    jq -nc '{schema:1,phase:"pulling",previousUnits:[],intendedUnits:[]}' | apply_write
    run_gate
}

@test "a boot with no pending deploy passes" {
    gate_no_pending
    assert_equal "$rc" 0
}

@test "an interrupted apps apply is journaled with its phase" {
    gate_no_pending
    assert_equal "$(journal_field apply-interrupted '.phase')" pulling
}

@test "the gate calls the apps revert" {
    gate_no_pending
    assert grep -qF -- 'revert' "$log/apps-calls"
}

@test "the gate journals the reverted apply" {
    gate_no_pending
    assert_equal "$(journal_field apply-reverted '.by')" boot-gate
}

@test "the reverted apply clears the record" {
    gate_no_pending
    assert [ ! -e "$state_dir/apply.json" ]
}

@test "no pending deploy means no rollback" {
    gate_no_pending
    refute grep -qF -- 'rollback' "$log/bootc-calls"
}

@test "a boot with no pending deploy marks the boot good" {
    gate_no_pending
    assert_equal "$(grub_flags '.boot_success')" 1
}

@test "a boot with no pending deploy resets the boot counter" {
    gate_no_pending
    assert_equal "$(grub_flags '.boot_counter')" 3
}

@test "a boot with no pending deploy clears the GRUB default" {
    gate_no_pending
    assert_equal "$(grub_flags '.default')" null
}

# The operator's documented check reads this file, so it has to say what the
# comment in the runbook says: the boot is good and the counter is whole.
@test "the operator's 'boot_success=1 boot_counter=3' check is true after an ordinary boot" {
    gate_no_pending
    assert grep -qx 'boot_success=1' "$GRUB_ENV"
    assert grep -qx 'boot_counter=3' "$GRUB_ENV"
}

@test "a quiet boot notifies nothing" {
    gate_no_pending
    assert [ ! -s "$log/curl-urls" ]
}

@test "a quiet boot runs no health checks" {
    gate_no_pending
    assert [ ! -s "$log/systemctl-calls" ]
}

# With a pending deployment the revert still comes first: the health gate must
# judge the revision the recorded plan names, not a half-applied tenant.
gate_matching_with_interrupted_apply() {
    seed_pending "$digest_index" "$digest_manifest" "$commit" "$digest_manifest"
    jq -nc '{schema:1,phase:"installing",previousUnits:[],intendedUnits:[]}' | apply_write
    run_gate
    revert_line=$(grep -n 'deploy-apps revert' "$log/gate-order" | head -n 1 | cut -d: -f1)
    first_check=$(grep -n 'is-active' "$log/gate-order" | head -n 1 | cut -d: -f1)
}

@test "a matching boot with an interrupted apply passes" {
    gate_matching_with_interrupted_apply
    assert_equal "$rc" 0
}

@test "the apps revert runs before the health checks" {
    gate_matching_with_interrupted_apply
    assert [ -n "$revert_line" ]
    assert [ -n "$first_check" ]
    assert [ "$revert_line" -lt "$first_check" ]
}

@test "a pending boot clears the reverted apply" {
    gate_matching_with_interrupted_apply
    assert [ ! -e "$state_dir/apply.json" ]
}

# An ordinary boot must not spend the counter: the GRUB snippet decrements it on
# every boot before userspace, and a gate that only reset it for a pending deploy
# would fall back to the previous deployment after three quiet reboots.
ordinary_boots() { # <count>: replay the snippet and the gate that many times
    for boot in $(seq 1 "$1"); do
        # What the GRUB snippet does before userspace: the boot is unproven, one
        # attempt is spent, and at zero the previous entry is selected.
        counter=$(grub_flags '.boot_counter')
        [[ -n $counter ]] || counter=3
        {
            printf 'boot_success=0\n'
            if ((counter > 0)); then
                printf 'boot_counter=%s\n' "$((counter - 1))"
                [[ $(grub_flags '.default') == null ]] ||
                    printf 'default=%s\n' "$(grub_flags '.default')"
            else
                printf 'boot_counter=-1\ndefault=1\n'
            fi
        } >"$GRUB_ENV"
        run_gate
    done
}

ordinary_boot_keeps_the_counter() { # <boot the assertion is about>
    ordinary_boots "$1"
    assert_equal "$(grub_flags '.default')" null
    assert_equal "$(grub_flags '.boot_counter')" 3
    assert_equal "$(grub_flags '.boot_success')" 1
}

for boot in 1 2 3; do
    register "ordinary boot $boot keeps the counter reset and the default cleared" \
        ordinary_boot_keeps_the_counter "$boot"
done
