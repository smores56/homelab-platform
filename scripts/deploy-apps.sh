#!/usr/bin/env bash
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
# one. Every knob is environment-overridable so tests/deploy/apps.sh can drive this
# exact code. Production sets none of them: the defaults are the host contract,
# not a way to skip a check.
#
# shellcheck disable=SC2154  # deploy-state.sh assigns these at source time
set -euo pipefail

self_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# The image installs the library as /usr/libexec/deploy-state (the smortress-src
# loop strips the `.sh`); a checkout has it beside this script.
state_lib=${DEPLOY_STATE_LIB:-}
if [[ -z $state_lib ]]; then
  if [[ -r /usr/libexec/deploy-state ]]; then
    state_lib=/usr/libexec/deploy-state
  else
    state_lib=$self_dir/deploy-state.sh
  fi
fi
[[ -r $state_lib ]] || {
  printf 'deploy-apps: no state library at %s\n' "$state_lib" >&2
  exit 1
}
# shellcheck source=/dev/null
source "$state_lib"

# $PATH is consulted first so a test can put a stand-in in front of an installed
# tool without touching /usr/libexec; root's PATH does not contain /usr/libexec,
# so on the host the installed name wins.
resolve_tool() { # <env override> <installed name> <checkout file>
  local override=${1:-} name=$2 sibling=$3 found
  if [[ -n $override ]]; then
    printf '%s\n' "$override"
    return 0
  fi
  if found=$(command -v "$name" 2>/dev/null); then
    printf '%s\n' "$found"
    return 0
  fi
  if [[ -x /usr/libexec/$name ]]; then
    printf '%s\n' "/usr/libexec/$name"
    return 0
  fi
  printf '%s\n' "$sibling"
}

schema_bin=$(resolve_tool "${APPS_SCHEMA:-}" apps-schema "$self_dir/apps-schema.py")

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
serve_timeout=${APPS_SERVE_TIMEOUT:-180}

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
intended_units=()
intended_secrets=()
intended_apps=()
new_apps=()
changed_apps=()
departed_apps=()

say() { printf 'deploy-apps: %s\n' "$*"; }
warn() { printf 'deploy-apps: %s\n' "$*" >&2; }

usage() {
  cat >&2 <<'EOF'
usage: deploy-apps apply --commit <40-hex>
       deploy-apps revert

  apply   fetch, validate, render and install one homelab-apps commit
  revert  restore the revision recorded in apply.json, or do nothing
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

# `systemctl --user` reaches the tenant's manager over its private socket, which
# needs no session bus: that is why the unit can widen /run/user and stop there.
user_ctl() { # <args...>
  tenant_bounded "$(cap_of "$ctl_timeout")" "$systemctl_bin" --user "$@"
}

system_ctl() { # <verb> <unit>
  bounded "$ctl_timeout" "$systemctl_bin" "$1" "$2"
}

secret_value() { # <podman name>  -> the value bytes on stdout
  # `--showsecret` is the only way to read a value back, and it prints the value
  # plus one newline: dropping exactly that byte keeps a restore byte-exact (a
  # value that really ends in a newline keeps it).
  tenant_bounded "$(cap_of "$ctl_timeout")" "$podman_bin" secret inspect --showsecret \
    --format '{{.SecretData}}' "$1" 2>/dev/null | head -c -1
}

secret_create() { # <podman name> <file holding the value>
  tenant_bounded "$(cap_of "$ctl_timeout")" "$podman_bin" secret create --replace \
    "$1" - >/dev/null <"$2"
}

# Removal is best effort: a secret that is already gone is the state the caller
# asked for, and a value a running container still mounts cannot be removed.
secret_remove() { # <podman name>
  tenant_bounded "$(cap_of "$ctl_timeout")" "$podman_bin" secret rm "$1" >/dev/null 2>&1 || true
}

# A secret name becomes a path under work/, so only what the renderer can emit is
# accepted; anything else is a plan this script refuses to act on.
secret_name_ok() {
  [[ $1 =~ ^[a-z0-9][a-z0-9._-]*$ ]]
}

# --- work tree ---------------------------------------------------------------
work_dir_for() { printf '%s/apps-%s\n' "$deploy_work_dir" "$1"; }

# Only a path this script minted is ever removed: apply.json is a file an operator
# can edit, and `rm -rf "$(jq -r .work apply.json)"` on a wrong path is how a
# state directory becomes a catastrophe.
cleanup_work() { # <dir>
  local dir=${1:-}
  [[ -n $dir ]] || return 0
  case $dir in
    "$deploy_work_dir"/apps-*) ;;
    *)
      warn "refusing to remove $dir: not a work tree of this deploy"
      return 1
      ;;
  esac
  rm -rf -- "$dir" || return 1
  sync -- "$deploy_work_dir" 2>/dev/null || true
  return 0
}

# --- fetch, decrypt, render --------------------------------------------------
fetch_commit() { # <commit> <dest>
  bounded "$fetch_timeout" "$curl_bin" --fail --silent --show-error --location \
    --connect-timeout 30 --retry 2 --output "$2" "$apps_fetch_base/$1"
}

