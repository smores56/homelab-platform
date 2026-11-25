#!/usr/bin/env bats
# bats file_tags=secrets
# The boot decrypt extracts a dotted key from a bundle and still accepts the
# five-column manifest an older image or fixture writes.
#
#   bats tests/secrets/decrypt.bats
#
# Every test mints its own age identity and SOPS config under $BATS_TEST_TMPDIR:
# the operator's key material is never read, and the plaintext the decrypt writes
# stays in that test's own destination directory.
load ../helpers

# scratch_identity: an age identity, the SOPS config that names it, the uid/gid a
# manifest line has to carry (the decrypt resolves both through NSS), and $tmp.
scratch_identity() {
    tmp=$BATS_TEST_TMPDIR
    export SOPS_AGE_KEY_FILE=$tmp/key.txt
    printf 'creation_rules:\n  - path_regex: .*\n' >"$tmp/.sops.yaml"
    age-keygen -o "$SOPS_AGE_KEY_FILE" >/dev/null 2>&1
    recipient=$(grep '^# public key:' "$SOPS_AGE_KEY_FILE" | awk '{print $NF}')
    uid=$(id -un)
    gid=$(id -gn)
}

# boot_fixture: one JSON bundle carrying a scalar and a subtree, its ciphertext
# where the decrypt looks for it, and the manifest that names both outputs.
boot_fixture() {
    scratch_identity
    src=$tmp/src
    dst=$tmp/dst
    manifest=$tmp/manifest
    mkdir -p "$src"
    printf '{"restic":{"password":"foo"},"misc":{"flag":"bar"}}' >"$tmp/bundle.json"
    sops --config "$tmp/.sops.yaml" --encrypt --age "$recipient" --input-type json --output-type json "$tmp/bundle.json" >"$src/boot.json"
    cat >"$manifest" <<M
restic-password.yaml boot.json restic.password $uid $gid 0400 value
misc.yaml boot.json misc.flag $uid $gid 0400 yaml
M
}

boot_decrypt() {
    SMORTRESS_AGE_KEY=$SOPS_AGE_KEY_FILE SMORTRESS_SECRETS_SRC=$src SMORTRESS_SECRETS_DST=$dst \
        SMORTRESS_SECRETS_MANIFEST=$manifest scripts/sops-decrypt.sh
}

# --- the seven-column manifest ------------------------------------------------
@test "a bundle value is extracted as a bare scalar" {
    boot_fixture
    run boot_decrypt
    assert_success
    assert_equal "$(cat "$dst/restic-password.yaml")" foo
}

@test "a bundle subtree is extracted as YAML" {
    boot_fixture
    run boot_decrypt
    assert_success
    assert_equal "$(cat "$dst/misc.yaml")" bar
}

# --- the five-column manifest -------------------------------------------------
# Legacy five-column manifest and a whole-file value.
@test "the five-column manifest still extracts its scalar" {
    scratch_identity
    legacy=$tmp/legacy
    mkdir -p "$legacy/src"
    printf 'password: old\n' >"$tmp/old.yaml"
    sops --config "$tmp/.sops.yaml" --encrypt --age "$recipient" --input-type yaml --output-type yaml "$tmp/old.yaml" >"$legacy/src/old.yaml"
    printf 'old.yaml %s %s 0400 value\n' "$uid" "$gid" >"$legacy/manifest"
    run env SMORTRESS_AGE_KEY="$SOPS_AGE_KEY_FILE" SMORTRESS_SECRETS_SRC="$legacy/src" \
        SMORTRESS_SECRETS_DST="$legacy/dst" SMORTRESS_SECRETS_MANIFEST="$legacy/manifest" \
        scripts/sops-decrypt.sh
    assert_success
    assert_equal "$(cat "$legacy/dst/old.yaml")" old
}
