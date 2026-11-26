#!/usr/bin/env bats
# bats file_tags=image
# The `server-image` area checks, as bats (SDLC #907, T13).
#
# The group was a chain of commands in the old driver:
#
#   scripts/check-server-image.sh
#   scripts/render-ignition.sh --synthetic --check
#   tests/core/ignition-boundary.sh            -> tests/image/ignition-boundary.bats
#   scripts/render-ignition.sh --synthetic --stock --check
#
# The Ignition boundary suite is its own file; this one holds the two commands
# that are assertions by exiting 0. check-server-image.sh prints its own ~770
# per-check `ok` lines and its verdict, so the file does not restate them: what
# the group proved about the image is that command's exit status, and a failure
# here is reproduced with `bash scripts/check-server-image.sh`.
#
#   bats tests/image/server-image.bats
load ../helpers

static_checks=scripts/check-server-image.sh
renderer=scripts/render-ignition.sh

@test "server image static checks passed" {
    run "$static_checks"
    assert_success
}

# --check only validates the Butane source with the pinned binary; the two forms
# differ in whether the autorebase units survive, so both are the group's claim.
@test "the synthetic render passes --check, stock and FCOS media" {
    run "$renderer" --synthetic --check
    assert_success
    run "$renderer" --synthetic --stock --check
    assert_success
}
