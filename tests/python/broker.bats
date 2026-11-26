#!/usr/bin/env bats
# bats file_tags=python
# The broker application's own unit suite, run the way its check-all group runs it.
#
#   bats tests/python/broker.bats
#
# The command is the group table's line verbatim, so the test fails for the same
# reason the group would, and unittest's own output is the failure text.
load ../helpers

@test "the broker unit tests pass" {
    run python3 -m unittest discover -s apps/broker/tests -t apps/broker
    assert_success
}
