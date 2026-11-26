#!/usr/bin/env bats
# bats file_tags=brave
# The browsing collector's provider half and its exhaust: the seed planter, the
# snapshot, and the raw collector over the copy.
#
# Static only: no browser, no Sync chain, no proxy. The seed is a fixture in the
# contract form, the profile is a temporary directory, and the History database is
# one these tests write. The collector half runs the real CLI over a real copy, so
# a failure is about this code.
#
#   bats tests/brave/check.bats
#
# The shell suite this replaced ran `unittest discover` over the directory and
# printed one line per unittest case, so the whole group asserted a single thing:
# the exit status of that run. Here each test module is its own test -- the module
# is the group of assertions and its cases are untouched -- so a failure names the
# module it came from instead of a line in one shared log.
load ../helpers

group=brave

# apps/ for the seeder and snapshot, libs/ for the collector the units run.
setup() {
    export PYTHONPATH="$repo_root:$repo_root/libs${PYTHONPATH:+:$PYTHONPATH}"
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
