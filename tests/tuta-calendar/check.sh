#!/usr/bin/env bash
# Tuta calendar exporter unit tests. Static only: no network, no Tuta account, no
# provider. The crypto tests compute their vectors from the vendored primitives,
# the session tests use a real gpg keyring in a temporary directory, and the API
# tests drive an injected transport, so a failure is about this code.
set -uo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root" || exit 1

# libs/ is on the path for the collector cross-check: the dumper's output is
# asserted against the same to_ics() the replica derives, not against a copy.
export PYTHONPATH="$root:$root/libs${PYTHONPATH:+:$PYTHONPATH}"
export PYTHONDONTWRITEBYTECODE=1

exec python3 -m unittest discover -s tests/tuta-calendar -t tests/tuta-calendar -v
