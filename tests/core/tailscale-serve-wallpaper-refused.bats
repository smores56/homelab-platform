#!/usr/bin/env bats
# bats file_tags=core
# An unpublishable wallpaper route fails the run, and the failure names the directory.
#
# One file of the suite that was tests/core/tailscale-serve.bats, split so bats
# can run the sections as parallel files (a file is one job). The fake, the Serve
# state, the drivers and the case helpers are in
# tests/core/tailscale-serve_lib.bash.
#
#   bats tests/core/tailscale-serve-wallpaper-refused.bats
load ../helpers
load ./tailscale-serve_lib

setup_file() { ts_setup_file; }
setup() { ts_setup; }

# --- an unpublishable wallpaper route fails the run --------------------------

path_fail_run() {
    reset_case
    path_fail=1
    drive
}

@test "Serve refusing the wallpaper directory fails the run" {
    path_fail_run
    [[ $rc -ne 0 ]]
}

@test "the failure names the directory it could not publish" {
    path_fail_run
    if ! grep -qF -- 'could not serve' "$tmp/stderr"; then
        cat "$tmp/stderr" >&2
        return 1
    fi
}

wallpapers_missing_run() {
    reset_case
    wallpapers_dir=$tmp/absent
    drive
}

@test "a missing wallpaper directory fails the run" {
    wallpapers_missing_run
    [[ $rc -ne 0 ]]
}

@test "a missing wallpaper directory still leaves the core routes declared" {
    wallpapers_missing_run
    if [[ $(grep -c -- '--bg --https=' "$log") != $(($(core_route_count) + 2)) ]]; then
        cat "$log" >&2
        return 1
    fi
}
