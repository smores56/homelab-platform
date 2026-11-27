#!/usr/bin/env bats
# bats file_tags=core
# The wallpaper library is static files under /wallpapers, not a listener.
#
# One file of the suite that was tests/core/tailscale-serve.bats, split so bats
# can run the sections as parallel files (a file is one job). The fake, the Serve
# state, the drivers and the case helpers are in
# tests/core/tailscale-serve_lib.bash.
#
#   bats tests/core/tailscale-serve-wallpapers.bats
load ../helpers
load ./tailscale-serve_lib

setup_file() { ts_setup_file; }
setup() { ts_setup; }

# --- the wallpaper library is static files, not a listener --------------------

@test "a host with no tenant plan still declares the wallpaper route" {
    core_run
    assert_equal "$rc" 0
}

@test "the wallpaper library is published from its directory, under /wallpapers/" {
    core_run
    assert_equal "$(static_served host:443 /wallpapers/)" "$wallpapers"
}

@test "the wallpaper handler carries no loopback target" {
    core_run
    assert_equal "$(jq -r '.Web["host:443"].Handlers["/wallpapers/"].Proxy // empty' "$status")" ''
}

@test "the declaration is 443, /wallpapers and an absolute path" {
    core_run
    if ! grep -qF -- "--bg --https=443 --set-path=/wallpapers $wallpapers" "$log"; then
        cat "$log" >&2
        return 1
    fi
}
