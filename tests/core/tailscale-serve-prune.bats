#!/usr/bin/env bats
# bats file_tags=core
# Stale routes are pruned: an app that left the plan loses its path and nothing else does.
#
# One file of the suite that was tests/core/tailscale-serve.bats, split so bats
# can run the sections as parallel files (a file is one job). The fake, the Serve
# state, the drivers and the case helpers are in
# tests/core/tailscale-serve_lib.bash.
#
#   bats tests/core/tailscale-serve-prune.bats
load ../helpers
load ./tailscale-serve_lib

setup_file() { ts_setup_file; }
setup() { ts_setup; }

# --- stale routes are pruned -------------------------------------------------

# The Serve state of a host that carried two app routes the plan no longer names.
prune_run() {
    reset_case
    jq '.Web["host:443"].Handlers["/apps/removed"] = {"Proxy": "http://127.0.0.1:21000"}
        | .Web["host:443"].Handlers["/apps/gamma"] = {"Proxy": "http://127.0.0.1:21555"}' "$status" >"$tmp/s" && mv "$tmp/s" "$status"
    plan_with "$(jq -cn --argjson a "$(app_entry alpha 21234 4001 1G internet)" '{alpha: $a}')" >"$plan"
    drive
}

@test "a plan with a removed app applies" {
    prune_run
    assert_equal "$rc" 0
}

@test "a route for an app that left the plan is removed" {
    prune_run
    if served host:443 | grep -q '^/apps/removed '; then
        served host:443 >&2
        return 1
    fi
}

@test "a route for an app that left the plan is pruned" {
    prune_run
    if served host:443 | grep -q '^/apps/gamma '; then
        served host:443 >&2
        return 1
    fi
}

@test "pruning leaves the core root route alone" {
    prune_run
    serves host:443 / http://127.0.0.1:2283
}

@test "pruning leaves the personal gateway path alone" {
    prune_run
    serves host:443 /apps/agent-local http://127.0.0.1:18001
}

@test "pruning leaves the wallpaper route alone" {
    prune_run
    assert_equal "$(static_served host:443 /wallpapers/)" "$wallpapers"
}

@test "pruning only removes /apps/ handlers" {
    prune_run
    if grep -E -- ' off$' "$log" | grep -qv -- '--set-path=/apps/'; then
        grep -E -- ' off$' "$log" >&2
        return 1
    fi
}
