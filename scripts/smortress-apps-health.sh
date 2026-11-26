#!/usr/bin/env bash
# Tenant health prober: is every app in the installed plan up and reachable?
#
#   smortress-apps-health
#
# Runs every five minutes from smortress-apps-health.timer. The three questions
# are the platform's definition of a serving app, asked the way the boot gate
# asked them: the Quadlet's unit is active in the tenant's own manager, the
# plan's loopback port accepts a connect, and Serve declares the app's base path.
# It reads the plan, the tenant's manager and Serve; it compares nothing against a
# commit and repairs nothing.
#
# It reports, and only reports. A crash-looping app is an apps-revision problem
# -- the apply already refuses to commit one (deploy-apps' `check_started_apps`)
# -- and rolling the host image back for it is the wrong coupling: a platform
# that rolls back a boot it judged healthy is a platform whose rollback means
# nothing. So nothing here reboots, stages, rolls back or reverts an apply.
#
# The signal is two-faced on purpose: the journal names the failing app, and the
# tenant's own Healthchecks check carries the page. It is a different check from
# the deploy dead-man -- one check answered by two programs would turn one
# crash-looping app into a down/recover pair every five minutes -- and it stays
# silent until the operator stages its URL (`apps-ping-url` in
# healthchecks.yaml). A green tick pings it; a failure pings `/fail` with the
# reason, so the page arrives in the same tick rather than after a grace period.
#
# An apps apply in flight is not a fault. deploy-apps installs the new plan
# before it writes the units and restarts Serve, with a bounded health wait in
# between, so a tick that lands inside that window sees a revision that looks
# exactly like one that broke. The drain and the gate's revert both hold
# `apply.json` for the whole of it, which is why the record -- and not the
# timer's schedule -- is what keeps this quiet.
#
# The plan semantics are the boot gate's, because the two may never disagree
# about what "serving" means: no plan is a host with no tenant yet and therefore
# success, and a plan that cannot be read is a failure -- a prober that shrugged
# at an unreadable plan would stay green on a host whose tenant nobody can
# describe.
#
# Exit codes: 0 every app in the plan is serving, or an apply is in flight;
# 1 a check failed or the run could not start.
#
# Every knob is environment-overridable so tests/deploy/apps-health.sh can drive
# this exact code against fakes. Production sets none of them: the defaults are
# the host contract, not a way to skip a check.
#
# shellcheck disable=SC2154  # deploy-state.sh assigns these at source time
set -euo pipefail
# shellcheck source=/dev/null
_smolib=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/log.sh
[[ -r $_smolib ]] || _smolib=/usr/libexec/lib/log.sh
# shellcheck source=/dev/null
source "$_smolib"

self_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
state_lib=${DEPLOY_STATE_LIB:-}
if [[ -z $state_lib ]]; then
  # Sibling first: in the image both files land in /usr/libexec, and in a
  # checkout both are in scripts/.
  if [[ -r $self_dir/deploy-state.sh ]]; then
    state_lib=$self_dir/deploy-state.sh
  elif [[ -r $self_dir/deploy-state ]]; then
    state_lib=$self_dir/deploy-state
  else
    state_lib=/usr/libexec/deploy-state
  fi
fi
[[ -r $state_lib ]] || {
  printf 'smortress-apps-health: no state library at %s\n' "$state_lib" >&2
  exit 1
}
# shellcheck source=/dev/null
source "$state_lib"

systemctl_bin=${SYSTEMCTL_BIN:-systemctl}
tailscale_bin=${TAILSCALE_BIN:-tailscale}
apps_plan=${APPS_PLAN:-/var/lib/homelab/apps/plan.json}
apps_user=${APPS_USER:-apps}
# Each probe is bounded on its own, so one wedged `systemctl` or a Serve query
# that never answers costs the whole run rather than one app's verdict.
ctl_timeout=${APPS_HEALTH_CTL_TIMEOUT:-10}
probe_timeout=${APPS_HEALTH_PROBE_TIMEOUT:-10}
connect_timeout=${APPS_HEALTH_CONNECT_TIMEOUT:-5}
# The tenant check's URL is the capability to keep it green, so it is read from
# the decrypted file and never echoed; both overrides exist for the suite.
healthchecks_secret=${APPS_HEALTH_SECRET:-/run/smortress/secrets/healthchecks.yaml}
healthchecks_url_override=${APPS_HEALTH_PING_URL:-}
curl_bin=${CURL_BIN:-curl}
ping_timeout=${APPS_HEALTH_PING_TIMEOUT:-10}


reason=
app=
unit=
serving=0

