#!/usr/bin/env bash
# Build the derived bootc image locally. Never pushes and never signs.
#
# The base tracks the uCore stream tag in image/pins.env; this script resolves
# that tag's digest and passes it as BASE_DIGEST, so a local build records the
# same org.opencontainers.image.base.digest label a CI build does. The build
# fails closed on a digest-pinned or `:latest` base, on a base the registry will
# not resolve, when the public cosign key has not been provisioned, or when a tool
# pin is missing.
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../image/pins.env disable=SC1091
source "$repo/image/pins.env"

engine=${ENGINE:-podman}
if ! command -v "$engine" >/dev/null 2>&1; then
  echo "build-image: $engine is not installed; install it or set ENGINE" >&2
  exit 1
fi

case $UCORE_IMAGE in
  *:latest) echo "build-image: UCORE_IMAGE must be a stream tag, not :latest: $UCORE_IMAGE" >&2; exit 1 ;;
  *@sha256:*) echo "build-image: UCORE_IMAGE must be a stream tag, not a digest: $UCORE_IMAGE" >&2; exit 1 ;;
  *:*) ;;
  *) echo "build-image: UCORE_IMAGE is not a tagged reference: $UCORE_IMAGE" >&2; exit 1 ;;
esac
# A caller that already resolved the digest (the publish workflow does, so the run
# summary names it before the build starts) passes it in BASE_DIGEST.
if [[ -z ${BASE_DIGEST:-} ]]; then
  command -v skopeo >/dev/null 2>&1 \
    || { echo "build-image: skopeo is not installed; it resolves the base digest" >&2; exit 1; }
  BASE_DIGEST=$(skopeo inspect --format '{{.Digest}}' "docker://$UCORE_IMAGE")
fi
if [[ ! $BASE_DIGEST =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "build-image: cannot resolve the base digest of $UCORE_IMAGE: ${BASE_DIGEST:-none}" >&2
  exit 1
fi
if [[ ! -s $repo/image/cosign.pub ]]; then
  echo "build-image: image/cosign.pub is missing. Run docs/manual-steps.md section 37." >&2
  exit 1
fi
if ! grep -q 'BEGIN PUBLIC KEY' "$repo/image/cosign.pub"; then
  echo "build-image: image/cosign.pub is not a PEM public key" >&2
  exit 1
fi
for var in SOPS_VERSION SOPS_SHA256 AGE_VERSION AGE_SHA256 RESTIC_VERSION RESTIC_SHA256 \
  PAM_RSSH_VERSION PAM_RSSH_COMMIT; do
  [[ -n ${!var:-} ]] || { echo "build-image: $var is unset in image/pins.env" >&2; exit 1; }
done

tag="sha-$(git -C "$repo" rev-parse --short=12 HEAD)"
image="${IMAGE_REPO}:${tag}"

# Remote layer cache, CI only: unset locally so a local build stays offline-safe.
cache_args=()
[[ -n ${CACHE_FROM:-} ]] && cache_args+=(--cache-from "$CACHE_FROM")
[[ -n ${CACHE_TO:-} ]] && cache_args+=(--cache-to "$CACHE_TO")

"$engine" build \
  --build-arg "BASE_IMAGE=$UCORE_IMAGE" \
  --build-arg "BASE_DIGEST=$BASE_DIGEST" \
  --build-arg "SOPS_VERSION=$SOPS_VERSION" \
  --build-arg "SOPS_SHA256=$SOPS_SHA256" \
  --build-arg "AGE_VERSION=$AGE_VERSION" \
  --build-arg "AGE_SHA256=$AGE_SHA256" \
  --build-arg "RESTIC_VERSION=$RESTIC_VERSION" \
  --build-arg "RESTIC_SHA256=$RESTIC_SHA256" \
  --build-arg "PAM_RSSH_VERSION=$PAM_RSSH_VERSION" \
  --build-arg "PAM_RSSH_COMMIT=$PAM_RSSH_COMMIT" \
  --label "org.opencontainers.image.revision=$(git -C "$repo" rev-parse HEAD)" \
  "${cache_args[@]}" \
  -f "$repo/image/Containerfile" \
  -t "$image" \
  "$repo"

echo "built $image on $UCORE_IMAGE@$BASE_DIGEST"
echo "next: $engine push $image; sign the pushed digest; pin it in ignition/operator/derived-image"
