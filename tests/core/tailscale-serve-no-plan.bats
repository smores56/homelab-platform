#!/usr/bin/env bats
# bats file_tags=core
# A missing plan prunes every app route and keeps the core ingress.
#
# One file of the suite that was tests/core/tailscale-serve.bats, split so bats
# can run the sections as parallel files (a file is one job). The fake, the Serve
# state, the drivers and the case helpers are in
# tests/core/tailscale-serve_lib.bash.
#
#   bats tests/core/tailscale-serve-no-plan.bats
load ../helpers
load ./tailscale-serve_lib

setup_file() { ts_setup_file; }
setup() { ts_setup; }

# --- a missing plan prunes every app route -----------------------------------

no_plan_prune_run() {
    reset_case
    jq '.Web["host:443"].Handlers["/apps/alpha"] = {"Proxy": "http://127.0.0.1:21234"}' "$status" >"$tmp/s" && mv "$tmp/s" "$status"
    drive
}

@test "no plan is not an error" {
    no_plan_prune_run
    assert_equal "$rc" 0
}

@test "no plan removes every app route" {
    no_plan_prune_run
    if served host:443 | grep -E '^/apps/' | grep -qvE '^/apps/agent-(local|general) '; then
        served host:443 >&2
        return 1
    fi
}

@test "no plan keeps the core agent path" {
    no_plan_prune_run
    serves host:443 /apps/agent-local http://127.0.0.1:18001
}

@test "no plan keeps the core root route" {
    no_plan_prune_run
    serves host:443 / http://127.0.0.1:2283
}
