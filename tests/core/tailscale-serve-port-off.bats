#!/usr/bin/env bats
# bats file_tags=core
# A host port that left core_routes is turned off, and only that port.
#
# One file of the suite that was tests/core/tailscale-serve.bats, split so bats
# can run the sections as parallel files (a file is one job). The fake, the Serve
# state, the drivers and the case helpers are in
# tests/core/tailscale-serve_lib.bash.
#
#   bats tests/core/tailscale-serve-port-off.bats
load ../helpers
load ./tailscale-serve_lib

setup_file() { ts_setup_file; }
setup() { ts_setup; }

# --- a host port that left core_routes is turned off -------------------------
#
# The script is declarative for the routes it declares, but tailscaled's state is
# not: a handler whose declaration is gone keeps answering until something turns
# it off. So a Web port nobody declares is retired on the next run, while every
# port still in core_routes, 443 and the per-app Services are left alone.

# A host that still answers one Web port the script no longer declares.
stale_port_run() {
    reset_case
    jq '.Web["host:9999"] = {"Handlers": {"/": {"Proxy": "http://127.0.0.1:2283"}}}' "$status" \
        >"$tmp/s" && mv "$tmp/s" "$status"
    drive
}

@test "a port the script no longer declares does not fail the run" {
    stale_port_run
    assert_equal "$rc" 0
}

@test "a stale https port is turned off exactly once" {
    stale_port_run
    assert_equal "$(grep -cF -- 'serve --https=9999 off' "$log" || true)" 1
}

@test "the stale port leaves the Serve config, so nothing answers it" {
    stale_port_run
    if ! jq -e '.Web | has("host:9999") | not' "$status" >/dev/null 2>&1; then
        jq -r '.Web | keys | join(" ")' "$status" >&2 || true
        return 1
    fi
}

# The declared ports are read out of the script rather than repeated here, so the
# assertion keeps up when an entry leaves core_routes -- which is the edit this
# reconcile exists to make safe, and the one task #1030 made.
@test "core_routes is readable" {
    stale_port_run
    [[ -n $(declared_ports) ]]
}

@test "a port core_routes still declares is never turned off" {
    stale_port_run
    declared=$(declared_ports | paste -sd'|' - || true)
    if grep -qE -- "--https=($declared) off$" "$log"; then
        grep -E -- ' off$' "$log" >&2
        return 1
    fi
}

@test "443 is never turned off" {
    stale_port_run
    if grep -qE -- '--https=443 off$' "$log"; then
        grep -E -- ' off$' "$log" >&2
        return 1
    fi
}

@test "the reconcile never declares an inbound forward" {
    stale_port_run
    refute grep -qF -- '--tcp=' "$log"
}

@test "the reconcile leaves the Service endpoints in place" {
    stale_port_run
    assert_equal "$(service_served svc:opds:443)" 'http://127.0.0.1:8083'
}

@test "the reconcile turns off Web ports only" {
    stale_port_run
    if grep -E -- ' off$' "$log" | grep -qE -- '(--tcp=|--service=)'; then
        grep -E -- ' off$' "$log" >&2
        return 1
    fi
}

# The host ports the fleet no longer declares are exactly that case, and a box that
# still carries them must lose them: the two the public edge used before it proxied
# the Services (design #725), and the per-port routes the core applications left
# when their `svc:` names became the interface (task #1030). Only 443 keeps a
# handler, because it is the host's own name and not one application's.
retired_ports=(8446 8447 8448 8445 8444 8443)

retired_ports_run() {
    reset_case
    jq '.Web["host:8446"] = {"Handlers": {"/": {"Proxy": "http://127.0.0.1:2283"}}}
        | .Web["host:8447"] = {"Handlers": {"/": {"Proxy": "http://127.0.0.1:8083"}}}
        | .Web["host:8448"] = {"Handlers": {"/": {"Proxy": "http://127.0.0.1:4533"}}}
        | .Web["host:8445"] = {"Handlers": {"/": {"Proxy": "http://127.0.0.1:18007"}}}
        | .Web["host:8444"] = {"Handlers": {"/": {"Proxy": "http://127.0.0.1:18008"}}}
        | .Web["host:8443"] = {"Handlers": {"/": {"Proxy": "http://127.0.0.1:8083"}}}' \
        "$status" >"$tmp/s" && mv "$tmp/s" "$status"
    drive
}

@test "the retired ports do not fail the run" {
    retired_ports_run
    assert_equal "$rc" 0
}

# One test per retired port, from the old suite's `for port in 8446 8447`.
check_retired_port_off_once() {
    retired_ports_run
    assert_equal "$(grep -cF -- "serve --https=$1 off" "$log" || true)" 1
}

for port in "${retired_ports[@]}"; do
    register "the retired port $port is turned off exactly once" check_retired_port_off_once "$port"
done

@test "no retired port is left in the Serve config" {
    retired_ports_run
    left=$(jq -r '.Web | keys[] | select(test("^host:844[3-8]$"))' "$status" 2>/dev/null || true)
    if [[ -n $left ]]; then
        jq -r '.Web | keys | join(" ")' "$status" >&2 || true
        return 1
    fi
}

# A port Tailscale refuses to turn off is reported and stops the prunes, like a
# stale `/apps/` route that will not go: the run fails rather than leaving the
# rest of the config half-reconciled without saying so.
off_fail_run() {
    reset_case
    jq '.Web["host:9999"] = {"Handlers": {"/": {"Proxy": "http://127.0.0.1:2283"}}}' "$status" \
        >"$tmp/s" && mv "$tmp/s" "$status"
    off_fail=1
    drive
}

@test "a port Serve refuses to turn off fails the run" {
    off_fail_run
    [[ $rc -ne 0 ]]
}

@test "the failure names the port it could not retire" {
    off_fail_run
    if ! grep -qF -- 'could not turn off the stale route https/9999' "$tmp/stderr"; then
        cat "$tmp/stderr" >&2
        return 1
    fi
}

@test "a failed port removal stops the further prunes" {
    off_fail_run
    if grep -qE -- '--set-path=/apps/.* off$' "$log"; then
        grep -E -- ' off$' "$log" >&2
        return 1
    fi
}
