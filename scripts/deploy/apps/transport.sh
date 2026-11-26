# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154  # globals are assigned by the entrypoint
# deploy-apps/transport.sh: sourced by scripts/deploy-apps.sh; no shebang.
usage() {
  cat >&2 <<'EOF'
usage: deploy-apps apply --commit <40-hex>
       deploy-apps revert
       deploy-apps sweep

  apply   fetch, validate, render and install one homelab-apps commit
  revert  restore the revision recorded in apply.json, or do nothing
  sweep   remove the work trees an interrupted apply left behind
EOF
}

# --- bounds ------------------------------------------------------------------
budget_left() {
  local left=$((deadline - $(date -u +%s)))
  ((left > 0)) || left=0
  printf '%s\n' "$left"
}

# Each child gets the smaller of its own bound and what is left of the apply's:
# without that, one 1800 s pull at the end of the budget overruns it.
cap_of() { # <cap>
  local cap=$1 left
  left=$(budget_left)
  if ((left < cap)); then cap=$left; fi
  # timeout(1) reads a zero duration as "no limit", which is the opposite of what
  # an exhausted budget means.
  ((cap > 0)) || cap=1
  printf '%s\n' "$cap"
}

bounded() { # <cap> <command...>
  local cap
  cap=$(cap_of "$1")
  shift
  timeout --signal=TERM --kill-after=60 "$cap" "$@"
}

# --- the tenant --------------------------------------------------------------
require_tenant() {
  local home
  apps_uid=${APPS_UID:-}
  [[ -n $apps_uid ]] || apps_uid=$(getent passwd "$apps_user" 2>/dev/null | cut -d: -f3) || apps_uid=""
  if [[ ! $apps_uid =~ ^[0-9]+$ ]]; then
    warn "there is no account named $apps_user"
    return 1
  fi
  apps_runtime_dir=${APPS_RUNTIME_DIR:-/run/user/$apps_uid}
  # APPS_HOME wins over the passwd entry so a test never has to create the
  # account; the host default is the home the account was created with.
  if [[ -n ${APPS_HOME:-} ]]; then
    home=$apps_home
  else
    home=$(getent passwd "$apps_user" 2>/dev/null | cut -d: -f6) || home=""
    [[ -n $home ]] || home=$apps_home
  fi
  apps_unit_dir=${APPS_UNIT_DIR:-$home/.config/containers/systemd}
  return 0
}

# Everything that touches the tenant's home or its user manager runs as the
# tenant. The subshell gives the child `/` as its working directory -- what the
# design's `cd /` is for -- without changing the argv a test asserts on, and the
# cap keeps a wedged pull from outliving the apply.
tenant_bounded() { # <cap> <command...>
  local cap=$1
  shift
  (
    cd / || exit 1
    exec timeout --signal=TERM --kill-after=60 "$cap" \
      "$runuser_bin" -u "$apps_user" -- env "XDG_RUNTIME_DIR=$apps_runtime_dir" "$@"
  )
}

tenant() { tenant_bounded "$(cap_of "$tenant_timeout")" "$@"; }

# The rendered tree is root-only, so the tenant never reads it: root opens the
# source and feeds it down a pipe to a process that is the tenant.
tenant_install() { # <src> <dst>
  tenant tee -- "$2" >/dev/null <"$1"
}

tenant_remove() { # <path>
  tenant rm -f -- "$1"
}

# The machine transport is the system bus's route to the tenant manager, so this
# works from the drain and from a root shell alike. `runuser -- systemctl --user`
# races the manager's private socket and inherits the caller's bus address.
user_ctl() { # <args...>; retry transport failures until the window closes
  local i rc out started=-1
  for ((i = 0; i < ctl_retries; i++)); do
    out=$(bounded "$(cap_of "$ctl_timeout")" "$systemctl_bin" --user \
      --machine="$apps_user@.host" "$@" 2>&1) && {
      [[ -n $out ]] && printf '%s\n' "$out" >&2
      return 0
    }
    rc=$?
    case $out in
      *"Transport endpoint is not connected"* | *"Failed to connect to user scope bus"* | \
        *"Connection refused"* | *"Connection reset"* | *"Broken pipe"*)
        # The window opens at the first failure, not at the call: a slow but
        # healthy call must not eat the time a starting manager is allowed.
        if ((started < 0)); then started=$SECONDS; fi
        if ((SECONDS - started >= ctl_retry_window)); then
          [[ -n $out ]] && printf '%s\n' "$out" >&2
          warn "the apps tenant manager user@$apps_uid has not answered in ${ctl_retry_window}s; check systemctl status user@$apps_uid.service and /run/user/$apps_uid"
          return "$rc"
        fi
        sleep 1
        ;;
      *)
        [[ -n $out ]] && printf '%s\n' "$out" >&2
        return "$rc"
        ;;
    esac
  done
  [[ -n $out ]] && printf '%s\n' "$out" >&2
  return "$rc"
}

