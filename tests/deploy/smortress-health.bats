#!/usr/bin/env bats
# bats file_tags=deploy
# smortress's greenboot check (SDLC #939): what "this host works" means.
#
# It reads the same list the post-boot gate read, so the properties to hold are
# that the list is honoured, that the pool is part of "serving", and that a slow
# boot is waited out rather than rolled back.
#
# The check is the shared program (lib/greenboot/required.d) and what it asserts
# is this host's file (lib/greenboot/assertions.d/server), which is the file the
# image installs into /etc/greenboot/assertions.d (SDLC #1024). The suite points
# the program at the host's directory, so what runs here is what greenboot runs
# on smortress, not a copy of it.
#
#   bats tests/deploy/smortress-health.bats
load ../helpers

check=lib/greenboot/required.d/10-health.sh
assertions=lib/greenboot/assertions.d/server/10-health.sh
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
    export GREENBOOT_ASSERTIONS_DIR=$repo_root/lib/greenboot/assertions.d/server
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

# The budget is this host's, so it lives in the assertion file, and a program
# with no assertions must not pass a host nobody checked.
@test "the shared check refuses to run without this host's assertions" {
    GREENBOOT_ASSERTIONS_DIR=$BATS_TEST_TMPDIR/none run "$check"
    assert_failure
    assert_contains "$output" "expected exactly one"
}

@test "the budget stays inside the timeout the drop-in gives the unit" {
    local budget limit
    budget=$(grep -o 'GREENBOOT_SMORTRESS_BUDGET:-[0-9]*' "$assertions" | grep -o '[0-9]*$')
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

# greenboot 0.16 (Rust) renamed its staged-deployment unit to
# greenboot-set-rollback-trigger.service, and the unit still hangs off
# ostree-finalize-staged.service as a RequiredBy= link. Since 0.16 it records the
# staged deployment id rather than arming boot_counter, so the counter is armed by
# the gate at rest; what the link still buys is greenboot making a bootloader
# fallback permanent. The enablement is that link, and the image asserts it.
@test "the image enables greenboot's rollback trigger, which records the staged deployment" {
    grep -qE '^[[:space:]]+greenboot-set-rollback-trigger\.service[[:space:]]*\\$' "$containerfile" ||
        fail "the Containerfile does not enable greenboot-set-rollback-trigger.service: a deployment the bootloader dropped would boot again instead of being made permanent"
    grep -qF -- 'test -e /etc/systemd/system/ostree-finalize-staged.service.requires/greenboot-set-rollback-trigger.service' "$containerfile" ||
        fail "the build does not assert the rollback trigger dependency link"
}
