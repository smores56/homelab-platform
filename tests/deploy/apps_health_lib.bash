# Shared prober helpers for the split apps-health suites. Sourced by
# tests/deploy/apps-health-*.bats through `load ./apps_health_lib`; bats
# sources it afresh for every test, so it only defines functions and the
# variables they read.
# shellcheck disable=SC2154,SC2034
# Offline checks for the tenant's five-minute health prober (smortress-apps-health).
#
# The prober asks the three questions that define a serving app: the Quadlet's
# unit active in the tenant's manager, the plan's loopback port accepting a
# connect, and the app's base path declared by Serve. It reports to the journal
# and to the tenant's own Healthchecks check, and nothing else: every case here
# also proves the run wrote no deploy record, requested no reboot and never
# touched the deploy dead-man -- a prober that could roll the host back would be
# the boot gate's coupling again, with a different clock, and one that pinged the
# deploy check would fight the poll that keeps it green.
#
# `systemctl`, `tailscale` and `curl` are fakes on PATH and the state is a
# throwaway directory; the journal and the command lines are real. The ingress
# check is a real TCP connect to a throwaway listener, because a fake would prove
# nothing about it. No root, no reboot, no image, no network.
#
#   bats tests/deploy/apps-health-matrix.bats tests/deploy/apps-health-cases.bats
prober=scripts/smortress-apps-health.sh
lib=scripts/deploy-state.sh
ping_url=https://hc.invalid/ping/abc
tenant_ping_url=https://hc.invalid/ping/tenant
# Two ports, both taken from the kernel's ephemeral range in health_setup_file:
# one a real listener holds, one nothing binds. They cannot be fixed numbers:
# bats runs files in parallel, and both health files call health_setup_file, so a
# constant would have the second file's listener lose the bind and then "pass"
# against the first file's socket.
app_port=
closed_port=

# pick_closed_port: a loopback port on which nothing is listening, allocated by
# binding port 0 and releasing it. The connect re-checks the port is closed at
# the moment it is chosen, so a foreign listener cannot silently become ours.
pick_closed_port() {
    local candidate
    for _ in $(seq 1 20); do
        candidate=$(python3 - <<'PY'
import socket
probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
probe.bind(("127.0.0.1", 0))
print(probe.getsockname()[1])
probe.close()
PY
        )
        if ! port_accepts "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

# port_accepts <port>: a TCP connect to a loopback port, from a child bash, so
# the port is a number and never a name this shell could resolve.
port_accepts() {
    # The single quotes are the point: the child bash expands the port.
    # shellcheck disable=SC2016
    timeout 1 bash -c 'exec 3<>"/dev/tcp/127.0.0.1/$1"' _ "$1" 2>/dev/null
}

# The fakes and the listener are the same for every test, so they are built once
# per file; the plan, the Serve answer, the records and the logs are per test.
health_setup_file() {
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
    # told. It binds port 0 and reports the port it got, so two files running
    # under `--jobs` cannot collide. One listener serves the whole file and its
    # pid is left behind for teardown_file, the one process that sees it again.
    rm -f "$BATS_FILE_TMPDIR/listener.port"
    python3 - "$BATS_FILE_TMPDIR/listener.port" <<'PY' &
import socket, sys
listener = socket.socket()
listener.bind(("127.0.0.1", 0))
listener.listen(16)
with open(sys.argv[1], "w") as fh:
    fh.write(str(listener.getsockname()[1]))
while True:
    try:
        conn, _ = listener.accept()
    except OSError:
        break
    conn.close()
PY
    printf '%s\n' "$!" >"$BATS_FILE_TMPDIR/listener.pid"
    for _ in $(seq 1 50); do
        [[ -s $BATS_FILE_TMPDIR/listener.port ]] && break
        sleep 0.1
    done
    if [[ ! -s $BATS_FILE_TMPDIR/listener.port ]]; then
        printf 'health_setup_file: the app listener never reported a port\n' >&2
        return 1
    fi
    app_port=$(cat "$BATS_FILE_TMPDIR/listener.port")
    if ! port_accepts "$app_port"; then
        printf 'health_setup_file: the app listener on port %s accepts no connection\n' "$app_port" >&2
        return 1
    fi
    if ! closed_port=$(pick_closed_port); then
        printf 'health_setup_file: no closed loopback port could be found\n' >&2
        return 1
    fi
    # bats runs each test in its own process, which does not inherit the file's
    # variables, so the pair is left on disk for health_setup to read.
    printf '%s %s\n' "$app_port" "$closed_port" >"$BATS_FILE_TMPDIR/ports"
}

teardown_file() {
    [[ -s $BATS_FILE_TMPDIR/listener.pid ]] || return 0
    kill "$(cat "$BATS_FILE_TMPDIR/listener.pid")" 2>/dev/null || true
    rm -f "$BATS_FILE_TMPDIR/listener.pid"
}

# Every test starts from the healthy tenant and breaks the one part it is about:
# bats runs a file's tests in parallel, so the state, the records and the logs
# are per test.
health_setup() {
    read -r app_port closed_port <"$BATS_FILE_TMPDIR/ports"
    export app_port closed_port
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
