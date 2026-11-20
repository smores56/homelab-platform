#!/usr/bin/env bash
# Build the derived bootc image locally. Never pushes and never signs.
#
# The build fails closed when the base image is not digest-pinned, when the
# public cosign key has not been provisioned, or when a tool pin is missing.
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../image/pins.env disable=SC1091
source "$repo/image/pins.env"

engine=${ENGINE:-podman}
if ! command -v "$engine" >/dev/null 2>&1; then
  echo "build-image: $engine is not installed; use 'nix shell nixpkgs#podman -c scripts/build-image.sh'" >&2
  exit 1
fi

if [[ ! $UCORE_IMAGE =~ @sha256:[0-9a-f]{64}$ ]]; then
  echo "build-image: UCORE_IMAGE is not digest-pinned: $UCORE_IMAGE" >&2
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
  CLOUDFLARED_VERSION CLOUDFLARED_SHA256 PAM_RSSH_VERSION PAM_RSSH_COMMIT; do
  [[ -n ${!var:-} ]] || { echo "build-image: $var is unset in image/pins.env" >&2; exit 1; }
done

tag="sha-$(git -C "$repo" rev-parse --short=12 HEAD)"
image="${IMAGE_REPO}:${tag}"

"$engine" build \
  --build-arg "BASE_IMAGE=$UCORE_IMAGE" \
  --build-arg "SOPS_VERSION=$SOPS_VERSION" \
  --build-arg "SOPS_SHA256=$SOPS_SHA256" \
  --build-arg "AGE_VERSION=$AGE_VERSION" \
  --build-arg "AGE_SHA256=$AGE_SHA256" \
  --build-arg "RESTIC_VERSION=$RESTIC_VERSION" \
  --build-arg "RESTIC_SHA256=$RESTIC_SHA256" \
  --build-arg "CLOUDFLARED_VERSION=$CLOUDFLARED_VERSION" \
  --build-arg "CLOUDFLARED_SHA256=$CLOUDFLARED_SHA256" \
  --build-arg "PAM_RSSH_VERSION=$PAM_RSSH_VERSION" \
  --build-arg "PAM_RSSH_COMMIT=$PAM_RSSH_COMMIT" \
  --label "org.opencontainers.image.revision=$(git -C "$repo" rev-parse HEAD)" \
  -f "$repo/image/Containerfile" \
  -t "$image" \
  "$repo"

echo "built $image"
echo "next: $engine push $image; sign the pushed digest; pin it in ignition/operator/derived-image"
