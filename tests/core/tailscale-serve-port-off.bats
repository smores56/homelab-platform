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
# reconcile exists to make safe.
declared_ports_of_script() {
    sed -n '/^declare -A core_routes=(/,/^)/p' "$script" |
        grep -oE '\[[0-9]+\]' | tr -dc '0-9\n' | paste -sd'|' -
}

@test "core_routes is readable" {
    stale_port_run
    [[ -n $(declared_ports_of_script) ]]
}

@test "a port core_routes still declares is never turned off" {
    stale_port_run
    declared_ports=$(declared_ports_of_script || true)
    if grep -qE -- "--https=($declared_ports) off$" "$log"; then
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

# The two host ports the public edge used before it proxied the Services (design
# #725) are exactly that case, and a box that still carries them must lose them:
# nothing has any reason to reach Immich or OPDShelf on the host's own address but
# the owner, who has 443 and 8443.
retired_ports_run() {
    reset_case
    jq '.Web["host:8446"] = {"Handlers": {"/": {"Proxy": "http://127.0.0.1:2283"}}}
        | .Web["host:8447"] = {"Handlers": {"/": {"Proxy": "http://127.0.0.1:8083"}}}' \
        "$status" >"$tmp/s" && mv "$tmp/s" "$status"
    drive
}

@test "the retired edge ports do not fail the run" {
    retired_ports_run
    assert_equal "$rc" 0
}

# One test per retired port, from the old suite's `for port in 8446 8447`.
check_retired_port_off_once() {
    retired_ports_run
    assert_equal "$(grep -cF -- "serve --https=$1 off" "$log" || true)" 1
}

for port in 8446 8447; do
    register "the retired edge port $port is turned off exactly once" check_retired_port_off_once "$port"
done

@test "neither retired edge port is left in the Serve config" {
    retired_ports_run
    if ! jq -e '.Web | (has("host:8446") or has("host:8447")) | not' "$status" >/dev/null 2>&1; then
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
