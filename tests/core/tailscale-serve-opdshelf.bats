#!/usr/bin/env bats
# bats file_tags=core
# OPDShelf is the first application off the per-port scheme: a Service of its own, not a port on the host.
#
# One file of the suite that was tests/core/tailscale-serve.bats, split so bats
# can run the sections as parallel files (a file is one job). The fake, the Serve
# state, the drivers and the case helpers are in
# tests/core/tailscale-serve_lib.bash.
#
#   bats tests/core/tailscale-serve-opdshelf.bats
load ../helpers
load ./tailscale-serve_lib

setup_file() { ts_setup_file; }
setup() { ts_setup; }

# --- OPDShelf is the first application off the per-port scheme ---------------
#
# A Service is the application's own name rather than a port on the host's, and
# Tailscale terminates TLS for it and issues the certificate for that name, so
# this is an `--https` declaration to the Service and not a handler on the host.
# It is a Service, though, so it must never land in `Web`: `host:443` already
# fronts Immich, and a service declaration recorded as a host handler would
# replace it. The 8443 host route stays declared above, as the rollback.

@test "the OPDShelf Service endpoint is declared exactly once, over https/443" {
    core_run
    assert_equal \
        "$(grep -cF -- 'serve --bg --service=svc:opds --https=443 http://127.0.0.1:8083' "$log" || true)" 1
}

@test "svc:opds advertises OPDShelf on its own port, not a host port" {
    core_run
    assert_equal "$(service_served svc:opds:443)" 'http://127.0.0.1:8083'
}

@test "the first Service is declared after every host route" {
    core_run
    opds_line=$(grep -nF -- '--service=svc:opds' "$log" | cut -d: -f1 || true)
    wallpapers_line=$(grep -nF -- '--set-path=/wallpapers' "$log" | cut -d: -f1 || true)
    if [[ -z $opds_line || -z $wallpapers_line ]] || ((opds_line <= wallpapers_line)); then
        printf "opds at '%s', wallpapers at '%s'\n" "$opds_line" "$wallpapers_line" >&2
        return 1
    fi
}

@test "the OPDShelf Service is declared before the Serve status read" {
    core_run
    opds_line=$(grep -nF -- '--service=svc:opds' "$log" | cut -d: -f1 || true)
    status_line=$(grep -nF -- 'serve status --json' "$log" | cut -d: -f1 || true)
    if [[ -z $opds_line || -z $status_line ]] || ((opds_line >= status_line)); then
        printf "opds at '%s', status at '%s'\n" "$opds_line" "$status_line" >&2
        return 1
    fi
}

@test "host:443 still fronts Immich after a Service declaration" {
    core_run
    assert_equal "$(jq -r '.Web["host:443"].Handlers["/"].Proxy // empty' "$status")" 'http://127.0.0.1:2283'
}

@test "no OPDShelf handler is left on the host 443" {
    core_run
    if ! jq -e '[.Web["host:443"].Handlers[] | .Proxy // empty | select(. == "http://127.0.0.1:8083")] | length == 0' \
        "$status" >/dev/null; then
        served host:443 >&2
        return 1
    fi
}

@test "a Service declaration leaves the host 443 route alone" {
    core_run
    assert_equal "$(jq -r '.TCP["443"].HTTPS // empty' "$status")" 'true'
}
