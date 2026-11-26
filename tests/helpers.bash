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
# bats only understands a literal `@test`. The tag is read from the file's own
# `# bats file_tags=` line, which does not cover a test registered this way, so
# a suite's area is written once. bats resolves the description with `eval`, so
# it must stay a literal or a value from the tree, never plan or tenant data.
# The tag is derived from the path, not read from the file: every test of every
# file sources this file and re-runs its registration loops, so a subprocess here
# costs one fork per registered test (97 per app-quadlets test, which hung the
# gate). tests/tags.bats holds this table to the `# bats file_tags=` lines.
register() {
    case $BATS_TEST_FILENAME in
        */tests/*/*.bats) tag=${BATS_TEST_FILENAME#*tests/}; tag=${tag%%/*} ;;
        */tests/lint.bats | */tests/tags.bats) tag=lint ;;
        */tests/docs.bats) tag=docs ;;
        */tests/actionlint.bats) tag=actionlint ;;
        */tests/tofu-fmt.bats) tag=tofu ;;
        *) tag=lint ;;
    esac
    bats_test_function --tags "$tag" --description "$1" -- "${@:2}"
}

# bats identifies a test by its command and arguments, so both must be unique:
# the description travels as an argument for that reason.
bats_skip() { skip "$2"; }

# register_skip <description> <reason>: a test this host cannot run. It is
# reported as skipped rather than omitted, so a closed host gate is visible and
# never mistaken for a proof.
register_skip() { register "$1" bats_skip "$1" "$2"; }
