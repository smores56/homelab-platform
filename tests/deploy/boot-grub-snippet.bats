#!/usr/bin/env bats
# bats file_tags=deploy
# The snippet the image installs, the missing GRUB tool, and where the counter is read (§8-§11).
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
# The snippet's content is greenboot's, so the tree keeps no copy of it to
# assert against: the image copies the package's 08_greenboot.cfg to its own path
# and removes it from bootupd's directory, because a regeneration that injected
# it would run the counter twice in one boot.

@test "the image ships greenboot's snippet at the path its installer reads" {
    assert grep -qF -- \
        'install -m 0644 /usr/lib/bootupd/grub2-static/configs.d/08_greenboot.cfg /usr/share/smortress/boot-counter.cfg' \
        "$containerfile"
}

@test "the image removes the snippet from bootupd's directory" {
    assert grep -qF -- 'rm -f /usr/lib/bootupd/grub2-static/configs.d/08_greenboot.cfg' "$containerfile"
}

@test "no hand-rolled copy of the counter ships in the tree" {
    assert [ ! -e bootc/server/rootfs/usr/lib/bootupd/grub2-static/configs.d ]
}

@test "a hung PID 1 becomes a reboot the counter can act on" {
    assert grep -qF -- 'RuntimeWatchdogSec=1min' bootc/server/rootfs/etc/systemd/system.conf.d/10-watchdog.conf
}

# A panic reboot without a bootloader counter loops the same image forever, so
# the image must not ship one until counting is installed on the host.
@test "no panic reboot ships without a counter" {
    assert [ ! -e bootc/server/rootfs/etc/sysctl.d/10-panic.conf ]
}

# --- 11. the counter is the file GRUB sources, /boot/grub2/custom.cfg -------
# The predicate used to grep grub.cfg, which bootupd generated once and never
# regenerates, so every boot journaled boot-counting-absent while the snippet sat
# in custom.cfg and the counter never reset. These cases pin the new path.
clean_boot() {
    # A clean boot: no deployment record, nothing to revert, and the units a
    # healthy host has. The earlier cases deliberately broke both.
    rm -f "$state_dir/pending.json" "$state_dir/apply.json"
    printf 'core-one.service\ncore-two.service\n' >"$STUB_SYSTEMCTL_ACTIVE"
    : >"$STUB_SYSTEMCTL_FAILED"
    run_gate
}

gate_with_boot_counting() {
    clean_boot
}

gate_without_boot_counting() {
    # The only file that reads the counter is gone: the installer never reached
    # custom.cfg, while the decoy grub.cfg still reads it.
    rm -f "$GRUB_CUSTOM_CFG"
    printf 'boot_success=0\nboot_counter=0\ndefault=1\n' >"$GRUB_ENV"
    clean_boot
}

@test "a host whose custom.cfg reads the counter is marked good" {
    gate_with_boot_counting
    assert_equal "$rc" 0
    assert_equal "$(grub_flags '.boot_success')" 1
    assert_equal "$(grub_flags '.boot_counter')" 3
    assert_equal "$(grub_flags '.default')" null
}

@test "a host with the snippet in custom.cfg journals no boot-counting-absent" {
    gate_with_boot_counting
    refute grep -qF -- 'boot-counting-absent' "$state_dir/journal.jsonl"
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
        "custom.cfg does not read boot_counter"
}

@test "a grub.cfg that reads the counter is not the file the gate looks at" {
    gate_without_boot_counting
    assert grep -qF -- 'set boot_counter=3' "$GRUB_CFG"
    assert_equal "$(journal_field boot-counting-absent '.reason' | tail -1)" \
        "custom.cfg does not read boot_counter"
}
