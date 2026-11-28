#!/usr/bin/env bats
# bats file_tags=image
# The laptop image's checker, and the wiring that publishes it (SDLC #1023).
#
# hosts/laptop/tests/check.sh carries the laptop's static invariants onto the
# image: the base-tag doctrine, the package set the session calls, the NymVPN
# vendoring, the display re-probe, the `login` and `sudo` PAM stacks with the
# FIDO2 mapping behind them, and `bootc container lint`. It runs in the `image`
# area beside the server's and the edge's checkers.
#
# The checker is a plain shell script that prints its own `ok`/`FAIL` rows and
# exits 0, so what this file adds is the verdict, the mode CI invokes it by, and
# the fact that the workflow publishing it still covers the tree it reads: the
# laptop is the one host whose publish lives in its own workflow, and a path
# filter that stopped covering hosts/laptop/** would leave the image stale with
# every check still green.
#
#   bats tests/image/laptop-image.bats
load ../helpers

checker=hosts/laptop/tests/check.sh
workflow=.github/workflows/publish-laptop-image.yml

# contains <text> <file>: a failure names the line that went missing instead of a
# bare status, because these assertions read files rather than run commands.
contains() {
    grep -qF -- "$1" "$2" || fail "missing '$1' in $2"
}

@test "the laptop checker passes on the tree as committed" {
    run bash "$checker"
    assert_success
    refute_output --partial 'FAIL'
    # The lint is the image's own analysis: outside the image the run proves the
    # assertions and says so, rather than skipping silently.
    assert_output --partial '0 failed'
}

# CI invokes it by path, so the mode is part of the contract.
@test "the laptop checker is tracked as an executable" {
    run git ls-files -s "$checker"
    assert_output --partial '100755'
}

# The workflow is the only thing that publishes this image, and the checker
# itself asserts the build arguments it passes; what it cannot assert is that it
# runs at all, because the same tree also carries the build-argument rows.
@test "the laptop publish workflow covers the tree it builds" {
    contains '- "hosts/laptop/**"' "$workflow"
    contains './hosts/laptop/tests/check.sh' "$workflow"
    contains '-f hosts/laptop/Containerfile' "$workflow"
    contains '. hosts/laptop/pins.env' "$workflow"
    # The build context is the repository root: the key, the policy and the
    # sudoers gate live in lib/ (SDLC #1024).
    contains 'lib/containers/cosign.pub' "$workflow"
    contains '- "lib/**"' "$workflow"
}
