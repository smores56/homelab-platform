#!/usr/bin/env bats
# bats file_tags=core
# Every loopback listener has a Serve route, the one host-networked container
# is bounded by the firewall, and every publish is loopback-only.
#
# One file of the suite that was tests/core/app-quadlets.bats, split so bats can
# run the sections as parallel files (a file is one job). The tables, the
# file-scope sources and every checker more than one section calls are in
# tests/core/app-quadlets_lib.bash; the checkers only this file uses stay here.
#
#   bats tests/core/app-quadlets-listeners.bats
load ../helpers
load ./app-quadlets_lib

setup_file() { aq_setup_file; }
setup() { aq_setup; }

# Ports that are published on loopback for the operator's own curl and are
# deliberately not a Serve route. 18003 is the hosted proxy: the gateway reaches
# it by container name on agent-general.network, so a tailnet path to it would
# only widen who can spend the provider key. 18006 is the legacy personal web UI,
# kept running only as the rollback for the Workspace cutover; the operator
# reaches it through an SSH forward, not through a name on the tailnet.
readonly no_serve_ports=(18003 18006)

# Loopback listeners that reach the tailnet through a proxy the image ships rather
# than through a route of their own. The Syncthing GUI refuses a foreign Host, so
# 8384 sits behind Caddy on 8385 (design #897): the Serve table names the proxy,
# and the proxy is what makes the GUI reachable at all.
# A list, not an associative array: the test bodies in this file are registered
# through `bats_test_function`, and an associative array declared here does not
# survive into them (a readonly indexed one does).
readonly proxied_pairs=(8384:8385)

# 4. Every loopback listener is fronted by a Serve route, and there is no route
#    to nothing. The Syncthing GUI is a listener too, even though it is not a
#    published port: it runs in the host network namespace.
published_ports() {
  {
    grep -h '^PublishPort=127\.0\.0\.1:' "${app_quadlets[@]}" | cut -d: -f2
    grep -h '^Environment=STGUIADDRESS=127\.0\.0\.1:' "${app_quadlets[@]}" | cut -d: -f2
  } | sort -u
}

serve_route_ports() {
  grep -oE '\[[^]]*\]=[0-9]+' scripts/tailscale-serve.sh | cut -d= -f2 | sort -u
}

# The targets of the named routes. A listener can be fronted without a host port
# (`--service=svc:sync --https=443 http://127.0.0.1:8385`), and those targets are
# not all Quadlet listeners: the zellij terminal is a system unit, so this set is
# read only when asking whether a *listener* has a route, never the reverse.
serve_service_ports() {
  grep -oE -- '--service=[^ ]+ --https=[0-9]+ http://127\.0\.0\.1:[0-9]+' \
    scripts/tailscale-serve.sh | grep -oE '[0-9]+$' | sort -u
}

# Both directions of the listener/Serve map live in this check: the shell suite
# only printed a line when a route pointed at no listener, so the reverse
# direction rides along here rather than standing as an ok of its own.
port_has_a_serve_route() { # port
  local port=$1 front stray route_port pair
  front=$port
  for pair in "${proxied_pairs[@]}"; do
    [[ ${pair%%:*} == "$port" ]] && front=${pair##*:}
  done
  if [[ " ${no_serve_ports[*]} " != *" $port "* ]]; then
    if ! { serve_route_ports; serve_service_ports; } | grep -qx -- "$front"; then
      printf 'no Serve route for %s (through %s)\n' "$port" "$front" >&2
      return 1
    fi
  fi
  stray=''
  for route_port in $(serve_route_ports); do
    grep -qw "$route_port" <<<"$(published_ports)" && continue
    for pair in "${proxied_pairs[@]}"; do
      [[ ${pair##*:} == "$route_port" ]] && continue 2
    done
    stray="$stray $route_port"
  done
  if [[ -n $stray ]]; then
    printf 'Serve route to no loopback listener:%s\n' "$stray" >&2
    return 1
  fi
}

for _port in $(published_ports); do
  if [[ " ${no_serve_ports[*]} " == *" $_port "* ]]; then
    registered "port $_port is loopback-only diagnostics, not a Serve route" \
      port_has_a_serve_route "$_port"
  else
    registered "port $_port has a Serve route" port_has_a_serve_route "$_port"
  fi
done
unset _port route_port

# 5. The one non-HTTP container publishes nothing and is bounded by the
#    firewall instead; nothing may auto-update a pinned application image.
@test "syncthing uses host networking" {
  grep -q '^Network=host' units/quadlet/syncthing.container
}

@test "syncthing publishes no port" {
  ! grep -q '^PublishPort=' units/quadlet/syncthing.container
}

@test "firewall permits 22000 on the tailscale zone only" {
  local zone=bootc/server/rootfs/etc/firewalld/zones/tailscale.xml
  grep -q '<port port="22000" protocol="tcp"/>' "$zone" &&
    grep -q '<port port="22000" protocol="udp"/>' "$zone" &&
    grep -q '<interface name="tailscale0"/>' "$zone"
}

@test "no application image auto-updates" {
  ! grep -qE '^(AutoUpdate=|Pull=always)' "${app_quadlets[@]}"
}

# A quadlet is a generated unit: [Install] is the only thing that starts it, and
# the check has to be per file or one good file hides five that never start.
starts_from_install() { # quadlet
  grep -q '^\[Install\]' "$1" && grep -q '^WantedBy=multi-user.target' "$1"
}

for _q in "${app_quadlets[@]}"; do
  registered "$_q starts from [Install]" starts_from_install "$_q"
done
unset _q

@test "no application unit is enabled at build time" {
  ! grep -qE 'systemctl enable (immich|opdshelf|syncthing)' bootc/server/Containerfile
}

# 2. Every published port is loopback only, and the Serve route matches the host
#    port rather than the container port.
#
# 7c. A published port on an internal network is silently dead: netavark skips
#     DNAT (`if !setup_portfw.internal`) and adds bidirectional isolation drops.
#     The container listens, the unit is green, and the host cannot connect --
#     the personal gateway and web UI were unreachable this way. Any container
#     that publishes must therefore be off every `Internal=true` network. The
#     shell suite only printed on failure, so it rides along in this check.
@test "every publish is loopback-only" {
  local offending spec net dead=''
  offending=$(grep -h '^PublishPort=' "${app_quadlets[@]}" | grep -v '^PublishPort=127\.0\.0\.1:' || true)
  if [[ -n $offending ]]; then
    printf '%s\n' "$offending" >&2
    return 1
  fi
  for q in units/quadlet/*.container; do
    if ! grep -q '^PublishPort=' "$q"; then
      continue
    fi
    while IFS= read -r spec; do
      net=${spec%%:*}
      if grep -qxF 'Internal=true' "units/quadlet/$net"; then
        dead="$dead $q($net)"
      fi
    done < <(sed -n 's/^Network=//p' "$q")
  done
  if [[ -n $dead ]]; then
    printf 'publishes from a network that forwards:%s\n' "$dead" >&2
    return 1
  fi
}