system_ctl() { # <verb> <unit>
  bounded "$ctl_timeout" "$systemctl_bin" "$1" "$2"
}

# One `systemctl show` answers both halves of the question: the state, and how
# many times systemd has restarted the unit. A container that exits under
# Restart= is usually `active` again by the next sample, so a state-only sample
# misses the crash loop; the counter does not. Only the two properties are read
# out of the answer, so a warning the bus prints alongside them cannot turn into
# a verdict.
user_state() { # <unit> -> "<ActiveState> <NRestarts>", or "unknown 0"
  local i out state restarts
  for ((i = 0; i < 10; i++)); do
    out=$(bounded "$(cap_of "$ctl_timeout")" "$systemctl_bin" --user \
      --machine="$apps_user@.host" show -p ActiveState -p NRestarts "$1" 2>&1)
    state=$(sed -n 's/^ActiveState=//p' <<<"$out")
    restarts=$(sed -n 's/^NRestarts=//p' <<<"$out")
    if [[ -n $state && $restarts =~ ^[0-9]+$ ]]; then
      printf '%s %s\n' "$state" "$restarts"
      return 0
    fi
    # The manager is busiest right after the restarts above, so a transport
    # failure here is expected occasionally and is not an answer.
    case $out in
      *"Transport endpoint is not connected"* | *"Failed to connect to user scope bus"* | \
        *"Connection refused"* | *"Connection reset"* | *"Broken pipe"*)
        sleep 1
        ;;
      *) break ;;
    esac
  done
  printf 'unknown 0\n'
  return 0
}

# Waits for the app to be active, then holds it through the settle window. Any
# non-active sample, and any restart after the baseline, is the crash loop this
# exists to catch. "Cannot ask" is not "unhealthy": an unanswered probe is
# retried until the wait budget is gone. Sets health_unit and health_state.
app_health() { # <name>
  local unit probe state restarts baseline='' end
  unit=$(app_service "$1")
  # A probe bounded by an exhausted apply budget is a one-second answer to a
  # question that needs seconds, and its failure would name the app instead of
  # the budget.
  if (($(budget_left) < health_wait_timeout + health_settle)); then
    health_unit=$unit health_state=budget-exhausted
    return 1
  fi
  end=$(($(date -u +%s) + health_wait_timeout))
  while :; do
    probe=$(user_state "$unit")
    state=${probe%% *} restarts=${probe##* }
    case $state in
      active)
        baseline=$restarts
        break
        ;;
      # Anything else may still resolve, but a failed unit that has run out of
      # restarts will not: waiting for it only delays the revert.
      failed)
        health_unit=$unit health_state=$state
        return 1
        ;;
    esac
    if (($(date -u +%s) >= end)); then
      health_unit=$unit health_state=$state
      return 1
    fi
    sleep 2
  done
  end=$(($(date -u +%s) + health_settle))
  while :; do
    probe=$(user_state "$unit")
    state=${probe%% *} restarts=${probe##* }
    if [[ $state != active ]]; then
      health_unit=$unit health_state=$state
      return 1
    fi
    if ((restarts > baseline)); then
      health_unit=$unit health_state=restarted
      return 1
    fi
    (($(date -u +%s) < end)) || return 0
    sleep 1
  done
}

# A unit that was never installed exits 5 from systemd; any other failure,
# including an unreadable manager, is a real failure. Probing is-active here
# turned a dead manager into "already stopped" and let the revert remove a
# secret a running container still mounted.
user_stop() { # <unit>
  local rc
  user_ctl stop "$1"
  rc=$?
  ((rc == 0 || rc == 5)) && return 0
  return 1
}

system_stop() { # <unit>
  local rc
  system_ctl stop "$1"
  rc=$?
  ((rc == 0 || rc == 5)) && return 0
  return 1
}
