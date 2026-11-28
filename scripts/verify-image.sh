#!/usr/bin/env bash
# Verify a pushed derived image against the repository's public cosign key and
# confirm it is digest-pinned. Read-only: no push, no signing.
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
ref=${1:-}
if [[ -z $ref ]]; then
  echo "usage: verify-image.sh <image>@sha256:<digest>" >&2
  exit 2
fi
if [[ ! $ref =~ @sha256:[0-9a-f]{64}$ ]]; then
  echo "verify-image: refusing a floating reference: $ref" >&2
  exit 1
fi
if [[ ! -s $repo/lib/containers/cosign.pub ]]; then
  echo "verify-image: lib/containers/cosign.pub is missing" >&2
  exit 1
fi

for tool in cosign skopeo; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "verify-image: $tool is not installed; install $tool and re-run scripts/verify-image.sh $ref" >&2
    exit 1
  fi
done

cosign verify --key "$repo/lib/containers/cosign.pub" "$ref"
# cosign verify reads the OCI 1.1 bundle; bootc and containers/image read the
# legacy `.sig` lookaside tag. Assert the tag the host actually needs, and that
# the registry digest matches the pin.
digest=$(skopeo inspect --format "{{.Digest}}" "docker://$ref")
[[ $digest == "${ref##*@}" ]] || { echo "verify-image: registry digest $digest differs from $ref" >&2; exit 1; }
skopeo inspect --raw "docker://${ref%@*}:${digest/:/-}.sig" >/dev/null 2>&1 || {
  echo "verify-image: no legacy .sig lookaside for $digest; bootc cannot verify this image" >&2
  exit 1
}
policy=$(mktemp)
trap 'rm -f "$policy"' EXIT
"$repo/lib/containers/render-policy.sh" smortress >"$policy"
jq -e '.default[0].type == "reject"' "$policy" >/dev/null
# An array where containers/image expects a repository map is not a weaker rule,
# it is an unreadable file: the ostree importer refuses the whole policy with
# "JSON object expected, got 91", which is how `bootc switch` failed on the live
# edge while the tag and the signature were both fine.
jq -e '[.transports[] | type] | all(. == "object")' "$policy" >/dev/null
echo "verified $ref"
echo "install/rollback: sudo bootc switch --enforce-container-sigpolicy $ref ; sudo bootc status ; sudo bootc rollback"
