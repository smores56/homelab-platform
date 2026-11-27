#!/usr/bin/env bats
# bats file_tags=deploy
# The edge's boot counter (SDLC #939): greenboot's GRUB snippet delivered where
# this host's grub.cfg actually reads it.
#
# grub.cfg is generated once by bootupd and never regenerated, so the snippet
# greenboot ships in bootupd's configs.d never reaches it. grub.cfg ends with
# `41_custom.cfg`, which sources /boot/grub2/custom.cfg, so the installer puts
# the package's own script there. The suite drives the real installer against a
# fake /boot rather than a reimplementation, because a copy of the counter logic
# is exactly the second answer to boot_success/boot_counter that the package
# exists to be.
#
#   bats tests/deploy/edge-boot-counter.bats
load ../helpers

counter=scripts/boot-counter-install.sh
installer_unit=bootc/edge/rootfs/usr/lib/systemd/system/smoresnet-boot-counter.service
rw_unit=bootc/edge/rootfs/usr/lib/systemd/system/smoresnet-boot-rw.service

# The snippet is greenboot's own at boot; here it only has to be a file whose
# content is copied or not, so it carries the one word the installer verifies.
snippet_text='if [ -n "${boot_counter}" ]; then decrement boot_counter; fi'

setup() {
    root=$BATS_TEST_TMPDIR/root
    bin=$BATS_TEST_TMPDIR/bin
    rm -rf "$root" "$bin"
    mkdir -p "$bin"
    install -D -m 0755 "$counter" "$root/usr/libexec/boot-counter"
    install -D -m 0644 scripts/lib/log.sh "$root/usr/libexec/lib/log.sh"
    snippet=$root/usr/lib/bootupd/grub2-static/configs.d/08_greenboot.cfg
    install -D -m 0644 /dev/null "$snippet"
    printf '%s\n' "$snippet_text" >"$snippet"
    target=$root/boot/grub2/custom.cfg
    mkdir -p "$root/boot/grub2"

    # mount, as far as the installer can tell: it records the call and, for the
    # read-only case, makes the directory writable the way a remount would.
    cat >"$bin/mount" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$MOUNT_LOG"
for argument; do last=$argument; done
chmod u+w "$last"
exit "${STUB_MOUNT_EXIT:-0}"
STUB
    chmod 0755 "$bin/mount"
    export MOUNT_LOG=$BATS_TEST_TMPDIR/mount-calls
    : >"$MOUNT_LOG"
    export MOUNT_BIN=$bin/mount
    export BOOT_COUNTER_SNIPPET=$snippet
    export BOOT_COUNTER_BOOT_DIR=$root/boot
}

run_installer() {
    run "$root/usr/libexec/boot-counter"
}

@test "the snippet is installed where grub.cfg sources it" {
    run_installer
    assert_equal "$status" 0
    cmp -s "$snippet" "$target" ||
        fail "custom.cfg is not the snippet" "$(diff -u "$snippet" "$target" | head -20)"
    # Nothing was remounted: the directory was already writable.
    assert_equal "$(cat "$MOUNT_LOG")" ""
}

@test "an installed counter is left alone and never remounts /boot" {
    run_installer
    assert_equal "$status" 0
    : >"$MOUNT_LOG"
    run_installer
    assert_equal "$status" 0
    assert_equal "$(cat "$MOUNT_LOG")" ""
    assert_contains "$output" "already installed"
}

@test "a missing snippet fails instead of booting blind" {
    rm -f "$snippet"
    run_installer
    assert_equal "$status" 1
    assert_contains "$output" "the image's boot counter snippet was not installed"
    [[ ! -e $target ]] || fail "an absent snippet still wrote a counter"
}

@test "a read-only /boot is remounted before the install" {
    chmod 0555 "$root/boot"
    run_installer
    assert_equal "$status" 0
    assert_contains "$(cat "$MOUNT_LOG")" "remount,rw"
    cmp -s "$snippet" "$target" || fail "the counter was not installed after the remount"
}

@test "a /boot that cannot be remounted is an error, not a silent skip" {
    chmod 0555 "$root/boot"
    STUB_MOUNT_EXIT=32 run_installer
    assert_equal "$status" 1
    assert_contains "$output" "cannot make"
}

@test "the installer runs before greenboot's healthcheck, which needs it" {
    grep -qxF 'Before=greenboot-healthcheck.service' "$installer_unit" ||
        fail "greenboot could health-check before the counter it writes exists"
    grep -qxF 'Requires=smoresnet-boot-rw.service' "$installer_unit" ||
        fail "the installer no longer depends on the writable /boot it needs"
    grep -qxF 'ExecStart=/usr/libexec/boot-counter' "$installer_unit" ||
        fail "the unit does not run the installed program"
    grep -qxF 'Before=greenboot-healthcheck.service smoresnet-boot-counter.service' "$rw_unit" ||
        fail "/boot is remounted after the units that write it"
}
