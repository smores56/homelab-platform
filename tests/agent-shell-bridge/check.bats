#!/usr/bin/env bats
# bats file_tags=agent-shell-bridge
# The agent shell bridge: the Unix socket the general facade reaches the job
# dispatcher through (SDLC #859, T17 of #702).
#
# Offline only: no root, no Podman, no /var/srv/git. The bridge runs for real
# against a fake dispatcher in a temporary directory, so a failure here is about
# this code and never about the host.
#
#   bats tests/agent-shell-bridge/check.bats
#
# The shell suite this replaced ran `unittest discover` over the directory and
# printed one line per unittest case, so the whole group asserted a single thing:
# the exit status of that run. Here each test module is its own test -- the module
# is the group of assertions and its cases are untouched -- so a failure names the
# module it came from instead of a line in one shared log.
load ../helpers

group=agent-shell-bridge

# The tests reach the bridge by path, so nothing goes on the import path; the one
# environment change the shell suite made is the bytecode write it suppressed.
setup() {
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
