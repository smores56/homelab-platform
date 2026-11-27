#!/usr/bin/env bats
# bats file_tags=core
# The rest of the core apps get a Service each, the same shape as OPDShelf, with the host ports left as rollback.
#
# One file of the suite that was tests/core/tailscale-serve.bats, split so bats
# can run the sections as parallel files (a file is one job). The fake, the Serve
# state, the drivers and the case helpers are in
# tests/core/tailscale-serve_lib.bash.
#
#   bats tests/core/tailscale-serve-app-services.bats
load ../helpers
load ./tailscale-serve_lib

setup_file() { ts_setup_file; }
setup() { ts_setup; }

# --- the rest of the core apps get a Service each, the same shape ------------
#
# Immich, Navidrome, the two agent web UIs and the Syncthing GUI follow the
# catalogue off the per-port scheme: each declaration is `--https` against a
# Service of its own, so Tailscale terminates TLS for that name, and each is
# additive -- the host routes (443, 8448, 8444, 8445) stay declared above. The GUI
# is here through the loopback proxy in front of it (design #897, T1/T2): Serve
# forwards the client's Host unchanged, so `svc:sync` targets 8385, where Caddy
# rewrites the Host to the one the GUI trusts. T2 cleared the skip PATCH and retired
# the 10000 host route, so this name is the GUI's only way in.

@test "the Immich Service endpoint is declared exactly once, over https/443" {
    core_run
    assert_equal \
        "$(grep -cF -- 'serve --bg --service=svc:immich --https=443 http://127.0.0.1:2283' "$log" || true)" 1
}

@test "svc:immich advertises Immich on its own port, not a host port" {
    core_run
    assert_equal "$(service_served svc:immich:443)" 'http://127.0.0.1:2283'
}

@test "the Navidrome Service endpoint is declared exactly once, over https/443" {
    core_run
    assert_equal \
        "$(grep -cF -- 'serve --bg --service=svc:navidrome --https=443 http://127.0.0.1:4533' "$log" || true)" 1
}

@test "svc:navidrome advertises Navidrome on its own port, not a host port" {
    core_run
    assert_equal "$(service_served svc:navidrome:443)" 'http://127.0.0.1:4533'
}

@test "the personal web UI Service endpoint is declared exactly once, over https/443" {
    core_run
    assert_equal \
        "$(grep -cF -- 'serve --bg --service=svc:assistant --https=443 http://127.0.0.1:18006' "$log" || true)" 1
}

@test "svc:assistant advertises the personal UI on its own port, not a host port" {
    core_run
    assert_equal "$(service_served svc:assistant:443)" 'http://127.0.0.1:18006'
}

@test "the general web UI Service endpoint is declared exactly once, over https/443" {
    core_run
    assert_equal \
        "$(grep -cF -- 'serve --bg --service=svc:agent --https=443 http://127.0.0.1:18007' "$log" || true)" 1
}

@test "svc:agent advertises the general UI on its own port, not a host port" {
    core_run
    assert_equal "$(service_served svc:agent:443)" 'http://127.0.0.1:18007'
}

@test "the Syncthing GUI Service endpoint is declared exactly once, over https/443" {
    core_run
    assert_equal \
        "$(grep -cF -- 'serve --bg --service=svc:sync --https=443 http://127.0.0.1:8385' "$log" || true)" 1
}

@test "svc:sync advertises the Syncthing GUI on its own port, not a host port" {
    core_run
    assert_equal "$(service_served svc:sync:443)" 'http://127.0.0.1:8385'
}

# The terminal is the last Service declared: `fail()` aborts the script, so a
# terminal route that cannot be advertised must not cost any route after it.
@test "the zellij web Service endpoint is declared exactly once, over https/443" {
    core_run
    assert_equal \
        "$(grep -cF -- 'serve --bg --service=svc:terminal --https=443 http://127.0.0.1:8082' "$log" || true)" 1
}

@test "svc:terminal advertises zellij web on its own port, not a host port" {
    core_run
    assert_equal "$(service_served svc:terminal:443)" 'http://127.0.0.1:8082'
}

@test "svc:terminal is the last route declared, so a refused terminal costs no other route" {
    core_run
    terminal_line=$(grep -nF -- '--service=svc:terminal' "$log" | cut -d: -f1 | head -n1 || true)
    last_other_route=$(grep -nE -- 'serve --bg' "$log" | grep -vF -- 'svc:terminal' |
        cut -d: -f1 | sort -n | tail -n1 || true)
    if [[ -z $terminal_line || -z $last_other_route ]] || ((last_other_route >= terminal_line)); then
        printf 'terminal at %q, last other route at %q\n' "$terminal_line" "$last_other_route" >&2
        return 1
    fi
}

@test "every core Service is recorded under Services, not on a host port" {
    core_run
    app_services='["svc:immich", "svc:navidrome", "svc:assistant", "svc:agent", "svc:sync", "svc:terminal"]'
    if ! jq -e --argjson names "$app_services" \
        '[.Services // {} | keys[] | select(. | endswith(":443")) | rtrimstr(":443")] as $served
         | ($names - $served) | length == 0' "$status" >/dev/null 2>&1; then
        jq -r '.Services // {} | keys | join(" ")' "$status" >&2 || true
        return 1
    fi
}

@test "no app Service declaration opens a host port" {
    core_run
    assert_equal "$(jq -r '.Web | keys | join(" ")' "$status" 2>/dev/null)" \
        'host:443 host:8443 host:8444 host:8445 host:8448'
}

@test "host:443 still fronts Immich as the rollback" {
    core_run
    serves host:443 / http://127.0.0.1:2283
}

@test "host:8448 still fronts Navidrome as the rollback" {
    core_run
    serves host:8448 / http://127.0.0.1:4533
}

@test "host:8444 still fronts the personal UI as the rollback" {
    core_run
    serves host:8444 / http://127.0.0.1:18006
}

@test "host:8445 still fronts the general UI as the rollback" {
    core_run
    serves host:8445 / http://127.0.0.1:18007
}

@test "the app Services are declared after the catalogue and before the Serve status read" {
    core_run
    app_service_lines=$(grep -nE -- '--service=svc:(immich|navidrome|assistant|agent|sync) ' "$log" | cut -d: -f1 || true)
    opds_line=$(grep -nF -- '--service=svc:opds' "$log" | cut -d: -f1 || true)
    status_line=$(grep -nF -- 'serve status --json' "$log" | cut -d: -f1 || true)
    if [[ -z $app_service_lines || -z $opds_line || -z $status_line ]] ||
        ((opds_line >= $(head -n1 <<<"$app_service_lines") ||
            $(tail -n1 <<<"$app_service_lines") >= status_line)); then
        printf "apps at '%s', opds at '%s', status at '%s'\n" \
            "$(tr '\n' ' ' <<<"$app_service_lines")" "$opds_line" "$status_line" >&2
        return 1
    fi
}
