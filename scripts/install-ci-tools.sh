#!/usr/bin/env bash
# Installs the pinned CI binaries. Versions and SHA-256 digests are explicit so a
# retagged or replaced upstream asset fails the checksum instead of running.
set -euo pipefail

dest="${1:-$HOME/.local/bin}"
mkdir -p "$dest"

TOFU_VERSION=1.13.9
TOFU_SHA256=bc44eb6b06446ba83bd4072114891987f590f66cca712737a7f1147c50c539ce

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fetch() {
  local url="$1" file="$2" sha256="$3"
  curl -sSfL -o "$tmp/$file" "$url"
  echo "$sha256  $tmp/$file" | sha256sum -c - >/dev/null
}

fetch "https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}/tofu_${TOFU_VERSION}_linux_amd64.zip" \
  tofu.zip "$TOFU_SHA256"
unzip -q -o "$tmp/tofu.zip" -d "$tmp/tofu"
install -m 0755 "$tmp/tofu/tofu" "$dest/tofu"

"$dest/tofu" version
