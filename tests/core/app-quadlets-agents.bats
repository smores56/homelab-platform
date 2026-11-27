#!/usr/bin/env bats
# bats file_tags=core
# The agent deployments: two networks split by authority, and every program a
# Quadlet names is inside the image it runs.
#
# One file of the suite that was tests/core/app-quadlets.bats, split so bats can
# run the sections as parallel files (a file is one job). The tables, the
# file-scope sources and every checker more than one section calls are in
# tests/core/app-quadlets_lib.bash; the checkers only this file uses stay here.
#
#   bats tests/core/app-quadlets-agents.bats
load ../helpers
load ./app-quadlets_lib

setup_file() { aq_setup_file; }
setup() { aq_setup; }

# 11. The agent deployments (#711). Two networks split by authority: the personal
#     side denies egress with a route and therefore has no way off the host, the
#     general side has egress and is the only side that can spend a hosted key --
#     which it does not hold. These are the properties a misread of the units
#     would silently undo.
readonly agent_local=units/quadlet/agent-local.container
readonly agent_general=units/quadlet/agent-general.container
readonly agent_model=units/quadlet/agent-model.container
readonly agent_proxy=units/quadlet/agent-proxy.container

# `Internal=true` cannot be the personal side's answer: netavark skips port
# forwarding entirely for internal networks, so the gateway and the web UI would
# listen while their published ports stayed dead. Egress is denied by the route.
@test "the personal network has no default route" {
  grep -qxF 'Options=no_default_route=true' units/quadlet/agent-local.network
}

@test "the personal network is not an internal network" {
  ! grep -q '^Internal=' units/quadlet/agent-local.network
}

# `podman network create --ignore` leaves an existing network's config alone, so
# an option change without this is silently ignored until someone deletes the
# network by hand.
@test "the personal network is recreated from this file at every boot" {
  grep -qxF 'NetworkDeleteOnStop=true' units/quadlet/agent-local.network
}

@test "the general network has egress" {
  ! grep -q '^Internal=' units/quadlet/agent-general.network
}

for _q in "$agent_local" "$agent_general" "$agent_model" "$agent_proxy"; do
  registered "$_q declares exactly one network" declares_exactly_one_network "$_q"
done
unset _q

gateway_network() { # quadlet
  sed -n 's/^Network=//p' "$1"
}

@test "the personal gateway is on the sealed network only" {
  assert_equal "$(gateway_network "$agent_local")" agent-local.network
}

@test "the general gateway is on the egress network only" {
  assert_equal "$(gateway_network "$agent_general")" agent-general.network
}

# The personal plane is a mount, and the one permission rule left in the design is
# its mode (SDLC #995): /srv/files read-write, the vault nested read-only. A volume
# that dropped the vault line would hand the agent a writable vault and nothing
# else in the stack would notice.
@test "the personal gateway mounts the files tree and the vault read-only" {
  run grep -E '^Volume=/srv/files:/srv/files$' "$agent_local"
  assert_success
  run grep -E '^Volume=/srv/files/vault:/srv/files/vault:ro$' "$agent_local"
  assert_success
  # Without the mount the shell sees an empty /srv/files and the agent reports a
  # plane that has no data rather than a mount that never happened.
  run grep -F 'zfs-ready@raw-files.service' "$agent_local"
  assert_success
}

@test "the proxy is on the egress network only" {
  assert_equal "$(gateway_network "$agent_proxy")" agent-general.network
}

@test "the model server is on the sealed network only" {
  assert_equal "$(gateway_network "$agent_model")" agent-local.network
}

# The stateful runtimes cannot be read-only; the model server can, and the proxy
# holds the credential file, so it is.
@test "the model server and the proxy have a read-only root filesystem" {
  grep -q '^ReadOnly=true$' "$agent_model" && grep -q '^ReadOnly=true$' "$agent_proxy"
}

gateway_is_writable_state_under_hardening() { # quadlet
  grep -q '^ReadOnly=false$' "$1" && grep -q '^NoNewPrivileges=true$' "$1"
}

