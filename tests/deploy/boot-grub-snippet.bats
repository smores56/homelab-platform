#!/usr/bin/env bats
# bats file_tags=deploy
# The GRUB snippet that ships, the missing tool, and the counter a host's GRUB never reads (§8-§11).
#
# One file of the suite that was tests/deploy/boot.bats, split so bats can run
# the sections in parallel; the fakes, the fixture, the drivers and the
# assertions are in boot_lib.bash.
#
#   bats tests/deploy/boot-grub-snippet.bats
load ../helpers
load ./boot_lib

setup_file() { bt_setup_file; }
setup() { bt_setup; }

# --- 8. a host without grub2-editenv says so instead of doing nothing ------
# The counter is the only pre-userspace rollback; a host that cannot reset it
# must journal the gap rather than leave it invisible.
gate_missing_grub_tool() {
    seed_pending "$digest_index" "$digest_manifest" "$commit" "$digest_manifest"
    export GRUB_EDITEV=$work/no-such-grub-tool
    run_gate
    unset GRUB_EDITEV
}

@test "a missing GRUB tool does not undo a healthy boot" {
    gate_missing_grub_tool
    assert_equal "$rc" 0
}

@test "a missing GRUB tool is journaled" {
    gate_missing_grub_tool
    assert_equal "$(journal_field grub-tool-missing '.tool')" "$work/no-such-grub-tool"
}

@test "the deployment is still recorded without the GRUB tool" {
    gate_missing_grub_tool
    assert [ -s "$state_dir/state.json" ]
}

@test "no GRUB write is attempted without the tool" {
    gate_missing_grub_tool
    assert [ ! -s "$log/grub-calls" ]
}

# --- 9. a failed rollback is never silent ---------------------------------
gate_failed_rollback() {
    seed_pending "$digest_index" "$digest_manifest" "$commit" "$digest_manifest"
    printf 'core-one.service\n' >"$STUB_SYSTEMCTL_ACTIVE"
    export STUB_BOOTC_ROLLBACK_EXIT=1
    run_gate
    unset STUB_BOOTC_ROLLBACK_EXIT
}

@test "a rollback that fails fails the gate" {
    gate_failed_rollback
    assert_equal "$rc" 1
}

@test "the failed rollback is journaled" {
    gate_failed_rollback
    assert_equal "$(journal_field rollback-failed '.exit')" 1
}

# --- 10. the boot counter ships with the image ----------------------------

@test "the GRUB snippet clears boot_success on every boot" {
    assert grep -qF -- 'set boot_success=0' "$snippet"
}

@test "the GRUB snippet counts the attempts" {
    assert grep -qF -- 'boot_counter=' "$snippet"
}

@test "the GRUB snippet falls back to the previous deployment" {
    assert grep -qF -- 'set default=1' "$snippet"
}

@test "a hung PID 1 becomes a reboot the counter can act on" {
    assert grep -qF -- 'RuntimeWatchdogSec=1min' bootc/server/rootfs/etc/systemd/system.conf.d/10-watchdog.conf
}

# A panic reboot without a bootloader counter loops the same image forever, so
# the image must not ship one until counting is installed on the host.
@test "no panic reboot ships without a counter" {
    assert [ ! -e bootc/server/rootfs/etc/sysctl.d/10-panic.conf ]
}

# --- 11. a host whose GRUB does not read the counter says so ----------------
# bootupd reports every component current and never regenerates grub.cfg, so the
# variables are written nowhere it would be read: the gate must journal that and
# still decide the deployment.
gate_without_boot_counting() {
    printf 'menuentry nothing\n' >"$GRUB_CFG"
    printf 'boot_success=0\nboot_counter=0\ndefault=1\n' >"$GRUB_ENV"
    # A clean boot: no deployment record, nothing to revert, and the units a
    # healthy host has. The previous cases deliberately broke both.
    rm -f "$state_dir/pending.json" "$state_dir/apply.json"
    printf 'core-one.service\ncore-two.service\n' >"$STUB_SYSTEMCTL_ACTIVE"
    : >"$STUB_SYSTEMCTL_FAILED"
    run_gate
}

@test "a host without boot counting still finishes the gate" {
    gate_without_boot_counting
    assert_equal "$rc" 0
}

@test "the counter is left untouched without counting" {
    gate_without_boot_counting
    assert_equal "$(grub_flags '.boot_counter')" 0
}

@test "the missing counter is journaled" {
    gate_without_boot_counting
    assert_equal "$(journal_field boot-counting-absent '.reason' | tail -1)" \
        "grub.cfg does not read boot_counter"
}
