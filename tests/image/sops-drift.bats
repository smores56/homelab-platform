#!/usr/bin/env bats
# bats file_tags=image
# The SOPS policy drift comparison, and the mutations it must refuse (SDLC #1032).
#
# `scripts/sops-policy.py` is canonical in smores56/dotfiles and vendored here,
# and `.sops.yaml` is its render; nothing compared either copy to its source.
# scripts/check-sops-drift.sh is that comparison, pinned to a dotfiles commit so
# an unrelated dotfiles change cannot fail this repository.
#
# A comparison nobody has seen fail is a comparison that proves nothing, so each
# rule has a mutation here: the fixture is the policy, the config and a canonical
# checkout, one thing is changed the way drift changes it, and the run must fail
# naming the rule that owned it. The canonical half is a directory, never a
# fetch: the suite runs offline and so does every host that runs it.
#
#   bats tests/image/sops-drift.bats
load ../helpers

checker=scripts/check-sops-drift.sh

# fixture <dir>: the tree the checker derives from its own location (the vendored
# policy and the config it must render to), plus the canonical checkout
# --canonical-dir reads instead of fetching the pinned commit.
fixture() {
    local dir=$1
    mkdir -p "$dir/scripts" "$dir/canonical/scripts"
    cp scripts/sops-policy.py scripts/check-sops-drift.sh "$dir/scripts/"
    cp scripts/sops-policy.py "$dir/canonical/scripts/"
    cp .sops.yaml "$dir/"
}

@test "the drift comparison passes on the tree as committed" {
    local dir=$BATS_TEST_TMPDIR/repo
    rm -rf "$dir"
    fixture "$dir"
    run bash "$dir/scripts/check-sops-drift.sh" --canonical-dir "$dir/canonical"
    assert_success
    refute_output --partial 'FAIL'
    assert_output --partial 'checks, 0 problems'
}

# The config in this checkout, not a fixture of it: whoever edits a recipient by
# hand fails here even before CI reaches the pinned ref.
@test "the committed config is the render of the committed policy" {
    run bash -c 'python3 scripts/sops-policy.py render --profile platform | diff -u .sops.yaml -'
    assert_success
}

# CI invokes it by path, so the mode is part of the contract.
@test "the drift checker is tracked as an executable" {
    run git ls-files -s "$checker"
    assert_output --partial '100755'
}

# A branch would make an unrelated dotfiles commit fail this repository, which is
# how a check like this gets ignored. The ref is a commit and the test says so.
@test "the comparison pins a dotfiles commit rather than a branch" {
    run grep -E '^dotfiles_ref=[0-9a-f]{40}$' "$checker"
    assert_success
}

# The comparison is the CI job's, so a job that does not run it is the drift this
# half of the task exists to prevent: green CI, nobody comparing.
@test "the CI drift job runs both comparisons" {
    drift_job() {
        awk '/^  drift:/{found=1} found && /^  [a-z-]+:/ && !/^  drift:/{exit} found' \
            .github/workflows/ci.yml
    }
    run drift_job
    assert_success
    assert_output --partial 'scripts/check-sops-drift.sh'
    assert_output --partial 'scripts/check-lib-drift.sh'
}

@test "the drift comparison selects its own suite" {
    run sh tests/tags.sh scripts/check-sops-drift.sh
    assert_output --partial 'tests/image/sops-drift.bats'
}

# A canonical checkout is read directly, so the suite needs neither git nor the
# network: git is replaced by a stub that fails, and a run that passes never
# called it.
@test "the comparison reads a canonical checkout without fetching" {
    local dir=$BATS_TEST_TMPDIR/repo stub=$BATS_TEST_TMPDIR/bin
    rm -rf "$dir" "$stub"
    fixture "$dir"
    mkdir -p "$stub"
    printf '#!/bin/sh\nexit 97\n' >"$stub/git"
    chmod 0755 "$stub/git"
    run env PATH="$stub:$PATH" bash "$dir/scripts/check-sops-drift.sh" \
        --canonical-dir "$dir/canonical"
    assert_success
    assert_output --partial 'checks, 0 problems'
}

# mutation_fails <fragment> <command...>: copy the fixture, run <command>, and
# require the run to fail naming <fragment>. The command is the mutation: a write
# into the fixture, a removal.
mutation_fails() {
    local fragment=$1
    shift
    local dir=$BATS_TEST_TMPDIR/repo out
    rm -rf "$dir"
    fixture "$dir"
    (cd "$dir" && "$@")
    out=$(bash "$dir/scripts/check-sops-drift.sh" --canonical-dir "$dir/canonical" 2>&1) && {
        printf 'the comparison passed a mutated tree; it was looking for %s\n%s\n' "$fragment" "$out" >&2
        return 1
    }
    assert_contains "$out" "$fragment"
}

# A recipient edited by hand is the failure this whole check exists for: that
# identity stops decrypting the next ciphertext, and only the host notices.
@test "a config with an edited recipient fails the comparison" {
    mutation_fails 'the committed config is the canonical platform render' \
        sed -i 's/^  - &yk3 .*/  - \&yk3 age1replaced/' .sops.yaml
}

@test "a config with an edited creation rule fails the comparison" {
    mutation_fails 'the committed config is the canonical platform render' \
        sed -i 's|^  - path_regex: .*|  - path_regex: ^secrets/.*$|' .sops.yaml
}

@test "a missing config fails the comparison" {
    mutation_fails 'the committed config is the canonical platform render' \
        rm -f .sops.yaml
}

# The vendored copy is copied, never edited: a local fix here is a policy the
# canonical repository does not have.
@test "a vendored policy that is not the canonical one fails the comparison" {
    mutation_fails 'the vendored policy is the canonical one' \
        bash -c 'printf "\n# local fix\n" >>scripts/sops-policy.py'
}

# The other direction: dotfiles changed the policy and this repository did not
# follow. The canonical side is the fixture's copy, so mutating it is that move.
@test "a canonical policy the vendored copy has not followed fails the comparison" {
    mutation_fails 'the vendored policy is the canonical one' \
        bash -c 'printf "\n# upstream\n" >>canonical/scripts/sops-policy.py'
}

# A pin that outlives the file it names: the policy moved in dotfiles and this
# repository would otherwise compare against nothing and pass.
@test "a pinned ref without the policy fails the comparison" {
    mutation_fails 'the canonical policy exists at the pinned ref' \
        rm -f canonical/scripts/sops-policy.py
}
