#!/usr/bin/env bats
# bats file_tags=deploy
# The prober fakes and the healthy/failure matrix (§1).
#
# The prober's fakes, fixture and helpers are in apps_health_lib.bash.
load ../helpers
load ./apps_health_lib

setup_file() { health_setup_file; }
setup() { health_setup; }

# --- the prober's own fakes --------------------------------------------------

# The fixture's whole claim, proved: without a bound port the ingress cases below
# would be proving the prober against a closed port twice.
@test "the ingress stand-in accepts connections on the file's loopback port" {
    for _ in $(seq 1 50); do
        port_accepts "$app_port" && return 0
        sleep 0.1
    done
    return 1
}

# --- 1. a healthy tenant passes silently ------------------------------------

@test "a healthy plan journals no failure" {
    case_probe healthy
    assert_equal "$(journal_field apps-health-failed '.reason')" ''
}

@test "the unit is asked of the tenant's own manager" {
    case_probe healthy
    assert grep -qF -- '--machine=apps@.host is-active demo.service' "$log/systemctl-calls"
}

@test "the plan's Quadlet name is asked about the .service unit it generates" {
    case_probe healthy
    assert grep -qF -- 'is-active demo.service' "$log/systemctl-calls"
}

@test "the base path is checked against Serve" {
    case_probe healthy
    assert grep -qF -- 'serve status --json' "$log/tailscale-calls"
}

@test "a healthy tick pings the tenant check green" {
    case_probe healthy
    ping_is '' '1 app(s) are serving'
}

# The prober judges and journals; it never acts on the platform or on the tenant,
# and it never touches the deploy check: one Healthchecks check answered by the
# host dead-man cannot carry a tenant verdict, and a `deploy_notify fail` from
# here would page a down/recover pair every five minutes for one broken app.
no_landed_record() { # <case>
    case_probe "$1"
    assert [ ! -e "$state/state.json" ]
}

no_pending_record() { # <case>
    case_probe "$1"
    assert [ ! -e "$state/pending.json" ]
}

no_denylist() { # <case>
    case_probe "$1"
    assert [ ! -e "$state/denylist.json" ]
}

no_reboot() { # <case>
    case_probe "$1"
    refute grep -q 'reboot' "$log/systemctl-calls"
}

pings_only_the_tenant_check() { # <case>
    case_probe "$1"
    [[ ! -s $log/curl-urls ]] || ! grep -qvF -- "$tenant_ping_url" "$log/curl-urls"
}

fails_the_probe() { # <case>
    case_probe "$1"
    expect_failure
}

journals_the_reason() { # <case>
    case_probe "$1"
    assert_equal "$(journal_field apps-health-failed '.reason')" "$(reason_for "$1")"
}

passes() { # <case>
    case_probe "$1"
    assert_equal "$rc" 0
}

for case in $fail_cases; do
    label=$(label_for "$case")
    register "$label fails the probe" fails_the_probe "$case"
    register "the failure is journaled as $(reason_for "$case")" journals_the_reason "$case"
    register "$label records no landed deployment" no_landed_record "$case"
    register "$label leaves no pending record" no_pending_record "$case"
    register "$label denylists nothing" no_denylist "$case"
    register "$label requests no reboot" no_reboot "$case"
    register "$label pings only the tenant check" pings_only_the_tenant_check "$case"
done

for case in $pass_cases; do
    label=$(label_for "$case")
    register "$label passes" passes "$case"
    register "$label records no landed deployment" no_landed_record "$case"
    register "$label leaves no pending record" no_pending_record "$case"
    register "$label denylists nothing" no_denylist "$case"
    register "$label requests no reboot" no_reboot "$case"
    register "$label pings only the tenant check" pings_only_the_tenant_check "$case"
done
