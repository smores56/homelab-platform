#!/usr/bin/env bats
# bats file_tags=secrets
# The operator CLI resolves a bundle, stages it with the manifest mode, and
# hands the editor the committed ciphertext. No identity is needed here.
#
#   bats tests/secrets/rotate.bats
load ../helpers

cli=scripts/secret.sh

# `list` asks the committed index; the row the old suite grepped for is the one
# output whose bundle and consumer are both named.
@test "list shows the output, bundle, and consumer" {
    rc=0
    out=$("$cli" list 2>&1) || rc=$?
    assert_equal "$rc" 0
    assert_equal "$(printf '%s\n' "$out" | grep -c $'^restic-password.yaml\tboot.json\t' || true)" 1
}

# Staging is a root write on a host; here the destination is the test's own
# directory and no command runs as root.
@test "stage writes the bundle with its mode" {
    dst=$BATS_TEST_TMPDIR/dst
    run env SMORTRESS_SECRETS_SRC="$dst" SMORTRESS_ROOT_CMD= \
        SMORTRESS_STAGE_OWNER="$(id -un)" SMORTRESS_STAGE_GROUP="$(id -gn)" \
        "$cli" stage restic-password.yaml --no-restart
    assert_success
    assert [ -s "$dst/boot.json" ]
}

# The editor is sops, and it must be handed the ciphertext the repository
# commits -- not the staged copy, which a decrypt unit may not have written yet.
@test "edit opens the committed ciphertext" {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat >"$BATS_TEST_TMPDIR/bin/sops" <<'SH'
#!/bin/sh
printf '%s\n' "$@" >"$SOPS_LOG"
SH
    chmod 0755 "$BATS_TEST_TMPDIR/bin/sops"
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" SOPS_LOG="$BATS_TEST_TMPDIR/sops.args" \
        SOPS_BIN=sops "$cli" edit restic-password.yaml
    assert_success
    run grep -q 'secrets/boot.json' "$BATS_TEST_TMPDIR/sops.args"
    assert_success
}

@test "verify runs the keyless checks" {
    run "$cli" verify
    assert_success
}
