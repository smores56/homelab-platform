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

# The suites exercise scripts that expect the checkout as their cwd.
cd "$repo_root" || return 1

# assert_contains <haystack> <needle>: for output a suite captured itself
# (assert_output reads only `$output`, which `run` fills).
assert_contains() {
    if [[ $1 != *"$2"* ]]; then
        printf 'missing %q in:\n%s\n' "$2" "$1" >&2
        return 1
    fi
}

# register <description> <command...>: a @test a suite generates in a loop —
# bats only understands a literal `@test`. The tag is the file's own path under
# tests/, because a test registered this way is not covered by `# bats
# file_tags` and --filter-tags would otherwise never select it.
register() {
    tag=${BATS_TEST_FILENAME##*/tests/}
    bats_test_function --tags "${tag%.bats}" --description "$1" -- "${@:2}"
}
