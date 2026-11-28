#!/usr/bin/env bash
# Resolve the moving upstream references behind pins.env: the newest stable
# NymVPN release that carries a Linux core tarball, and -- informationally -- the
# digest the Fedora bootc base tag currently resolves to.
#
#   scripts/refresh-pins.sh          print the base tag and its current digest
#   scripts/refresh-pins.sh --check  exit 0 if the NymVPN pin is current, 1 if a
#                                    newer release exists, 2 on error (CI watcher)
#   scripts/refresh-pins.sh --write  rewrite the NymVPN pin in pins.env
#
# The base is not a pin, so nothing here moves it: pins.env carries the
# fedora-bootc release tag, each build resolves it, and the digest it gets is
# recorded on the image. That digest is printed and validated here only -- quay
# garbage-collects it within hours, so writing it down is what used to rot the
# build into `manifest unknown`. Drift is a NymVPN question alone.
#
# A tag is the multi-arch index, so its digest stays valid if the image is ever
# built for another architecture.
# The NymVPN hashes come from the release's own checksums.txt, which is what the
# Containerfile verifies the tarball against: a release page that changes under
# the pin breaks the build instead of slipping a binary in. Nym signs no Linux
# asset, so that hash is reproducibility, not authenticity: read the release
# notes before running --write.
set -euo pipefail

host=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../pins.env disable=SC1091
source "$host/pins.env"

nym_repo=nymtech/nym-vpn-client
curl_opts=(--fail --silent --show-error --location --proto '=https'
  --retry 3 --connect-timeout 10 --max-time 300)
api=(-H 'Accept: application/vnd.github+json')
if [[ -n ${GITHUB_TOKEN:-} ]]; then
  api+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

mode="print"
case "${1:-}" in
  --check) mode="check" ;;
  --write) mode="write" ;;
  "") ;;
  *) echo "usage: refresh-pins.sh [--check|--write]" >&2; exit 2 ;;
esac

for tool in skopeo curl jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "refresh-pins.sh: $tool is not installed" >&2
    exit 2
  fi
done

# --- base ------------------------------------------------------------------

# Information only: the build resolves this same tag, so this is what it would
# record. Nothing writes the result back into pins.env.
tag=$BASE_IMAGE
if [[ $tag != "quay.io/fedora/fedora-bootc:${FEDORA_VERSION}" ]]; then
  echo "refresh-pins.sh: BASE_IMAGE is not the fedora-bootc:${FEDORA_VERSION} release tag: $tag" >&2
  exit 2
fi
if ! digest=$(skopeo inspect --format '{{.Digest}}' "docker://$tag"); then
  echo "refresh-pins.sh: cannot resolve $tag to a digest" >&2
  exit 2
fi
if [[ ! $digest =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "refresh-pins.sh: registry returned no usable digest for $tag: $digest" >&2
  exit 2
fi

# Some stable tags carry a F-Droid APK alone, and a prerelease is never a
# candidate, so the assets decide: the newest release with a core tarball wins.
if ! releases=$(curl "${curl_opts[@]}" "${api[@]}" \
  "https://api.github.com/repos/${nym_repo}/releases?per_page=30"); then
  echo "refresh-pins.sh: cannot list ${nym_repo} releases" >&2
  exit 2
fi
nym_tag=$(printf '%s' "$releases" | jq -r '
    .[]
    | select(.draft | not)
    | select(.prerelease | not)
    | select(.tag_name | test("^nym-vpn-v[0-9]+\\.[0-9]+\\.[0-9]+$"))
    | select([.assets[].name] | any(test("_linux_x86_64\\.tar\\.gz$")))
    | [.tag_name, .published_at] | @tsv' |
  sort -k2,2r | head -n1 | cut -f1)
if [[ ! $nym_tag =~ ^nym-vpn-v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "refresh-pins.sh: no stable ${nym_repo} release carries a Linux tarball" >&2
  exit 2
fi
nym_latest=${nym_tag#nym-vpn-v}

# A yanked release must not rewrite the pin backwards; the bump is reviewed by a
# human anyway, so refuse instead of guessing.
if [[ $NYM_VERSION != "$nym_latest" ]] \
    && [[ $(printf '%s\n%s\n' "$NYM_VERSION" "$nym_latest" | sort -V | tail -n1) == "$NYM_VERSION" ]]; then
  echo "refresh-pins.sh: pinned ${NYM_VERSION} is newer than ${nym_latest}; not downgrading" >&2
  exit 2
fi

if ! sums=$(curl "${curl_opts[@]}" \
  "https://github.com/${nym_repo}/releases/download/${nym_tag}/checksums.txt"); then
  echo "refresh-pins.sh: cannot read ${nym_tag} checksums.txt" >&2
  exit 2
fi
hash_of() {
  printf '%s\n' "$sums" | awk -v want="$1" '$2 == want { print $1 }'
}
nym_amd=$(hash_of "nym-vpn-core-v${nym_latest}_linux_x86_64.tar.gz")
nym_arm=$(hash_of "nym-vpn-core-v${nym_latest}_linux_aarch64.tar.gz")
for hash in "$nym_amd" "$nym_arm"; do
  if [[ ! $hash =~ ^[0-9a-f]{64}$ ]]; then
    echo "refresh-pins.sh: ${nym_tag} checksums.txt has no usable hash for a core tarball" >&2
    exit 2
  fi
done

# --- modes -----------------------------------------------------------------

drift=0
[[ $NYM_VERSION != "$nym_latest" ]] && drift=1

case $mode in
  print)
    printf '%s -> %s (recorded per build, not pinned)\n' "$tag" "$digest"
    ;;
  check)
    # Drift is a NymVPN question: the base tag is always current by
    # construction, so only a stale release may open the watcher's issue.
    if [[ $drift -eq 0 ]]; then
      printf 'pins.env: current (nym %s; base %s resolves to %s)\n' "$NYM_VERSION" "$tag" "$digest"
      exit 0
    fi
    printf 'pins.env: newer NymVPN release available\n  pinned:  %s\n  current: %s\n' "$NYM_VERSION" "$nym_latest"
    exit 1
    ;;
  write)
    if [[ $drift -eq 0 ]]; then
      printf 'pins.env: unchanged (nym %s)\n' "$NYM_VERSION"
      exit 0
    fi
    # sed cannot create a line, so a pins.env missing a key would "succeed"
    # while writing nothing.
    for key in NYM_VERSION NYM_SHA256_AMD64 NYM_SHA256_ARM64; do
      if ! grep -q "^${key}=" "$host/pins.env"; then
        echo "refresh-pins.sh: pins.env has no ${key} line" >&2
        exit 2
      fi
    done
    sed -i \
      -e "s|^NYM_VERSION=.*|NYM_VERSION=$nym_latest|" \
      -e "s|^NYM_SHA256_AMD64=.*|NYM_SHA256_AMD64=$nym_amd|" \
      -e "s|^NYM_SHA256_ARM64=.*|NYM_SHA256_ARM64=$nym_arm|" \
      "$host/pins.env"
    printf 'pins.env: NYM_VERSION=%s\n' "$nym_latest"
    ;;
esac
