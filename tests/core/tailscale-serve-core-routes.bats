#!/usr/bin/env bats
# bats file_tags=core
# Serve's core routes exist on a host with no tenant plan: every fixed port still fronts its app.
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

@test "8443 still fronts OPDShelf" {
    core_run
    serves host:8443 / http://127.0.0.1:8083
}

@test "10000 still fronts Syncthing" {
    core_run
    serves host:10000 / http://127.0.0.1:8384
}

@test "8448 fronts Navidrome" {
    core_run
    serves host:8448 / http://127.0.0.1:4533
}
