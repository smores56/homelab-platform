#!/usr/bin/env bash
# Root-owned ingress for one apps-tenant app (SDLC #726, T7 of #701).
#
#   apps-ingress <name>
#
# Serve terminates TLS and proxies `/apps/<name>` to `127.0.0.1:<loopbackPort>`
# on the host. That address is deliberately not a Podman publish: rootless
# publishing is performed by a forwarder running as the tenant uid, and the
# tenant's egress table drops tenant traffic, so every published port timed out
# while that table was loaded. This helper answers on the loopback port as root
# and crosses into the container's network namespace over a unix socket, which
# is a filesystem object and needs no route:
#
#   host 127.0.0.1:<loopback>  ->  /run/smortress/apps/<name>/ingress.sock
#                                  -> (container netns) 127.0.0.1:<containerPort>
#
# Nothing in this path runs as the tenant and nothing listens off loopback. The
# plan is re-verified before either end exists, so a foreign path, a port
# outside the platform range or an app that is not in the plan changes nothing.
# A container restart destroys the namespace this helper joined, which ends the
# netns-side listener; the unit then restarts and resolves the new pid.
#
# Every knob is environment-overridable so tests/apps/ingress.bats can drive this
# exact code against stubs. Production sets none of them: the defaults are the
# host paths, and a wrong override is a wrong host path, not a way to skip a
# check.
set -euo pipefail

schema=${APPS_SCHEMA:-/usr/libexec/apps-schema}
plan=${APPS_PLAN:-/var/lib/homelab/apps/plan.json}
socat_bin=${SOCAT:-socat}
nsenter_bin=${NSENTER:-nsenter}
podman_bin=${PODMAN:-podman}
runuser_bin=${RUNUSER:-runuser}
apps_user=${APPS_USER:-apps}
runtime_root=${APPS_INGRESS_RUNTIME:-/run/smortress/apps}
wait_attempts=${APPS_INGRESS_WAIT:-60}
socket_attempts=${APPS_INGRESS_SOCKET_WAIT:-50}

usage() {
  echo 'usage: apps-ingress <app>' >&2
}

[[ $# -eq 1 ]] || {
  usage
  exit 2
}
name=$1
# The name becomes a path component below; refuse anything the schema would not
# accept as an app name, so no definition or command line can name `../..`.
if [[ ! $name =~ ^[a-z]([a-z0-9-]{0,29}[a-z0-9])?$ ]]; then
  echo "apps-ingress: invalid app name: $name" >&2
  exit 2
fi

if ! problems=$("$schema" verify-plan --plan "$plan" 2>&1); then
  printf 'apps-ingress: %s is not accepted:\n%s\n' "$plan" "$problems" >&2
  exit 1
fi

entry=$(jq -er --arg n "$name" '.apps[$n] // empty | "\(.loopbackPort) \(.containerPort)"' "$plan") || {
  echo "apps-ingress: $name is not in $plan" >&2
  exit 1
}
read -r loopback container_port <<<"$entry"
if [[ ! $loopback =~ ^[0-9]+$ || ! $container_port =~ ^[0-9]+$ ]]; then
  echo "apps-ingress: $name has no usable ports in $plan" >&2
  exit 1
fi

uid=$(id -u "$apps_user") || {
  echo "apps-ingress: there is no account named $apps_user" >&2
  exit 1
}

sock_dir=$runtime_root/$name
install -d -m 0755 "$runtime_root"
# On the host this runs as root and owns the directory; under the offline tests
# it runs as the invoking user, which may not chown. The socket is created by
# the listener below either way, and only root can reach a 0700 directory.
if ((EUID == 0)); then
  install -d -m 0700 -o root -g root "$sock_dir"
else
  install -d -m 0700 "$sock_dir"
fi
sock=$sock_dir/ingress.sock

container_pid() {
  "$runuser_bin" -u "$apps_user" -- env XDG_RUNTIME_DIR="/run/user/$uid" \
    "$podman_bin" inspect --format '{{.State.Pid}}' "smortress-app-$name" 2>/dev/null
}

pid=""
for _ in $(seq 1 "$wait_attempts"); do
  pid=$(container_pid) || pid=""
  if [[ $pid =~ ^[0-9]+$ ]] && ((pid > 0)); then
    break
  fi
  pid=""
  sleep 1
done
if [[ -z $pid ]]; then
  echo "apps-ingress: container smortress-app-$name did not appear" >&2
  exit 1
fi

netns_socat=""
host_socat=""
# shellcheck disable=SC2329  # invoked by the trap below
cleanup() {
  trap - EXIT INT TERM
  [[ -n $host_socat ]] && kill "$host_socat" 2>/dev/null || true
  [[ -n $netns_socat ]] && kill "$netns_socat" 2>/dev/null || true
  rm -f "$sock"
}
trap cleanup EXIT INT TERM

# Inside the container's namespace, answer on a socket the host can open: only
# the network namespace changes, so the filesystem (and this path) is the host's.
"$nsenter_bin" --target "$pid" --net "$socat_bin" \
  "UNIX-LISTEN:$sock,fork,unlink-early,mode=600" \
  "TCP:127.0.0.1:$container_port" &
netns_socat=$!

# The listener in the host namespace must not appear before the socket exists,
# or the first connections fail while the unit is already reporting started.
for _ in $(seq 1 "$socket_attempts"); do
  [[ -S $sock ]] && break
  sleep 0.1
done
if [[ ! -S $sock ]]; then
  echo "apps-ingress: $sock did not appear" >&2
  exit 1
fi

"$socat_bin" "TCP-LISTEN:$loopback,bind=127.0.0.1,fork,reuseaddr" \
  "UNIX-CONNECT:$sock" &
host_socat=$!

# Whichever end dies first (a container restart takes the namespace, and with it
# the socket, away) is a reason to be restarted with a fresh pid.
wait -n "$netns_socat" "$host_socat" || true
exit 1
