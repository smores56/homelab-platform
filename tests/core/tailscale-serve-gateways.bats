#!/usr/bin/env bats
# bats file_tags=core
# The two agent gateways own a fixed path each on 443; the browser UIs behind them
# answer on their Service names, not on a port of the host's.
#
# One file of the suite that was tests/core/tailscale-serve.bats, split so bats
# can run the sections as parallel files (a file is one job). The fake, the Serve
# state, the drivers and the case helpers are in
# tests/core/tailscale-serve_lib.bash.
#
#   bats tests/core/tailscale-serve-gateways.bats
load ../helpers
load ./tailscale-serve_lib

setup_file() { ts_setup_file; }
setup() { ts_setup; }

# --- the two agent gateways own a fixed path each on 443 ----------------------

@test "the personal gateway gets /apps/agent-local" {
    core_run
    serves host:443 /apps/agent-local http://127.0.0.1:18001
}

@test "the general gateway gets /apps/agent-general" {
    core_run
    serves host:443 /apps/agent-general http://127.0.0.1:18002
}

# The UIs cannot be served under a path on 443 (a web UI emits absolute asset URLs,
# which would land on the tailnet root, where Immich is), so each answers on its own
# Service name instead. Neither gets a port on the host: task #1030 retired those
# routes, and `svc:assistant`/`svc:agent` are the only way in.
@test "neither web UI gets a port on the host" {
    core_run
    assert_equal "$(grep -oE -- '--https=[0-9]+' "$log" | sort -u | tr '\n' ' ')" '--https=443 '
}

@test "the personal workspace's only route is its Service" {
    core_run
    assert_equal "$(service_served svc:assistant:443)" 'http://127.0.0.1:18008'
}

@test "the general UI's only route is its Service" {
    core_run
    assert_equal "$(service_served svc:agent:443)" 'http://127.0.0.1:18007'
}

@test "each agent gateway is declared exactly once" {
    core_run
    assert_equal "$(grep -cE -- '--set-path=/apps/agent-(local|general) ' "$log" || true)" 2
}

@test "the hosted proxy is never a Serve route" {
    core_run
    ! grep -qF -- 'http://127.0.0.1:18003' "$log"
}
