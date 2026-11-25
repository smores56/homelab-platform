#!/usr/bin/env bats
# bats file_tags=secrets
# The seed must retire an unlisted ciphertext, preserve a rotation, render the
# manifest from the index, and put the retired set back on --rollback.
#
#   bats tests/secrets/migration.bats
#
# The shell suite this replaced ran one seed and then one rollback over a single
# fixture; here each check seeds its own tree under $BATS_TEST_TMPDIR, so the
# rollback checks do not depend on what the seeding checks left behind.
load ../helpers

# seed_fixture: the image's ciphertext set, the host set that is already one
# secret behind it, and the image's index. $dst holds a rotation of a.yaml -- the
# value the host wrote -- and old.yaml/old.json, which the index no longer names.
seed_fixture() {
    baked=$BATS_TEST_TMPDIR/baked
    dst=$BATS_TEST_TMPDIR/dst
    retired=$BATS_TEST_TMPDIR/retired
    manifest=$BATS_TEST_TMPDIR/etc/smortress/secrets.manifest
    index=$BATS_TEST_TMPDIR/index.json

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
}

# seed_run [<seed args>...]: the seed, pointed at the fixture above.
seed_run() {
    SMORTRESS_SECRETS_BAKED=$baked \
    SMORTRESS_SECRETS_SRC=$dst \
    SMORTRESS_SECRETS_IMAGE_INDEX=$index \
    SMORTRESS_SECRETS_MANIFEST=$manifest \
    SMORTRESS_SECRETS_RETIRED=$retired \
    SMORTRESS_INDEX_BIN=$repo_root/scripts/secrets-index.py \
        scripts/smortress-secrets-seed.sh "$@"
}

# seed_once: the fixture, seeded as a boot would seed it.
seed_once() {
    seed_fixture
    seed_run >/dev/null 2>&1
}

# --- the boot seed -----------------------------------------------------------
@test "an existing ciphertext is a rotation and is not overwritten" {
    seed_once
    assert_equal "$(cat "$dst/a.yaml")" a-old
}

@test "a missing ciphertext is seeded from the image" {
    seed_once
    assert_equal "$(cat "$dst/b.yaml")" b-image
}

@test "a missing JSON bundle is seeded from the image" {
    seed_once
    assert_equal "$(cat "$dst/c.json")" c-json
}

@test "an unlisted ciphertext is retired" {
    seed_once
    assert [ ! -e "$dst/old.yaml" ]
}

@test "the retired YAML and JSON files are kept, not deleted" {
    seed_once
    assert [ -n "$(find "$retired" -name old.yaml -print -quit)" ]
    assert [ -n "$(find "$retired" -name old.json -print -quit)" ]
}

@test "the manifest is rendered from the index" {
    seed_once
    assert_equal "$(wc -l <"$manifest")" 3
    run grep -qxF 'a.yaml a.yaml * root root 0400 yaml' "$manifest"
    assert_success
    run grep -qxF 'b.yaml b.yaml * root root 0400 yaml' "$manifest"
    assert_success
    run grep -qxF 'c.yaml c.json * root root 0400 yaml' "$manifest"
    assert_success
}

# --- the rollback ------------------------------------------------------------
# seed_and_roll_back: a seeded host, then the seed asked to undo its own
# retirement.
seed_and_roll_back() {
    seed_once
    seed_run --rollback >/dev/null 2>&1
}

@test "--rollback restores the retired YAML" {
    seed_and_roll_back
    assert_equal "$(cat "$dst/old.yaml")" old
}

@test "--rollback restores the retired JSON" {
    seed_and_roll_back
    assert_equal "$(cat "$dst/old.json")" old-json
}

@test "rollback leaves the current set alone" {
    seed_and_roll_back
    assert [ -e "$dst/a.yaml" ]
    assert [ -e "$dst/b.yaml" ]
}

@test "rollback removes the empty retirement run" {
    seed_and_roll_back
    assert_equal "$(find "$retired" -mindepth 1 -type d -print -quit 2>/dev/null || true)" ""
}
