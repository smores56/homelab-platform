#!/usr/bin/env bash
# Build the derived bootc image locally. Never pushes and never signs.
#
# The build fails closed when the base is not digest-pinned, when the public
# cosign key is not in place, or when a pin is missing.
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../image/pins.env disable=SC1091
source "$repo/image/pins.env"

engine=${ENGINE:-podman}
if ! command -v "$engine" >/dev/null 2>&1; then
  echo "build-image: $engine is not installed" >&2
  exit 1
fi

if [[ ! $BASE_IMAGE =~ @sha256:[0-9a-f]{64}$ ]]; then
  echo "build-image: BASE_IMAGE is not digest-pinned: $BASE_IMAGE" >&2
  exit 1
fi
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
  --label "org.opencontainers.image.revision=$revision" \
  -f "$repo/image/Containerfile" \
  -t "$tag" \
  -t "localhost/smorespro-image:latest" \
  "$repo"

echo "built $tag"
