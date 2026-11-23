#!/usr/bin/env bash
# The agent shell bridge: the Unix socket the general facade reaches the job
# dispatcher through (SDLC #859, T17 of #702).
#
# Offline only: no root, no Podman, no /var/srv/git. The bridge runs for real
# against a fake dispatcher in a temporary directory, so a failure here is about
# this code and never about the host.
set -uo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root" || exit 1

export PYTHONDONTWRITEBYTECODE=1

exec python3 -m unittest discover -s tests/agent-shell-bridge \
  -t tests/agent-shell-bridge -v
