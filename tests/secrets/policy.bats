#!/usr/bin/env bats
# bats file_tags=secrets
# The SOPS policy checker must pass the real tree and fail each drift shape.
#
#   bats tests/secrets/policy.bats
#
# The shell suite this replaced built every drift shape in one scratch tree and
# kept a running count; here each shape is its own test with its own scratch
# repository under $BATS_TEST_TMPDIR, so a failure names the drift it found.
load ../helpers

policy=scripts/sops-policy.py

# scratch_repo <profile>: a git repository holding nothing but the policy
# rendered for that profile. The recipients it grants land in $repo_age, which is
# where every ciphertext below takes its keys from.
scratch_repo() {
    local profile=$1 line
    scratch=$BATS_TEST_TMPDIR/repo
    mkdir -p "$scratch/secrets"
    git -C "$scratch" init -q
    python3 "$policy" render --profile "$profile" --out "$scratch/.sops.yaml"
    repo_age=()
    while IFS= read -r line; do repo_age+=("$line"); done < <(
        awk '/^keys:/{f=1} /^creation_rules:/{f=0} f && /age1/{print $NF}' "$scratch/.sops.yaml"
    )
}

# yaml_cipher <file> [<recipient>...]: what sops writes for a YAML document, with
# the recipients given and no data key anyone can open.
yaml_cipher() {
    local file=$1 r
    shift
    {
        printf 'secret: ENC[AES256_GCM,data:x]\n'
        printf 'sops:\n    age:\n'
        for r in "$@"; do
            printf '        - recipient: %s\n          enc: |\n            fake\n' "$r"
        done
    } >"$file"
}

# json_cipher <file> [<recipient>...]: the same shape for a JSON bundle.
json_cipher() {
    local file=$1 r first=true
    shift
    {
        printf '{"apps":{},"sops":{"age":['
        for r in "$@"; do
            $first || printf ','
            first=false
            printf '{"recipient":"%s","enc":"fake"}' "$r"
        done
        printf ']}}'
    } >"$file"
}

# check_repo <dir>: the checker's exit status is the whole assertion.
check_repo() { python3 "$policy" check --repo "$1" >/dev/null 2>&1; }

# --- the drift shapes --------------------------------------------------------
# Valid platform-shaped repo.
@test "a canonical ciphertext passes" {
    scratch_repo platform
    yaml_cipher "$scratch/secrets/a.yaml" "${repo_age[@]}"
    git -C "$scratch" add -A
    run check_repo "$scratch"
    assert_success
}

# Missing recipient.
@test "a missing recipient fails" {
    scratch_repo platform
    yaml_cipher "$scratch/secrets/a.yaml" "${repo_age[@]:0:4}"
    git -C "$scratch" add -A
    run check_repo "$scratch"
    assert_failure
}

# Reordered recipients.
@test "a reordered recipient list fails" {
    scratch_repo platform
    yaml_cipher "$scratch/secrets/a.yaml" "${repo_age[1]}" "${repo_age[0]}" "${repo_age[@]:2}"
    git -C "$scratch" add -A
    run check_repo "$scratch"
    assert_failure
}

# A plaintext file under a matching rule.
@test "a plaintext ciphertext path fails" {
    scratch_repo platform
    yaml_cipher "$scratch/secrets/a.yaml" "${repo_age[@]}"
    printf 'token: hunter2\n' >"$scratch/secrets/plain.yaml"
    git -C "$scratch" add -A
    run check_repo "$scratch"
    assert_failure
}

# A ciphertext matched by no rule.
@test "an unmatched ciphertext fails" {
    scratch_repo platform
    yaml_cipher "$scratch/secrets/a.yaml" "${repo_age[@]}"
    yaml_cipher "$scratch/elsewhere.yaml" "${repo_age[@]}"
    git -C "$scratch" add -A
    run check_repo "$scratch"
    assert_failure
}

# Tenant JSON is covered by the apps profile.
@test "the tenant JSON passes" {
    scratch_repo apps
    json_cipher "$scratch/secrets.sops.json" "${repo_age[@]}"
    git -C "$scratch" add -A
    run check_repo "$scratch"
    assert_success
}

@test "the tenant JSON missing a recipient fails" {
    scratch_repo apps
    json_cipher "$scratch/secrets.sops.json" "${repo_age[@]:0:4}"
    git -C "$scratch" add -A
    run check_repo "$scratch"
    assert_failure
}
