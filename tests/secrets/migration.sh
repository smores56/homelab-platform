#!/usr/bin/env bash
# The seed must retire an unlisted ciphertext, preserve a rotation, render the
# manifest from the index, and put the retired set back on --rollback.
#   tests/secrets/migration.sh
set -euo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root" || exit 1

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

baked=$work/baked
dst=$work/dst
retired=$work/retired
manifest=$work/etc/smortress/secrets.manifest
index=$work/index.json

mkdir -p "$baked" "$dst"
printf 'a-old\n' >"$dst/a.yaml"
printf 'old\n' >"$dst/old.yaml"
printf 'old-json\n' >"$dst/old.json"
printf 'a-image\n' >"$baked/a.yaml"
printf 'b-image\n' >"$baked/b.yaml"
printf 'c-json\n' >"$baked/c.json"

python3 - "$index" <<'PY'
import json, sys
outputs = [
    {"name": "a.yaml", "bundle": "a.yaml", "key": "*", "uid": "root", "gid": "root", "mode": "0400", "format": "yaml"},
    {"name": "b.yaml", "bundle": "b.yaml", "key": "*", "uid": "root", "gid": "root", "mode": "0400", "format": "yaml"},
    {"name": "c.yaml", "bundle": "c.json", "key": "*", "uid": "root", "gid": "root", "mode": "0400", "format": "yaml"},
]
json.dump({"bundles": {o["name"]: o["bundle"] for o in outputs}, "operator": [], "outputs": outputs}, open(sys.argv[1], "w"))
PY

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$*"; }
no() { fail=$((fail + 1)); printf 'FAIL %s\n' "$*" >&2; }
expect_file() {
    if [[ $(cat "$1" 2>/dev/null) == "$2" ]]; then ok "$3"; else no "$3 (got '$(cat "$1" 2>/dev/null)')"; fi
}

run_seed() {
    SMORTRESS_SECRETS_BAKED=$baked \
    SMORTRESS_SECRETS_SRC=$dst \
    SMORTRESS_SECRETS_IMAGE_INDEX=$index \
    SMORTRESS_SECRETS_MANIFEST=$manifest \
    SMORTRESS_SECRETS_RETIRED=$retired \
    SMORTRESS_INDEX_BIN=$root/scripts/secrets-index.py \
    scripts/smortress-secrets-seed.sh "$@"
}

run_seed >/dev/null 2>&1
expect_file "$dst/a.yaml" "a-old" "an existing ciphertext is a rotation and is not overwritten"
expect_file "$dst/b.yaml" "b-image" "a missing ciphertext is seeded from the image"
expect_file "$dst/c.json" "c-json" "a missing JSON bundle is seeded from the image"
if [[ -e "$dst/old.yaml" ]]; then no "an unlisted ciphertext is retired"; else ok "an unlisted ciphertext is retired"; fi
if find "$retired" -name old.yaml -print -quit | grep -q . && find "$retired" -name old.json -print -quit | grep -q .; then ok "the retired YAML and JSON files are kept, not deleted"; else no "the retired YAML and JSON files are kept, not deleted"; fi

if [[ $(wc -l <"$manifest") -eq 3 ]] && grep -qxF 'a.yaml a.yaml * root root 0400 yaml' "$manifest" && grep -qxF 'b.yaml b.yaml * root root 0400 yaml' "$manifest" && grep -qxF 'c.yaml c.json * root root 0400 yaml' "$manifest"; then
    ok "the manifest is rendered from the index"
else
    no "the manifest is rendered from the index"
fi

run_seed --rollback >/dev/null 2>&1
expect_file "$dst/old.yaml" "old" "--rollback restores the retired YAML"
expect_file "$dst/old.json" "old-json" "--rollback restores the retired JSON"
if [[ -e "$dst/a.yaml" && -e "$dst/b.yaml" ]]; then ok "rollback leaves the current set alone"; else no "rollback leaves the current set alone"; fi
if [[ -z $(find "$retired" -mindepth 1 -type d -print -quit) ]]; then ok "rollback removes the empty retirement run"; else no "rollback removes the empty retirement run"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
