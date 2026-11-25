#!/usr/bin/env bats
# bats file_tags=deploy
# Offline checks for the tenant's five-minute health prober (smortress-apps-health).
#
# The prober asks the three questions that define a serving app: the Quadlet's
# unit active in the tenant's manager, the plan's loopback port accepting a
# connect, and the app's base path declared by Serve. It reports to the journal
# and to the tenant's own Healthchecks check, and nothing else: every case here
# also proves the run wrote no deploy record, requested no reboot and never
# touched the deploy dead-man -- a prober that could roll the host back would be
# the boot gate's coupling again, with a different clock, and one that pinged the
# deploy check would fight the heartbeat that keeps it green.
#
# `systemctl`, `tailscale` and `curl` are fakes on PATH and the state is a
# throwaway directory; the journal and the command lines are real. The ingress
# check is a real TCP connect to a throwaway listener, because a fake would prove
# nothing about it. No root, no reboot, no image, no network.
#
#   bats tests/deploy/apps-health.bats
load ../helpers

prober=scripts/smortress-apps-health.sh
lib=scripts/deploy-state.sh
ping_url=https://hc.invalid/ping/abc
tenant_ping_url=https://hc.invalid/ping/tenant
# Two ports: one a real listener holds, one nothing ever binds. The closed one is
# a fixed number rather than a second ephemeral bind, so a rerun on another host
# keeps meaning the same thing.
app_port=34711
closed_port=34712

# port_accepts <port>: a TCP connect to a loopback port, from a child bash, so
# the port is a number and never a name this shell could resolve.
port_accepts() {
    # The single quotes are the point: the child bash expands the port.
    # shellcheck disable=SC2016
    timeout 1 bash -c 'exec 3<>"/dev/tcp/127.0.0.1/$1"' _ "$1" 2>/dev/null
}

# The fakes and the listener are the same for every test, so they are built once
# per file; the plan, the Serve answer, the records and the logs are per test.
setup_file() {
    bin=$BATS_FILE_TMPDIR/bin
    mkdir -p "$bin"

    # The prober reaches the tenant through `--user --machine=<user>@.host`, and
    # that is what this stub records: a run that asked the host's manager about a
    # user unit would see nothing and report every app inactive.
    cat >"$bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG/systemctl-calls"
scope=system
rest=()
for a in "$@"; do
  case $a in
    --user | --machine=*) scope=user ;;
    *) rest+=("$a") ;;
  esac
done
verb=${rest[0]-}
unit=${rest[1]-}
case $verb in
  is-active)
    printf 'is-active %s\n' "$unit" >>"$STUB_LOG/probe-order"
    if [[ $scope == user ]]; then file=$STUB_SYSTEMCTL_USER_ACTIVE; else file=$STUB_SYSTEMCTL_ACTIVE; fi
    if grep -qxF -- "$unit" "$file" 2>/dev/null; then
      printf 'active\n'
      exit 0
    fi
    printf 'inactive\n'
    exit 3
    ;;
  *) exit 0 ;;
esac
STUB

    cat >"$bin/tailscale" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG/tailscale-calls"
[[ ${STUB_TAILSCALE_EXIT:-0} == 0 ]] || exit "$STUB_TAILSCALE_EXIT"
# An apply that begins while a probe is running writes its record after the
# prober's first look: a case points STUB_TAILSCALE_APPLY at a record to move it
# in here, which is the earliest moment inside the probe that is deterministic.
if [[ -n ${STUB_TAILSCALE_APPLY:-} ]]; then
  mv -- "$STUB_TAILSCALE_APPLY" "$DEPLOY_STATE_DIR/apply.json"
fi
if [[ $* == "serve status --json" ]]; then
  cat "$STUB_SERVE_JSON"
fi
exit 0
STUB

    # The tenant ping passes its URL as an argument, and the body beside it is
    # recorded so a case can assert the reason the check received.
    cat >"$bin/curl" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
url=${*: -1}
prev=
body=
for arg in "$@"; do
  [[ $prev == --data-binary ]] && body=$arg
  prev=$arg
done
if [[ ${FAKE_PING_BODY:-0} == 1 ]]; then
  printf '%s\t%s\n' "$url" "$body" >>"$FAKE_PING_LOG"
else
  printf '%s\n' "$url" >>"$FAKE_PING_LOG"
