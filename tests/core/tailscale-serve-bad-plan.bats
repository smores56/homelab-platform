#!/usr/bin/env bats
# bats file_tags=core
# Malformed plans fail closed: a rejected plan applies nothing and leaves the core routes.
#
# One file of the suite that was tests/core/tailscale-serve.bats, split so bats
# can run the sections as parallel files (a file is one job). The fake, the Serve
# state, the drivers and the case helpers are in
# tests/core/tailscale-serve_lib.bash.
#
#   bats tests/core/tailscale-serve-bad-plan.bats
load ../helpers
load ./tailscale-serve_lib

setup_file() { ts_setup_file; }
setup() { ts_setup; }

# --- malformed plans fail closed ---------------------------------------------

reject_run() { # plan body
    reset_case
    printf '%s\n' "$1" >"$plan"
    drive
}

@test "a non-object plan is rejected" {
    reject_run '[]'
    [[ $rc -ne 0 ]]
}

@test "a plan whose base path is not /apps/<name> is rejected" {
    reject_run '{"apps": {"alpha": {"basePath": "/elsewhere", "loopbackPort": 21234, "projectId": 4001, "quota": "1G"}}}'
    [[ $rc -ne 0 ]]
}

@test "a plan whose path disagrees with its name is rejected" {
    reject_run '{"apps": {"alpha": {"basePath": "/apps/beta", "loopbackPort": 21234, "projectId": 4001, "quota": "1G"}}}'
    [[ $rc -ne 0 ]]
}

@test "a loopback port outside the tenant range is rejected" {
    reject_run '{"apps": {"alpha": {"basePath": "/apps/alpha", "loopbackPort": 2283, "projectId": 4001, "quota": "1G"}}}'
    [[ $rc -ne 0 ]]
}

@test "a non-numeric loopback port is rejected" {
    reject_run '{"apps": {"alpha": {"basePath": "/apps/alpha", "loopbackPort": "21234", "projectId": 4001, "quota": "1G"}}}'
    [[ $rc -ne 0 ]]
}

@test "a path traversal in the app name is rejected" {
    reject_run '{"apps": {"../etc": {"basePath": "/apps/../etc", "loopbackPort": 21234, "projectId": 4001, "quota": "1G"}}}'
    [[ $rc -ne 0 ]]
}

@test "an app entry that is not an object is rejected" {
    reject_run '{"apps": {"alpha": "x"}}'
    [[ $rc -ne 0 ]]
}

# A tenant app that claims a core path would be declared by two loops; the whole
# plan is refused rather than letting the last writer win.
core_claim_run() {
    reset_case
    plan_with "$(jq -cn --argjson a "$(app_entry agent-local 21234 4001 1G internet)" \
        --argjson b "$(app_entry alpha 21235 4002 1G internet)" '{"agent-local": $a, alpha: $b}')" >"$plan"
    drive
}

@test "a plan that claims a core path is rejected" {
    core_claim_run
    [[ $rc -ne 0 ]]
}

@test "the rejection names the core path" {
    core_claim_run
    if ! grep -qF -- 'which a core route owns' "$tmp/stderr"; then
        cat "$tmp/stderr" >&2
        return 1
    fi
}

@test "a plan that claims a core path applies none of its routes" {
    core_claim_run
    if served host:443 | grep -qx '/apps/alpha http://127.0.0.1:21235'; then
        served host:443 >&2
        return 1
    fi
}

@test "the refused plan leaves the core path alone" {
    core_claim_run
    serves host:443 /apps/agent-local http://127.0.0.1:18001
}

invalid_json_run() {
    reset_case
    printf 'not json\n' >"$plan"
    drive
}

@test "invalid JSON is rejected" {
    invalid_json_run
    [[ $rc -ne 0 ]]
}

# A rejected plan must still leave the core applications and the wallpapers
# route reachable, and must change no app route.
@test "a rejected plan changes no app route" {
    invalid_json_run
    tenant_traffic=$(grep -E -- '(--set-path=/apps/| off)' "$log" | grep -vE -- '--set-path=/apps/agent-(local|general) ' || true)
    if [[ -n $tenant_traffic ]]; then
        printf '%s\n' "$tenant_traffic" >&2
        return 1
    fi
}

@test "a rejected plan still declares the core routes, the two core paths and the wallpapers route" {
    invalid_json_run
    if [[ $(grep -c -- '--bg --https=' "$log") != $(($(core_route_count) + 3)) ]]; then
        cat "$log" >&2
        return 1
    fi
}

@test "a rejected plan declares no inbound forward" {
    invalid_json_run
    if grep -qF -- '--tcp=' "$log"; then
        cat "$log" >&2
        return 1
    fi
}

# The consequence of being last, on the case that matters: the tenant routes and
# the prune have already run, so a Service the tailnet refuses costs the terminal.
refused_terminal_run() {
    reset_case
    plan_with "$(jq -cn --argjson a "$(app_entry alpha 21234 4001 1G internet)" '{alpha: $a}')" >"$plan"
    service_name_fail=svc:terminal
    drive
}

@test "a refused terminal Service fails the run" {
    refused_terminal_run
    assert_equal "$rc" 1
}

@test "a refused terminal still leaves the tenant route declared" {
    refused_terminal_run
    serves host:443 /apps/alpha http://127.0.0.1:21234
}

@test "a refused terminal advertises nothing" {
    refused_terminal_run
    if [[ -n $(service_served svc:terminal:443) ]]; then
        service_served svc:terminal:443 >&2
        return 1
    fi
}
