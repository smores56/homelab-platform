#!/usr/bin/env bats
# bats file_tags=lint
# The lint group's chain, one test per command it runs.
#
#   bats tests/lint.bats
#
# The group chains its commands with `&&`, so the first failure hides every one
# behind it; here each is its own test and a run reports all that fail. The
# command lines stay byte-identical to the group table's and build their file
# lists from `git ls-files` the same way, so a test fails for the reason the
# group would. SC2046 is waived on those lines: the word split the group's own
# unquoted command substitutions perform is the behaviour under test.
load helpers

@test "the tracked yaml passes yamllint" {
    # shellcheck disable=SC2046
    run yamllint -c .yamllint.yaml $(git ls-files '*.yaml' '*.yml')
    assert_success
}

@test "every shell script passes shellcheck" {
    # shellcheck disable=SC2046
    run shellcheck scripts/*.sh scripts/lib/*.sh scripts/deploy/apps/*.sh bootc/lib/deploy/*.sh scripts/check/server/*.sh backrest/scripts/*.sh backrest/container/entrypoint.sh .githooks/* hosts/*/scripts/*.sh $(git ls-files 'tests/*.sh' 'tests/*/*.sh' 'tests/*.bash' 'tests/*/*.bash' 'bootc/*/tests/*.sh' 'hosts/*/tests/*.sh')
    assert_success
}

@test "every bats file passes shellcheck at warning severity" {
    # shellcheck disable=SC2046
    run shellcheck --severity=warning -e SC2030,SC2031,SC2034,SC2154 $(git ls-files '*.bats')
    assert_success
}

@test "every remote action is pinned to a full commit sha" {
    run scripts/check-action-pins.sh
    assert_success
}

@test "no pull_request workflow reads a secret outside the exempt one" {
    run scripts/check-pr-secret-boundary.sh
    assert_success
}

@test "CODEOWNERS and the critical doc agree" {
    run scripts/check-codeowners.sh
    assert_success
}

@test "the branch adds no whitespace errors" {
    run diff_check
    assert_success
}

# diff_check: the group's compound verbatim, against ${BASE:-origin/main} when
# that ref exists and HEAD^1 otherwise. SC1075 is waived because the `else if`
# is the table's own text, kept so the two cannot drift.
diff_check() {
    # shellcheck disable=SC1075
    if git rev-parse --verify -q "${BASE:-origin/main}" >/dev/null; then git diff --check "${BASE:-origin/main}"; else if ! git diff --check HEAD^1 2>/dev/null; then git diff --check; fi; fi
}
