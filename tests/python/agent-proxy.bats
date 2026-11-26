#!/usr/bin/env bats
# bats file_tags=python
# The agent-proxy unit suite, run the way its CI area runs it.
#
#   bats tests/python/agent-proxy.bats
#
# The command is the group table's line verbatim, so the test fails for the same
# reason the group would, and unittest's own output is the failure text.
load ../helpers

@test "the agent-proxy unit tests pass" {
    run python3 -m unittest discover -s apps/agent_proxy/tests -t apps/agent_proxy
    assert_success
}
