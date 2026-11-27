#!/usr/bin/env bats
# bats file_tags=deploy
# The gate fails closed when a core unit is inactive: rollback, denylist, page, counter (§4).
#
# One file of the suite that was tests/deploy/boot.bats, split so bats can run
# the sections in parallel; the fakes, the fixture, the drivers and the
# assertions are in boot_lib.bash.
#
#   bats tests/deploy/boot-gate-unit-inactive.bats
load ../helpers
load ./boot_lib

setup_file() { bt_setup_file; }
setup() { bt_setup; }

# --- 4. the gate fails closed on an unhealthy host -------------------------
# Each case names one host check, so a check that stops working is visible as the
# one assertion that fails rather than as "the gate is stricter now".
# shellcheck disable=SC2043 # one case per file: the four cases are four parallel suites
for case in unit-inactive; do
    register "$case fails the gate" unhealthy_fails "$case"
    register "$case rolls back with the apply argv" unhealthy_rollback "$case"
    register "the index digest is denylisted after $case" unhealthy_index_denied "$case"
    register "the manifest digest is denylisted after $case" unhealthy_manifest_denied "$case"
    register "$case pages the deploy check" unhealthy_pages "$case"
    register "$case keeps the pending record for the next boot" unhealthy_pending_kept "$case"
    register "$case records no landed deployment" unhealthy_no_state "$case"
    register "the abandon path spends the boot counter after $case" unhealthy_counter "$case"
    register "the abandon path clears boot_success after $case" unhealthy_boot_success "$case"
    register "the abandon path selects entry 0 after $case" unhealthy_default "$case"
    register "the failure is journaled with its reason after $case" unhealthy_journal "$case"
done
