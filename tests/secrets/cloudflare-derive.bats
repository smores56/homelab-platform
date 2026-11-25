#!/usr/bin/env bats
# bats file_tags=secrets
# The derivation rewrites only boot.json .r2 and keeps every other key; the
# retired .acme token is deleted if an older bundle still carries it, and a key
# of the wrong shape is refused without touching the bundle.
#
#   bats tests/secrets/cloudflare-derive.bats
#
# Every test mints its own age identity and SOPS config under $BATS_TEST_TMPDIR
# and derives into its own bundle, so nothing here reads the operator's key or
# the committed ciphertext.
load ../helpers

# derive_fixture: the Cloudflare bundle the host derives from, and a boot.json
# that still carries the retired .acme token. $work is the whole fixture.
derive_fixture() {
    work=$BATS_TEST_TMPDIR/work
    export SOPS_AGE_KEY_FILE=$work/key.txt
    mkdir -p "$work/secrets"
    age-keygen -o "$SOPS_AGE_KEY_FILE" >/dev/null 2>&1
    recipient=$(grep '^# public key:' "$SOPS_AGE_KEY_FILE" | awk '{print $NF}')
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
YAML
    sops --config "$work/.sops.yaml" --encrypt --input-type yaml --output-type yaml --filename-override "$work/secrets/cloudflare.yaml" "$work/cloudflare.yml" >"$work/secrets/cloudflare.yaml"
    printf '{"restic":{"password":"keep"},"r2":{"r2_access_key_id":"old","r2_secret_access_key":"old"},"acme":{"token":"retired"}}' >"$work/boot.json"
    sops --config "$work/.sops.yaml" --encrypt --input-type json --output-type json --filename-override "$work/secrets/boot.json" "$work/boot.json" >"$work/secrets/boot.json"
}

derive_run() {
    CLOUDFLARE_SECRETS_FILE=$work/secrets/cloudflare.yaml \
    SMORTRESS_BOOT_BUNDLE=$work/secrets/boot.json \
    SMORTRESS_SOPS_CONFIG=$work/.sops.yaml \
        scripts/cloudflare-derive.sh
}

# derived: one field of the bundle the derivation wrote.
derived() { sops -d --input-type json --output-type json --extract "$1" "$work/secrets/boot.json"; }

# --- what the derivation writes ----------------------------------------------
@test "the R2 id is derived" {
    derive_fixture
    run derive_run
    assert_success
    assert_equal "$(derived '["r2"]["r2_access_key_id"]')" "$(printf 'a%.0s' {1..32})"
}

@test "the R2 secret is derived" {
    derive_fixture
    run derive_run
    assert_success
    assert_equal "$(derived '["r2"]["r2_secret_access_key"]')" "$(printf 'b%.0s' {1..64})"
}

@test "the retired ACME token is deleted" {
    derive_fixture
    run derive_run
    assert_success
    acme=$(derived '["acme"]' 2>/dev/null || true)
    assert_equal "$acme" ""
}

@test "every other bundle key is preserved" {
    derive_fixture
    run derive_run
    assert_success
    assert_equal "$(derived '["restic"]["password"]')" keep
}

# --- a key of the wrong shape fails the whole run ----------------------------
# A secret that is not an R2 secret fails the shape check, and the refusal is
# total: the bundle keeps what the last good run wrote, because a half-derived
# boot.json is a consumer holding a value the store does not have.
bad_cloudflare() {
    cat >"$work/cloudflare-bad.yml" <<YAML
restic-backup-rw-access-key-id: $(printf 'a%.0s' {1..32})
restic-backup-rw-secret-access-key: truncated
YAML
    sops --config "$work/.sops.yaml" --encrypt --input-type yaml --output-type yaml \
        --filename-override "$work/secrets/cloudflare.yaml" "$work/cloudflare-bad.yml" >"$work/secrets/cloudflare.yaml"
}

# derived_once_with_a_bad_secret: a good derivation, its bundle kept aside as
# $work/boot.good, then a Cloudflare bundle whose secret is truncated.
derived_once_with_a_bad_secret() {
    derive_fixture
    run derive_run
    assert_success
    cp "$work/secrets/boot.json" "$work/boot.good"
    bad_cloudflare
}

@test "a key of the wrong shape is refused" {
    derived_once_with_a_bad_secret
    run derive_run
    assert_failure
}

@test "a refused derivation leaves the bundle alone" {
    derived_once_with_a_bad_secret
    run derive_run
    assert_failure
    assert cmp -s "$work/boot.good" "$work/secrets/boot.json"
}
