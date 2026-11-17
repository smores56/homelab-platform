#!/usr/bin/env bash
# Resolve the current digest of the Fedora bootc base for the pinned Fedora
# release. This is the only script allowed to consume a moving tag; every other
# script and the Containerfile consume the digest.
#
#   scripts/refresh-pins.sh          print the current reference
#   scripts/refresh-pins.sh --check  exit 0 if the pin is current, 1 if a newer
#                                    digest exists, 2 on error (CI watcher)
#   scripts/refresh-pins.sh --write  rewrite image/pins.env
#
# The digest is the index digest, not a per-architecture manifest digest, so
# the pin stays valid if the image is ever built for another architecture.
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../image/pins.env disable=SC1091
source "$repo/image/pins.env"

mode="print"
case "${1:-}" in
  --check) mode="check" ;;
  --write) mode="write" ;;
  "") ;;
  *) echo "usage: refresh-pins.sh [--check|--write]" >&2; exit 2 ;;
esac

if ! command -v skopeo >/dev/null 2>&1; then
  echo "refresh-pins.sh: skopeo is not installed" >&2
  exit 2
fi

tag="quay.io/fedora/fedora-bootc:${FEDORA_VERSION}"
if ! raw=$(skopeo inspect --raw "docker://$tag"); then
  echo "refresh-pins.sh: cannot read $tag from the registry" >&2
  exit 2
fi
if [[ -z $raw ]]; then
  echo "refresh-pins.sh: registry returned an empty manifest for $tag" >&2
  exit 2
fi
digest="sha256:$(printf '%s' "$raw" | sha256sum | cut -d' ' -f1)"
if [[ ! $digest =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "refresh-pins.sh: registry returned no usable digest for $tag" >&2
  exit 2
fi
ref="quay.io/fedora/fedora-bootc@${digest}"

case $mode in
  print)
    printf '%s\n' "$ref"
    ;;
  check)
    if [[ $BASE_IMAGE == "$ref" ]]; then
      printf 'image/pins.env: current (%s)\n' "$ref"
    else
      printf 'image/pins.env: newer base digest available\n  pinned:  %s\n  current: %s\n' "$BASE_IMAGE" "$ref"
      exit 1
    fi
    ;;
  write)
    if [[ $BASE_IMAGE == "$ref" ]]; then
      printf 'image/pins.env: unchanged (%s)\n' "$ref"
      exit 0
    fi
    sed -i "s|^BASE_IMAGE=.*|BASE_IMAGE=$ref|" "$repo/image/pins.env"
    printf 'image/pins.env: BASE_IMAGE=%s\n' "$ref"
    ;;
esac
