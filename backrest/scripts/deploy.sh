#!/usr/bin/env bash
# Deploys the reader: builds the image, pushes it to the Cloudflare registry, and
# deploys the Worker against the digest the registry actually stored.
#
# The repository location is deliberately not in wrangler.json (a checked-in
# default is the wrong repo for either the gate or production), so this wrapper
# refuses to run without it and makes the failure happen here rather than as a
# 503 on the first request.
#
#   BACKREST_REPO_ID=r2 \
#   BACKREST_REPO_URI=s3:https://<account>.r2.cloudflarestorage.com/<bucket>/<path> \
#   BACKREST_REPO_GUID=<64 hex from restic cat config> \
#     backrest/scripts/deploy.sh
#
# Two things make this less direct than `wrangler deploy`:
#   * wrangler builds with Docker and passes Docker-only flags; the shim below
#     translates them for podman (see docs/core/backrest.md).
#   * wrangler reads a local image digest after a podman push, and the registry
#     stores a different one, so the image is referenced by the digest the
#     registry reports rather than by a Dockerfile.
set -euo pipefail

: "${BACKREST_REPO_ID:?BACKREST_REPO_ID is required}"
: "${BACKREST_REPO_URI:?BACKREST_REPO_URI is required}"
: "${BACKREST_REPO_GUID:?BACKREST_REPO_GUID is required}"

if [[ ! $BACKREST_REPO_GUID =~ ^[0-9a-f]{64}$ ]]; then
  printf 'BACKREST_REPO_GUID must be the 64-character restic repository id\n' >&2
  exit 64
fi

die() {
  printf 'deploy: %s\n' "$*" >&2
  exit 1
}

cd "$(dirname "$0")/.."
repo_root=$(git rev-parse --show-toplevel)
image_repo=smortress-backrest
tag=$(git rev-parse --short HEAD)

account_id=$(sed -n 's/^account_id[[:space:]]*=[[:space:]]*"\([0-9a-f]\{32\}\)".*/\1/p' \
  "$repo_root/tofu/terraform.tfvars" | head -1)
[[ ${#account_id} -eq 32 ]] || die "account_id not found in tofu/terraform.tfvars"

command -v podman >/dev/null 2>&1 || die "podman is required to build the image"
command -v jq >/dev/null 2>&1 || die "jq is required"
export WRANGLER_DOCKER_BIN=${WRANGLER_DOCKER_BIN:-$(command -v podman)}
export DOCKER_HOST=${DOCKER_HOST:-unix://${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock}

work=$(mktemp -d)
chmod 700 "$work"
trap 'rm -rf "$work" wrangler.deploy.json' EXIT

# Docker-compatible shim: docker's --provenance is unknown to podman, and
# `-f -` (Dockerfile on stdin) cannot be opened inside podman's build sandbox.
cat >"$work/docker" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
args=()
tmp=""
while [ $# -gt 0 ]; do
  case "$1" in
    --provenance*|--load) shift ;;
    -f)
      if [ "${2:-}" = "-" ]; then
        tmp=$(mktemp /tmp/dockerfile.XXXXXX)
        cat >"$tmp"
        args+=(-f "$tmp")
        shift 2
      else
        args+=(-f "$2")
        shift 2
      fi
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done
set +e
/usr/bin/podman "${args[@]}"
rc=$?
set -e
[ -n "$tmp" ] && rm -f "$tmp"
exit $rc
SHIM
chmod 700 "$work/docker"
export WRANGLER_DOCKER_BIN=$work/docker

printf 'deploy: building %s:%s\n' "$image_repo" "$tag" >&2
npx wrangler containers build container -t "$image_repo:$tag" -p --path-to-docker "$WRANGLER_DOCKER_BIN"

# Ask the registry what it stored. wrangler's `docker login` credentials are in
# the container auth file, so nothing below puts a secret on a command line.
cat >"$work/digest.sh" <<'DIGEST'
#!/usr/bin/env bash
set -euo pipefail
authfile="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/containers/auth.json"
[[ -f $authfile ]] || { echo "no registry credentials" >&2; exit 1; }
b64=$(jq -r '.auths["registry.cloudflare.com"].auth // empty' "$authfile")
[[ -n $b64 ]] || { echo "not logged in to registry.cloudflare.com" >&2; exit 1; }
creds=$(printf '%s' "$b64" | base64 -d)
cfg=$(mktemp); chmod 600 "$cfg"
printf 'silent\nheader = "Authorization: Basic %s"\n' "$(printf '%s' "$creds" | base64 -w0)" >"$cfg"
code=$(curl --config "$cfg" -o "$cfg.body" -w '%{http_code}' -I \
  -H 'Accept: application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json' \
  "https://registry.cloudflare.com/v2/$ACCOUNT_ID/$IMAGE_REPO/manifests/$TAG")
[[ $code == 200 ]] || { echo "registry returned $code" >&2; exit 1; }
grep -i '^docker-content-digest:' "$cfg.body" | awk '{print $2}' | tr -d '\r'
rm -f "$cfg" "$cfg.body"
DIGEST

digest=$(ACCOUNT_ID=$account_id IMAGE_REPO=$image_repo TAG=$tag bash "$work/digest.sh") ||
  die "could not read the pushed digest from the registry"
[[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || die "registry returned an unexpected digest: $digest"

printf 'deploy: image digest %s\n' "$digest" >&2
jq --arg img "registry.cloudflare.com/$account_id/$image_repo@$digest" \
  '.containers[0].images.backrest = {image: $img}' wrangler.json >wrangler.deploy.json

npx wrangler deploy -c wrangler.deploy.json \
  --var BACKREST_REPO_ID:"$BACKREST_REPO_ID" \
  --var BACKREST_REPO_URI:"$BACKREST_REPO_URI" \
  --var BACKREST_REPO_GUID:"$BACKREST_REPO_GUID" \
  "$@"
