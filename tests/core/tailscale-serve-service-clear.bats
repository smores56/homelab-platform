#!/usr/bin/env bats
# bats file_tags=core
# A Service no declaration makes is cleared whole, and only that Service.
#
# One file of the suite that was tests/core/tailscale-serve.bats, split so bats
# can run the sections as parallel files (a file is one job). The fake, the Serve
# state, the drivers and the case helpers are in
# tests/core/tailscale-serve_lib.bash.
#
#   bats tests/core/tailscale-serve-service-clear.bats
load ../helpers
load ./tailscale-serve_lib

setup_file() { ts_setup_file; }
setup() { ts_setup; }

# --- a Service no declaration makes is cleared -------------------------------
#
# The same decay in the other map, and the one the tailnet actually carried:
# `svc:agent-ui` was deleted from the tailnet (its Service and VIP are gone with
# the host Caddy), but its handler still answered
# `tcp://agent-ui.<tailnet>.ts.net:443` pointing at 127.0.0.1:9443, where nothing
# listens. A host port is retired by `off`; a whole Service is `clear`, and a
# handler no declaration makes must not survive a run.
stale_service_run() {
    reset_case
    jq '.Services["svc:agent-ui"] = {"Proxy": "http://127.0.0.1:9443"}' "$status" \
        >"$tmp/s" && mv "$tmp/s" "$status"
    drive
}

@test "a Service the script no longer declares does not fail the run" {
    stale_service_run
    assert_equal "$rc" 0
}

@test "a stale Service is cleared exactly once" {
    stale_service_run
    assert_equal "$(grep -cF -- 'serve clear svc:agent-ui' "$log" || true)" 1
}

@test "a run clears the one stale Service and nothing else" {
    stale_service_run
    assert_equal "$(grep -cE -- 'serve clear' "$log" || true)" 1
}

@test "the stale Service leaves the Serve config, so nothing answers its name" {
    stale_service_run
    if ! jq -e '.Services // {} | has("svc:agent-ui") | not' "$status" >/dev/null 2>&1; then
        jq -r '.Services // {} | keys | join(" ")' "$status" >&2 || true
        return 1
    fi
}

@test "clearing a stale Service leaves the declared ones in place" {
    stale_service_run
    assert_equal "$(service_served svc:opds:443)" 'http://127.0.0.1:8083'
}

# The index the reconcile reads is the declarations' index: a `--service=` block
# added to the script without its entry here would be cleared on the next run, and
# an entry with no declaration would pin a route nothing makes. Both are read out
# of the script rather than repeated, so this is the assertion that fails when a
# seventh Service is declared.
declared_services_of_script() {
    sed -n 's/^declared_services=(\(.*\))$/\1/p' "$script" |
        tr -s ' ' '\n' | grep -v '^$' | sort | paste -sd' ' -
}

@test "declared_services is readable" {
    stale_service_run
    [[ -n $(declared_services_of_script) ]]
}

@test "declared_services names exactly the Services the script declares" {
    stale_service_run
    assert_equal "$(grep -oE -- '--service=svc:[A-Za-z0-9._-]+' "$script" | sed 's/^--service=//' |
        sort -u | paste -sd' ' -)" "$(declared_services_of_script)"
}

@test "a Service the script declares is never cleared" {
    stale_service_run
    declared_service_re=$(tr ' ' '\n' <<<"$(declared_services_of_script)" | paste -sd'|' -)
    if grep -qE -- "serve clear ($declared_service_re)$" "$log"; then
        grep -E -- 'serve clear' "$log" >&2
        return 1
    fi
}

# A Service Tailscale refuses to clear is reported and stops the further prunes,
# like a port that will not go: the run fails rather than leaving the rest of the
# config half-reconciled in silence.
clear_fail_run() {
    reset_case
    jq '.Services["svc:agent-ui"] = {"Proxy": "http://127.0.0.1:9443"}' "$status" \
        >"$tmp/s" && mv "$tmp/s" "$status"
    clear_fail=1
    drive
}

@test "a Service Serve refuses to clear fails the run" {
    clear_fail_run
    [[ $rc -ne 0 ]]
}

@test "the failure names the Service it could not clear" {
    clear_fail_run
    if ! grep -qF -- 'could not clear the stale Service svc:agent-ui' "$tmp/stderr"; then
        cat "$tmp/stderr" >&2
        return 1
    fi
}

@test "a failed Service clear stops the further prunes" {
    clear_fail_run
    if grep -qE -- '--set-path=/apps/.* off$' "$log"; then
        grep -E -- ' off$' "$log" >&2
        return 1
    fi
}
