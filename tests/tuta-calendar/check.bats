#!/usr/bin/env bats
# bats file_tags=tuta-calendar
# Tuta calendar exporter unit tests. Static only: no network, no Tuta account, no
# provider. The crypto tests compute their vectors from the vendored primitives,
# the session tests use a real gpg keyring in a temporary directory, and the API
# tests drive an injected transport, so a failure is about this code.
#
#   bats tests/tuta-calendar/check.bats
#
# The shell suite this replaced ran `unittest discover` over the directory and
# printed one line per unittest case, so the whole group asserted a single thing:
# the exit status of that run. Here each test module is its own test -- the module
# is the group of assertions and its cases are untouched -- so a failure names the
# module it came from instead of a line in one shared log.
load ../helpers

group=tuta-calendar
# The exporter's dependencies are the ones the image ships, pinned in the lock
# file, so the tests run against a venv built from it. The venv is cached beside
# the other suites and built once per machine, not per run.
# The cache is keyed on the lock file: a bump must build a new venv, or a stale
# one keeps being executed by later runs.
lock_hash=$(sha256sum images/tuta-calendar/requirements.lock | cut -c1-16)
venv=${XDG_CACHE_HOME:-$HOME/.cache}/homelab-bats/tuta-calendar-$lock_hash
requirements=images/tuta-calendar/requirements.lock

setup_file() {
    if [[ -x $venv/bin/python ]]; then
        return 0
    fi
    if python3 -m venv "$venv" >/dev/null 2>&1 &&
        "$venv/bin/pip" install -q --disable-pip-version-check \
            -r "$requirements" >/dev/null 2>&1; then
        return 0
    fi
    # No pip, no network, or a host that cannot build the environment: the tests
    # below skip visibly with this reason instead of failing as if the exporter
    # had broken.
    printf 'pip or network is unavailable to build %s\n' "$venv" \
        >"$BATS_FILE_TMPDIR/venv-unavailable"
}

setup() {
    if [[ -s $BATS_FILE_TMPDIR/venv-unavailable ]]; then
        IFS= read -r reason <"$BATS_FILE_TMPDIR/venv-unavailable"
        skip "$reason"
    fi
    # libs/ is on the path for the collector cross-check: the dumper's output is
    # asserted against the same to_ics() the replica derives, not against a copy.
    PATH=$venv/bin:$PATH
    export PATH
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

# A host with no venv module cannot build the environment at all, and that is
# known before any test runs: registering the modules as skips keeps the closed
# gate visible instead of letting the tests vanish from the count.
if python3 -m venv --help >/dev/null 2>&1; then
    unbuildable=''
else
    unbuildable='no python3 venv support on this host'
fi

# One test per module from the tree rather than a list: a module added to the
# directory is covered without this file being touched.
for file in tests/"$group"/test_*.py; do
    module=${file##*/}
    if [[ -z $unbuildable ]]; then
        register "$module passes" module_passes "$module"
    else
        register_skip "$module passes" "$unbuildable"
    fi
done
