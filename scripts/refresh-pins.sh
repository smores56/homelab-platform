#!/usr/bin/env bash
# Print the digest the uCore stream tag currently resolves to. Informational
# only: image/pins.env tracks the tag, so there is no base pin to refresh and
# nothing here edits a file. The digest a build resolves is recorded in the
# image's org.opencontainers.image.base.digest label and in the publish run
# summary; this script only answers "what would the next build get today".
#
#   scripts/refresh-pins.sh           # print <tag>@<digest>
#   scripts/refresh-pins.sh --check   # same, and exit 0: no base drift to report
#   scripts/refresh-pins.sh --write   # same, and exit 0: nothing base-related is written
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../image/pins.env disable=SC1091
source "$repo/image/pins.env"

write=false
case "${1:-}" in
  --write) write=true ;;
  --check | "") ;;
  *) echo "usage: refresh-pins.sh [--check|--write]" >&2; exit 2 ;;
esac

# Both flags are accepted because the surrounding steps still call them; a moving
# tag has no pin to rewrite, so neither changes anything on disk.
if $write; then
  echo "refresh-pins.sh: image/pins.env tracks the tag; nothing to write" >&2
fi

if ! command -v skopeo >/dev/null 2>&1; then
  echo "refresh-pins.sh: skopeo is not installed; install skopeo to read the tag's digest" >&2
  echo "refresh-pins.sh: the base is a tag ($UCORE_IMAGE); no pin needs refreshing" >&2
  exit 0
fi

digest=$(skopeo inspect --format '{{.Digest}}' "docker://$UCORE_IMAGE") || {
  echo "refresh-pins.sh: cannot read $UCORE_IMAGE from the registry; a build would fail here too" >&2
  exit 1
}
if [[ ! $digest =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "refresh-pins.sh: the registry returned no usable digest for $UCORE_IMAGE: $digest" >&2
  exit 1
fi

echo "$UCORE_IMAGE@$digest"
