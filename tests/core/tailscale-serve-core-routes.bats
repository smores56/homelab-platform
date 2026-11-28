#!/usr/bin/env bats
# bats file_tags=core
# Serve's core routes exist on a host with no tenant plan: 443 fronts Immich, and
# no application keeps a per-port route of its own.
#
# One file of the suite that was tests/core/tailscale-serve.bats, split so bats
# can run the sections as parallel files (a file is one job). The fake, the Serve
# state, the drivers and the case helpers are in
# tests/core/tailscale-serve_lib.bash.
#
#   bats tests/core/tailscale-serve-core-routes.bats
load ../helpers
load ./tailscale-serve_lib

setup_file() { ts_setup_file; }
setup() { ts_setup; }

# --- core routes always exist -------------------------------------------------

@test "a host with no tenant plan still declares the core routes" {
    core_run
    assert_equal "$rc" 0
}

@test "443 still fronts Immich" {
    core_run
    serves host:443 / http://127.0.0.1:2283
}

# The per-port routes the applications left when the `svc:` names became the
# interface served the owner alone; task #1030 retired them, so the declaration
# holds 443 and nothing else. Read out of the script, because the count is the
# claim: an entry someone adds back to core_routes fails here.
@test "443 is the only host port the script declares" {
    core_run
    assert_equal "$(declared_ports | paste -sd' ' -)" 443
}

@test "no route is declared on a port other than 443" {
    core_run
    assert_equal "$(grep -oE -- '--https=[0-9]+' "$log" | sort -u | tr '\n' ' ')" '--https=443 '
}

@test "the Serve state carries one host port after a run" {
    core_run
    assert_equal "$(jq -r '.Web | keys | join(" ")' "$status")" 'host:443'
}
