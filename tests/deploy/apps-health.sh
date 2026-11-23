#!/usr/bin/env bash
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
#   tests/deploy/apps-health.sh
# shellcheck disable=SC2154  # deploy-state.sh assigns these at source time
set -uo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root" || exit 1

prober=scripts/smortress-apps-health.sh
lib=scripts/deploy-state.sh
for file in "$prober" "$lib"; do
  [[ -r $file ]] || {
    printf 'FAIL %s is missing\n' "$file" >&2
    exit 1
  }
done
for tool in jq timeout python3; do
  command -v "$tool" >/dev/null || {
    printf 'FAIL %s is required\n' "$tool" >&2
    exit 1
  }
done

pass=0
fail=0
ok() {
  pass=$((pass + 1))
  printf 'ok   %s\n' "$1"
}
bad() {
  fail=$((fail + 1))
  printf 'FAIL %s\n' "$1" >&2
  [[ -n ${2:-} ]] && printf '     %s\n' "${2//$'\n'/$'\n'     }" >&2
  return 0
}
check_eq() { # got want label
  if [[ $1 == "$2" ]]; then ok "$3"; else bad "$3" "want '$2', got '$1'"; fi
}
check_file() { # path label
  if [[ -s $1 ]]; then ok "$2"; else bad "$2" "missing or empty: $1"; fi
}
check_no_file() { # path label
  if [[ -e $1 ]]; then bad "$2" "$(cat "$1" 2>/dev/null)"; else ok "$2"; fi
}
check_grep() { # file pattern label
  if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3" "no '$2' in $1"; fi
}

work=$(mktemp -d)
listener=
cleanup() {
  [[ -n $listener ]] && kill "$listener" 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

bin=$work/bin
log=$work/log
state_dir=$work/state
install -d -m 0755 "$bin" "$log"
export DEPLOY_STATE_DIR=$state_dir
export DEPLOY_PING_SECRET=$work/deploy-ping-url.yaml
export APPS_HEALTH_SECRET=$work/healthchecks.yaml
export APPS_PLAN=$work/plan.json
export STUB_LOG=$log
export PATH="$bin:$PATH"
# shellcheck source=/dev/null
source "$lib"
deploy_state_init || exit 1

ping_url=https://hc.invalid/ping/abc
tenant_ping_url=https://hc.invalid/ping/tenant
# Two ports: one a real listener holds, one nothing ever binds. The closed one is
# a fixed number rather than a second ephemeral bind, so a rerun on another host
# keeps meaning the same thing.
app_port=34711
closed_port=34712

# --- the fakes ---------------------------------------------------------------
# The prober reaches the tenant through `--user --machine=<user>@.host`, and that
# is what this stub records: a run that asked the host's manager about a user unit
# would see nothing and report every app inactive.
cat >"$bin/systemctl" <<'EOF'
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
EOF

cat >"$bin/tailscale" <<'EOF'
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
EOF

# deploy_notify hands the URL over as a curl config on stdin, never in argv; the
# tenant ping passes it as an argument. Both are recorded with their body so a
# case can assert the suffix and the reason the check received.
cat >"$bin/curl" <<'EOF'
#!/usr/bin/env bash
url=
body=
while (($#)); do
  case $1 in
    --config) shift 2 ;;
    --data-binary) body=${2-}; shift 2 ;;
    --max-time | --retry | --connect-timeout | --retry-delay | -o) shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
if [[ -z $url ]]; then
  url=$(sed -n 's/^url = "\(.*\)"$/\1/p' | head -n 1)
