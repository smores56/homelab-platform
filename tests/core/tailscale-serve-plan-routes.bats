#!/usr/bin/env bats
# bats file_tags=core
# One path per app: a valid plan applies one /apps/<name> route per app on 443.
#
# One file of the suite that was tests/core/tailscale-serve.bats, split so bats
# can run the sections as parallel files (a file is one job). The fake, the Serve
# state, the drivers and the case helpers are in
# tests/core/tailscale-serve_lib.bash.
#
#   bats tests/core/tailscale-serve-plan-routes.bats
load ../helpers
load ./tailscale-serve_lib

setup_file() { ts_setup_file; }
setup() { ts_setup; }

# --- one path per app --------------------------------------------------------

# A valid plan of two apps, alpha and beta.
plan_run() {
    reset_case
    plan_with "$(jq -cn --argjson a "$(app_entry alpha 21234 4001 1G internet)" \
        --argjson b "$(app_entry beta 22999 4002 1G internet)" '{alpha: $a, beta: $b}')" >"$plan"
    drive
}

@test "a valid plan applies" {
    plan_run
    assert_equal "$rc" 0
}

@test "alpha gets its path on 443" {
    plan_run
    serves host:443 /apps/alpha http://127.0.0.1:21234
}

@test "beta gets its path on 443" {
    plan_run
    serves host:443 /apps/beta http://127.0.0.1:22999
}

@test "the declaration names the https port, path and loopback target" {
    plan_run
    if ! grep -q -- '--https=443 --set-path=/apps/alpha http://127.0.0.1:21234' "$log"; then
        cat "$log" >&2
        return 1
    fi
}
