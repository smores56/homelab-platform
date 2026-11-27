#!/usr/bin/env bash
# Declare the Tailscale Serve routes that front the loopback-published
# applications. Serve state lives in tailscaled's state file, which is not part
# of a recovery group and not worth backing up: it is re-declared on every boot.
#
# The core applications own a root path on their own HTTPS port, because none of
# them supports being served under a subpath. The two agent gateways are not
# applications with a root path to spare: those ports are taken, so they
# get one fixed path each on 443. Tenant apps from `homelab-apps`
# get one `/apps/<name>` path each on 443 instead: the core applications already
# own every root-path HTTPS port, and a path on 443 is what is left. Their
# loopback ports come from the rendered plan, never from a definition, and every
# path the plan no longer names is removed, including when the tenant is empty.
#
# The wallpaper library is a fourth core route and the only one with no
# application behind it: `/srv/wallpapers` is a directory, so Serve publishes it
# as static files under `/wallpapers` on 443. An absolute path is Serve's
# static-file target -- a URL would be a proxy instead -- and Serve appends the
# trailing slash itself, so `https://<host>.<tailnet>.ts.net/wallpapers/` is
# exactly what this declares.
#
# Nothing here is Funnel: Serve answers tailnet clients only.
#
# The deploy receiver gets one raw TCP forward (8484) rather than an HTTPS route:
# the caller is a curl in a CI job that joins the tailnet for this one request.
#
# The applications are published as Services (design #834) rather than as host
# ports alone: OPDShelf was the first to leave the per-port scheme, because the
# name belongs to the application instead of to a port on the host. Each Service
# is advertised over HTTPS, so Tailscale terminates TLS and provisions the
# certificate for the name, and the host routes stay declared as the rollback.
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
# 8444 the personal web UI, 8445 the general one, 8448 Navidrome. Every one of them
# serves the owner's own tailnet clients; the public edge does not read them. It
# proxies the `svc:immich` and `svc:opds` Services instead (design #725), because
# the edge may not use 443, which also carries the agent gateways and the
# wallpaper tree, and a port-scoped tailnet rule cannot express a path. The
# wallpaper library is absent here: it is a directory published as static files
# under a path on 443, not a loopback port with a root path.
declare -A core_routes=(
  [443]=2283
  [8443]=8083
  [10000]=8384
  [8444]=18006
  [8445]=18007
  [8448]=4533
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

# The deploy receiver's forward. `serve --tcp` forwards raw TCP, because the caller
# is a curl in a CI job and the receiver speaks plain HTTP on loopback; Serve
# terminates the tailnet side, so the listener never binds a wildcard. It is
# declared here with the core routes and before anything that reads the tenant
# plan, so a broken plan cannot take the trigger path down with it -- and a `--tcp`
# forward is not a Web handler, so the `/apps/` prune below never reaches it.
if ! "$tailscale_bin" serve --bg --tcp=8484 tcp://127.0.0.1:8484; then
  fail "could not forward tcp/8484 to the deploy receiver"
fi

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

# OPDShelf's own Service, the first application off the per-port scheme: the name
# belongs to the application rather than to a port on the host, and Tailscale
# terminates TLS and provisions the certificate for that name. Declared after the
# host routes, so a Service the tailnet does not have yet costs this route alone.
# The 8443 host route stays as the rollback until every client has moved.
if ! "$tailscale_bin" serve --bg --service=svc:opds --https=443 http://127.0.0.1:8083; then
  fail "could not advertise the OPDShelf Service on svc:opds https/443"
fi

# The other core applications off the per-port scheme, the same `--https` form as
# the catalogue's: Serve terminates TLS and Tailscale issues and renews the
# certificate for each service name. A Service that is a few minutes old prints
# "approval from an admin is required" and answers nothing until the tailnet's
# auto-approver (tofu/tailscale.tf) has taken it, so a pending advertisement is
# not a failed one. Syncthing's GUI is advertised as a Service below, through the
# loopback proxy that rewrites the Host Serve forwards unchanged (design #897,
# T1), and its 10000 route is unchanged.
if ! "$tailscale_bin" serve --bg --service=svc:immich --https=443 http://127.0.0.1:2283; then
  fail "could not advertise the Immich Service on svc:immich https/443"
fi
if ! "$tailscale_bin" serve --bg --service=svc:navidrome --https=443 http://127.0.0.1:4533; then
  fail "could not advertise the Navidrome Service on svc:navidrome https/443"
fi
if ! "$tailscale_bin" serve --bg --service=svc:assistant --https=443 http://127.0.0.1:18006; then
  fail "could not advertise the personal web UI Service on svc:assistant https/443"
fi
if ! "$tailscale_bin" serve --bg --service=svc:agent --https=443 http://127.0.0.1:18007; then
  fail "could not advertise the general web UI Service on svc:agent https/443"
fi
# The Syncthing GUI, on a Service like the rest, through the loopback proxy this
# host runs in front of it (design #897, T1): the GUI keeps its Host check on, so
# Serve's unchanged Host is rewritten to the address the GUI trusts on 8385 rather
# than the check being turned off. The 10000 host route stays as the rollback and
# still targets the GUI itself, as does `insecureSkipHostcheck` until T2 retires
# both.
if ! "$tailscale_bin" serve --bg --service=svc:sync --https=443 http://127.0.0.1:8385; then
  fail "could not advertise the Syncthing GUI Service on svc:sync https/443"
fi
# The recovery reader (SDLC #953), which runs on this host now: the guard owns
# 127.0.0.1:9898 and Backrest sits behind it on 9899. This is the only route the
# public edge reads that is not an application the owner browses, and it is
# declared here rather than on the edge because the corpus-read credential lives
# here. The Service, not the host's own 443: that port also carries the agent
# gateway APIs and the wallpaper tree, and a tailnet ACL is port-scoped.
if ! "$tailscale_bin" serve --bg --service=svc:recovery --https=443 http://127.0.0.1:9898; then
  fail "could not advertise the recovery reader Service on svc:recovery https/443"
fi

# The status is only needed to prune stale app routes; if it cannot be read,
# declare the plan's routes anyway and leave the pruning to a later run.
status=$("$tailscale_bin" serve status --json) || {
  echo "tailscale-serve: could not read Serve status; not pruning app routes" >&2
  status='{}'
}

# A host port this version stops declaring has to leave tailscaled, not just this
# file: Serve answers a handler for as long as its config names it, and nothing in
# tailscaled knows a newer script retired the route. So deleting an entry from
# core_routes above is enough to retire it on the next run -- without this loop the
# handler outlived the declaration. That is how the two host ports the public edge
# used (8446 and 8447) leave, now that the edge reads the Services instead.
#
# Every https port in the status is stale unless core_routes names it. 443 is
# exempt: that is the tenant root, where the two gateways and the wallpaper tree
# live, and it never retires by dropping an entry. Only `Web` is read: `TCP` is the
# receiver's forward and `Services` are the per-app names, which the loop below
# reconciles and neither of which is a host port. Same guard as the `/apps/` prune
# below -- a plan that did not verify leaves the pruning to a run that can read it.
while IFS= read -r port; do
  $plan_ok || break
  [[ -n $port ]] || continue
  [[ $port == 443 ]] && continue
  [[ -n ${core_routes[$port]+x} ]] && continue
  if ! "$tailscale_bin" serve --https="$port" off; then
    echo "tailscale-serve: could not turn off the stale route https/$port" >&2
    plan_ok=false
    break
  fi
done < <(
  jq -r '[.Web // {} | keys[] | split(":") | last | select(test("^[0-9]+$"))] | unique[]' \
    <<<"$status" 2>/dev/null || true
)

# The same decay in the other map: a Service handler is answered for as long as
# tailscaled's config names it, and a Service the tailnet no longer has leaves
# nothing that could refuse the handler. `svc:agent-ui` is the proof -- the Service
# was deleted and its handler kept pointing at a Caddy that no longer exists -- so a
# name the declarations above do not make is cleared on the next run.
#
# This list is the declarations' index, not a second declaration: every `--service=`
# above is named here once, and tests/core/tailscale-serve-*.bats fails when a
# declaration and this list disagree. `clear` removes the whole Service, which is
# what a retired name needs; the per-path `off` above would leave it behind.
#
# 443 is the handler's port and not part of the name: `.Services` keys the entry
# `svc:agent` and other recordings of it `svc:agent:443`, so a key is reduced to the
# name it holds before it is compared. Only `Services` is read here -- the host
# ports are the loop above, and the receiver's forward is `TCP`.
declared_services=(svc:opds svc:recovery svc:immich svc:navidrome svc:assistant svc:agent svc:sync svc:terminal)
while IFS= read -r name; do
  $plan_ok || break
  [[ -n $name ]] || continue
  [[ " ${declared_services[*]} " == *" $name "* ]] && continue
  if ! "$tailscale_bin" serve clear "$name"; then
    echo "tailscale-serve: could not clear the stale Service $name" >&2
    plan_ok=false
    break
  fi
done < <(
  jq -r '[.Services // {} | keys[] | sub(":[0-9]+$"; "")] | unique[]' \
    <<<"$status" 2>/dev/null || true
)

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

# The zellij web terminal, declared last of every route: `fail()` aborts the
# script, so a terminal the tailnet will not take must not cost a route declared
# after it. Zellij binds loopback itself and Serve terminates TLS for the Service
# name, so this adds no host port and no certificate of our own.
if ! "$tailscale_bin" serve --bg --service=svc:terminal --https=443 http://127.0.0.1:8082; then
  fail "could not advertise the zellij web terminal on svc:terminal https/443"
fi

"$tailscale_bin" serve status || true
