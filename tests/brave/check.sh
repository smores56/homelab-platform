#!/usr/bin/env bash
# The browsing collector's provider half and its exhaust: the seed planter, the
# snapshot, and the raw collector over the copy.
#
# Static only: no browser, no Sync chain, no proxy. The seed is a fixture in the
# contract form, the profile is a temporary directory, and the History database is
# one these tests write. The collector half runs the real CLI over a real copy, so
# a failure is about this code.
set -uo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root" || exit 1

# apps/ for the seeder and snapshot, libs/ for the collector the units run.
export PYTHONPATH="$root:$root/libs${PYTHONPATH:+:$PYTHONPATH}"
export PYTHONDONTWRITEBYTECODE=1

exec python3 -m unittest discover -s tests/brave -t tests/brave -v
