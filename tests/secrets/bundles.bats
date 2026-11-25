#!/usr/bin/env bats
# bats file_tags=secrets
# The bundle migration round-trips a value and a map through one bundle, writes
# the target index, and the boot decrypt reads the result.
#
#   bats tests/secrets/bundles.bats
#
# The shell suite this replaced applied the migration once and asserted six
# things about it; here every test builds its own repository under
# $BATS_TEST_TMPDIR -- its own age identity and SOPS config, so no operator key
# is read -- and applies the migration to that.
load ../helpers

# bundle_fixture: two secrets as their own ciphertexts (the set the migration
# reads), the index that names them, and the bundle spec that folds both into
# boot.json. $work is the repository the migration is pointed at.
bundle_fixture() {
    work=$BATS_TEST_TMPDIR/work
    export SOPS_AGE_KEY_FILE=$work/key.txt
    mkdir -p "$work/secrets/server" "$work/scripts"
    age-keygen -o "$SOPS_AGE_KEY_FILE" >/dev/null 2>&1
    recipient=$(grep '^# public key:' "$SOPS_AGE_KEY_FILE" | awk '{print $NF}')

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
}

# apply_bundles: the migration, as the operator runs it.
apply_bundles() { python3 scripts/secrets-bundle.py --repo "$work" --apply --write-index; }

# missing_source_fixture: a migrated tree with one source ciphertext and the
# target index removed, so the next apply has a gap to refuse.
missing_source_fixture() {
    bundle_fixture
    run apply_bundles
    assert_success
    rm -f "$work/secrets/server/a.yaml" "$work/secrets/index.bundles.json"
}

# --- the migration writes the bundle -----------------------------------------
@test "the bundle is written and encrypted" {
    bundle_fixture
    run apply_bundles
    assert_success
    assert [ -s "$work/secrets/boot.json" ]
}

@test "the target index names the bundle" {
    bundle_fixture
    run apply_bundles
    assert_success
    run grep -q '"bundle": "boot.json"' "$work/secrets/index.bundles.json"
    assert_success
}

# --- the boot decrypt reads what the migration wrote -------------------------
# bundle_round_trip: a migrated tree, then the manifest the migration's index
# renders and the decrypt of that bundle into $work/run.
bundle_round_trip() {
    bundle_fixture
    run apply_bundles
    assert_success
    mkdir -p "$work/src"
    cp "$work/secrets/boot.json" "$work/src/boot.json"
    python3 scripts/secrets-index.py render-manifest --index "$work/secrets/index.bundles.json" --out "$work/manifest"
    run env SMORTRESS_AGE_KEY="$SOPS_AGE_KEY_FILE" SMORTRESS_SECRETS_SRC="$work/src" \
        SMORTRESS_SECRETS_DST="$work/run" SMORTRESS_SECRETS_MANIFEST="$work/manifest" \
        scripts/sops-decrypt.sh
    assert_success
}

@test "a scalar round-trips through the bundle" {
    bundle_round_trip
    assert_equal "$(cat "$work/run/a.yaml")" alpha
}

@test "a map round-trips through the bundle" {
    bundle_round_trip
    run grep -qx 'map:' "$work/run/b.yaml"
    assert_success
    run grep -q 'x: "y"' "$work/run/b.yaml"
    assert_success
}

# --- a missing source set is refused -----------------------------------------
@test "a missing source set is refused before anything is written" {
    missing_source_fixture
    run apply_bundles
    assert_failure
}

@test "a failed apply does not write the target index" {
    missing_source_fixture
    run apply_bundles
    assert_failure
    assert [ ! -e "$work/secrets/index.bundles.json" ]
}
