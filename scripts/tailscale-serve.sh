#!/usr/bin/env bash
# Declare the Tailscale Serve routes that front the loopback-published
# applications. Serve state lives in tailscaled's state file, which is not part
# of a recovery group and not worth backing up: it is re-declared on every boot.
#
# The core applications own a root path on their own HTTPS port, because none of
# them supports being served under a subpath. The two agent gateways are not
# applications with a root path to spare: 443, 8443 and 10000 are taken, so they
# get one fixed path each on 443. Tenant apps from `homelab-apps`
# get one `/apps/<name>` path each on 443 instead: Serve exposes root-path HTTPS
# only on 443, 8443 and 10000, and those are taken. Their loopback ports come
# from the rendered plan, never from a definition, and every path the plan no
# longer names is removed, including when the tenant is empty.
#
# The wallpaper library is a fourth core route and the only one with no
# application behind it: `/srv/wallpapers` is a directory, so Serve publishes it
# as static files under `/wallpapers` on 443. An absolute path is Serve's
# static-file target -- a URL would be a proxy instead -- and Serve appends the
# trailing slash itself, so `https://<host>.<tailnet>.ts.net/wallpapers/` is
# exactly what this declares.
#
# Nothing here is Funnel: Serve answers tailnet clients only.
set -euo pipefail

tailscale_bin=${TAILSCALE_BIN:-tailscale}
schema=${APPS_SCHEMA:-/usr/libexec/apps-schema}
plan=${APPS_PLAN:-/var/lib/homelab/apps/plan.json}
wallpapers=${WALLPAPERS_DIR:-/srv/wallpapers}

fail() {
  echo "tailscale-serve: $*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is missing"

# https port -> loopback port. 443 Immich, 8443 OPDShelf, 10000 Syncthing GUI,
# 8444 the personal web UI, 8445 the general one. The wallpaper library is
# deliberately absent: it is a directory published as static files under a path on
# 443, not a loopback port with a root path.
declare -A core_routes=(
  [443]=2283
  [8443]=8083
  [10000]=8384
  [8444]=18006
  [8445]=18007
)

# https/443 path -> loopback port, for the two agent gateway APIs. A fixed path
# each, because the documents and clients that address them already use
# /apps/agent-local/v1 and /apps/agent-general/v1, and an API client can be told a
# path. The hosted proxy on 127.0.0.1:18003 is deliberately absent -- the gateway
# reaches it by container name, and a tailnet path to it would let any device
# spend the provider key.
#
# The browser UIs are NOT here: a web UI emits absolute asset and link URLs
# (`/static/…`, `/login`), which a path prefix on 443 cannot serve -- the browser
# would ask the tailnet root, which is Immich. They get their own HTTPS ports in
# core_routes instead.
declare -A core_path_routes=(
  [/apps/agent-local]=18001
  [/apps/agent-general]=18002
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
    # A tenant app may not take a path the core owns: the two loops would declare
    # the same Serve handler and the last writer would win. Checked over the whole
    # plan first, so a claim like that applies no route at all rather than the
    # half before the offending entry.
    while IFS=$'\t' read -r path _port; do
      [[ -n $path ]] || continue
      if [[ -n ${core_path_routes[$path]+x} ]]; then
        plan_ok=false
        echo "tailscale-serve: $plan claims $path, which a core route owns" >&2
      fi
    done <<<"$rows"
    if $plan_ok; then
      while IFS=$'\t' read -r path port; do
        [[ -n $path && -n $port ]] || continue
        app_routes[$path]=$port
      done <<<"$rows"
    fi
  fi
fi

# Core ingress first: whatever is wrong with the tenant plan or the Serve
# status, the core applications, the two agent gateways, their two web UIs and the
# wallpaper tree must stay reachable. Nothing below this point may run before
# these declarations.
for https in "${!core_routes[@]}"; do
  backend=http://127.0.0.1:${core_routes[$https]}
  if ! "$tailscale_bin" serve --bg --https="$https" "$backend"; then
    fail "could not serve $backend on https/$https"
  fi
done

for path in "${!core_path_routes[@]}"; do
  backend=http://127.0.0.1:${core_path_routes[$path]}
  if ! "$tailscale_bin" serve --bg --https=443 --set-path="$path" "$backend"; then
    fail "could not serve $backend on https/443$path"
  fi
done

# The wallpaper library is declared here, with the rest of the core ingress, so
# a tenant plan that cannot be read or verified still leaves that route up. The
# directory has to exist when Serve is asked for it -- Serve stats the target
# and rejects it otherwise -- which is what makes a missing dataset a failed
# unit rather than an empty listing.
[[ -d $wallpapers ]] || fail "$wallpapers is missing"
if ! "$tailscale_bin" serve --bg --https=443 --set-path=/wallpapers "$wallpapers"; then
  fail "could not serve $wallpapers on https/443/wallpapers"
fi

# The status is only needed to prune stale app routes; if it cannot be read,
# declare the plan's routes anyway and leave the pruning to a later run.
status=$("$tailscale_bin" serve status --json) || {
  echo "tailscale-serve: could not read Serve status; not pruning app routes" >&2
  status='{}'
}

# An app that left the plan, or the whole tenant, leaves no route behind. Only
# `/apps/` handlers on 443 are ours: the root paths belong to the core apps,
# `/apps/agent-local` and `/apps/agent-general` belong to the core gateways, and
# `/wallpapers` is not under that prefix either, so every one of those survives
# every prune.
while IFS= read -r path; do
  $plan_ok || break
  [[ -n $path ]] || continue
  [[ -n ${core_path_routes[$path]+x} ]] && continue
  [[ -n ${app_routes[$path]+x} ]] && continue
  if ! "$tailscale_bin" serve --https=443 --set-path="$path" off; then
    echo "tailscale-serve: could not remove the stale route $path" >&2
    plan_ok=false
    break
  fi
done < <(
  jq -r '.Web // {} | to_entries[]
    | select(.key | endswith(":443"))
    | .value.Handlers // {} | keys[]
    | select(startswith("/apps/"))' <<<"$status" 2>/dev/null || true
)

$plan_ok || fail "$plan is not a valid tenant plan"

for path in "${!app_routes[@]}"; do
  backend=http://127.0.0.1:${app_routes[$path]}
  if ! "$tailscale_bin" serve --bg --https=443 --set-path="$path" "$backend"; then
    fail "could not serve $backend on https/443$path"
  fi
done

"$tailscale_bin" serve status || true
