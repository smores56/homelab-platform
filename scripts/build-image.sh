#!/usr/bin/env bash
# Build a derived bootc image locally. Never pushes and never signs.
#
#   scripts/build-image.sh [server|edge]     # server is the default
#
# Each artifact's base tracks a uCore stream tag in bootc/lib/pins.env; this
# script resolves that tag's digest and passes it as BASE_DIGEST, so a local build
# records the same org.opencontainers.image.base.digest label a CI build does. The
# build fails closed on a digest-pinned or `:latest` base, on a base the registry
# will not resolve, when the public cosign key has not been provisioned, or when a
# tool pin is missing.
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../bootc/lib/pins.env disable=SC1091
source "$repo/bootc/lib/pins.env"

artifact=server
case ${1:-} in
  server | edge) artifact=$1 ;;
  -h | --help)
    sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  '') ;;
  *) printf 'build-image: unknown artifact %s (want server or edge)\n' "$1" >&2; exit 2 ;;
esac

# Everything that differs between the two artifacts is named here: the pin that
# holds the base, the repository the image is tagged for, the Containerfile, the
# tool pins it takes as build arguments, and what the operator does next.
case $artifact in
  server)
    base_var=UCORE_IMAGE
    base_image=$UCORE_IMAGE
    target_repo=$IMAGE_REPO
    containerfile=bootc/server/Containerfile
    pins=(SOPS_VERSION SOPS_SHA256 AGE_VERSION AGE_SHA256 RESTIC_VERSION RESTIC_SHA256 \
      BACKREST_VERSION BACKREST_SHA256 \
      PAM_RSSH_VERSION PAM_RSSH_COMMIT)
    next="pin it in ignition/operator/derived-image"
    ;;
  edge)
    base_var=EDGE_IMAGE
    base_image=$EDGE_IMAGE
    target_repo=$EDGE_IMAGE_REPO
    containerfile=bootc/edge/Containerfile
    # No tool build arguments: the edge's one added package is Caddy from
    # Fedora's repository, and the auth key and Caddy environment file are the
    # operator's. There is nothing here to hash-pin, and an empty list is what
    # says so rather than a pin that no COPY consumes.
    pins=()
    next="the edge install path takes it by digest"
    ;;
esac

engine=${ENGINE:-podman}
if ! command -v "$engine" >/dev/null 2>&1; then
  echo "build-image: $engine is not installed; install it or set ENGINE" >&2
  exit 1
fi

case $base_image in
  *:latest) echo "build-image: $base_var must be a stream tag, not :latest: $base_image" >&2; exit 1 ;;
  *@sha256:*) echo "build-image: $base_var must be a stream tag, not a digest: $base_image" >&2; exit 1 ;;
  *:*) ;;
  *) echo "build-image: $base_var is not a tagged reference: $base_image" >&2; exit 1 ;;
esac
# A caller that already resolved the digest (the publish workflow does, so the run
# summary names it before the build starts) passes it in BASE_DIGEST.
if [[ -z ${BASE_DIGEST:-} ]]; then
  command -v skopeo >/dev/null 2>&1 \
    || { echo "build-image: skopeo is not installed; it resolves the base digest" >&2; exit 1; }
  BASE_DIGEST=$(skopeo inspect --format '{{.Digest}}' "docker://$base_image")
fi
if [[ ! $BASE_DIGEST =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "build-image: cannot resolve the base digest of $base_image: ${BASE_DIGEST:-none}" >&2
  exit 1
fi
# The signing key is the repository's single one, shared by every artifact, and
# the publish workflow proves the Environment's private half matches it.
if [[ ! -s $repo/bootc/server/cosign.pub ]]; then
  echo "build-image: bootc/server/cosign.pub is missing. Run docs/manual-steps.md section 37." >&2
  exit 1
fi
if ! grep -q 'BEGIN PUBLIC KEY' "$repo/bootc/server/cosign.pub"; then
  echo "build-image: bootc/server/cosign.pub is not a PEM public key" >&2
  exit 1
fi
for var in "${pins[@]}"; do
  [[ -n ${!var:-} ]] || { echo "build-image: $var is unset in bootc/lib/pins.env" >&2; exit 1; }
done

tag="sha-$(git -C "$repo" rev-parse --short=12 HEAD)"
image="${target_repo}:${tag}"

build_args=()
for var in "${pins[@]}"; do
  build_args+=(--build-arg "$var=${!var}")
done

"$engine" build \
  --build-arg "BASE_IMAGE=$base_image" \
  --build-arg "BASE_DIGEST=$BASE_DIGEST" \
  "${build_args[@]}" \
  --label "org.opencontainers.image.revision=$(git -C "$repo" rev-parse HEAD)" \
  -f "$repo/$containerfile" \
  -t "$image" \
  "$repo"

echo "built $image on $base_image@$BASE_DIGEST"
echo "next: $engine push $image; sign the pushed digest; $next"