fi
printf '%s\t%s\n' "${url:-}" "$body" >>"$STUB_LOG/curl-urls"
exit 0
EOF
chmod 0755 "$bin"/*

export STUB_SYSTEMCTL_ACTIVE=$work/active-units
export STUB_SYSTEMCTL_USER_ACTIVE=$work/active-user-units
export STUB_SERVE_JSON=$work/serve.json

# The listener is a real socket: the ingress check must pass on a bound port and
# fail on an unbound one, and a stub could only ever say what it was told.
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
listener=$!
port_up=false
for _ in $(seq 1 50); do
  # The single quotes are the point: the child bash expands the port.
  # shellcheck disable=SC2016
  if timeout 1 bash -c 'exec 3<>"/dev/tcp/127.0.0.1/$1"' _ "$app_port" 2>/dev/null; then
    port_up=true
    break
  fi
  sleep 0.1
done
if $port_up; then
  ok "the ingress stand-in accepts connections on 127.0.0.1:$app_port"
else
  bad "the ingress stand-in accepts connections on 127.0.0.1:$app_port"
fi

# --- the fixtures ------------------------------------------------------------
journal_field() { # <event> <jq path>
  jq -r "select(.event==\"$1\") | $2" "$state_dir/journal.jsonl" 2>/dev/null
}

reset_case() {
  rm -f "$state_dir"/state.json "$state_dir"/pending.json "$state_dir"/apply.json \
    "$state_dir"/denylist.json "$state_dir"/journal.jsonl "$DEPLOY_PING_SECRET" \
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
  jq -nc --argjson port "$app_port" \
    '{version:1,apps:{demo:{basePath:"/apps/demo",containerPort:8080,loopbackPort:$port}}}' \
    >"$APPS_PLAN"
  jq -nc '{"Web":{":443":{"Handlers":{"/apps/demo":{Proxy:"http://127.0.0.1:8080"}}}}}' \
    >"$STUB_SERVE_JSON"
}

run_prober() {
  out=$(bash "$prober" 2>&1)
  rc=$?
}

# The run's own output is carried into a failure: a probe that fails for a reason
# the assertion did not expect shows that reason, not only its exit code.
check_rc() { # want label
  if [[ $rc == "$1" ]]; then ok "$2"; else bad "$2" "want exit $1, got $rc: $out"; fi
}

# The prober judges and journals; it never acts on the platform or on the tenant,
# and it never touches the deploy check: one Healthchecks check answered by the
# host heartbeat cannot carry a tenant verdict, and a `deploy_notify fail` from
# here would page a down/recover pair every five minutes for one broken app.
no_side_effects() { # <label>
  check_no_file "$state_dir/state.json" "$1 records no landed deployment"
  check_no_file "$state_dir/pending.json" "$1 leaves no pending record"
  check_no_file "$state_dir/denylist.json" "$1 denylists nothing"
  if grep -q 'reboot' "$log/systemctl-calls" 2>/dev/null; then
    bad "$1 requests no reboot" "$(cat "$log/systemctl-calls")"
  else
    ok "$1 requests no reboot"
  fi
  if [[ -s $log/curl-urls ]] && grep -qvF "${tenant_ping_url}" "$log/curl-urls"; then
    bad "$1 pings only the tenant check" "$(cat "$log/curl-urls")"
  else
    ok "$1 pings only the tenant check"
  fi
}

# <url suffix> <body> <label>. The suffix and the body are the page's whole
# content; a /fail without the reason is what the deploy check's dead-man sends.
check_ping() {
  local want_url="${tenant_ping_url}$1" want_body=$2 label=$3 got_url='' got_body=''
  IFS=$'\t' read -r got_url got_body <"$log/curl-urls" 2>/dev/null || true
  if [[ $got_url == "$want_url" && $got_body == "$want_body" ]]; then
    ok "$label"
  else
    bad "$label" "want '$want_url' body '$want_body', got '$got_url' body '$got_body'"
  fi
}

failed_with() { # <reason> <label>
  check_rc 1 "$2 fails the probe"
  check_eq "$(journal_field apps-health-failed '.reason')" "$1" \
    "the failure is journaled as $1"
  no_side_effects "$2"
}

# --- 1. a healthy tenant passes silently ------------------------------------
reset_case
run_prober
check_rc 0 "a healthy plan passes"
if [[ -n $(journal_field apps-health-failed '.reason') ]]; then
  bad "a healthy plan journals no failure" "$(journal_field apps-health-failed '.reason')"
else
  ok "a healthy plan journals no failure"
fi
check_grep "$log/systemctl-calls" '--machine=apps@.host is-active demo.service' \
  "the unit is asked of the tenant's own manager"
check_grep "$log/systemctl-calls" 'is-active demo.service' \
  "the plan's Quadlet name is asked about the .service unit it generates"
check_grep "$log/tailscale-calls" 'serve status --json' "the base path is checked against Serve"
check_ping "" "1 app(s) are serving" "a healthy tick pings the tenant check green"
no_side_effects "a healthy plan"

# --- 2. an app whose unit is not active -------------------------------------
reset_case
: >"$STUB_SYSTEMCTL_USER_ACTIVE"
run_prober
failed_with tenant-unit-inactive:demo "an inactive tenant unit"
check_eq "$(journal_field apps-health-failed '.app')" demo "the journal names the app"
check_eq "$(journal_field apps-health-failed '.unit')" demo.service "the journal names the unit"
check_grep <(printf '%s\n' "$out") 'not serving: tenant-unit-inactive:demo' \
  "the unit's own stderr names the reason too"
check_ping /fail "not serving: tenant-unit-inactive:demo" \
  "a failure reports the reason to the tenant check in the same tick"

# --- 3. an app whose loopback port nothing answers --------------------------
reset_case
jq -nc --argjson port "$closed_port" \
  '{version:1,apps:{demo:{basePath:"/apps/demo",containerPort:8080,loopbackPort:$port}}}' \
  >"$APPS_PLAN"
run_prober
failed_with "ingress-unreachable:demo:$closed_port" "a closed loopback port"

# --- 4. an app Serve does not declare --------------------------------------
reset_case
jq -nc '{"Web":{":443":{"Handlers":{"/apps/other":{}}}}}' >"$STUB_SERVE_JSON"
run_prober
failed_with serve-path-missing:/apps/demo "a missing base path"

# A Serve query that cannot run is not a tenant verdict, but it is not a pass
# either: a prober that read an unreadable Serve state as healthy would be green
# on the one route it exists to check.
reset_case
export STUB_TAILSCALE_EXIT=1
run_prober
unset STUB_TAILSCALE_EXIT
failed_with serve-status-unreadable "an unreadable Serve state"

# --- 5. a plan nobody can read ---------------------------------------------
reset_case
printf 'not a plan\n' >"$APPS_PLAN"
run_prober
failed_with plan-unreadable "an unreadable plan"

# A row that names no unit, path or port is the same failure, named after the
# app: the plan is readable, so the row itself is what cannot be asked about.
reset_case
jq -nc '{version:1,apps:{demo:{containerPort:8080}}}' >"$APPS_PLAN"
run_prober
failed_with plan-unreadable:demo "a plan row that cannot be probed"
check_eq "$(journal_field apps-health-failed '.app')" demo \
  "the unreadable row is journaled with its app"

# --- 6. an apps apply in flight is not a fault -----------------------------
# deploy-apps installs the new plan before it writes the units and restarts
# Serve, so the window between those steps looks exactly like a broken revision.
# A tick inside it must say nothing rather than page on a deploy that succeeds.
reset_case
: >"$STUB_SYSTEMCTL_USER_ACTIVE"
jq -nc '{schema:1,phase:"installing",previousUnits:[],intendedUnits:[]}' \
  >"$state_dir/apply.json"
run_prober
check_rc 0 "an apply in flight passes"
if [[ -n $(journal_field apps-health-failed '.reason') ]]; then
  bad "an apply in flight journals no failure" "$(journal_field apps-health-failed '.reason')"
else
  ok "an apply in flight journals no failure"
fi
if [[ -s $log/systemctl-calls ]]; then
  bad "an apply in flight probes no unit" "$(cat "$log/systemctl-calls")"
else
  ok "an apply in flight probes no unit"
fi
check_ping "" "apps apply in flight; nothing was probed" \
  "an apply in flight keeps the tenant check green"
no_side_effects "an apply in flight"

# An apply that begins after the run's first look is the same window: the record
# the prober read for was not there yet, and the revision it is now halfway
# through is the one this tick would call broken. Reporting it would put a false
# line on the tenant's only signal for every deploy that overlaps a tick.
reset_case
: >"$STUB_SYSTEMCTL_USER_ACTIVE"
printf '{"schema":1,"phase":"installing","previousUnits":[],"intendedUnits":[]}\n' \
  >"$work/apply-mid-probe.json"
export STUB_TAILSCALE_APPLY=$work/apply-mid-probe.json
run_prober
unset STUB_TAILSCALE_APPLY
check_rc 0 "an apply that starts mid-probe passes"
check_grep "$log/systemctl-calls" 'is-active demo.service' \
  "the mid-probe apply is seen after the probe started"
if [[ -n $(journal_field apps-health-failed '.reason') ]]; then
  bad "an apply that starts mid-probe journals no failure" \
    "$(journal_field apps-health-failed '.reason')"
else
  ok "an apply that starts mid-probe journals no failure"
fi
check_ping "" "apps apply in flight; nothing was reported" \
  "an apply that starts mid-probe keeps the tenant check green"
no_side_effects "an apply that starts mid-probe"

# --- 7. no plan is a host with no tenant -----------------------------------
# The prober runs from the first boot, before the first apps apply installs a
# plan: failing here would name every healthy host a host with a broken tenant.
reset_case
rm -f "$APPS_PLAN"
run_prober
check_rc 0 "no plan passes"
check_ping "" "no tenant plan" "no plan still pings the tenant check green"
if [[ -s $log/systemctl-calls ]]; then bad "no plan probes no unit" "$(cat "$log/systemctl-calls")"; else ok "no plan probes no unit"; fi
no_side_effects "no plan"

# An empty app set is the same answer as no plan: the tenant exists and runs
# nothing, which is a normal revision rather than a fault.
reset_case
jq -nc '{version:1,apps:{}}' >"$APPS_PLAN"
run_prober
check_rc 0 "an empty plan passes"
no_side_effects "an empty plan"

# --- 8. one run journals one failure --------------------------------------
# Two broken apps are one outage, not two: the run stops at the first failure, so
# the journal gets a single line naming the app that came first in the plan.
reset_case
: >"$STUB_SYSTEMCTL_USER_ACTIVE"
jq -nc --argjson port "$app_port" \
  '{version:1,apps:{alpha:{basePath:"/apps/alpha",containerPort:8080,loopbackPort:$port},
    beta:{basePath:"/apps/beta",containerPort:8081,loopbackPort:$port}}}' >"$APPS_PLAN"
run_prober
check_rc 1 "a plan with two inactive apps fails the probe"
check_eq "$(grep -c 'apps-health-failed' "$state_dir/journal.jsonl")" 1 \
  "a run with two inactive apps journals one failure"
check_eq "$(journal_field apps-health-failed '.reason')" tenant-unit-inactive:alpha \
  "the first failing app decides the reason"

# --- 9. an unstaged check is silent, not a failure -------------------------
# The URL is an operator step: until it is in the decrypted file the prober has
# nothing to ping, and the tenant verdict must still be journaled normally.
reset_case
printf 'restic-ping-url: https://hc.invalid/ping/restic\n' >"$APPS_HEALTH_SECRET"
run_prober
check_rc 0 "a missing apps-ping-url key does not fail the probe"
check_eq "$(wc -l <"$log/curl-urls" | tr -d ' ')" 0 \
  "a missing apps-ping-url key pings nothing"
: >"$STUB_SYSTEMCTL_USER_ACTIVE"
run_prober
check_rc 1 "a missing apps-ping-url key still fails a broken tenant"
check_eq "$(journal_field apps-health-failed '.reason')" tenant-unit-inactive:demo \
  "a missing apps-ping-url key still journals the reason"
check_eq "$(wc -l <"$log/curl-urls" | tr -d ' ')" 0 \
  "a broken tenant with no check configured pings nothing"

# The deploy check is never pinged from here, whatever the tenant's state.
if [[ -e $DEPLOY_PING_SECRET ]] && grep -qF "$ping_url" "$log/curl-urls" 2>/dev/null; then
  bad "the tenant prober never pings the deploy check" "$(cat "$log/curl-urls")"
else
  ok "the tenant prober never pings the deploy check"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
