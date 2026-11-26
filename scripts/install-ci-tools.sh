#!/usr/bin/env bash
# Installs the pinned CI binaries. Versions and SHA-256 digests are explicit so a
# retagged or replaced upstream asset fails the checksum instead of running.
set -euo pipefail

dest=${1:-$HOME/.local/bin}
# bats installs bin/, libexec/ and lib/ under a prefix, so dest must be its bin:
# checking after the install would run install.sh somewhere else first.
dest=${dest%/}
case $(basename -- "$dest") in
  bin) ;;
  *)
    printf 'install-ci-tools: dest must be a directory named bin, got %s\n' "$dest" >&2
    exit 2
    ;;
esac
mkdir -p "$dest"
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck source=/dev/null
. "$root/bootc/lib/pins.env"

TOFU_VERSION=1.13.9
TOFU_SHA256=bc44eb6b06446ba83bd4072114891987f590f66cca712737a7f1147c50c539ce

# The gate's test runner, and the job queue `bats --jobs` shells out to. GNU
# parallel publishes no prebuilt binary; its tarball ships the script.
BATS_VERSION=1.14.0
BATS_SHA256=bb537b70b15b732f6d8827dd6578e3d8ce166636ce1f18ea9a074184fcce9177
PARALLEL_VERSION=20261122
PARALLEL_SHA256=95d3f68a482561c68fbc1a136b7e10098b7068493451b53380b322388403aa6f
# bats searches only $BATS_LIB_PATH, whose default is /usr/lib/bats;
# tests/helpers.bash points it here, so no root and one path on every host.
BATS_SUPPORT_VERSION=0.3.0
BATS_SUPPORT_SHA256=7815237aafeb42ddcc1b8c698fc5808026d33317d8701d5ec2396e9634e2918f
BATS_ASSERT_VERSION=2.2.4
BATS_ASSERT_SHA256=e305df20c4c36cba4570e10f1cd824efb1ae71d88b5ef474550781ebee04192f
BATS_LIB_DEST=${BATS_LIB_DEST:-${XDG_DATA_HOME:-$HOME/.local/share}/bats}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# ftp.gnu.org is the only source for parallel and it stalls rather than refuses:
# a job on 2026-11-26 spent 134 s of its 5-minute timeout failing to connect,
# which the retry cannot help if the first attempt has no cap of its own. Every
# fetch therefore bounds itself and retries, and the checksum still decides.
fetch() {
  local url="$1" file="$2" sha256="$3"
  curl -sSfL --connect-timeout 15 --max-time 300 \
    --retry 3 --retry-delay 2 --retry-all-errors -o "$tmp/$file" "$url"
  echo "$sha256  $tmp/$file" | sha256sum -c - >/dev/null
}

fetch "https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}/tofu_${TOFU_VERSION}_linux_amd64.zip" \
  tofu.zip "$TOFU_SHA256"
unzip -q -o "$tmp/tofu.zip" -d "$tmp/tofu"
install -m 0755 "$tmp/tofu/tofu" "$dest/tofu"

fetch "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.amd64" \
  sops "$SOPS_SHA256"
install -m 0755 "$tmp/sops" "$dest/sops"

fetch "https://github.com/FiloSottile/age/releases/download/v${AGE_VERSION}/age-v${AGE_VERSION}-linux-amd64.tar.gz" \
  age.tar.gz "$AGE_SHA256"
tar -xzf "$tmp/age.tar.gz" -C "$tmp"
install -m 0755 "$tmp/age/age" "$tmp/age/age-keygen" "$dest/"

# bats installs bin/ libexec/ and lib/ under a prefix, so dest must be its bin.
fetch "https://github.com/bats-core/bats-core/archive/refs/tags/v${BATS_VERSION}.tar.gz" \
  bats.tar.gz "$BATS_SHA256"
tar -xzf "$tmp/bats.tar.gz" -C "$tmp"
"$tmp/bats-core-$BATS_VERSION/install.sh" "$(dirname -- "$dest")" >/dev/null

fetch "https://ftp.gnu.org/gnu/parallel/parallel-${PARALLEL_VERSION}.tar.bz2" \
  parallel.tar.bz2 "$PARALLEL_SHA256"
tar -xjf "$tmp/parallel.tar.bz2" -C "$tmp"
install -m 0755 "$tmp/parallel-$PARALLEL_VERSION/src/parallel" "$dest/parallel"

# Extract a verified tree beside the installed one and swap it in, so an
# interrupted install never leaves half a library.
install_lib() {
  local name="$1" version="$2" sha256="$3"
  local tarball="$tmp/$name.tar.gz"
  if [[ -f $BATS_LIB_DEST/$name/load.bash ]] &&
    [[ $(cat "$BATS_LIB_DEST/$name/.version" 2>/dev/null) == "$version" ]]; then
    return 0
  fi
  fetch "https://github.com/bats-core/$name/archive/refs/tags/v${version}.tar.gz" \
    "$name.tar.gz" "$sha256"
  mkdir -p "$tmp/$name" "$BATS_LIB_DEST"
  tar -xzf "$tarball" -C "$tmp/$name"
  rm -rf "${BATS_LIB_DEST:?}/$name.new"
  mv "$tmp/$name/$name-$version" "$BATS_LIB_DEST/$name.new"
  printf '%s\n' "$version" >"$BATS_LIB_DEST/$name.new/.version"
  rm -rf "${BATS_LIB_DEST:?}/$name"
  mv "$BATS_LIB_DEST/$name.new" "$BATS_LIB_DEST/$name"
}

install_lib bats-support "$BATS_SUPPORT_VERSION" "$BATS_SUPPORT_SHA256"
install_lib bats-assert "$BATS_ASSERT_VERSION" "$BATS_ASSERT_SHA256"

"$dest/tofu" version
"$dest/sops" --version
"$dest/age" --version
"$dest/bats" --version
"$dest/parallel" --version | head -n 1
