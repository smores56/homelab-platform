#!/usr/bin/env bash
# The personal shell-jobs entry point (SDLC #715). The class is this file.
#
# The caller supplies one shell command. It cannot choose the trust class, the
# image, a mount or a network: scripts/agent-job.sh reads the class from this
# invocation and everything else is a constant there. The command is the only
# argument that reaches Podman's argv, after the image.
set -euo pipefail
core="$(dirname -- "${BASH_SOURCE[0]}")/agent-job"
[[ -x $core ]] || core="$core.sh"
exec "$core" personal "$@"