# The runtime image refuses `--user <arbitrary uid>` ("not supported") and asks
# for HERMES_UID/HERMES_GID, which remap its internal account to the platform uid
# and chown the volume. A `User=` here would be a container that cannot start, so
# the uid-1000 convention is reached the way the image supports.
gateway_remaps_to_uid_1000() { # quadlet
  grep -q '^Environment=HERMES_UID=1000$' "$1" &&
    grep -q '^Environment=HERMES_GID=1000$' "$1" &&
    ! grep -q '^User=' "$1"
}

for _q in "$agent_local" "$agent_general"; do
  registered "$_q is writable state under the same hardening" gateway_is_writable_state_under_hardening "$_q"
  registered "$_q remaps the runtime to uid 1000 instead of forcing --user" gateway_remaps_to_uid_1000 "$_q"
done
unset _q

# GPU access is a device plus the SELinux type the device nodes carry: without the
# type, NVML answers "Insufficient Permissions" instead of a GPU.
@test "the model server addresses the GPU through the CDI device and its label" {
  grep -q '^AddDevice=nvidia.com/gpu=all$' "$agent_model" &&
    grep -q '^SecurityLabelType=nvidia_container_t$' "$agent_model"
}

# The CDI spec only hands the container a device node; SELinux decides whether
# llama.cpp may mmap it. crun creates that node as container_file_t and
# nvidia_container_t has no `map` on the type, so the server silently ran on CPU
# with nvidia-smi showing nothing. The rule ships as a CIL file and is loaded
# before the model server starts.
@test "the rule that lets the model server map the GPU ships" {
  grep -qF '(allow nvidia_container_t container_file_t (chr_file (map)))' \
    bootc/server/rootfs/usr/share/selinux/smortress/agent-nvidia-map.cil
}

@test "the rule is loaded before the model server starts" {
  local map_unit=units/systemd/smortress-selinux-nvidia-map.service
  grep -qxF 'Before=agent-model.service' "$map_unit" &&
    grep -qF 'semodule -i /usr/share/selinux/smortress/agent-nvidia-map.cil' "$map_unit"
}

@test "the CDI spec is generated before the model container starts" {
  grep -q 'nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml' \
    units/systemd/smortress-nvidia-cdi.service &&
    grep -q '^Before=agent-model.service$' units/systemd/smortress-nvidia-cdi.service &&
    grep -qE '^(Requires|After)=.*smortress-nvidia-cdi.service' "$agent_model"
}

