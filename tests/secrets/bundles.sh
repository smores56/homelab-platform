#!/usr/bin/env bash
# The bundle migration round-trips a value and a map through one bundle, writes
# the target index, and the boot decrypt reads the result.
#   tests/secrets/bundles.sh
set -euo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root" || exit 1
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export SOPS_AGE_KEY_FILE=$work/key.txt
age-keygen -o "$SOPS_AGE_KEY_FILE" >/dev/null 2>&1
recipient=$(grep '^# public key:' "$SOPS_AGE_KEY_FILE" | awk '{print $NF}')

mkdir -p "$work/secrets/server" "$work/scripts"
cat >"$work/.sops.yaml" <<YAML
keys:
  - &test $recipient
creation_rules:
  - path_regex: ^secrets/.*\.(yaml|json)$
    key_groups:
      - age:
          - *test
YAML
printf 'password: alpha\n' >"$work/a.yml"
printf 'map:\n  x: y\n' >"$work/b.yml"
sops --config "$work/.sops.yaml" --encrypt --input-type yaml --output-type yaml --filename-override "$work/secrets/server/a.yaml" "$work/a.yml" >"$work/secrets/server/a.yaml"
sops --config "$work/.sops.yaml" --encrypt --input-type yaml --output-type yaml --filename-override "$work/secrets/server/b.yaml" "$work/b.yml" >"$work/secrets/server/b.yaml"
cat >"$work/secrets/index.json" <<JSON
{"bundles":{"a.yaml":"a.yaml","b.yaml":"b.yaml"},"operator":[],"outputs":[
 {"name":"a.yaml","bundle":"a.yaml","key":"password","uid":"$(id -un)","gid":"$(id -gn)","mode":"0400","format":"value","consumer":""},
 {"name":"b.yaml","bundle":"b.yaml","key":"*","uid":"$(id -un)","gid":"$(id -gn)","mode":"0400","format":"yaml","consumer":""}
]}
JSON
cat >"$work/scripts/secrets-bundles.json" <<'JSON'
{"boot.json":{"a.yaml":"nested.value","b.yaml":"nested.map"}}
JSON

python3 scripts/secrets-bundle.py --repo "$work" --apply --write-index >/dev/null 2>&1

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$*"; }
no() { fail=$((fail + 1)); printf 'FAIL %s\n' "$*" >&2; }
expect() { if [[ $(cat "$1" 2>/dev/null) == "$2" ]]; then ok "$3"; else no "$3 (got '$(cat "$1" 2>/dev/null)')"; fi; }

[[ -s $work/secrets/boot.json ]] && ok "the bundle is written and encrypted" || no "the bundle is written and encrypted"
grep -q '"bundle": "boot.json"' "$work/secrets/index.bundles.json" && ok "the target index names the bundle" || no "the target index names the bundle"

mkdir -p "$work/src"
cp "$work/secrets/boot.json" "$work/src/boot.json"
python3 scripts/secrets-index.py render-manifest --index "$work/secrets/index.bundles.json" --out "$work/manifest"
SMORTRESS_AGE_KEY=$SOPS_AGE_KEY_FILE SMORTRESS_SECRETS_SRC=$work/src SMORTRESS_SECRETS_DST=$work/run \
  SMORTRESS_SECRETS_MANIFEST=$work/manifest scripts/sops-decrypt.sh >/dev/null 2>&1
expect "$work/run/a.yaml" "alpha" "a scalar round-trips through the bundle"
if grep -qx 'map:' "$work/run/b.yaml" && grep -q 'x: "y"' "$work/run/b.yaml"; then
  ok "a map round-trips through the bundle"
else
  no "a map round-trips through the bundle (got '$(cat "$work/run/b.yaml")')"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
