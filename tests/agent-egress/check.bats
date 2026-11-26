#!/usr/bin/env bats
# bats file_tags=agent-egress
# Collector egress proxy and resolver unit tests. Static only: no network, no
# container, no nftables. The proxy is driven over a loopback listener it binds
# itself with an injected upstream dialer, and the resolver is driven with a
# socket stand-in and an injected lookup, so every refusal is proved without a
# packet leaving the process.
#
#   bats tests/agent-egress/check.bats
#
# The shell suite this replaced ran `unittest discover` over the directory and
# printed one line per unittest case, so the whole group asserted a single thing:
# the exit status of that run. Here each test module is its own test -- the module
# is the group of assertions and its cases are untouched -- so a failure names the
# module it came from instead of a line in one shared log.
load ../helpers

group=agent-egress

# The checkout's own packages are what the tests import, and the shell suite put
# the checkout on the path: a module has to resolve the same way here.
setup() {
    export PYTHONPATH="$repo_root${PYTHONPATH:+:$PYTHONPATH}"
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
