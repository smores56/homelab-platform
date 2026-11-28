#!/usr/bin/env bats
# bats file_tags=deploy
# smortress's greenboot check (SDLC #939): what "this host works" means.
#
# It reads the same list the post-boot gate read, so the properties to hold are
# that the list is honoured, that the pool is part of "serving", and that a slow
# boot is waited out rather than rolled back.
#
#   bats tests/deploy/smortress-health.bats
load ../helpers

check=bootc/server/rootfs/etc/greenboot/check/required.d/10-smortress-health.sh
drop_in=units/systemd/greenboot-healthcheck.service.d/10-timeout.conf
counter_unit=units/systemd/smortress-boot-counter.service
containerfile=bootc/server/Containerfile

setup() {
    bin=$BATS_TEST_TMPDIR/bin
    root=$BATS_TEST_TMPDIR/root
    rm -rf "$bin" "$root"
    mkdir -p "$bin" "$root"
    printf '# a comment\n\nfirewalld.service\ntailscaled.service\n' >"$root/units.txt"
    export GREENBOOT_DEPLOY_UNITS=$root/units.txt
    export GREENBOOT_SMORTRESS_BUDGET=0
    cat >"$bin/zpool" <<'STUB'
#!/usr/bin/env bash
# `zpool list` prints a degraded pool and still exits 0; only an unreadable pool
# fails, which is what $STUB_POOL_FAIL stands in for.
[[ ${STUB_POOL_FAIL:-0} == 1 ]] && exit 1
printf '%s\n' "${STUB_POOL:-ONLINE}"
STUB
    cat >"$bin/systemctl" <<'STUB'
#!/usr/bin/env bash
for argument; do last=$argument; done
[[ " ${STUB_INACTIVE:-} " == *" $last "* ]] && exit 3
exit 0
STUB
    chmod 0755 "$bin"/*
    export PATH=$bin:$PATH
}

@test "a serving host passes" {
    run "$check"
    assert_success
}

@test "a pool that is not ONLINE fails the deployment" {
    STUB_POOL=DEGRADED run "$check"
    assert_failure
    assert_contains "$output" "zpool: DEGRADED"
}

@test "a unit the list names but is not active fails the deployment" {
    STUB_INACTIVE=tailscaled.service run "$check"
    assert_failure
    assert_contains "$output" "tailscaled.service: not active"
    # The unit that is active is not blamed for it.
    [[ $output != *"firewalld.service: not active"* ]] ||
        fail "an active unit was reported as not active"
}

@test "a missing serving list fails instead of passing blind" {
    rm -f "$root/units.txt"
    run "$check"
    assert_failure
    assert_contains "$output" "missing or unreadable"
}

@test "the check ships executable, which is what makes greenboot run it" {
    [[ -x $check ]] || fail "$check is not executable: greenboot would skip it silently"
}

@test "the budget stays inside the timeout the drop-in gives the unit" {
    local budget limit
    budget=$(grep -o 'GREENBOOT_SMORTRESS_BUDGET:-[0-9]*' "$check" | grep -o '[0-9]*$')
    limit=$(grep -o 'TimeoutStartSec=[0-9]*' "$drop_in" | grep -o '[0-9]*$')
    [[ -n $budget ]] || fail "the budget is not a literal"
    [[ -n $limit ]] || fail "the drop-in sets no timeout"
    ((budget < limit)) || fail "a ${budget}s budget outlives the unit's ${limit}s limit"
}

@test "the counter unit names the snippet path this image ships" {
    # The installer is shared with the edge, whose snippet lives elsewhere; the
    # first boot of this image proved what happens when this unit stays silent.
    grep -qxF 'Environment=BOOT_COUNTER_SNIPPET=/usr/share/smortress/boot-counter.cfg' "$counter_unit" ||
        fail "the counter unit does not name this image's snippet"
}

# The snippet only moves a counter that is armed, and greenboot arms it when a
# deployment is staged (boot_counter=3, boot_success=0 before the reboot). Its
# unit is installed RequiredBy=ostree-finalize-staged.service, so the enablement
# is that dependency link, and the image asserts the link at build time.
@test "the image enables greenboot's set-counter, which arms the fallback" {
    grep -qE '^[[:space:]]+greenboot-grub2-set-counter\.service[[:space:]]*\\$' "$containerfile" ||
        fail "the Containerfile does not enable greenboot-grub2-set-counter.service: a staged deployment would carry no armed counter into its first boot"
    grep -qF -- 'test -e /etc/systemd/system/ostree-finalize-staged.service.requires/greenboot-grub2-set-counter.service' "$containerfile" ||
        fail "the build does not assert the set-counter dependency link"
}
