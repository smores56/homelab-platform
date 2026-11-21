#!/usr/bin/env bash
# Print the current digest of the pinned uCore stream, or rewrite image/pins.env
# with --write. This is the only script allowed to touch a moving tag; the rest
# of the pipeline consumes the digest.
#
#   scripts/refresh-pins.sh
#   scripts/refresh-pins.sh --write
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../image/pins.env disable=SC1091
source "$repo/image/pins.env"

write=false
case "${1:-}" in
  --write) write=true ;;
  "") ;;
  *) echo "usage: refresh-pins.sh [--write]" >&2; exit 2 ;;
esac

if ! command -v skopeo >/dev/null 2>&1; then
  echo "refresh-pins.sh: skopeo is not installed; install skopeo" >&2
  exit 1
fi

ref="ghcr.io/ublue-os/ucore:${UCORE_TAG}"
digest=$(skopeo inspect --format '{{.Digest}}' "docker://$ref")
if [[ ! $digest =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "refresh-pins.sh: registry returned no usable digest for $ref" >&2
  exit 1
fi

if $write; then
  sed -i "s|^UCORE_IMAGE=.*|UCORE_IMAGE=ghcr.io/ublue-os/ucore@${digest}|" "$repo/image/pins.env"
  echo "image/pins.env: UCORE_IMAGE=ghcr.io/ublue-os/ucore@${digest}"
else
  echo "ghcr.io/ublue-os/ucore@${digest}"
fi
