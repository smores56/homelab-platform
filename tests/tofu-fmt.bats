#!/usr/bin/env bats
# bats file_tags=tofu
# The tofu formatting gate, run the way its check-all group runs it.
#
#   bats tests/tofu-fmt.bats
#
# `fmt -check` reads no providers, so this needs no plugin cache; tofu itself is
# a mise tool, so a host without it reports a skip that names the reason.
load helpers

@test "the tofu sources are canonically formatted" {
    command -v tofu >/dev/null 2>&1 ||
        skip "tofu is not on PATH (mise installs it; CI runs this group)"
    run tofu fmt -check -recursive tofu
    assert_success
}
