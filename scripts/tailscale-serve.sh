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
plan=${APPS_PLAN:-/var/lib/homelab/apps/plan.json}

# Same grammar the renderer enforces, repeated because this file acts on the
# plan without trusting that it was rendered by a trusted revision.
app_name_re='^[a-z]([a-z0-9-]{0,29}[a-z0-9])?$'
loopback_min=20000
loopback_max=29999

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

# Validate the whole plan before touching Serve: a plan that names a foreign
# path or port must leave the previous routes untouched, not apply half of it.
declare -A app_routes=()
if [[ -e $plan ]]; then
  [[ -f $plan ]] || fail "$plan is not a regular file"
  jq -e 'type == "object" and ((.apps // {}) | type) == "object"' "$plan" >/dev/null 2>&1 \
    || fail "$plan is not a tenant plan"
  while IFS=$'\t' read -r name path port kind reachable; do
    [[ $reachable == true ]] || continue
    [[ $name =~ $app_name_re ]] || fail "invalid app name in $plan: $name"
    [[ $path == "/apps/$name" ]] || fail "app $name: base path is $path, not /apps/$name"
    [[ $kind == number ]] || fail "app $name: loopback port is not a number: $port"
    ((port >= loopback_min && port <= loopback_max)) \
      || fail "app $name: loopback port $port is outside $loopback_min-$loopback_max"
    app_routes[$path]=$port
  done < <(
    jq -r '(.apps // {}) | to_entries[]
      | [.key, (.value.basePath // ""), (.value.loopbackPort // "" | tostring),
         (.value.loopbackPort | type), (.value.reachable // false)]
      | @tsv' "$plan"
  )
fi

status=$("$tailscale_bin" serve status --json) || fail "cannot read Serve status"

# An app that left the plan, or the whole tenant, leaves no route behind. Only
# `/apps/` handlers on 443 are ours: the root paths belong to the core apps.
while IFS= read -r path; do
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

for path in "${!app_routes[@]}"; do
  backend=http://127.0.0.1:${app_routes[$path]}
  if ! "$tailscale_bin" serve --bg --https=443 --set-path="$path" "$backend"; then
    fail "could not serve $backend on https/443$path"
  fi
done

"$tailscale_bin" serve status