# The provider key is one file, read by one program. Nothing else may name it.
@test "only the proxy names the hosted key" {
  local key_mentioning
  key_mentioning=$(grep -l 'agent-hosted-key' units/quadlet/*.container "${agent_templates[@]}" 2>/dev/null |
    sort | paste -sd' ')
  assert_equal "$key_mentioning" "$agent_proxy"
}

@test "no agent config template carries an api key" {
  ! grep -rqE '^[[:space:]]*api_key:' "${agent_templates[@]}"
}

@test "the proxy unit runs the shipped program" {
  grep -q '^Exec=/usr/libexec/agent-proxy$' "$agent_proxy" &&
    grep -qF 'apps/agent_proxy/proxy.py /usr/libexec/agent-proxy' images/agent-runtime/Containerfile
}

# The runtime image's entrypoint is a dispatcher into an s6 tree that boots the
# gateway; the proxy is one program, and it also refuses an arbitrary --user.
@test "the proxy bypasses the runtime entrypoint and runs as uid 1000" {
  grep -q '^Entrypoint=python3$' "$agent_proxy" && grep -q '^User=1000:1000$' "$agent_proxy"
}

# The runtime refuses a model under 64,000 tokens, so the server's window and the
# config's pin are one decision in two files.
# `-c` is the TOTAL context and llama.cpp divides it across --parallel slots, so
# the config's context_length is one slot: c / parallel, never c itself. A unit
# that changes --parallel without -c shrinks every slot under the runtime's floor.
each_model_slot_is_pinned() {
  local model_context slot_parallel config_context
  model_context=$(sed -n 's/^Exec=.*-c \([0-9]*\).*/\1/p' "$agent_model")
  slot_parallel=$(sed -n 's/^Exec=.*--parallel \([0-9]*\).*/\1/p' "$agent_model")
  config_context=$(sed -n 's/^  context_length: //p' bootc/server/rootfs/etc/smortress/agent/local-config.yaml)
  if [[ -z $model_context || -z $slot_parallel || $slot_parallel -le 0 ]] ||
    ((model_context % slot_parallel != 0)) ||
    ((model_context / slot_parallel != config_context)) || ((config_context < 64000)); then
    printf 'model=%s parallel=%s config=%s\n' "$model_context" "$slot_parallel" "$config_context" >&2
    return 1
  fi
}

_model_context=$(sed -n 's/^  context_length: //p' bootc/server/rootfs/etc/smortress/agent/local-config.yaml)
registered "each model slot is pinned to $_model_context tokens like the config" each_model_slot_is_pinned
unset _model_context

@test "the model server runs flash attention with a quantized cache" {
  grep -qE '^Exec=.*-fa on' "$agent_model" && grep -qE '^Exec=.*-ctk q8_0' "$agent_model"
}

personal_config_disables_toolset() { # toolset
  local disabled
  disabled=$(sed -n '/^  disabled_toolsets:/,/^[^ -]/p' bootc/server/rootfs/etc/smortress/agent/local-config.yaml)
  grep -qE "^[[:space:]]+- $1$" <<<"$disabled"
}

for _toolset in web search browser memory code_execution catalog \
  computer_use cronjob skills image_gen connections; do
  registered "the personal config disables the $_toolset toolset" personal_config_disables_toolset "$_toolset"
done
unset _toolset

# The data plane is the mount plus the runtime's own shell (SDLC #995). A
# `terminal` or `file` entry in that list would leave the agent with a mounted
# tree it has no way to read, which is the failure this assertion exists for: the
# list is the only place the two toolsets can be closed and the mount cannot say
# anything about them.
@test "the personal config leaves the shell and file toolsets available" {
  local disabled
  disabled=$(sed -n '/^  disabled_toolsets:/,/^[^ ]/p' bootc/server/rootfs/etc/smortress/agent/local-config.yaml)
  ! grep -qE '^    - (terminal|file)$' <<<"$disabled"
}

# Subagents are wanted, and they are the one runtime default the personal side
# keeps on purpose: a child inherits this process's provider and MCP toolsets, so
# it adds concurrency, not authority. The cap is what keeps it inside four llama.cpp
# slots, and the flat depth is what stops a spawn tree.
@test "the personal config enables subagents" {
  grep -qE '^delegation:$' bootc/server/rootfs/etc/smortress/agent/local-config.yaml
}

@test "the personal subagents are capped at two concurrent and one level" {
  local delegation
  delegation=$(sed -n '/^delegation:/,/^[^ ]/p' bootc/server/rootfs/etc/smortress/agent/local-config.yaml)
  grep -qE '^  max_concurrent_children: [1-2]$' <<<"$delegation" &&
    grep -qE '^  max_spawn_depth: 1$' <<<"$delegation"
}

@test "the general subagents are capped at three concurrent and one level" {
  local delegation
  delegation=$(sed -n '/^delegation:/,/^[^ ]/p' bootc/server/rootfs/etc/smortress/agent/general-config.yaml)
  grep -qE '^  max_concurrent_children: [1-3]$' <<<"$delegation" &&
    grep -qE '^  max_spawn_depth: 1$' <<<"$delegation"
}

# The runtime has no _FILE variant, so the key reaches it through .env written by
# the seed unit -- from the decrypted ciphertext, at the container's uid. The unit
# delegates to a script: a value built inside an `ExecStart` line is a value in the
# process table.

# shellcheck disable=SC2016  # the matched text is the seed script's own source line
@test "the seed unit derives both gateway keys from their ciphertext" {
  grep -qF 'for spec in personal:local general:general; do' "$seed_script" &&
    grep -qF 'api_key=$secrets_dir/agent-$state-api-key.yaml' "$seed_script" &&
    grep -q 'ExecStart=/usr/libexec/agent-config-seed' units/systemd/smortress-agent-config.service
}

# shellcheck disable=SC2016  # the matched text is the seed script's own source line
@test "the seed unit is idempotent and keeps the key owner-only" {
  grep -qF -- '-m 0400' "$seed_script" &&
    grep -qF 'cp -n "$template" "$config"' "$seed_script"
}

# A bind source podman has to create would land root-owned inside a dataset owned
# by uid 1000, so the seed unit creates the derived-index directory at the
# container's uid -- on the personal side only, where the collectors write.
# shellcheck disable=SC2016  # the matched text is the seed script's own source line
@test "the seed unit creates the personal index directory at the container uid" {
  grep -qF 'if [[ $state == local ]]; then' "$seed_script" &&
    grep -qF 'install -d -o 1000 -g 1000 -m 0750 "$home/index"' "$seed_script"
}

# 12. Code delivery. A Quadlet hands `Exec=`/`Entrypoint=` a program that has to
#     exist inside the container's own filesystem. The agent-runtime image is ours
#     now (images/agent-runtime/Containerfile), so a path is delivered when that
#     image installs it, when a Volume= or Secret= puts it there, or when it is one
#     of the interpreters every image carries. agent-proxy once shipped
#     `Exec=/usr/libexec/agent-proxy` with neither a mount nor the program, and
#     python3 started against a path that was not there -- this is the assertion
#     that would have caught it.

volume_container_paths() { # quadlet
  sed -n 's|^Volume=[^:]*:\([^:]*\).*|\1|p' "$1"
}
secret_targets() { # quadlet
  sed -n 's/^Secret=.*target=\([^,]*\).*/\1/p' "$1"
}

covered_by_volume() { # quadlet path
  local container_path
  while IFS= read -r container_path; do
    if [[ -z $container_path ]]; then
      continue
    fi
    if [[ $2 == "$container_path" || $2 == "$container_path"/* ]]; then
      return 0
    fi
  done < <(volume_container_paths "$1")
  return 1
}

covered_by_secret() { # quadlet path
  local target
  while IFS= read -r target; do
    if [[ -n $target && $2 == "$target" ]]; then
      return 0
    fi
  done < <(secret_targets "$1")
  return 1
}

delivers() { # quadlet path
  local q=$1 path=$2 accounted=0 interpreter
  for interpreter in "${image_interpreters[@]}"; do
    if [[ $path == "$interpreter" ]]; then
      accounted=1
    fi
  done
  if ((!accounted)) && baked_by_runtime_image "$path"; then
    accounted=1
  fi
  if ((!accounted)) && covered_by_volume "$q" "$path"; then
    accounted=1
  fi
  if ((!accounted)) && covered_by_secret "$q" "$path"; then
    accounted=1
  fi
  if ((accounted)); then
    return 0
  fi
  printf '%s is neither in the runtime image nor in a Volume=/Secret= of %s\n' "$path" "$q" >&2
  return 1
}

for _q in "${app_quadlets[@]}"; do
  _seen=' '
  while IFS= read -r _line; do
    case $_line in
      Exec=* | Entrypoint=*) ;;
      *) continue ;;
    esac
    for _path in ${_line#*=}; do
      if [[ ! $_path =~ ^/[A-Za-z0-9._/-]+$ ]]; then
        continue
      fi
      case $_seen in
        *" $_path "*) continue ;;
      esac
      _seen="$_seen$_path "
      registered "$_q delivers $_path" delivers "$_q" "$_path"
    done
  done <"$_q"
done
unset _q _line _path _seen

# The collectors run the same package through a plain podman unit, where the
# environment is a podman argument rather than Quadlet's Environment=. The rule
# above covered only the Quadlet, so both collectors shipped a PYTHONPATH one
# directory too high and could not import data_plane at all — the image puts the
# package under /usr/lib/agent-facade/libs.
@test "the collector units name the package root in PYTHONPATH" {
  local u
  for u in units/systemd/smortress-agent-collect-finance.service \
    units/systemd/smortress-agent-mail-stream.service; do
    if ! grep -qF -- '--env PYTHONPATH=/usr/lib/agent-facade/libs:/usr/lib/agent-facade' "$u"; then
      printf '%s\n' "$(grep -F -- '--env PYTHONPATH=' "$u" || true)" >&2
      return 1
    fi
  done
}
