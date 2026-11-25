#!/usr/bin/env bash
# Derive the boot outputs that come from the single Cloudflare credential bundle.
#
#   scripts/cloudflare-derive.sh
#
# secrets/cloudflare.yaml is the only place a Cloudflare token is authored, and
# one output of secrets/boot.json is a copy of it: `r2`, from
# `restic-backup-rw-*`, for the host's restic reader (`r2.r2_access_key_id` /
# `r2_secret_access_key`).
# This rewrites that object and preserves every other key in the bundle.
#
# `acme.token` used to be the second copy: a DNS-01 token for the smortress
# Caddy, which needed one because no public CA could reach a tailnet VIP over
# HTTP. That Caddy is gone and each application answers through a Tailscale
# Service, so the token is dead weight -- and it is *deleted* here rather than
# only no longer written, because a bundle that keeps a retired credential hands
# it to every future decrypt for nothing.
# Needs the operator identity; writes no plaintext outside the temporary directory
# it removes on exit.
# shellcheck disable=SC2016  # the jq expression is single-quoted on purpose
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(cd -- "$here/.." && pwd)
# shellcheck source=/dev/null
source "$here/lib/log.sh"

src=${CLOUDFLARE_SECRETS_FILE:-$root/secrets/cloudflare.yaml}
boot=${SMORTRESS_BOOT_BUNDLE:-$root/secrets/boot.json}
config=${SMORTRESS_SOPS_CONFIG:-$root/.sops.yaml}
sops_bin=${SOPS_BIN:-sops}
jq_bin=${JQ_BIN:-jq}

[[ -r $src ]] || die "cannot read $src"
[[ -r $boot ]] || die "cannot read $boot"
[[ -r $config ]] || die "cannot read $config"

key_id=$("$sops_bin" -d --extract '["restic-backup-rw-access-key-id"]' "$src")
key_secret=$("$sops_bin" -d --extract '["restic-backup-rw-secret-access-key"]' "$src")
[[ $key_id =~ ^[0-9a-f]{32}$ ]] \
  || die "restic-backup-rw-access-key-id is not 32 hex characters"
[[ $key_secret =~ ^[0-9a-f]{64}$ ]] \
  || die "restic-backup-rw-secret-access-key is not 64 hex characters"

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

"$sops_bin" -d --input-type json --output-type json "$boot" >"$tmp/boot.json"
# `.acme` is dropped with `del` rather than left alone: a bundle written by an
# older run carries it, and preserving every *other* key is about the ones that
# still have a consumer.
"$jq_bin" --arg id "$key_id" --arg secret "$key_secret" \
  '.r2 = {"r2_access_key_id": $id, "r2_secret_access_key": $secret}
   | del(.acme)' \
  "$tmp/boot.json" >"$tmp/next.json"
"$sops_bin" --config "$config" --encrypt --input-type json --output-type json \
  --filename-override "$boot" "$tmp/next.json" >"$tmp/next.enc"
chmod 0644 "$tmp/next.enc"

got=$("$sops_bin" -d --input-type json --output-type json \
  --extract '["r2"]["r2_access_key_id"]' "$tmp/next.enc")
[[ $got == "$key_id" ]] || die "the derived bundle did not round-trip"
mv -- "$tmp/next.enc" "$boot"
say "derived $boot .r2 from $src"
say "next: scripts/secret.sh stage boot.json"
