#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are consumed by scripts/deploy/apps/*.sh
# Apps apply: fetch a verified `homelab-apps` commit, render it, pull its images,
# install the tenant's units and secrets, commit the plan, regenerate Serve -- and
# put the previous revision back when any of that fails (SDLC #798, T5).
#
#   deploy-apps apply --commit <40-hex>
#   deploy-apps revert
#
# An apps deploy has no reboot, so there is no boot gate to fall back on: its
# shape is "verify and pull everything, then change anything", with a crash state
# the next boot gate or drain reverts. The steps, in order:
#
#   1. fetch the commit tarball from codeload into work/apps-<sha>/, decrypt the
#      tenant SOPS file, run the shipped validator, then render beside it. A
#      rejected definition stops here with the installed plan untouched;
#   2. check free space, snapshot the installed revision (units, plan, secret
#      values) and write apply.json -- the record a crash is reverted from --
#      before the first mutation;
#   3. pull every changed image by digest as the tenant, under a deadline. One
#      failed pull aborts with nothing changed;
#   4. install plan.json atomically, restart the quota applier so it reads the new
#      plan before any container starts, then as the tenant install the units,
#      remove the departed apps' units, replace changed secrets, reload the user
#      manager, and start/restart/stop the apps, their secrets and their ingress;
#   5. commit: state.json records the commit and the unit and secret content
#      hashes, apply.json and the previous tree are removed, and Serve is
#      restarted because it is a RemainAfterExit oneshot that would otherwise
#      keep the previous revision's routes.
#
# A Serve failure after the commit is journaled and paged, never reverted: Serve
# also fails on unrelated dataset absenteeism, and an apps revision that is
# running must not be rolled back for a route. A failure after the first mutation
# is: the previous units, plan and secret values are restored, the apps the
# failed apply added are stopped, the ones it removed are started, Serve is
# regenerated, and the record is cleared.
#
# Root never writes inside the tenant's home. Every file, secret and unit under
# the tenant's home is written by a process running as the tenant through
# `runuser`, because a root write there follows a symlink the tenant planted; the
# rendered tree stays root-only and is fed to that process down a pipe.
#
# Exit codes: 0 the commit is running (or already was), or the revert succeeded,
# or nothing needed reverting; 2 usage; 3 the commit is rejected and denylisted (a
# definition the validator refused); 4 nothing was changed and the entry can be
# retried (fetch, decrypt, render, space, pull, the record); 5 the apply failed
# after it started changing the host and the previous revision was restored.
#
# This takes no deploy lock: the drain and the boot gate that call it already hold
# one. Every knob is environment-overridable so tests/deploy/apps.bats can drive this
# exact code. Production sets none of them: the defaults are the host contract,
# not a way to skip a check.
#
# shellcheck disable=SC2154  # deploy-state.sh assigns these at source time
set -euo pipefail
# shellcheck source=/dev/null
_smolib=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/log.sh
[[ -r $_smolib ]] || _smolib=/usr/libexec/lib/log.sh
# shellcheck source=/dev/null
source "$_smolib"

self_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# The image installs the library as /usr/libexec/deploy-state (the smortress-src
# loop strips the `.sh`); a checkout has it beside this script.
state_lib=${DEPLOY_STATE_LIB:-}
if [[ -z $state_lib ]]; then
  # Sibling first: in the image both files land in /usr/libexec, and in a
  # checkout both are in scripts/. Preferring the fixed path made a checkout run
  # the installed copy from the running image -- the suites silently tested the
  # old library on the host that had one.
  if [[ -r $self_dir/deploy-state.sh ]]; then
    state_lib=$self_dir/deploy-state.sh
  elif [[ -r $self_dir/deploy-state ]]; then
    state_lib=$self_dir/deploy-state
  else
    state_lib=/usr/libexec/deploy-state
  fi
fi
[[ -r $state_lib ]] || {
  printf 'deploy-apps: no state library at %s\n' "$state_lib" >&2
  exit 1
}
# shellcheck source=/dev/null
source "$state_lib"

# The renderer is the image's `apps-schema`, resolved by the state library's
# `deploy_resolve` (the same rule the platform gate uses).
schema_bin=$(deploy_resolve "${APPS_SCHEMA:-}" apps-schema "$self_dir/apps-schema.py")

