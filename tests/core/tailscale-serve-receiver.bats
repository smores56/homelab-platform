#!/usr/bin/env bats
# bats file_tags=core
# The deploy receiver's TCP forward is a core route, declared once, before the plan-dependent routes.
#
# One file of the suite that was tests/core/tailscale-serve.bats, split so bats
# can run the sections as parallel files (a file is one job). The fake, the Serve
# state, the drivers and the case helpers are in
# tests/core/tailscale-serve_lib.bash.
#
#   bats tests/core/tailscale-serve-receiver.bats
load ../helpers
load ./tailscale-serve_lib

setup_file() { ts_setup_file; }
setup() { ts_setup; }

# --- the deploy receiver's TCP forward is a core route -----------------------
#
# The CI notify job and the hourly poll are the only callers, and both must reach
# the receiver on a host whose tenant plan is broken: the forward is declared with
# the core routes, before anything that reads the plan, exactly once, and the
# `/apps/` prune never touches it.

@test "the receiver is forwarded on tcp/8484 to its loopback port" {
    core_run
    assert_equal "$(tcp_forward)" 127.0.0.1:8484
}

@test "the forward is declared exactly once" {
    core_run
    assert_equal \
        "$(grep -cF -- 'serve --bg --tcp=8484 tcp://127.0.0.1:8484' "$log" || true)" 1
}

@test "the forward is declared with the core routes, before the plan-dependent routes" {
    core_run
    forward_line=$(grep -nF -- '--tcp=8484' "$log" | cut -d: -f1 || true)
    wallpapers_line=$(grep -nF -- '--set-path=/wallpapers' "$log" | cut -d: -f1 || true)
    if [[ -z $forward_line || -z $wallpapers_line ]] || ((forward_line >= wallpapers_line)); then
        printf "forward at '%s', wallpapers at '%s'\n" "$forward_line" "$wallpapers_line" >&2
        return 1
    fi
}
