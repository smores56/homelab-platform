#!/usr/bin/env bash
# The boot decrypt extracts a dotted key from a bundle and still accepts the
# five-column manifest an older image or fixture writes.
#   tests/secrets/decrypt.sh
set -euo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root" || exit 1
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export SOPS_AGE_KEY_FILE=$work/key.txt
printf 'creation_rules:\n  - path_regex: .*\n' >"$work/.sops.yaml"
age-keygen -o "$SOPS_AGE_KEY_FILE" >/dev/null 2>&1
recipient=$(grep '^# public key:' "$SOPS_AGE_KEY_FILE" | awk '{print $NF}')

uid=$(id -un)
gid=$(id -gn)
src=$work/src
dst=$work/dst
mkdir -p "$src"
printf '{"restic":{"password":"foo"},"misc":{"flag":"bar"}}' >"$work/bundle.json"
sops --config "$work/.sops.yaml" --encrypt --age "$recipient" --input-type json --output-type json "$work/bundle.json" >"$src/boot.json"

cat >"$work/manifest" <<M
restic-password.yaml boot.json restic.password $uid $gid 0400 value
misc.yaml boot.json misc.flag $uid $gid 0400 yaml
M

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$*"; }
no() { fail=$((fail + 1)); printf 'FAIL %s\n' "$*" >&2; }
expect() { if [[ $(cat "$1" 2>/dev/null) == "$2" ]]; then ok "$3"; else no "$3 (got '$(cat "$1" 2>/dev/null)')"; fi; }

SMORTRESS_AGE_KEY=$work/key.txt SMORTRESS_SECRETS_SRC=$src SMORTRESS_SECRETS_DST=$dst SMORTRESS_SECRETS_MANIFEST=$work/manifest \
  scripts/sops-decrypt.sh >/dev/null 2>&1
expect "$dst/restic-password.yaml" "foo" "a bundle value is extracted as a bare scalar"
expect "$dst/misc.yaml" "bar" "a bundle subtree is extracted as YAML"

# Legacy five-column manifest and a whole-file value.
legacy=$work/legacy
mkdir -p "$legacy/src"
printf 'password: old\n' >"$work/old.yaml"
sops --config "$work/.sops.yaml" --encrypt --age "$recipient" --input-type yaml --output-type yaml "$work/old.yaml" >"$legacy/src/old.yaml"
printf 'old.yaml %s %s 0400 value\n' "$uid" "$gid" >"$legacy/manifest"
SMORTRESS_AGE_KEY=$work/key.txt SMORTRESS_SECRETS_SRC=$legacy/src SMORTRESS_SECRETS_DST=$legacy/dst \
  SMORTRESS_SECRETS_MANIFEST=$legacy/manifest scripts/sops-decrypt.sh >/dev/null 2>&1
expect "$legacy/dst/old.yaml" "old" "the five-column manifest still extracts its scalar"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
