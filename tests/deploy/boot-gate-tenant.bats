#!/usr/bin/env bats
# bats file_tags=deploy
# A tenant failure never fails the gate: the four tenant cases pass, record and page green (§4).
#
# One file of the suite that was tests/deploy/boot.bats, split so bats can run
# the sections in parallel; the fakes, the fixture, the drivers and the
# assertions are in boot_lib.bash.
#
#   bats tests/deploy/boot-gate-tenant.bats
load ../helpers
load ./boot_lib

setup_file() { bt_setup_file; }
setup() { bt_setup; }

# The three tenant failures that used to fail this gate are a pass now: an
# inactive unit, a Serve list without the path, and a port nothing answers (the
# default fixture, since the suite binds no listener at all). A check that comes
# back shows up here as a rollback rather than as a stricter gate nobody noticed.
for case in tenant-unit-inactive serve-path-missing ingress-unreachable plan-unreadable; do
    register "$case does not fail the gate" tenant_passes "$case"
    register "$case rolls nothing back" tenant_no_rollback "$case"
    register "$case records the deployment" tenant_records_deployment "$case"
    register "$case records a landed deployment" tenant_landed_record "$case"
    register "$case denylists nothing" tenant_no_denylist "$case"
    register "$case pages the deploy check green" tenant_pages_green "$case"
done
