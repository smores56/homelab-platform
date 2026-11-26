#!/usr/bin/env bats
# bats file_tags=python
# The agent-facade unit suite, run the way its CI area runs it.
#
#   bats tests/python/agent-facade.bats
#
# Its top-level dir is `apps`, not the package, because the suites import each
# other's support modules through `apps.agent_facade`. The command is the group
# table's line verbatim, so the test fails for the same reason the group would.
load ../helpers

@test "the agent-facade unit tests pass" {
    run python3 -m unittest discover -s apps/agent_facade/tests -t apps
    assert_success
}
