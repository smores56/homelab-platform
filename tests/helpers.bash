# shellcheck shell=bash
# Sourced by every .bats file: the checkout the scripts run against, the pinned
# assertion libraries, and the table helper a suite needs.

# `load` may hand over a bare name, so fall back to the test's own dir.
helpers_dir=$(dirname -- "${BASH_SOURCE[0]}")
case $helpers_dir in /*) ;; *) helpers_dir=$BATS_TEST_DIRNAME ;; esac
# shellcheck disable=SC2034 # the suites read it
repo_root=$(CDPATH='' cd -- "$helpers_dir/.." && pwd -P)

# bats searches only $BATS_LIB_PATH, which defaults to /usr/lib/bats: no root
# here, and the same path on every host. Assigned, never appended: an inherited
# entry could shadow the pinned library. scripts/install-ci-tools.sh fills it.
BATS_LIB_PATH=${BATS_LIB_DEST:-${XDG_DATA_HOME:-$HOME/.local/share}/bats}
export BATS_LIB_PATH
bats_load_library bats-support
bats_load_library bats-assert

# run --separate-stderr is load-bearing: assert_silent checks both streams.
bats_require_minimum_version 1.5.0
assert_silent() {
    # shellcheck disable=SC2154 # bats sets both from the last `run`
    assert_equal "$output$stderr" ""
}

# The suites exercise scripts that expect the checkout as their cwd.
cd "$repo_root" || return 1
