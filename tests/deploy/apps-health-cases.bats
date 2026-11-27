#!/usr/bin/env bats
# bats file_tags=deploy
# The failure, in-flight, no-plan and unstaged-check cases (§2-§9).
#
# The prober's fakes, fixture and helpers are in apps_health_lib.bash.
load ../helpers
load ./apps_health_lib

setup_file() { health_setup_file; }
setup() { health_setup; }

# --- 2. an app whose unit is not active -------------------------------------

@test "the journal names the app" {
    case_probe tenant-unit-inactive
    assert_equal "$(journal_field apps-health-failed '.app')" demo
}

@test "the journal names the unit" {
    case_probe tenant-unit-inactive
    assert_equal "$(journal_field apps-health-failed '.unit')" demo.service
}

@test "the unit's own stderr names the reason too" {
    case_probe tenant-unit-inactive
    assert_contains "$out" 'not serving: tenant-unit-inactive:demo'
}

@test "a failure reports the reason to the tenant check in the same tick" {
    case_probe tenant-unit-inactive
    ping_is /fail 'not serving: tenant-unit-inactive:demo'
}

# --- 3. a plan row that cannot be probed ------------------------------------

@test "the unreadable row is journaled with its app" {
    case_probe plan-row-unreadable
    assert_equal "$(journal_field apps-health-failed '.app')" demo
}

# --- 6. an apps apply in flight is not a fault ------------------------------

# A tick inside the apply window must say nothing rather than page on a deploy
# that succeeds.
@test "an apply in flight journals no failure" {
    case_probe apply-in-flight
    assert_equal "$(journal_field apps-health-failed '.reason')" ''
}

@test "an apply in flight probes no unit" {
    case_probe apply-in-flight
    assert [ ! -s "$log/systemctl-calls" ]
}

@test "an apply in flight keeps the tenant check green" {
    case_probe apply-in-flight
    ping_is '' 'apps apply in flight; nothing was probed'
}

# An apply that begins after the run's first look is the same window: the record
# the prober read for was not there yet, and the revision it is now halfway
# through is the one this tick would call broken. Reporting it would put a false
# line on the tenant's only signal for every deploy that overlaps a tick.
@test "the mid-probe apply is seen after the probe started" {
    case_probe apply-mid-probe
    assert grep -qF -- 'is-active demo.service' "$log/systemctl-calls"
}

@test "an apply that starts mid-probe journals no failure" {
    case_probe apply-mid-probe
    assert_equal "$(journal_field apps-health-failed '.reason')" ''
}

@test "an apply that starts mid-probe keeps the tenant check green" {
    case_probe apply-mid-probe
    ping_is '' 'apps apply in flight; nothing was reported'
}

# --- 7. no plan is a host with no tenant -----------------------------------

# The prober runs from the first boot, before the first apps apply installs a
# plan: failing here would name every healthy host a host with a broken tenant.
@test "no plan still pings the tenant check green" {
    case_probe no-plan
    ping_is '' 'no tenant plan'
}

@test "no plan probes no unit" {
    case_probe no-plan
    assert [ ! -s "$log/systemctl-calls" ]
}

# --- 8. one run journals one failure --------------------------------------

# Two broken apps are one outage, not two: the run stops at the first failure, so
# the journal gets a single line naming the app that came first in the plan.
two_inactive_apps() {
    : >"$STUB_SYSTEMCTL_USER_ACTIVE"
    jq -nc --argjson port "$app_port" \
        '{version:1,apps:{alpha:{basePath:"/apps/alpha",containerPort:8080,loopbackPort:$port},
          beta:{basePath:"/apps/beta",containerPort:8081,loopbackPort:$port}}}' >"$APPS_PLAN"
    probe
}

@test "a plan with two inactive apps fails the probe" {
    two_inactive_apps
    expect_failure
}

@test "a run with two inactive apps journals one failure" {
    two_inactive_apps
    assert_equal "$(grep -c 'apps-health-failed' "$state/journal.jsonl")" 1
}

@test "the first failing app decides the reason" {
    two_inactive_apps
    assert_equal "$(journal_field apps-health-failed '.reason')" tenant-unit-inactive:alpha
}

# --- 9. an unstaged check is silent, not a failure -------------------------
# The URL is an operator step: until it is in the decrypted file the prober has
# nothing to ping, and the tenant verdict must still be journaled normally.
no_apps_ping_url() {
    printf 'restic-ping-url: https://hc.invalid/ping/restic\n' >"$APPS_HEALTH_SECRET"
}

nothing_pinged() {
    assert_equal "$(wc -l <"$log/curl-urls" | tr -d ' ')" 0
}

@test "a missing apps-ping-url key does not fail the probe" {
    no_apps_ping_url
    probe
    assert_equal "$rc" 0
}

@test "a missing apps-ping-url key pings nothing" {
    no_apps_ping_url
    probe
    nothing_pinged
}

@test "a missing apps-ping-url key still fails a broken tenant" {
    no_apps_ping_url
    : >"$STUB_SYSTEMCTL_USER_ACTIVE"
    probe
    expect_failure
}

@test "a missing apps-ping-url key still journals the reason" {
    no_apps_ping_url
    : >"$STUB_SYSTEMCTL_USER_ACTIVE"
    probe
    assert_equal "$(journal_field apps-health-failed '.reason')" tenant-unit-inactive:demo
}

@test "a broken tenant with no check configured pings nothing" {
    no_apps_ping_url
    : >"$STUB_SYSTEMCTL_USER_ACTIVE"
    probe
    nothing_pinged
}

# The deploy check is never pinged from here, whatever the tenant's state; the
# case that pages the tenant check is the one that could reach it.
@test "the tenant prober never pings the deploy check" {
    case_probe tenant-unit-inactive
    assert [ -e "$DEPLOY_PING_SECRET" ]
    refute grep -qF -- "$ping_url" "$log/curl-urls"
}