# 0: wrote <out>; 10: the commit carries no tenant secrets; 1: cannot decrypt.
decrypt_tenant_secrets() { # <tree> <out>
  local src=$1/secrets.sops.json out=$2 rc=0
  if [[ ! -e $src ]]; then
    return 10
  fi
  [[ -s $src ]] || {
    warn "$src is empty"
    return 1
  }
  [[ -s $age_key ]] || {
    warn "$age_key is missing; stage the age identity from the recovery kit"
    return 1
  }
  SOPS_AGE_KEY_FILE="$age_key" bounded "$sops_timeout" "$sops_bin" --decrypt \
    --input-type json --output-type json "$src" >"$out.tmp" || rc=$?
  if ((rc != 0)); then
    warn "cannot decrypt $src with $age_key"
    rm -f -- "$out.tmp"
    return 1
  fi
  chmod 0600 "$out.tmp" || return 1
  mv -f -- "$out.tmp" "$out"
}

render_commit() { # <tree> <secrets|""> <out>
  local -a args=(render --root "$1" --out "$3")
  if [[ -n $2 ]]; then args+=(--secrets "$2"); fi
  # --allow-empty is the deploy's alone, and it is unconditional here: an empty
  # `apps/` the validator accepted is a tenant an operator emptied, and without
  # the flag the last app could never be removed. A missing or unreadable `apps/`
  # is still refused by the validator that ran above.
  args+=(--allow-empty)
  bounded "$schema_timeout" "$schema_bin" "${args[@]}"
}

