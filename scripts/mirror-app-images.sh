#!/usr/bin/env bash
# Copy every pinned application image into ghcr.io/smores56/homelab-platform and
# sign it with the smortress cosign key.
#
# The runtime default-reject policy accepts no upstream registry, so this is the
# only way an application image reaches the host. `--preserve-digests` keeps the
# manifest digest the pin file already records: the image the host verifies is
# byte-identical to the upstream one, and `--all` keeps the multi-arch index
# intact. The signature is ours because it carries our repository identity.
#
# Runs in CI (.github/workflows/publish-app-images.yml) where the private key is
# an environment secret. Never run with a key in argv.
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo"
# shellcheck source=./app-images.sh disable=SC1091
source scripts/app-images.sh

: "${COSIGN_PRIVATE_KEY:?COSIGN_PRIVATE_KEY is not set}"
cosign_bin=${COSIGN_BIN:-cosign}
skopeo_bin=${SKOPEO_BIN:-skopeo}
authfile=${AUTHFILE:-${DOCKER_CONFIG:-$HOME/.docker}/config.json}

if [[ ! -s image/cosign.pub ]]; then
  echo "mirror-app-images: image/cosign.pub is missing; nothing to verify against" >&2
  exit 1
fi

# app_repo and the lookup helpers come from the sourced table.
# shellcheck disable=SC2154
while IFS= read -r name; do
  digest=$(app_image_digest "$name")
  # The source is repo@digest, never tag@digest: skopeo rejects a reference that
  # carries both.
  src=$(app_image_source "$name")
  dst=docker://$app_repo/$name

  echo "mirror-app-images: copying $src"
  "$skopeo_bin" copy --all --preserve-digests --authfile "$authfile" "$src" "$dst"

  got=$("$skopeo_bin" inspect --no-tags --authfile "$authfile" --format '{{.Digest}}' "$dst")
  if [[ $got != "$digest" ]]; then
    echo "mirror-app-images: $name landed as $got, not the pinned $digest" >&2
    exit 1
  fi

  "$cosign_bin" sign --key env://COSIGN_PRIVATE_KEY --yes "$app_repo/$name@$digest"
  # containers-image reads the legacy lookaside tag, not the OCI 1.1 referrer
  # bundle cosign >=3 writes by default, so prove the tag exists before claiming
  # the host will accept the image.
  "$skopeo_bin" inspect --raw --authfile "$authfile" \
    "docker://$app_repo/$name:${digest/:/-}.sig" >/dev/null
  "$cosign_bin" verify --key image/cosign.pub "$app_repo/$name@$digest"
  # The host has no registry credential: bootc pulls with an unverified
  # reference and the Quadlets pull with the default-reject policy, both
  # anonymously. A private package would 401 on the first boot after deploy, so
  # the push is not finished until an anonymous read works.
  if ! "$skopeo_bin" inspect --no-tags --format '{{.Digest}}' "docker://$app_repo/$name@$digest" \
      >/dev/null 2>&1; then
    echo "mirror-app-images: $name is not anonymously pullable; make the package public" >&2
    exit 1
  fi
  echo "mirror-app-images: $name is signed and publicly readable at $digest"
done < <(app_image_names)
