#!/usr/bin/env bash
# The general shell-jobs entry point (SDLC #715). The class is this file.
#
# This is the only entry point that reaches /var/srv/git and general egress. The
# caller supplies one shell command; it cannot choose the trust class, the
# image, a mount or a network, and it cannot submit a personal job here because
# the class is compiled into this wrapper.
set -euo pipefail
core="$(dirname -- "${BASH_SOURCE[0]}")/agent-job"
[[ -x $core ]] || core="$core.sh"
exec "$core" general "$@"
