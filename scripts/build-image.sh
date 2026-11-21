#!/usr/bin/env bash
# Build the derived bootc image locally. Never pushes and never signs.
#
# The base is the fedora-bootc release tag from image/pins.env, which moves: the
# build resolves it to a digest, fails closed when the registry will not answer,
# and records that digest in the image's org.opencontainers.image.base.digest
# label. The build also fails closed when the base is not that tag, when the
# public cosign key is not in place, or when a pin is missing.
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../image/pins.env disable=SC1091
source "$repo/image/pins.env"

engine=${ENGINE:-podman}
if ! command -v "$engine" >/dev/null 2>&1; then
  echo "build-image: $engine is not installed" >&2
  exit 1
fi

if [[ ! $BASE_IMAGE =~ ^quay\.io/fedora/fedora-bootc:[0-9]+$ ]]; then
  echo "build-image: BASE_IMAGE is not a fedora-bootc release tag: $BASE_IMAGE" >&2
  exit 1
fi
if ! command -v skopeo >/dev/null 2>&1; then
  echo "build-image: skopeo is not installed; it resolves the base digest" >&2
  exit 1
fi
if ! base_digest=$(skopeo inspect --format '{{.Digest}}' "docker://$BASE_IMAGE"); then
  echo "build-image: cannot resolve $BASE_IMAGE to a digest" >&2
  exit 1
fi
if [[ ! $base_digest =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "build-image: registry returned no usable digest for $BASE_IMAGE: $base_digest" >&2
  exit 1
fi
for pin in NYM_VERSION NYM_SHA256_AMD64 NYM_SHA256_ARM64; do
  if [[ -z ${!pin:-} ]]; then
    echo "build-image: $pin is missing from image/pins.env" >&2
    exit 1
  fi
done
if [[ ! -s $repo/image/cosign.pub ]]; then
  echo "build-image: image/cosign.pub is missing; copy it from homelab-platform" >&2
  exit 1
fi
if ! grep -q 'BEGIN PUBLIC KEY' "$repo/image/cosign.pub"; then
  echo "build-image: image/cosign.pub is not a PEM public key" >&2
  exit 1
fi

revision=$(git -C "$repo" rev-parse HEAD)
tag="localhost/smorespro-image:sha-${revision:0:12}"

"$engine" build \
  --build-arg "BASE_IMAGE=$BASE_IMAGE" \
  --build-arg "BASE_DIGEST=$base_digest" \
  --build-arg "NYM_VERSION=$NYM_VERSION" \
  --build-arg "NYM_SHA256_AMD64=$NYM_SHA256_AMD64" \
  --build-arg "NYM_SHA256_ARM64=$NYM_SHA256_ARM64" \
  --label "org.opencontainers.image.revision=$revision" \
  -f "$repo/image/Containerfile" \
  -t "$tag" \
  -t "localhost/smorespro-image:latest" \
  "$repo"

echo "built $tag from $BASE_IMAGE@$base_digest"