# --- free space --------------------------------------------------------------
# df reports 1K blocks; the available column is the fourth field of the second
# line in the POSIX form.
available_bytes() { # <path>
  local blocks
  blocks=$(bounded "$df_timeout" "$df_bin" -P -k -- "$1" | awk 'NR == 2 { print $4 }') || return 1
  [[ $blocks =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$((blocks * 1024))"
}

check_space() {
  local pair path need got
  for pair in "$home_path:$home_need" "$root_path:$root_need" "$var_path:$var_need"; do
    path=${pair%%:*}
    need=${pair##*:}
    if ! got=$(available_bytes "$path"); then
      warn "cannot read the free space on $path"
      return 1
    fi
    if ((got < need)); then
      warn "$path has $got bytes free, below the $need byte floor for an apps apply"
      return 1
    fi
  done
  return 0
}

# --- the plan and its consumers ----------------------------------------------
install_plan() { # <file>
  install -d -m 0700 "$(dirname -- "$apps_plan")" || return 1
  atomic_write "$apps_plan" <"$1"
}

plan_apps() { # <plan> -> one name per line
  jq -r '(.apps // {}) | keys[]' "$1"
}

plan_units() { # <render dir> -> one unit basename per line
  local file
  for file in "$1"/*.container "$1"/*.network; do
    [[ -f $file ]] || continue
    basename -- "$file"
  done
}

app_unit() { printf '%s.container\n' "$1"; }
app_service() { printf '%s.service\n' "$1"; }

in_list() { # <needle> <haystack...>
  local needle=$1 item
  shift
  for item in "$@"; do
    [[ $item == "$needle" ]] && return 0
  done
  return 1
}

json_list() {
  if (($# == 0)); then
    printf '[]\n'
    return 0
  fi
  jq -nc '$ARGS.positional' --args -- "$@"
}

# --- snapshots and hashes ----------------------------------------------------
snapshot_previous() {
  local file base pname
  previous_units=()
  previous_secrets_json='{}'
  previous_plan=false
  previous_state=false
  previous_commit=$(deployed_commit homelab-apps 2>/dev/null) || previous_commit=""
  install -d -m 0700 "$work/render.prev" "$work/prev-secrets" || return 1
  # The plan's exact installed bytes: a revert puts them back rather than
  # re-rendering a commit the host no longer has.
  if [[ -f $apps_plan && ! -L $apps_plan ]]; then
    cp -- "$apps_plan" "$work/render.prev/plan.json" || return 1
    previous_plan=true
  fi
  # state.json is part of the revision the revert restores: the record is
  # written before apply.json is cleared, so a failure between the two leaves a
  # host on one revision and a state naming another.
  if [[ -f $deploy_state_file && ! -L $deploy_state_file ]]; then
    cp -- "$deploy_state_file" "$work/render.prev/state.json" || return 1
    previous_state=true
  fi
  # The units: exactly the files this platform rendered (its marker is in the
  # first line). A foreign file in the tenant's unit dir is left alone, never
  # removed and never restored -- it is the tenant's, not this deploy's.
  if [[ -d $apps_unit_dir ]]; then
    for file in "$apps_unit_dir"/*.container "$apps_unit_dir"/*.network; do
      [[ -f $file && ! -L $file ]] || continue
      head -n 1 -- "$file" 2>/dev/null | grep -qF -- "$render_marker" || continue
      base=$(basename -- "$file")
      cp -- "$file" "$work/render.prev/$base" || return 1
      previous_units+=("$base")
    done
  fi
  # The secret values: `create --replace` cannot be undone, so the old value is
  # captured before it is replaced. Every one the installed plan names is taken,
  # because which ones change is only known after the render.
  if [[ -f $apps_plan && ! -L $apps_plan ]]; then
    while IFS= read -r pname; do
      [[ -n $pname ]] || continue
      secret_name_ok "$pname" || {
        warn "$apps_plan names an unusable secret: $pname"
        return 1
      }
      if secret_value "$pname" >"$work/prev-secrets/$pname"; then
        chmod 0600 "$work/prev-secrets/$pname" || return 1
        previous_secrets_json=$(jq -c --arg n "$pname" --arg p "prev-secrets/$pname" \
          '. + {($n): $p}' <<<"$previous_secrets_json")
      else
        # The plan and the store disagree. Recording the absence makes a revert
        # remove what the failed commit created instead of inventing a value.
        rm -f -- "$work/prev-secrets/$pname"
        previous_secrets_json=$(jq -c --arg n "$pname" '. + {($n): null}' <<<"$previous_secrets_json")
      fi
    done < <(jq -r '(.apps // {}) | .[] | (.secretNames // {}) | .[]' "$apps_plan" | sort -u)
  fi
  return 0
}

file_hash() { # <file>
  sha256sum <"$1" | cut -d' ' -f1
}

secret_file() { printf '%s/secrets/%s\n' "$work" "$1"; }

secret_hash() { # <podman name>
  local file
  file=$(secret_file "$1")
  if [[ -f $file ]]; then file_hash "$file"; else printf 'absent\n'; fi
}

unit_hash() { # <app>
  local file
  file=$work/render.next/$(app_unit "$1")
  if [[ -f $file ]]; then file_hash "$file"; else printf 'absent\n'; fi
}

# A hash over the app's secret *names and values*, so a rotation and a rename are
# both a change even when the unit file is identical.
app_secret_hash() { # <app>
  local pname out=''
  while IFS= read -r pname; do
    [[ -n $pname ]] || continue
    out+="$pname $(secret_hash "$pname")"$'\n'
  done < <(jq -r --arg n "$1" '(.apps[$n].secretNames // {}) | .[]' "$work/render.next/plan.json")
  printf '%s' "$out" | sha256sum | cut -d' ' -f1
}

# The table state.json keeps: one entry per app plus the whole-set hashes, which
# is what `status` reports and what the next apply compares against.
build_apps_state() {
  local apps='{}' name units_hash secrets_hash
  while IFS= read -r name; do
    [[ -n $name ]] || continue
    apps=$(jq -c --arg n "$name" --arg u "$(unit_hash "$name")" --arg s "$(app_secret_hash "$name")" \
      '. + {($n): {unit:$u, secrets:$s}}' <<<"$apps")
  done < <(plan_apps "$work/render.next/plan.json")
  units_hash=$(jq -r 'to_entries[] | "\(.key) \(.value.unit)"' <<<"$apps" | sort | sha256sum | cut -d' ' -f1)
  secrets_hash=$(jq -r 'to_entries[] | "\(.key) \(.value.secrets)"' <<<"$apps" | sort | sha256sum | cut -d' ' -f1)
  jq -nc --argjson apps "$apps" --arg u "$units_hash" --arg s "$secrets_hash" \
    '{unitsHash:$u,secretsHash:$s,apps:$apps}'
}

state_apps_write() { # <apps table>
  local current
  current=$(state_read 2>/dev/null) || current='{}'
  jq -c --argjson apps "$1" --arg now "$(deploy_now)" '
    . as $s
    | {schema: ($s.schema // 1), repos: ($s.repos // {}), apps: $apps, updated: $now}
  ' <<<"$current" | atomic_write "$deploy_state_file"
}

# --- the revision's differences ----------------------------------------------
diff_revision() {
  local name old_unit old_secrets unit
  local -a installed=()
  intended_units=()
  intended_apps=()
  intended_secrets=()
  new_apps=()
  changed_apps=()
  departed_apps=()
  mapfile -t intended_units < <(plan_units "$work/render.next")
  mapfile -t intended_apps < <(plan_apps "$work/render.next/plan.json")
  mapfile -t intended_secrets < <(
    jq -r '(.apps // {}) | .[] | (.secretNames // {}) | .[]' "$work/render.next/plan.json" | sort -u
  )
  # What is installed is the unit set the snapshot found, not the state record:
  # the state may describe a revision whose units were never written.
  for unit in "${previous_units[@]}"; do
    [[ $unit == *.container ]] || continue
    installed+=("${unit%.container}")
  done
  for name in "${intended_apps[@]}"; do
    if ! in_list "$name" "${installed[@]}"; then
      new_apps+=("$name")
      continue
    fi
    # A restart is needed when the unit or any value it mounts moved:
    # `create --replace` leaves a running container on the old value, so a
    # secret-only rotation is a restart too.
    old_unit=$(jq -r --arg n "$name" '.apps.apps[$n].unit // ""' <<<"$state_doc")
    old_secrets=$(jq -r --arg n "$name" '.apps.apps[$n].secrets // ""' <<<"$state_doc")
    if [[ $old_unit != "$(unit_hash "$name")" || $old_secrets != "$(app_secret_hash "$name")" ]]; then
      changed_apps+=("$name")
    fi
  done
  for name in "${installed[@]}"; do
    in_list "$name" "${intended_apps[@]}" || departed_apps+=("$name")
  done
  return 0
}

# The images the revision changes, one `<app>\t<image>` per line: an unchanged
# digest is already in the store, and pulling it again on every apply would make
# a secret rotation wait for the registry.
changed_images() {
  local name image previous
  while IFS=$'\t' read -r name image; do
    [[ -n $name ]] || continue
    previous=''
    if [[ -f $apps_plan ]]; then
      previous=$(jq -r --arg n "$name" '.apps[$n].image // ""' "$apps_plan" 2>/dev/null) || previous=''
    fi
    [[ $previous == "$image" ]] && continue
    printf '%s\t%s\n' "$name" "$image"
  done < <(jq -r '(.apps // {}) | to_entries[] | [.key, .value.image] | @tsv' \
    "$work/render.next/plan.json")
}

pull_ref() { # <image> -> <repo>@sha256:<digest>
  local image=$1 repo digest
  [[ $image == *@* ]] || return 1
  repo=${image%@*}
  digest=${image##*@}
  [[ $repo == */* && $digest =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
  printf '%s@%s\n' "$repo" "$digest"
}

# --- mutations ---------------------------------------------------------------
# Each of these changes the host, so the caller reverts on the first failure.

# The record a crash is reverted from: the phase, the two unit sets, whether a
# previous plan exists, and where the previous secret values were saved.
write_apply() { # <phase>
  jq -nc --arg phase "$1" --arg commit "$commit" --arg previous "${previous_commit:-}" \
    --arg work "$work" --argjson previousUnits "$(json_list "${previous_units[@]}")" \
    --argjson intendedUnits "$(json_list "${intended_units[@]}")" \
    --argjson previousPlan "$previous_plan" --argjson previousState "$previous_state" \
    --argjson previousSecrets "$previous_secrets_json" \
    --argjson intendedSecrets "$(json_list "${intended_secrets[@]}")" \
    --arg at "$(deploy_now)" \
    '{schema:1,phase:$phase,commit:$commit,previousCommit:$previous,work:$work,
      previousUnits:$previousUnits,intendedUnits:$intendedUnits,previousPlan:$previousPlan,
      previousState:$previousState,previousSecrets:$previousSecrets,
      intendedSecrets:$intendedSecrets,startedAt:$at}' |
    apply_write
}

install_units() {
  local unit
  tenant mkdir -p -- "$apps_unit_dir" || return 1
  for unit in "${intended_units[@]}"; do
    tenant_install "$work/render.next/$unit" "$apps_unit_dir/$unit" || return 1
  done
  return 0
}

remove_departed_units() {
  local name
  for name in "${departed_apps[@]}"; do
    tenant_remove "$apps_unit_dir/$(app_unit "$name")" || return 1
  done
  # The internal network unit goes when nothing needs it any more: render emits it
  # only while an app with egress = "none" exists.
  if [[ -f $apps_unit_dir/smortress-apps.network &&
    ! -f $work/render.next/smortress-apps.network ]]; then
    tenant_remove "$apps_unit_dir/smortress-apps.network" || return 1
  fi
  return 0
}

create_changed_secrets() {
  local pname
  for pname in "${intended_secrets[@]}"; do
    if [[ ! -f $(secret_file "$pname") ]]; then
      warn "the render names the secret $pname but no value was resolved"
      return 1
    fi
    # `create --replace` and not `rm` then `create`: a secret a running container
    # still mounts cannot be removed.
    secret_create "$pname" "$(secret_file "$pname")" || return 1
  done
  return 0
}

remove_departed_secrets() {
  local name pname
  for name in "${departed_apps[@]}"; do
    while IFS= read -r pname; do
      [[ -n $pname ]] || continue
      in_list "$pname" "${intended_secrets[@]}" && continue
      secret_remove "$pname"
    done < <(jq -r --arg n "$name" '(.apps[$n].secretNames // {}) | .[]' \
      "$work/render.prev/plan.json" 2>/dev/null || true)
  done
  return 0
}

start_new_apps() {
  local name
  for name in "${new_apps[@]}"; do
    user_ctl start "$(app_service "$name")" || return 1
  done
  return 0
}

restart_changed_apps() {
  local name
  for name in "${changed_apps[@]}"; do
    user_ctl restart "$(app_service "$name")" || return 1
  done
  return 0
}

stop_departed_apps() {
  local name
  for name in "${departed_apps[@]}"; do
    user_ctl stop "$(app_service "$name")" || return 1
  done
  return 0
}

# The ingress helper reads the installed plan for the loopback port it binds and
# the container port it forwards to, so it follows its app by name.
apply_ingress() {
  local name
  for name in "${new_apps[@]}"; do
    system_ctl start "$ingress_template$name" || return 1
  done
  for name in "${changed_apps[@]}"; do
    system_ctl restart "$ingress_template$name" || return 1
  done
  for name in "${departed_apps[@]}"; do
    system_ctl stop "$ingress_template$name" || return 1
  done
  return 0
}

apply_mutations() {
  # The plan first: the quota applier and Serve both re-read it, and neither may
  # act on the previous revision once a container of the new one exists.
  install_plan "$work/render.next/plan.json" || return 1
  journal_append apps-plan-installed "$(jq -nc --arg commit "$commit" \
    --argjson apps "$(json_list "${intended_apps[@]}")" '{commit:$commit,apps:$apps}')" ||
    warn "cannot journal the installed plan"
  # A RemainAfterExit unit: `start` is a no-op and only a restart makes it read
  # the new plan. It creates the new apps' directories and project quotas before
  # anything starts, so a new app is never unquoted.
  system_ctl restart "$quota_unit" || return 1
  journal_append apps-quota-applied "$(jq -nc --arg commit "$commit" '{commit:$commit}')" ||
    warn "cannot journal the quota restart"

  install_units || return 1
  remove_departed_units || return 1
  create_changed_secrets || return 1
  user_ctl daemon-reload || return 1
  start_new_apps || return 1
  restart_changed_apps || return 1
  # A departed app is stopped before its secrets are removed: a value a running
  # container still mounts cannot be removed.
  stop_departed_apps || return 1
  remove_departed_secrets || return 1
  apply_ingress || return 1
  return 0
}

restart_serve() { # <reason>
  local rc=0
  bounded "$serve_timeout" "$systemctl_bin" restart "$serve_unit" || rc=$?
  if ((rc != 0)); then
    journal_append apps-serve-failed "$(jq -nc --arg commit "$commit" --argjson exit "$rc" \
      --arg reason "$1" '{commit:$commit,exit:$exit,reason:$reason}')" ||
      warn "cannot journal the failed Serve restart"
    warn "Serve did not regenerate (exit $rc); the routes stay as they were"
  fi
  return "$rc"
}

# --- revert ------------------------------------------------------------------
# Restores the revision apply.json recorded and clears the record. Idempotent:
# the units and the plan are written from the saved tree, so a second run after a
# crash in the middle of a revert finishes the same work.
revert_apply() {
  local doc phase dir render_prev rc=0 pname path name current
  local -a previous=() intended=() saved=()
  doc=$(apply_read) || {
    warn "cannot read $deploy_state_dir/apply.json"
    return 1
  }
  phase=$(jq -r '.phase // "installing"' <<<"$doc") || phase=installing
  dir=$(jq -r '.work // ""' <<<"$doc") || dir=""
  render_prev=$dir/render.prev
  mapfile -t previous < <(jq -r '.previousUnits[]?' <<<"$doc" 2>/dev/null || true)
  mapfile -t intended < <(jq -r '.intendedUnits[]?' <<<"$doc" 2>/dev/null || true)
  current=$(jq -r '.commit // ""' <<<"$doc") || current=""

  if [[ $phase == pulling ]]; then
    # Nothing outside the image store was touched yet, and the store is not a
    # revision: there is nothing to put back.
    journal_append apps-reverted "$(jq -nc --arg commit "$current" --arg phase "$phase" \
      '{commit:$commit,phase:$phase,mutated:false}')" || warn "cannot journal the revert"
    cleanup_work "$dir" || warn "cannot remove $dir"
    record_clear apply || warn "cannot clear the apply record"
    say "cleared an interrupted pull; the installed revision was untouched"
    return 0
  fi

  if [[ -z $dir || ! -d $render_prev ]]; then
    # Without the saved tree there is nothing to restore, and deleting the record
    # would make the next boot believe the host is consistent.
    journal_append apps-revert-failed "$(jq -nc --arg work "$dir" --arg commit "$current" \
      '{reason:"no-saved-tree",work:$work,commit:$commit}')" ||
      warn "cannot journal the failed revert"
    warn "cannot revert: $render_prev is missing"
    return 1
  fi

  # 1. The previous units back, and away with the ones the failed apply added.
  for name in "${previous[@]}"; do
    [[ -f $render_prev/$name ]] || continue
    tenant_install "$render_prev/$name" "$apps_unit_dir/$name" || rc=1
  done
  for name in "${intended[@]}"; do
    in_list "$name" "${previous[@]}" && continue
    tenant_remove "$apps_unit_dir/$name" || rc=1
  done

  # 2. The previous plan, then the quota applier for it, before any container of
  # the restored revision is started.
  if [[ $(jq -r '.previousPlan // false' <<<"$doc") == true && -f $render_prev/plan.json ]]; then
    install_plan "$render_prev/plan.json" || rc=1
  else
    rm -f -- "$apps_plan" || rc=1
  fi
  system_ctl restart "$quota_unit" || rc=1

  # 2b. The state document, so a revert leaves nothing claiming the new commit
  # or the new content hashes.
  if [[ $(jq -r '.previousState // false' <<<"$doc") == true && -f $render_prev/state.json ]]; then
    atomic_write "$deploy_state_file" <"$render_prev/state.json" || rc=1
  else
    rm -f -- "$deploy_state_file" || rc=1
  fi

  # 3. The previous secret values. A saved value that is a null path names a
  # secret the previous plan wanted and the store did not hold, so it is left out.
  while IFS=$'\t' read -r pname path; do
    [[ -n $pname ]] || continue
    if [[ -n $path && -f $dir/$path ]]; then
      secret_create "$pname" "$dir/$path" || rc=1
    else
      secret_remove "$pname"
    fi
  done < <(jq -r '(.previousSecrets // {}) | to_entries[] | [.key, (.value // "")] | @tsv' <<<"$doc")

  # 4. The apps themselves.
  user_ctl daemon-reload || rc=1
  for name in "${intended[@]}"; do
    in_list "$name" "${previous[@]}" && continue
    [[ $name == *.container ]] || continue
    name=${name%.container}
    user_ctl stop "$(app_service "$name")" || rc=1
    system_ctl stop "$ingress_template$name" || rc=1
  done
  # Only after their containers are gone: a secret a running container mounts
  # cannot be removed.
  mapfile -t saved < <(jq -r '(.previousSecrets // {}) | keys[]' <<<"$doc")
  while IFS= read -r pname; do
    [[ -n $pname ]] || continue
    in_list "$pname" "${saved[@]}" && continue
    secret_remove "$pname"
  done < <(jq -r '.intendedSecrets[]?' <<<"$doc" 2>/dev/null || true)
  for name in "${previous[@]}"; do
    [[ $name == *.container ]] || continue
    name=${name%.container}
    if in_list "${name}.container" "${intended[@]}"; then
      user_ctl restart "$(app_service "$name")" || rc=1
      system_ctl restart "$ingress_template$name" || rc=1
    else
      user_ctl start "$(app_service "$name")" || rc=1
      system_ctl start "$ingress_template$name" || rc=1
    fi
  done

  # 5. Serve, so the routes match the plan that is installed again.
  bounded "$serve_timeout" "$systemctl_bin" restart "$serve_unit" || rc=1

  if ((rc != 0)); then
    journal_append apps-revert-failed "$(jq -nc --arg commit "$current" --arg phase "$phase" \
      '{commit:$commit,phase:$phase,reason:"restore-incomplete"}')" ||
      warn "cannot journal the failed revert"
    warn "the previous revision was not fully restored; the record is kept"
    return 1
  fi
  journal_append apps-reverted "$(jq -nc --arg commit "$current" --arg phase "$phase" \
    --argjson units "$(json_list "${previous[@]}")" \
    '{commit:$commit,phase:$phase,mutated:true,units:$units}')" || warn "cannot journal the revert"
  # The record goes last: a crash before this leaves it, and the next gate or
  # drain repeats an idempotent revert instead of forgetting it.
  cleanup_work "$dir" || warn "cannot remove $dir"
  record_clear apply || {
    warn "cannot clear the apply record"
    return 1
  }
  say "restored the previous revision"
  return 0
}

# --- commands ----------------------------------------------------------------
# Resolve the tenant SOPS values into root-only files under work/secrets: the
# rendered units mount them by name, and a hash, a `create --replace` and a
# restore then read the same bytes.
resolve_secret_values() { # <plan> <secrets json|"">
  local secrets=$2 app key pname
  mkdir -p "$work/secrets" || return 1
  chmod 0700 "$work/secrets" || return 1
  [[ -n $secrets ]] || return 0
  while IFS=$'\t' read -r app key pname; do
    [[ -n $app && -n $key && -n $pname ]] || continue
    secret_name_ok "$pname" || {
      warn "the render names an unusable secret: $pname"
      return 1
    }
    # The tenant file's shape is `apps.<app>.<key>`, and the renderer refuses a
    # definition that names a key its own section does not declare; a missing
    # value here is a ciphertext that decrypted to nothing, which must not become
    # an empty secret.
    # `-j` writes the string's own bytes and adds nothing: a value that ends in a
    # newline keeps it, so a snapshot taken from the store restores it exactly.
    jq -j --arg a "$app" --arg k "$key" '.apps[$a][$k] // empty' "$secrets" \
      >"$(secret_file "$pname").tmp" 2>/dev/null || true
    if [[ ! -s $(secret_file "$pname").tmp ]]; then
      warn "the tenant SOPS file has no value for $app/$key"
      rm -f -- "$(secret_file "$pname").tmp"
      return 1
    fi
    chmod 0600 "$(secret_file "$pname").tmp" || return 1
    mv -f -- "$(secret_file "$pname").tmp" "$(secret_file "$pname")" || return 1
  done < <(jq -r '(.apps // {}) | to_entries[] | .key as $a
    | (.value.secretNames // {}) | to_entries[] | [$a, .key, .value] | @tsv' "$1")
  return 0
}

cmd_apply() {
  local commit_arg='' secrets='' rc=0 name ref image_ref reason='' pull_rc=0 apps_state=''
  local -a validate_args=()
  while (($#)); do
    case $1 in
      --commit)
        commit_arg=${2-}
        shift 2
        ;;
      *) usage; return 2 ;;
    esac
  done
  if [[ ! $commit_arg =~ ^[0-9a-f]{40}$ ]]; then
    warn "--commit must be a 40-character lowercase hex sha"
    usage
    return 2
  fi
  commit=$commit_arg
  deploy_state_init || {
    warn "cannot create $deploy_state_dir"
    return 4
  }
  require_tenant || return 4
  deadline=$(($(date -u +%s) + apps_budget))

  # An interrupted apply is reconciled first: the "previous" revision this apply
  # snapshots would otherwise be half of two revisions.
  if record_exists apply; then
    say "an apps apply was interrupted; reverting it first"
    revert_apply || {
      warn "cannot revert the interrupted apply; not starting another"
      return 4
    }
  fi

  # The listener and the drain already refuse a commit the state records, but a
  # hand-run apply must not restart a healthy tenant for a commit it has.
  if [[ $(deployed_commit homelab-apps 2>/dev/null || true) == "$commit" ]]; then
    journal_append already-deployed "$(jq -nc --arg repo homelab-apps --arg commit "$commit" \
      '{repo:$repo,commit:$commit}')" || warn "cannot journal the already-deployed commit"
    say "$commit is already deployed"
    return 0
  fi

  work=$(work_dir_for "$commit")
  journal_append apps-start "$(jq -nc --arg commit "$commit" '{commit:$commit}')" || {
    warn "cannot journal the apply start"
    return 4
  }
  cleanup_work "$work" || return 4
  install -d -m 0700 "$work/tree" "$work/secrets" || return 4

  # 1. Fetch, then work from the extracted tree only. The tarball is only kept
  # until the tree is there.
  if ! fetch_commit "$commit" "$work/commit.tar.gz"; then
    warn "cannot fetch $apps_fetch_base/$commit"
    cleanup_work "$work" || true
    return 4
  fi
  if ! bounded "$tar_timeout" "$tar_bin" -xzf "$work/commit.tar.gz" -C "$work/tree" \
    --strip-components=1; then
    warn "cannot extract the commit tarball"
    cleanup_work "$work" || true
    return 4
  fi
  rm -f -- "$work/commit.tar.gz" || true

  # 2. Decrypt the tenant SOPS file once: the validator needs its key names and
  # the apply needs its values, and neither may read the ciphertext twice.
  rc=0
  decrypt_tenant_secrets "$work/tree" "$work/secrets.json" || rc=$?
  case $rc in
    0) secrets=$work/secrets.json ;;
    # No tenant SOPS file: a definition that references a secret is then refused
    # by the validator, which is the right outcome rather than an empty value.
    10) secrets='' ;;
    *)
      cleanup_work "$work" || true
      return 4
      ;;
  esac

  # 3. Validate, then render. A rejected definition never reaches the installed
  # plan, and the commit is denylisted so the poll stops re-enqueueing it.
  validate_args=(validate --root "$work/tree")
  if [[ -n $secrets ]]; then validate_args+=(--secrets "$secrets"); fi
  if ! bounded "$schema_timeout" "$schema_bin" "${validate_args[@]}" >"$work/validate.log" 2>&1; then
    sed -e 's/^/deploy-apps: /' "$work/validate.log" >&2 || true
    journal_append apps-rejected "$(jq -nc --arg commit "$commit" --arg reason definition-rejected \
      '{commit:$commit,reason:$reason}')" || warn "cannot journal the rejection"
    denylist_add commit "$commit" apps:definition-rejected || warn "cannot denylist $commit"
    deploy_notify fail apps-definition-rejected || warn "could not report the rejection"
    warn "$commit is rejected by the schema; the installed plan is untouched"
    cleanup_work "$work" || true
    return 3
  fi
  if ! render_commit "$work/tree" "$secrets" "$work/render.next" >"$work/render.log" 2>&1; then
    sed -e 's/^/deploy-apps: /' "$work/render.log" >&2 || true
    # Rendering failed after validation passed: that is this environment (a full
    # disk, an unwritable work tree), not the commit, so nothing is denylisted and
    # the entry is retried.
    warn "cannot render $commit"
    cleanup_work "$work" || true
    return 4
  fi

  # 4. Resolve the values the rendered units mount.
  if ! resolve_secret_values "$work/render.next/plan.json" "$secrets"; then
    cleanup_work "$work" || true
    return 4
  fi

  # 5. Free space, then the record, then the pull: a host that cannot hold the
  # images must not be half-applied.
  if ! check_space; then
    cleanup_work "$work" || true
    return 4
  fi
  state_doc=$(state_read 2>/dev/null) || state_doc='{}'
  snapshot_previous || {
    warn "cannot snapshot the installed revision"
    cleanup_work "$work" || true
    return 4
  }
  diff_revision
  if ! write_apply pulling; then
    warn "cannot write $deploy_state_dir/apply.json"
    cleanup_work "$work" || true
    return 4
  fi
  journal_append apps-apply-recorded "$(jq -nc --arg commit "$commit" --arg phase pulling \
    --argjson new "$(json_list "${new_apps[@]}")" --argjson changed "$(json_list "${changed_apps[@]}")" \
    --argjson departed "$(json_list "${departed_apps[@]}")" \
    '{commit:$commit,phase:$phase,new:$new,changed:$changed,departed:$departed}')" ||
    warn "cannot journal the apply record"

  while IFS=$'\t' read -r name ref; do
    [[ -n $name ]] || continue
    if ! image_ref=$(pull_ref "$ref"); then
      warn "$name: $ref is not a digest-pinned reference"
      reason="image-not-pinned"
      pull_rc=1
      break
    fi
    say "$name: pulling $image_ref"
    pull_rc=0
    tenant_bounded "$(cap_of "$pull_timeout")" "$podman_bin" pull \
      --signature-policy="$apps_policy" "$image_ref" >/dev/null || pull_rc=$?
    if ((pull_rc != 0)); then
      reason="pull-failed"
      journal_append apps-pull-failed "$(jq -nc --arg commit "$commit" --arg app "$name" \
        --arg image "$image_ref" --argjson exit "$pull_rc" \
        '{commit:$commit,app:$app,image:$image,exit:$exit}')" || warn "cannot journal the failed pull"
      break
    fi
    journal_append apps-pulled "$(jq -nc --arg commit "$commit" --arg app "$name" \
      --arg image "$image_ref" '{commit:$commit,app:$app,image:$image}')" ||
      warn "cannot journal the pull"
  done < <(changed_images)
  if ((pull_rc != 0)); then
    # A pull changes nothing the host runs, so the record goes with it: a failed
    # pull leaves no crash state behind. A pinned digest the registry will not
    # serve is treated as retryable -- an outage and a withdrawn image are
    # indistinguishable here -- and the deploy check names it.
    warn "${reason:-pull-failed}: the installed revision is untouched"
    deploy_notify fail "apps-${reason:-pull-failed}" || warn "could not report the failed pull"
    cleanup_work "$work" || true
    record_clear apply || warn "cannot clear the apply record"
    return 4
  fi

  # 6. Mutate. From here on every failure is reverted.
  if ! write_apply installing; then
    warn "cannot update $deploy_state_dir/apply.json"
    cleanup_work "$work" || true
    record_clear apply || true
    return 4
  fi
  journal_append apps-apply-recorded "$(jq -nc --arg commit "$commit" --arg phase installing \
    --argjson apps "$(json_list "${intended_apps[@]}")" \
    --argjson new "$(json_list "${new_apps[@]}")" --argjson changed "$(json_list "${changed_apps[@]}")" \
    --argjson departed "$(json_list "${departed_apps[@]}")" \
    '{commit:$commit,phase:$phase,apps:$apps,new:$new,changed:$changed,departed:$departed}')" ||
    warn "cannot journal the apply record"

  if ! apply_mutations; then
    warn "the apply failed after it started changing the host; reverting"
    journal_append apps-failed "$(jq -nc --arg commit "$commit" --arg phase restoring \
      '{commit:$commit,phase:$phase,reason:"mutation-failed"}')" || warn "cannot journal the failure"
    revert_apply || warn "the revert did not finish; the record is kept for the next gate"
    deploy_notify fail apps-apply-reverted || warn "could not report the failed apply"
    say "$commit was rolled back to the previous revision"
    return 5
  fi

  # 7. Commit: the content hashes first, then the commit itself, then the tree a
  # revert would have used. Only after that does Serve regenerate.
  if ! apps_state=$(build_apps_state) || ! state_apps_write "$apps_state" ||
    ! state_record_verified homelab-apps "$commit"; then
    warn "cannot record the applied revision"
    revert_apply || warn "the revert did not finish; the record is kept for the next gate"
    deploy_notify fail apps-state-failed || warn "could not report the failed record"
    return 5
  fi
  # The record goes before the saved tree: a crash in between leaves garbage the
  # next apply of this commit removes, while the reverse leaves a boot reverting
  # a revision that already committed. A record that will not clear is a rollback
  # instead -- the state restore is what makes that safe after the commit write.
  if ! record_clear apply; then
    warn "cannot clear the apply record; rolling back so no boot reverts a committed revision"
    revert_apply || warn "the revert did not finish; the record is kept for the next gate"
    deploy_notify fail apps-state-failed || warn "could not report the failed record"
    return 5
  fi
  cleanup_work "$work" || warn "cannot remove $work"
  journal_append apps-applied "$(jq -nc --arg commit "$commit" \
    --argjson apps "$(json_list "${intended_apps[@]}")" \
    --argjson new "$(json_list "${new_apps[@]}")" --argjson changed "$(json_list "${changed_apps[@]}")" \
    --argjson departed "$(json_list "${departed_apps[@]}")" \
    '{commit:$commit,apps:$apps,new:$new,changed:$changed,departed:$departed}')" ||
    warn "cannot journal the applied commit"

  # Serve is a RemainAfterExit oneshot: without this restart a new app has no
  # route and a removed one keeps one. A failure here is a route to fix, not a
  # reason to roll a running revision back -- Serve also fails on unrelated
  # dataset absenteeism -- so the apply stands and the deploy check is paged.
  if ! restart_serve commit; then
    deploy_notify fail apps-serve-failed || warn "could not report the failed Serve restart"
  elif ! deploy_notify success; then
    warn "could not report the deployment to the deploy check"
  fi
  say "$commit is running"
  return 0
}

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
  -h | --help)
    usage
    exit 0
    ;;
  *)
    usage
    exit 2
    ;;
esac
