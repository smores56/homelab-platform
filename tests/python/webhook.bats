#!/usr/bin/env bats
# bats file_tags=python
# The webhook application's own unit suite, run the way its CI area runs it.
#
#   bats tests/python/webhook.bats
#
# The command is the group table's line verbatim, so the test fails for the same
# reason the group would, and unittest's own output is the failure text.
load ../helpers

@test "the webhook unit tests pass" {
    run python3 -m unittest discover -s apps/webhook/tests -t apps/webhook
    assert_success
}
