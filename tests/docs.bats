#!/usr/bin/env bats
# bats file_tags=docs
# The documentation reference check, run the way its check-all group runs it.
#
#   bats tests/docs.bats
#
# The command is the group table's line verbatim, so the test fails for the same
# reason the group would, and the checker's own output is the failure text.
load helpers

@test "every documentation reference resolves" {
    run python3 scripts/check-doc-refs.py
    assert_success
}
