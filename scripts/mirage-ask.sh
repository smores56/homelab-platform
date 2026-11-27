#!/usr/bin/env bash
# Answer a Mirage ask, from the host, as the human (SDLC #979, T7).
#
# An ask is a decision the workspace is not allowed to make: the agent gets
# `requires approval: <reason> (ask <id>)` and stops. The daemon keeps the
# decision until someone answers it, and the CLI that answers lives inside the
# container, on the daemon's loopback, where a workspace with `network: false`
# cannot reach it. This script is the host's door to that CLI, so the answer is
# always the operator's and never the agent's.
#
#   mirage-ask.sh list [--all]
#   mirage-ask.sh allow <ask> [--scope once|session]
#   mirage-ask.sh deny  <ask>
#
# `--scope once` answers this line only and is spent; `session` covers
# everything that ask covers for the session. Both are the daemon's own
# semantics -- this script passes them through rather than reimplementing them.
#
# PODMAN may be overridden for a test; nothing else is configurable, because the
# container name and workspace id are the deployment's, not the caller's.
set -euo pipefail

podman_bin=${PODMAN:-podman}
container=${SMORTRESS_MIRAGE_CONTAINER:-smortress-mirage-personal}
workspace=${SMORTRESS_MIRAGE_WORKSPACE:-personal}

usage() {
  sed -n '7,10p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit "${1:-2}"
}

die() {
  echo "mirage-ask: $*" >&2
  exit 1
}

run_mirage() {
  "$podman_bin" exec "$container" mirage workspace "$@"
}

[[ $# -ge 1 ]] || usage 2
command=$1
shift

case $command in
  list)
    case ${1:-} in
      '') run_mirage list-asks -w "$workspace" ;;
      --all) run_mirage list-asks -w "$workspace" --all ;;
      *) usage 2 ;;
    esac
    ;;
  allow)
    [[ $# -ge 1 && -n ${1:-} ]] || usage 2
    ask=$1
    shift
    scope=once
    while [[ $# -gt 0 ]]; do
      case $1 in
        --scope)
          [[ $# -ge 2 ]] || usage 2
          scope=$2
          shift 2
          ;;
        *) usage 2 ;;
      esac
    done
    case $scope in
      once | session) ;;
      *)
        echo "mirage-ask: --scope is once or session, not $scope" >&2
        exit 2
        ;;
    esac
    run_mirage allow "$workspace" "$ask" --scope "$scope"
    ;;
  deny)
    [[ $# -eq 1 && -n ${1:-} ]] || usage 2
    run_mirage deny "$workspace" "$1"
    ;;
  *)
    usage 2
    ;;
esac
