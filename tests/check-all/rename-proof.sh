#!/usr/bin/env bash
# Proves the `image/` -> `bootc/` rename is mechanical (#940): rebuilds the base
# tree with the same mapping the commit applied and fails unless that reproduces
# the target byte for byte, apart from this script.
#
#   tests/check-all/rename-proof.sh [base] [target]
#
# Run it while the branch is unmerged. Once the rename is on main the base is
# the commit itself and the check is vacuous.
set -euo pipefail

base=${1:-origin/main}
target=${2:-HEAD}
self=tests/check-all/rename-proof.sh

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/base" "$tmp/target"

git archive "$base" | tar -x -C "$tmp/base"
git archive "$target" | tar -x -C "$tmp/target"

# The moves. `pins.env` leaves the artifact tree because the app publish
# workflows read the pins too.
mkdir -p "$tmp/base/bootc/lib"
mv "$tmp/base/image/pins.env" "$tmp/base/bootc/lib/pins.env"
mv "$tmp/base/image" "$tmp/base/bootc/server"
mv "$tmp/base/scripts/check/image" "$tmp/base/scripts/check/server"

# Path references, in the order the commit applied them. The second pass accepts
# `/` as a boundary so `$repo/image/...` moves too; that also catches the
# `tests/image/` suite paths, which did not move, so they are put back.
for pair in 'scripts/check/image/:scripts/check/server/' \
            'image/pins.env:bootc/lib/pins.env'; do
  from=${pair%%:*}
  to=${pair#*:}
  grep -rlIF "$from" "$tmp/base" | xargs -r sed -i "s#$from#$to#g"
done
for boundary in '\(^\|[^A-Za-z0-9_./-]\)' '\(^\|[^A-Za-z0-9_.-]\)'; do
  grep -rlI 'image/' "$tmp/base" \
    | xargs -r sed -i "s#${boundary}image/#\\1bootc/server/#g"
done
grep -rlI 'tests/bootc/server/' "$tmp/base" \
  | xargs -r sed -i 's#tests/bootc/serv''er/#tests/image/#g'

# Three names that look like artifact paths but are not. `secrets-check.py`
# splits the manifest path into components, and `tags.tsv`'s first column names
# a suite under `tests/image/`.
sed -i 's#"image" / "rootfs"#"bootc" / "server" / "rootfs"#' \
  "$tmp/base/scripts/secrets-check.py"
sed -i 's#^bootc/server/\([a-z-]*\)	#image/\1	#' "$tmp/base/tests/tags.tsv"

# Two edits the rename cannot perform. The OS workflows' filters and the
# check-all claim must name the new parent, because the pins now live beside the
# artifact and the checker derives build context from the Containerfile.
grep -rlI '^      - "bootc/server/\*\*"$' "$tmp/base/.github/workflows" \
  | xargs -r sed -i 's#^      - "bootc/server/\*\*"$#      - "bootc/**"#'
sed -i 's#scripts/check/server/\*,bootc/server/\*,#scripts/check/server/*,bootc/server/*,bootc/lib/*,#' \
  "$tmp/base/scripts/check-all.sh"

rm -f "$tmp/base/$self" "$tmp/target/$self"

if diff -r -u "$tmp/base" "$tmp/target" >"$tmp/diff"; then
  printf 'rename-proof: %s equals %s rewritten mechanically\n' "$target" "$base"
else
  head -200 "$tmp/diff"
  printf 'rename-proof: %s differs from the mechanical rewrite of %s\n' "$target" "$base" >&2
  exit 1
fi
