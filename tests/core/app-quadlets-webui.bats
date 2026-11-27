#!/usr/bin/env bats
# bats file_tags=core
# Each web UI is a client of its own deployment's gateway, and a network with
# any pinned peer pins every peer.
#
# One file of the suite that was tests/core/app-quadlets.bats, split so bats can
# run the sections as parallel files (a file is one job). The tables, the
# file-scope sources and every checker more than one section calls are in
# tests/core/app-quadlets_lib.bash; the checkers only this file uses stay here.
#
#   bats tests/core/app-quadlets-webui.bats
load ../helpers
load ./app-quadlets_lib

setup_file() { aq_setup_file; }
setup() { aq_setup; }

# 7. Each web UI is a client of its own deployment's gateway and nothing else. It
#    shares the gateway's network -- the personal one internal, so the UI has no
#    route off the host either -- and the pairing is asserted in both directions:
#    a UI that named the other deployment's gateway would answer from the wrong
#    authority domain while looking healthy.
#
# spec: deployment:state:port:network:gateway:gateway port
webui_field() { # spec field number, 1-6
  local IFS=: index=$(($2 - 1))
  local -a fields
  read -r -a fields <<<"$1"
  printf '%s\n' "${fields[$index]}"
}

webui_unit() { # spec
  printf 'units/quadlet/agent-webui-%s.container\n' "$(webui_field "$1" 1)"
}
webui_state() { # spec
  webui_field "$1" 2
}
webui_port() { # spec
  webui_field "$1" 3
}
webui_network() { # spec
  webui_field "$1" 4
}
webui_gateway() { # spec
  webui_field "$1" 5
}
webui_gateway_port() { # spec
  webui_field "$1" 6
}

webui_joins_only_its_network() { # spec
  local q
  q=$(webui_unit "$1")
  assert_equal "$(sed -n 's/^Network=//p' "$q")" "$(webui_network "$1")"
}

webui_publishes_its_own_port() { # spec
  assert_equal "$(sed -n 's/^PublishPort=//p' "$(webui_unit "$1")")" \
    "127.0.0.1:$(webui_port "$1"):8787"
}

webui_runs_the_built_ui() { # spec
  # shellcheck source=/dev/null
  source scripts/app-images.sh
  assert_equal "$(sed -n 's/^Image=//p' "$(webui_unit "$1")")" "$(app_image_ref agent-webui)"
}

webui_takes_its_key_from_the_seeded_file() { # spec
  assert_equal "$(sed -n 's/^EnvironmentFile=//p' "$(webui_unit "$1")")" \
    "/var/lib/agent/$(webui_state "$1")/webui.env"
}

webui_mounts_its_ui_directory() { # spec
  assert_equal "$(sed -n 's/^Volume=//p' "$(webui_unit "$1")")" \
    "/var/lib/agent/$(webui_state "$1")/webui:/data:z"
}

webui_points_at_its_own_gateway() { # spec
  local q
  q=$(webui_unit "$1")
  if ! grep -qxF "Environment=HERMES_WEBUI_GATEWAY_BASE_URL=http://$(webui_gateway "$1"):$(webui_gateway_port "$1")" "$q"; then
    printf '%s\n' "$(grep -F 'GATEWAY_BASE_URL' "$q" || true)" >&2
    return 1
  fi
}

webui_carries_no_credential() { # spec
  ! grep -qE '^Environment=(HERMES_WEBUI_PASSWORD|HERMES_WEBUI_GATEWAY_API_KEY)=' "$(webui_unit "$1")"
}

webui_never_names_the_hosted_key() { # spec
  ! grep -qF 'agent-hosted-key' "$(webui_unit "$1")"
}

for _spec in \
  personal:local:18006:agent-local.network:smortress-agent-local:18001 \
  general:general:18007:agent-general.network:smortress-agent-general:18002; do
  IFS=: read -r _deployment _state _port _network _gateway _gport <<<"$_spec"
  _q=units/quadlet/agent-webui-$_deployment.container
  registered "$_q declares exactly one network" declares_exactly_one_network "$_q"
  registered "$_q joins only $_network" webui_joins_only_its_network "$_spec"
  registered "$_q publishes loopback $_port, the UI's own port" \
    webui_publishes_its_own_port "$_spec"
  registered "$_q runs the built web UI at the pinned digest" webui_runs_the_built_ui "$_spec"
  registered "$_q takes its key and password from the seeded file" \
    webui_takes_its_key_from_the_seeded_file "$_spec"
  registered "$_q mounts only its deployment's UI directory" webui_mounts_its_ui_directory "$_spec"
  registered "$_q points at its own deployment's gateway" webui_points_at_its_own_gateway "$_spec"
  registered "$_q carries no credential in the unit" webui_carries_no_credential "$_spec"
  registered "$_q never names the hosted provider key" webui_never_names_the_hosted_key "$_spec"
done
unset _spec _deployment _state _port _network _gateway _gport _q

# 7b. A static peer address is all-or-nothing per network. Podman's IPAM hands
#     out the lowest free address, so an unpinned container that starts first
#     takes the address a peer asked for and the peer fails with "IPAM error:
#     requested ip address ... is already allocated" until its restart limit
#     trips. That happened at boot: the browser took 10.89.73.2 before the
#     egress proxy claimed it. Two containers may also never pin the same one.
#     The rule is generic: a network with any pinned container pins every
#     container on it.
every_container_pins_its_address() { # net
  local net=$1 q spec ip seen='' unpinned=''
  for q in units/quadlet/*.container; do
    while IFS= read -r spec; do
      if [[ ${spec%%:*} != "$net" ]]; then
        continue
      fi
      if [[ $spec == *':ip='* ]]; then
        ip=${spec##*:ip=}
        if [[ " $seen " == *" $ip "* ]]; then
          printf '%s also pins %s\n' "$q" "$ip" >&2
          return 1
        fi
        seen="$seen $ip"
      else
        unpinned="$unpinned $q"
      fi
    done < <(sed -n 's/^Network=//p' "$q")
  done
  if [[ -n $unpinned ]]; then
    printf 'unpinned:%s, would race for %s\n' "$unpinned" "${seen# }" >&2
    return 1
  fi
}

_pinned_nets=''
for _q in units/quadlet/*.container; do
  while IFS= read -r _line; do
    case $_line in
      Network=*':ip='*) ;;
      *) continue ;;
    esac
    _net=${_line#Network=}
    _net=${_net%%:*}
    case " $_pinned_nets " in
      *" $_net "*) ;;
      *) _pinned_nets="$_pinned_nets $_net" ;;
    esac
  done <"$_q"
done
for _net in $_pinned_nets; do
  registered "every container on $_net pins its address" every_container_pins_its_address "$_net"
done
unset _q _line _net _pinned_nets