apps_user=${APPS_USER:-apps}
apps_home=${APPS_HOME:-/var/home/apps}
apps_unit_dir=${APPS_UNIT_DIR:-$apps_home/.config/containers/systemd}
apps_plan=${APPS_PLAN:-/var/lib/homelab/apps/plan.json}
apps_policy=${APPS_POLICY:-/usr/share/smortress/apps-policy.json}
# The tarball URL is `<base>/<commit>`, which is what codeload answers with; the
# base is overridable so an offline test serves its own fixture.
apps_fetch_base=${APPS_FETCH_BASE:-https://codeload.github.com/smores56/homelab-apps/tar.gz}
# The age identity is the machine's, staged root-only from the recovery kit; the
# tenant SOPS file is committed encrypted over the same recipients.
age_key=${SOPS_AGE_KEY_FILE:-${SMORTRESS_AGE_KEY:-/var/lib/homelab/age/keys.txt}}
sops_bin=${SOPS_BIN:-sops}
curl_bin=${DEPLOY_CURL_BIN:-curl}
df_bin=${APPS_DF_BIN:-df}
findmnt_bin=${APPS_FINDMNT_BIN:-findmnt}
tar_bin=${APPS_TAR_BIN:-tar}
runuser_bin=${RUNUSER:-runuser}
podman_bin=${APPS_PODMAN_BIN:-podman}
systemctl_bin=${SYSTEMCTL_BIN:-systemctl}
quota_unit=${APPS_QUOTA_UNIT:-smortress-apps-quota.service}
serve_unit=${APPS_SERVE_UNIT:-smortress-tailscale-serve.service}
ingress_template=${APPS_INGRESS_TEMPLATE:-smortress-app-ingress@}

# The renderer's own first line: it is how the snapshot tells a unit this platform
# wrote from a file the tenant put in its own home.
render_marker='# Rendered from apps/'

# The design's bounds. The pull is the long one (a cold layer cache), the fetch
# and the render are short, and the whole apply is bounded so a wedged child
# cannot hold the deploy lock until the drain unit's own TimeoutStartSec.
apps_budget=${APPS_BUDGET:-5400}
fetch_timeout=${APPS_FETCH_TIMEOUT:-300}
tar_timeout=${APPS_TAR_TIMEOUT:-300}
schema_timeout=${APPS_SCHEMA_TIMEOUT:-120}
sops_timeout=${APPS_SOPS_TIMEOUT:-120}
df_timeout=${APPS_DF_TIMEOUT:-30}
pull_timeout=${APPS_PULL_TIMEOUT:-1800}
tenant_timeout=${APPS_TENANT_TIMEOUT:-120}
ctl_timeout=${APPS_CTL_TIMEOUT:-120}
# Transport failures are retried while the tenant manager starts; the count is a
# knob because a suite that has to prove the exhausted case cannot wait 30 s for
# every call. The count alone is not a bound -- a dead manager answers instantly
# and forever, and one that hangs to `ctl_timeout` on every attempt costs hours
# per call site (#119) -- so the window closes the loop on wall clock instead.
ctl_retries=${APPS_CTL_RETRIES:-180}
ctl_retry_window=${APPS_CTL_RETRY_WINDOW:-180}
serve_timeout=${APPS_SERVE_TIMEOUT:-180}
# How long a started app may take to come up, and how long it must then stay up:
# a container that exits is restarted, so one active sample is not health.
health_wait_timeout=${APPS_HEALTH_WAIT_TIMEOUT:-180}
health_settle=${APPS_HEALTH_SETTLE:-15}

# Free space, in bytes: the tenant home takes the pulled layers, `/` and `/var`
# take the container store and the ostree staging a platform deploy needs at the
# same time. Paths are overridable so a test can point them at known trees.
home_need=${APPS_MIN_FREE_HOME_BYTES:-$((10 * 1024 * 1024 * 1024))}
root_need=${APPS_MIN_FREE_ROOT_BYTES:-$((8 * 1024 * 1024 * 1024))}
var_need=${APPS_MIN_FREE_VAR_BYTES:-$((8 * 1024 * 1024 * 1024))}
home_path=${APPS_FREE_HOME_PATH:-$apps_home}
root_path=${APPS_FREE_ROOT_PATH:-/}
var_path=${APPS_FREE_VAR_PATH:-/var}

deadline=0
work=
commit=
apps_uid=
apps_runtime_dir=
# The state document the diff compares against, read once before anything moves.
state_doc=''

# The revision sets, filled by diff_revision.
previous_units=()
previous_secrets_json='{}'
previous_plan=false
previous_state=false
previous_commit=
# The health check's verdict, set by app_health; the failure reason journals it.
health_unit=
health_state=
failure_reason=
intended_units=()
intended_secrets=()
intended_apps=()
new_apps=()
changed_apps=()
departed_apps=()


# The image installs the modules under /usr/libexec/deploy/apps; a checkout has
# them beside this script itself.
apps_lib=$self_dir/deploy/apps
[[ -d $apps_lib ]] || {
  printf 'deploy-apps: missing module directory %s\n' "$apps_lib" >&2
  exit 1
}
for _module in transport secrets render state apply commands; do
  # shellcheck source=/dev/null
  source "$apps_lib/$_module.sh"
done
unset _module
cmd_revert() {
  deploy_state_init || {
    warn "cannot create $deploy_state_dir"
    return 4
  }
  require_tenant || return 1
  deadline=$(($(date -u +%s) + apps_budget))
  if ! record_exists apply; then
    say "no apps apply to revert"
    return 0
  fi
  revert_apply || return 1
  return 0
}

case ${1-} in
  apply)
    shift
    rc=0
    cmd_apply "$@" || rc=$?
    exit "$rc"
    ;;
  revert)
    shift
    rc=0
    cmd_revert "$@" || rc=$?
    exit "$rc"
    ;;
  sweep)
    shift
    rc=0
    cmd_sweep "$@" || rc=$?
    exit "$rc"
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    usage
    exit 2
    ;;
esac
