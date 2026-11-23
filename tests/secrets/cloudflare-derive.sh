#!/usr/bin/env bash
# The derivation rewrites only boot.json .r2 and .acme.token and keeps every
# other key; a token of the wrong shape is refused without touching the bundle.
#   tests/secrets/cloudflare-derive.sh
set -euo pipefail
root=$(git rev-parse --show-toplevel)
cd "$root" || exit 1
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
export SOPS_AGE_KEY_FILE=$work/key.txt
age-keygen -o "$SOPS_AGE_KEY_FILE" >/dev/null 2>&1
recipient=$(grep '^# public key:' "$SOPS_AGE_KEY_FILE" | awk '{print $NF}')
mkdir -p "$work/secrets"
cat >"$work/.sops.yaml" <<YAML
keys:
  - &test $recipient
creation_rules:
  - path_regex: .*
    key_groups:
      - age:
          - *test
YAML
cat >"$work/cloudflare.yml" <<YAML
restic-backup-rw-access-key-id: $(printf 'a%.0s' {1..32})
restic-backup-rw-secret-access-key: $(printf 'b%.0s' {1..64})
platform-zone-rw-api-token: cf-token
tailnet-dns-api-token: $(printf 'c%.0s' {1..40})
YAML
sops --config "$work/.sops.yaml" --encrypt --input-type yaml --output-type yaml --filename-override "$work/secrets/cloudflare.yaml" "$work/cloudflare.yml" >"$work/secrets/cloudflare.yaml"
printf '{"restic":{"password":"keep"},"r2":{"r2_access_key_id":"old","r2_secret_access_key":"old"}}' >"$work/boot.json"
sops --config "$work/.sops.yaml" --encrypt --input-type json --output-type json --filename-override "$work/secrets/boot.json" "$work/boot.json" >"$work/secrets/boot.json"

CLOUDFLARE_SECRETS_FILE=$work/secrets/cloudflare.yaml \
SMORTRESS_BOOT_BUNDLE=$work/secrets/boot.json \
SMORTRESS_SOPS_CONFIG=$work/.sops.yaml \
  scripts/cloudflare-derive.sh >/dev/null 2>&1

pass=0; fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$*"; }
no() { fail=$((fail + 1)); printf 'FAIL %s\n' "$*" >&2; }
id=$(sops -d --input-type json --output-type json --extract '["r2"]["r2_access_key_id"]' "$work/secrets/boot.json")
secret=$(sops -d --input-type json --output-type json --extract '["r2"]["r2_secret_access_key"]' "$work/secrets/boot.json")
keep=$(sops -d --input-type json --output-type json --extract '["restic"]["password"]' "$work/secrets/boot.json")
acme=$(sops -d --input-type json --output-type json --extract '["acme"]["token"]' "$work/secrets/boot.json")
[[ $id == $(printf 'a%.0s' {1..32}) ]] && ok "the R2 id is derived" || no "the R2 id is derived"
[[ $secret == $(printf 'b%.0s' {1..64}) ]] && ok "the R2 secret is derived" || no "the R2 secret is derived"
[[ $acme == $(printf 'c%.0s' {1..40}) ]] && ok "the ACME token is derived" || no "the ACME token is derived"
[[ $keep == keep ]] && ok "every other bundle key is preserved" || no "every other bundle key is preserved"

# A token that is not a Cloudflare API token fails the shape check, and the
# refusal is total: the bundle keeps what the last good run wrote, because a
# half-derived boot.json is a consumer holding a value the store does not have.
cp "$work/secrets/boot.json" "$work/boot.good"
cat >"$work/cloudflare-bad.yml" <<YAML
restic-backup-rw-access-key-id: $(printf 'a%.0s' {1..32})
restic-backup-rw-secret-access-key: $(printf 'b%.0s' {1..64})
tailnet-dns-api-token: truncated
YAML
sops --config "$work/.sops.yaml" --encrypt --input-type yaml --output-type yaml \
  --filename-override "$work/secrets/cloudflare.yaml" "$work/cloudflare-bad.yml" >"$work/secrets/cloudflare.yaml"
if CLOUDFLARE_SECRETS_FILE=$work/secrets/cloudflare.yaml \
  SMORTRESS_BOOT_BUNDLE=$work/secrets/boot.json \
  SMORTRESS_SOPS_CONFIG=$work/.sops.yaml \
  scripts/cloudflare-derive.sh >/dev/null 2>&1; then
  no "a token of the wrong shape is refused"
else
  ok "a token of the wrong shape is refused"
fi
if cmp -s "$work/boot.good" "$work/secrets/boot.json"; then
  ok "a refused derivation leaves the bundle alone"
else
  no "a refused derivation leaves the bundle alone"
fi
printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
