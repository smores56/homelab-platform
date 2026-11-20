#!/usr/bin/env bash
# Collector egress proxy and resolver unit tests. Static only: no network, no
# container, no nftables. The proxy is driven over a loopback listener it binds
# itself with an injected upstream dialer, and the resolver is driven with a
# socket stand-in and an injected lookup, so every refusal is proved without a
# packet leaving the process.
set -uo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root" || exit 1

export PYTHONPATH="$root${PYTHONPATH:+:$PYTHONPATH}"
export PYTHONDONTWRITEBYTECODE=1

exec python3 -m unittest discover -s tests/agent-egress -t tests/agent-egress -v