# The decrypted Healthchecks file is plain YAML with top-level scalars; the restic
# plane reads the same file with the same rule. A malformed or absent file means
# the operator has not staged this check, which is not a failure of the tenant.
healthchecks_url() {
  local value
  if [[ -n $healthchecks_url_override ]]; then
    printf '%s\n' "$healthchecks_url_override"
    return 0
  fi
  [[ -r $healthchecks_secret ]] || return 1
  value=$(sed -n 's/^apps-ping-url:[[:space:]]*//p' "$healthchecks_secret" | head -n 1)
  value=${value%\"}
  value=${value#\"}
  [[ -n $value ]] || return 1
  printf '%s\n' "$value"
}

# <suffix> <body>. Never echo the URL: its UUID is the capability. A ping that
# cannot be sent is a warning, not a probe failure -- the tenant's verdict is
# already journaled, and a broken check is the check's own dead-man's business.
ping_check() {
  local url suffix=$1 body=$2
  local -a args=(--fail --silent --show-error --max-time "$ping_timeout" -o /dev/null)
  url=$(healthchecks_url) || return 0
  if [[ -n $body ]]; then
    args+=(--data-binary "$body")
  fi
  timeout --signal=TERM --kill-after=2 "$((ping_timeout + 5))" \
    "$curl_bin" "${args[@]}" "$url$suffix" >/dev/null 2>&1 ||
    warn "the tenant Healthchecks check could not be pinged"
  return 0
}

# The single quotes are the point: the port is expanded by the child bash that
# opens the connection, not by this shell, so no path here can be a hostname.
# shellcheck disable=SC2016
tcp_open() { # <port>
  timeout --signal=TERM "$(clamp_timeout "$connect_timeout")" bash -c 'exec 3<>"/dev/tcp/127.0.0.1/$1"' _ "$1" \
    2>/dev/null
}

# The handlers on 443 are the tenant's namespace: Serve exposes root-path HTTPS
# only on 443, 8443 and 10000, and those belong to the core applications.
serve_status_paths() {
  local doc
  doc=$(timeout --signal=TERM --kill-after=10 "$(clamp_timeout "$probe_timeout")" \
    "$tailscale_bin" serve status --json 2>/dev/null) ||
    return 1
  jq -r '.Web // {} | to_entries[]
    | select(.key | endswith(":443"))
    | (.value.Handlers // {}) | keys[]' <<<"$doc" 2>/dev/null
}

# Every failure names the reason and, when it is one app's fault, that app and
# the unit it was reached through: the journal line carries all three, and that
# line is the whole report.
probe_plan() {
  local rows serve_paths loopback path name app_unit
  # No plan is a host with no tenant: nothing to probe, and failing here would
  # name every host before its first apps apply an unhealthy tenant.
  [[ -e $apps_plan ]] || return 0
  jq -e '(.apps | type) == "object"' "$apps_plan" >/dev/null 2>&1 || {
    reason="plan-unreadable"
    return 1
  }
  rows=$(jq -r '(.apps // {}) | to_entries[]
    | [.key, (.value.unitName // (.key + ".container")), (.value.basePath // ""),
       ((.value.loopbackPort // "") | tostring)] | @tsv' "$apps_plan" 2>/dev/null) || {
    reason="plan-unreadable"
    return 1
  }
  [[ -n $rows ]] || return 0
  serve_paths=$(serve_status_paths) || {
    reason="serve-status-unreadable"
    return 1
  }
  while IFS=$'\t' read -r name app_unit path loopback; do
    [[ -n $name ]] || continue
    if [[ -z $path || -z $app_unit ]]; then
      reason="plan-unreadable:$name"
      app=$name
      unit=$app_unit
      return 1
    fi
    # Quadlet generates `<name>.service` from `<name>.container`; the plan names
    # the file, not the unit systemd runs.
    [[ $app_unit == *.container ]] && app_unit=${app_unit%.container}.service
    # A user unit is reached through the tenant's own manager: this runs as root
    # and cannot `--user` against a session it does not have.
    if [[ $(timeout --signal=TERM "$(clamp_timeout "$ctl_timeout")" "$systemctl_bin" --user \
      --machine="$apps_user@.host" is-active "$app_unit" 2>/dev/null) != active ]]; then
      reason="tenant-unit-inactive:$name"
      app=$name
      unit=$app_unit
      return 1
    fi
    if [[ ! $loopback =~ ^[0-9]+$ ]] || ! tcp_open "$loopback"; then
      reason="ingress-unreachable:$name:$loopback"
      app=$name
      unit=$app_unit
      return 1
    fi
    if ! grep -qxF -- "$path" <<<"$serve_paths" 2>/dev/null; then
      reason="serve-path-missing:$path"
      app=$name
      unit=$app_unit
      return 1
    fi
    serving=$((serving + 1))
  done <<<"$rows"
  return 0
}

# The journal line is the report: it names the reason, the app and the unit, and
# `journalctl -u smortress-apps-health` shows the same run's stderr beside it.
report_failure() {
  journal_append apps-health-failed "$(jq -nc --arg reason "$reason" --arg app "$app" \
    --arg unit "$unit" '{reason:$reason,app:$app,unit:$unit}')" ||
    warn "cannot journal the failure"
  warn "not serving: $reason"
  ping_check /fail "not serving: $reason"
}

if [[ -e $deploy_state_dir/apply.json ]]; then
  say "an apps apply is in flight; nothing was probed"
  ping_check "" "apps apply in flight; nothing was probed"
  exit 0
fi

if probe_plan; then
  if ((serving)); then
    say "$serving app(s) are serving"
    ping_check "" "$serving app(s) are serving"
  elif [[ -e $apps_plan ]]; then
    say "the plan names no app; nothing to probe"
    ping_check "" "the plan names no app"
  else
    say "no tenant plan at $apps_plan; nothing to probe"
    ping_check "" "no tenant plan"
  fi
  exit 0
fi
# The record above was read before the probe began; an apply that started while
# it ran is the same window, and a tick that reported a revision the drain is
# halfway through would put a false line on the tenant's only signal.
if [[ -e $deploy_state_dir/apply.json ]]; then
  say "an apps apply started during the probe; nothing was reported"
  ping_check "" "apps apply in flight; nothing was reported"
  exit 0
fi
report_failure
exit 1
