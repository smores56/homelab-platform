#!/usr/bin/env bash
# Deploys the reader. The repository location is deliberately not in
# wrangler.json (a checked-in default is the wrong repo for either the gate or
# production), so this wrapper refuses to run without it and makes the failure
# happen here rather than as a 503 on the first request.
#
#   BACKREST_REPO_ID=r2 \
#   BACKREST_REPO_URI=s3:https://<account>.r2.cloudflarestorage.com/<bucket>/<path> \
#   BACKREST_REPO_GUID=<64 hex from restic cat config> \
#     backrest/scripts/deploy.sh
set -euo pipefail

: "${BACKREST_REPO_ID:?BACKREST_REPO_ID is required}"
: "${BACKREST_REPO_URI:?BACKREST_REPO_URI is required}"
: "${BACKREST_REPO_GUID:?BACKREST_REPO_GUID is required}"

if [[ ! $BACKREST_REPO_GUID =~ ^[0-9a-f]{64}$ ]]; then
  printf 'BACKREST_REPO_GUID must be the 64-character restic repository id\n' >&2
  exit 64
fi

cd "$(dirname "$0")/.."

if ! command -v podman >/dev/null 2>&1; then
  printf 'podman is required: wrangler builds the container image locally\n' >&2
  exit 64
fi
export WRANGLER_DOCKER_BIN=${WRANGLER_DOCKER_BIN:-$(command -v podman)}
export DOCKER_HOST=${DOCKER_HOST:-unix://${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock}

exec npx wrangler deploy \
  --var BACKREST_REPO_ID:"$BACKREST_REPO_ID" \
  --var BACKREST_REPO_URI:"$BACKREST_REPO_URI" \
  --var BACKREST_REPO_GUID:"$BACKREST_REPO_GUID" \
  "$@"