fi
exit 0
STUB
    chmod 0755 "$bin"/*

    # The listener is a real socket: the ingress check must pass on a bound port
    # and fail on an unbound one, and a stub could only ever say what it was
    # told. One listener serves the whole file and its pid is left behind for
    # teardown_file, the one process that can see it again.
    python3 - "$app_port" <<'PY' &
import socket, sys
listener = socket.socket()
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(("127.0.0.1", int(sys.argv[1])))
listener.listen(16)
while True:
    try:
        conn, _ = listener.accept()
    except OSError:
        break
    conn.close()
PY
    printf '%s\n' "$!" >"$BATS_FILE_TMPDIR/listener.pid"
    for _ in $(seq 1 50); do
        port_accepts "$app_port" && break
        sleep 0.1
    done
}

teardown_file() {
    [[ -s $BATS_FILE_TMPDIR/listener.pid ]] || return 0
    kill "$(cat "$BATS_FILE_TMPDIR/listener.pid")" 2>/dev/null || true
    rm -f "$BATS_FILE_TMPDIR/listener.pid"
}

# Every test starts from the healthy tenant and breaks the one part it is about:
# bats runs a file's tests in parallel, so the state, the records and the logs
# are per test.
setup() {
    work=$BATS_TEST_TMPDIR
    log=$work/log
    state=$work/state
    mkdir -p "$log"
    export PATH="$BATS_FILE_TMPDIR/bin:$PATH"
    export DEPLOY_STATE_DIR=$state
    export DEPLOY_PING_SECRET=$work/deploy-ping-url.yaml
    export APPS_HEALTH_SECRET=$work/healthchecks.yaml
    export APPS_PLAN=$work/plan.json
    export STUB_LOG=$log
    export FAKE_PING_LOG=$log/curl-urls
    export FAKE_PING_BODY=1
    export STUB_SYSTEMCTL_ACTIVE=$work/active-units
    export STUB_SYSTEMCTL_USER_ACTIVE=$work/active-user-units
    export STUB_SERVE_JSON=$work/serve.json
    # shellcheck source=/dev/null
    source "$lib"
    deploy_state_init
    reset_case
}

journal_field() { # <event> <jq-path>
    jq -r "select(.event==\"$1\") | $2" "$state/journal.jsonl" 2>/dev/null
}

plan_with_port() { # <loopback port>
    jq -nc --argjson port "$1" \
        '{version:1,apps:{demo:{basePath:"/apps/demo",containerPort:8080,loopbackPort:$port}}}' \
        >"$APPS_PLAN"
}

serve_healthy() {
    jq -nc --argjson port "$app_port" \
        '{"Web":{":443":{"Handlers":{"/apps/demo":{Proxy:("http://127.0.0.1:" + ($port | tostring))}}}}}' \
        >"$STUB_SERVE_JSON"
}

reset_case() {
    rm -f "$state"/state.json "$state"/pending.json "$state"/apply.json \
        "$state"/denylist.json "$state"/journal.jsonl "$DEPLOY_PING_SECRET" \
        "$APPS_HEALTH_SECRET"
    : >"$log/systemctl-calls"
    : >"$log/probe-order"
    : >"$log/tailscale-calls"
    : >"$log/curl-urls"
    unset STUB_TAILSCALE_EXIT STUB_TAILSCALE_APPLY
    printf '%s\n' "$ping_url" >"$DEPLOY_PING_SECRET"
    printf 'restic-ping-url: https://hc.invalid/ping/restic\napps-ping-url: %s\n' \
        "$tenant_ping_url" >"$APPS_HEALTH_SECRET"
    printf 'demo.service\n' >"$STUB_SYSTEMCTL_USER_ACTIVE"
    printf 'demo.service\n' >"$STUB_SYSTEMCTL_ACTIVE"
    plan_with_port "$app_port"
    serve_healthy
}

# probe: one run of the prober; its status in `rc` and both streams in `out`.
# The run's own output is carried into a failure: a probe that fails for a reason
# the assertion did not expect shows that reason, not only its exit code.
probe() {
    rc=0
    out=$(bash "$prober" 2>&1) || rc=$?
}

expect_failure() {
    ((rc != 0)) && return 0
    printf '%s\n' "$out" >&2
    return 1
}

# ping_is <suffix> <body>: the tenant check's whole page. A /fail without the
# reason is what the deploy check's dead-man sends.
ping_is() {
    local want_url="${tenant_ping_url}$1" want_body=$2 got_url='' got_body=''
    IFS=$'\t' read -r got_url got_body <"$log/curl-urls" 2>/dev/null || true
    assert_equal "$got_url" "$want_url"
    assert_equal "$got_body" "$want_body"
}

# The cases that must fail, and what each of their assertions is called: the
# label is the scenario, the reason is what the prober has to journal.
fail_cases='tenant-unit-inactive ingress-unreachable serve-path-missing serve-status-unreadable plan-unreadable plan-row-unreadable'
pass_cases='healthy apply-in-flight apply-mid-probe no-plan empty-plan'

label_for() {
    case $1 in
        healthy) printf 'a healthy plan' ;;
        tenant-unit-inactive) printf 'an inactive tenant unit' ;;
        ingress-unreachable) printf 'a closed loopback port' ;;
        serve-path-missing) printf 'a missing base path' ;;
        serve-status-unreadable) printf 'an unreadable Serve state' ;;
        plan-unreadable) printf 'an unreadable plan' ;;
        plan-row-unreadable) printf 'a plan row that cannot be probed' ;;
        apply-in-flight) printf 'an apply in flight' ;;
        apply-mid-probe) printf 'an apply that starts mid-probe' ;;
        no-plan) printf 'no plan' ;;
        empty-plan) printf 'an empty plan' ;;
    esac
}

reason_for() {
    case $1 in
        tenant-unit-inactive) printf 'tenant-unit-inactive:demo' ;;
        ingress-unreachable) printf 'ingress-unreachable:demo:%s' "$closed_port" ;;
        serve-path-missing) printf 'serve-path-missing:/apps/demo' ;;
        serve-status-unreadable) printf 'serve-status-unreadable' ;;
        plan-unreadable) printf 'plan-unreadable' ;;
        plan-row-unreadable) printf 'plan-unreadable:demo' ;;
    esac
}

# case_fixture <case>: the one thing the case breaks inside the healthy tenant.
case_fixture() {
    case $1 in
        healthy) ;;
        tenant-unit-inactive) : >"$STUB_SYSTEMCTL_USER_ACTIVE" ;;
        ingress-unreachable) plan_with_port "$closed_port" ;;
        serve-path-missing) jq -nc '{"Web":{":443":{"Handlers":{"/apps/other":{}}}}}' >"$STUB_SERVE_JSON" ;;
        serve-status-unreadable) export STUB_TAILSCALE_EXIT=1 ;;
        plan-unreadable) printf 'not a plan\n' >"$APPS_PLAN" ;;
        # A row that names no unit, path or port is the same failure, named after
        # the app: the plan is readable, so the row is what cannot be asked about.
        plan-row-unreadable) jq -nc '{version:1,apps:{demo:{containerPort:8080}}}' >"$APPS_PLAN" ;;
        # deploy-apps installs the new plan before it writes the units and
        # restarts Serve, so the window between those steps looks exactly like a
        # broken revision.
        apply-in-flight)
            : >"$STUB_SYSTEMCTL_USER_ACTIVE"
            jq -nc '{schema:1,phase:"installing",previousUnits:[],intendedUnits:[]}' \
                >"$state/apply.json"
            ;;
        apply-mid-probe)
            : >"$STUB_SYSTEMCTL_USER_ACTIVE"
            printf '{"schema":1,"phase":"installing","previousUnits":[],"intendedUnits":[]}\n' \
                >"$work/apply-mid-probe.json"
            export STUB_TAILSCALE_APPLY=$work/apply-mid-probe.json
            ;;
        no-plan) rm -f "$APPS_PLAN" ;;
        empty-plan) jq -nc '{version:1,apps:{}}' >"$APPS_PLAN" ;;
    esac
}

# A case run from its fixture: every assertion below is about one property of
# that run, so each test drives its own.
case_probe() { # <case>
    case_fixture "$1"
    probe
}

# --- the prober's own fakes --------------------------------------------------

# The fixture's whole claim, proved: without a bound port the ingress cases below
# would be proving the prober against a closed port twice.
@test "the ingress stand-in accepts connections on 127.0.0.1:34711" {
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
# host heartbeat cannot carry a tenant verdict, and a `deploy_notify fail` from
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
