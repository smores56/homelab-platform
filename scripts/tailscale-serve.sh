#!/usr/bin/env bash
# Declare the Tailscale Serve routes that front the loopback-published
# applications. Serve state lives in tailscaled's state file, which is not part
# of a recovery group and not worth backing up: it is re-declared on every boot.
#
# The core applications own a root path on their own HTTPS port, because none of
# them supports being served under a subpath. Tenant apps from `homelab-apps`
# get one `/apps/<name>` path each on 443 instead: Serve exposes root-path HTTPS
# only on 443, 8443 and 10000, and those are taken. Their loopback ports come
# from the rendered plan, never from a definition, and every path the plan no
# longer names is removed, including when the tenant is empty.
#
# Nothing here is Funnel: Serve answers tailnet clients only.
set -euo pipefail

tailscale_bin=${TAILSCALE_BIN:-tailscale}
schema=${APPS_SCHEMA:-/usr/libexec/apps-schema}
plan=${APPS_PLAN:-/var/lib/homelab/apps/plan.json}

fail() {
  echo "tailscale-serve: $*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is missing"

# https port -> loopback port. 443 Immich, 8443 OPDShelf, 10000 Syncthing GUI.
declare -A core_routes=(
  [443]=2283
  [8443]=8083
  [10000]=8384
)

# Validate the whole plan through the shipped verifier before touching Serve:
# a plan that names a foreign path, a malformed entry or an out-of-range port
# must leave the previous routes untouched, not apply half of it. The verifier
# is the renderer's own, so the two definitions cannot drift apart.
declare -A app_routes=()
plan_ok=true
if [[ -e $plan ]]; then
  if [[ ! -f $plan ]] || ! "$schema" verify-plan --plan "$plan"; then
    # A bad plan must not take the core applications' routes down with it: the
    # declarations below still run, and the unit fails afterwards.
    plan_ok=false
    echo "tailscale-serve: $plan is not a valid tenant plan; core routes only" >&2
  elif ! rows=$(jq -r '(.apps // {}) | to_entries[]
      | [.value.basePath, (.value.loopbackPort | tostring)] | @tsv' "$plan"); then
    plan_ok=false
    echo "tailscale-serve: could not read $plan; core routes only" >&2
  else
    while IFS=$'\t' read -r path port; do
      [[ -n $path && -n $port ]] || continue
      app_routes[$path]=$port
    done <<<"$rows"
  fi
fi

status=$("$tailscale_bin" serve status --json) || fail "cannot read Serve status"

# Every app in the plan is routed; an app that left the plan, or the whole
# tenant, leaves no route behind. Only `/apps/` handlers on 443 are ours: the
# root paths belong to the core apps.
while IFS= read -r path; do
  $plan_ok || break
  [[ -n $path ]] || continue
  [[ -n ${app_routes[$path]+x} ]] && continue
  if ! "$tailscale_bin" serve --https=443 --set-path="$path" off; then
    fail "could not remove the stale route $path"
  fi
done < <(
  jq -r '.Web // {} | to_entries[]
    | select(.key | endswith(":443"))
    | .value.Handlers // {} | keys[]
    | select(startswith("/apps/"))' <<<"$status"
)

for https in "${!core_routes[@]}"; do
  backend=http://127.0.0.1:${core_routes[$https]}
  if ! "$tailscale_bin" serve --bg --https="$https" "$backend"; then
    fail "could not serve $backend on https/$https"
  fi
done

$plan_ok || fail "$plan is not a valid tenant plan"

for path in "${!app_routes[@]}"; do
  backend=http://127.0.0.1:${app_routes[$path]}
  if ! "$tailscale_bin" serve --bg --https=443 --set-path="$path" "$backend"; then
    fail "could not serve $backend on https/443$path"
  fi
done

"$tailscale_bin" serve status
