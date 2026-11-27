#!/usr/bin/env bats
# bats file_tags=deploy
# The health gate's retry budget, and a boot the bootloader already rolled back (§5-§6).
#
# One file of the suite that was tests/deploy/boot.bats, split so bats can run
# the sections in parallel; the fakes, the fixture, the drivers and the
# assertions are in boot_lib.bash.
#
#   bats tests/deploy/boot-gate-rolled-back.bats
load ../helpers
load ./boot_lib

setup_file() { bt_setup_file; }
setup() { bt_setup; }

# --- 5. the health gate retries inside its budget, then fails closed -------
health_budget_exhausted() {
    seed_pending "$digest_index" "$digest_manifest" "$commit" "$digest_manifest"
    printf 'core-one.service\n' >"$STUB_SYSTEMCTL_ACTIVE"
    started=$(date -u +%s)
    run_gate
    elapsed=$(($(date -u +%s) - started))
    attempts=$(grep -c 'is-active core-two.service' "$log/systemctl-calls")
}

# The parenthetical is the count the shell suite observed under this budget: the
# assertion is the same one it made -- the gate looked more than once -- and the
# text is kept because parity compares it.
@test "the health gate retries inside its budget (3 attempts)" {
    health_budget_exhausted
    ((attempts >= 2)) || printf '%s attempts\n' "$attempts" >&2
    ((attempts >= 2))
}

@test "the retries are spread over the budget (2s)" {
    health_budget_exhausted
    ((elapsed >= 1)) || printf '%ss\n' "$elapsed" >&2
    ((elapsed >= 1))
}

@test "an exhausted health budget fails the gate" {
    health_budget_exhausted
    assert_equal "$rc" 1
}

@test "an exhausted health budget rolls back" {
    health_budget_exhausted
    assert_equal "$(last_bootc_call)" 'rollback --apply'
}

# --- 6. a boot the bootloader already rolled back --------------------------
# The counter fell back (or an operator did): the staged deployment is not
# running, so there is nothing to roll back -- but the digest is refused and the
# stale record is consumed, so a later manual reboot cannot roll a healthy host
# back either.
gate_rolled_back_by_bootloader() {
    seed_pending "$digest_index" "$digest_manifest" "$commit" "$digest_other"
    printf 'boot_success=0\nboot_counter=0\ndefault=1\n' >"$GRUB_ENV"
    run_gate
}

@test "a booted digest that is not the staged one is not a failure" {
    gate_rolled_back_by_bootloader
    assert_equal "$rc" 0
}

@test "the rollback is journaled with the deployment that booted" {
    gate_rolled_back_by_bootloader
    assert_equal "$(journal_field rolled-back-by-bootloader '.booted')" "$digest_other"
}

@test "a rolled-back index digest is denylisted" {
    gate_rolled_back_by_bootloader
    assert_equal "$(jq -r --arg d "$digest_index" '.digests[$d].reason' <<<"$(denylist_json)")" \
        rolled-back-by-bootloader
}

@test "a rolled-back manifest digest is denylisted" {
    gate_rolled_back_by_bootloader
    assert_equal "$(jq -r --arg d "$digest_manifest" '.digests[$d].reason' <<<"$(denylist_json)")" \
        rolled-back-by-bootloader
}

@test "the gate does not roll back a boot the bootloader chose" {
    gate_rolled_back_by_bootloader
    refute grep -qF -- 'rollback' "$log/bootc-calls"
}

@test "a rolled-back deploy consumes the pending record" {
    gate_rolled_back_by_bootloader
    assert [ ! -e "$state_dir/pending.json" ]
}

@test "a rollback pages the deploy check" {
    gate_rolled_back_by_bootloader
    assert_equal "$(cat "$log/curl-urls")" "$ping_url/fail"
}

@test "a rolled-back boot resets the GRUB default" {
    gate_rolled_back_by_bootloader
    assert_equal "$(grub_flags '.default')" null
}

@test "a rolled-back boot resets the boot counter" {
    gate_rolled_back_by_bootloader
    assert_equal "$(grub_flags '.boot_counter')" 3
}

@test "a rolled-back boot marks the boot good" {
    gate_rolled_back_by_bootloader
    assert_equal "$(grub_flags '.boot_success')" 1
}

@test "a rolled-back deployment records nothing" {
    gate_rolled_back_by_bootloader
    assert [ ! -e "$state_dir/state.json" ]
}

@test "a rolled-back boot runs no health checks" {
    gate_rolled_back_by_bootloader
    refute grep -qF -- 'is-active' "$log/systemctl-calls"
}
