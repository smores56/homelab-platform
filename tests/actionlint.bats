#!/usr/bin/env bats
# bats file_tags=actionlint
# The workflow linter, run the way its CI area runs it.
#
#   bats tests/actionlint.bats
#
# actionlint is a mise tool, not a host one, so a host without it reports a skip
# that names the reason instead of passing on an absent binary.
load helpers

@test "the workflows pass actionlint" {
    command -v actionlint >/dev/null 2>&1 ||
        skip "actionlint is not on PATH (mise installs it; CI runs this group)"
    run actionlint
    assert_success
}
