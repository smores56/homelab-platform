#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2154  # the storage table's values and the source text quoted below are literal
# Static checks for the derived image, Ignition template, Quadlets and SOPS
# layout. No registry, no cosign key and no operator secret is required.
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# The storage table is the only list of datasets: a volume is a dataset iff its
# mountpoint is in the table, and the readiness instance is derived from it.
# shellcheck source=/dev/null
source "$repo/scripts/storage-layout.sh"
declare -A mount_to_instance=()
for _key in "${dataset_order[@]}"; do
  for _alias in $(mountpoint_aliases "$_key"); do
    mount_to_instance[$_alias]=$(readiness_instance "$_key")
  done
done
unset _key
cd "$repo"
# shellcheck source=../bootc/lib/pins.env disable=SC1091
source bootc/lib/pins.env

fail=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }
check() { local name=$1; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
has() { grep -rqF -- "$1" "$2"; }
lacks() { ! grep -rqF -- "$1" "$2"; }
count() { grep -cF -- "$1" "$2" || true; }
probe() { local name=$1; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }
no_file_exists() { [[ ! -e $1 ]]; }

# shellcheck source=/dev/null
source "$repo/scripts/check/server/image.sh"
# shellcheck source=/dev/null
source "$repo/scripts/check/server/access.sh"
# shellcheck source=/dev/null
source "$repo/scripts/check/server/secrets.sh"
# shellcheck source=/dev/null
source "$repo/scripts/check/server/deploy.sh"
