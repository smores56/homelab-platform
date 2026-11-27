#!/usr/bin/env bats
# bats file_tags=core
# The two agent gateways own a fixed path each on 443, and each UI its own HTTPS port.
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

@test "the personal UI gets its own HTTPS port" {
    core_run
    serves host:8444 / http://127.0.0.1:18006
}

@test "the general UI gets its own HTTPS port" {
    core_run
    serves host:8445 / http://127.0.0.1:18007
}

@test "each agent gateway is declared exactly once" {
    core_run
    assert_equal "$(grep -cE -- '--set-path=/apps/agent-(local|general) ' "$log" || true)" 2
}

@test "the hosted proxy is never a Serve route" {
    core_run
    ! grep -qF -- 'http://127.0.0.1:18003' "$log"
}
