#!/usr/bin/env bats
# bats file_tags=core
# Serve status is a nicety, not a precondition for core ingress.
#
# One file of the suite that was tests/core/tailscale-serve.bats, split so bats
# can run the sections as parallel files (a file is one job). The fake, the Serve
# state, the drivers and the case helpers are in
# tests/core/tailscale-serve_lib.bash.
#
#   bats tests/core/tailscale-serve-status.bats
load ../helpers
load ./tailscale-serve_lib

setup_file() { ts_setup_file; }
setup() { ts_setup; }

# --- Serve status is a nicety, not a precondition for core ingress ----------

status_fail_run() {
    reset_case
    plan_with "$(jq -cn --argjson a "$(app_entry alpha 21234 4001 1G internet)" '{alpha: $a}')" >"$plan"
    status_fail=1
    drive
}

@test "an unreadable status still applies the plan" {
    status_fail_run
    assert_equal "$rc" 0
}

@test "the core routes, the two core paths, the wallpaper route and the app route are declared without status" {
    status_fail_run
    if [[ $(grep -c -- '--bg --https=' "$log") != $(($(core_route_count) + 4)) ]]; then
        cat "$log" >&2
        return 1
    fi
}
