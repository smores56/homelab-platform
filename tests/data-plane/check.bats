#!/usr/bin/env bats
# bats file_tags=data-plane
# Data-plane unit tests. Static only: no cluster, no credentials, no network.
# Covers contracts, identity, journal, broker, backup, collectors, memory, CLI,
# restore planning, and the migration gates (phases, preflight, data-loss
# verification, rollback planning).
#
#   bats tests/data-plane/check.bats
#
# The shell suite this replaced ran `unittest discover` over the directory and
# printed one line per unittest case, so the whole group asserted a single thing:
# the exit status of that run. Here each test module is its own test -- the module
# is the group of assertions and its cases are untouched -- so a failure names the
# module it came from instead of a line in one shared log.
load ../helpers

group=data-plane

# The group command ran this before the suite, so it stays a file bootstrap: a
# stale rendered schema fails every test in the file the way it failed the group.
setup_file() {
    python3 scripts/render-source-schemas.py --check
}

# libs/ is where the tests import from, and the shell suite put only that on the
# path: a module has to resolve the same way here.
setup() {
    export PYTHONPATH="$repo_root/libs${PYTHONPATH:+:$PYTHONPATH}"
    export PYTHONDONTWRITEBYTECODE=1
}

# module_passes <test module>: discover over that one file, as the suite
# discovered the directory, and read the exit status. assert_success prints the
# module's own output, so a failure still carries unittest's traceback.
module_passes() {
    run python3 -m unittest discover -s "tests/$group" -t "tests/$group" -p "$1"
    assert_success
}

# One test per module from the tree rather than a list: a module added to the
# directory is covered without this file being touched.
for file in tests/"$group"/test_*.py; do
    module=${file##*/}
    register "$module passes" module_passes "$module"
done
