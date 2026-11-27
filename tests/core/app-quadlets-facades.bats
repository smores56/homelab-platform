#!/usr/bin/env bats
# bats file_tags=core
# The source facades: one per deployment, the shell transports either class
# may dial, and the two live general trees only the general one mounts.
#
# One file of the suite that was tests/core/app-quadlets.bats, split so bats can
# run the sections as parallel files (a file is one job). The tables, the
# file-scope sources and every checker more than one section calls are in
# tests/core/app-quadlets_lib.bash; the checkers only this file uses stay here.
#
#   bats tests/core/app-quadlets-facades.bats
load ../helpers
load ./app-quadlets_lib

setup_file() { aq_setup_file; }
setup() { aq_setup; }

# 13. The two source facades (T2b). They complete the deployment split: each
#     gateway reads its sources and its memory through one facade process of its
#     own deployment, whose only client is that gateway. Container name, port and
#     deployment are one decision in two files (the unit and the gateway template),
#     so both sides are checked against each other.

# spec: deployment:state:port, and the facade unit and gateway template follow
# from it.
facade_unit() { # spec
  printf 'units/quadlet/agent-facade-%s.container\n' "${1%%:*}"
}
facade_state() { # spec
  local rest=${1#*:}
  printf '%s\n' "${rest%%:*}"
}
facade_port() { # spec
  printf '%s\n' "${1##*:}"
}
facade_template() { # spec
  printf 'bootc/server/rootfs/etc/smortress/agent/%s-config.yaml\n' "$(facade_state "$1")"
}

facade_is_on_its_own_network() { # spec
  local q
  q=$(facade_unit "$1")
  assert_equal "$(sed -n 's/^Network=//p' "$q")" "agent-$(facade_state "$1").network"
}

facade_runs_hardened() { # spec
  local q
  q=$(facade_unit "$1")
  grep -q '^ReadOnly=true$' "$q" && grep -q '^NoNewPrivileges=true$' "$q" &&
    grep -q '^DropCapability=ALL$' "$q" && grep -q '^User=1000:1000$' "$q"
}

quadlet_bypasses_the_runtime_entrypoint() { # quadlet
  grep -q '^Entrypoint=python3$' "$1"
}

facade_exec_line() { # spec
  sed -n 's/^Exec=//p' "$(facade_unit "$1")"
}

facade_runs_with() { # spec want
  local exec_line
  exec_line=$(facade_exec_line "$1")
  if [[ " $exec_line " != *" $2 "* ]]; then
    printf 'exec line: %s\n' "$exec_line" >&2
    return 1
  fi
}

facade_mounts_its_token() { # spec
  local q
  q=$(facade_unit "$1")
  assert_equal "$(sed -n 's/^Secret=//p' "$q" | cut -d, -f1)" "agent-facade-${1%%:*}-token"
}

facade_mounts_only_memory() { # spec
  grep -q "^Volume=/var/lib/agent/$(facade_state "$1")/memory:/memory:z$" "$(facade_unit "$1")"
}

# The derived source index is personal: every raw collector is, so the general
# deployment has no replica to index and takes neither the flag nor the mount.
facade_serves_replica_state() { # spec source
  local exec_line
  exec_line=$(facade_exec_line "$1")
  if [[ " $exec_line " != *" --replica $2=/replica/$2 "* ]]; then
    printf 'exec line: %s\n' "$exec_line" >&2
    return 1
  fi
}

facade_mounts_personal_replica_read_only() { # spec
  grep -qxF 'Volume=/var/lib/agent/local/replica:/replica:ro,z' "$(facade_unit "$1")"
}

facade_indexes_the_replicas() { # spec
  local exec_line
  exec_line=$(facade_exec_line "$1")
  if [[ " $exec_line " != *' --index-root /index '* ]] ||
    ! grep -qxF 'Volume=/var/lib/agent/local/index:/index:z' "$(facade_unit "$1")"; then
    printf 'exec line: %s\n' "$exec_line" >&2
    return 1
  fi
}

facade_carries_no_index_or_replica() { # spec
  local q exec_line
  q=$(facade_unit "$1")
  exec_line=$(facade_exec_line "$1")
  if [[ " $exec_line " == *'--index-root'* ]] ||
    grep -qE '^Volume=.*:/index(:z)?$' "$q" ||
    [[ " $exec_line " == *'--replica'* ]] ||
    grep -qE '^Volume=.*:/replica(:[^ ]*)?$' "$q"; then
    printf 'exec line: %s\n' "$exec_line" >&2
    return 1
  fi
}

# The gateway is the facade's only client, so its template must name the facade's
# container and port, carry the placeholder rather than a token, and trust it.
template_wires_the_facade() { # spec
  local deployment=${1%%:*} port mcp_block
  port=$(facade_port "$1")
  mcp_block=$(sed -n '/^mcp_servers:/,$p' "$(facade_template "$1")")
  if ! grep -qE "^  $deployment:\$" <<<"$mcp_block" ||
    ! grep -qF "url: http://smortress-agent-facade-$deployment:$port/mcp" <<<"$mcp_block" ||
    ! grep -qE '^ +X-Deployment-Token: __FACADE_TOKEN__$' <<<"$mcp_block" ||
    ! grep -qE '^    trust: full$' <<<"$mcp_block"; then
    printf '%s\n' "$mcp_block" >&2
    return 1
  fi
}

# shellcheck disable=SC2016  # the matched text is the seed script's own source line
seed_substitutes_the_placeholder() { # spec
  grep -qF 'agent-facade-$deployment-token.yaml' "$seed_script" &&
    grep -qF '__FACADE_TOKEN__' "$seed_script"
}

for _spec in personal:local:18004 general:general:18005; do
  _deployment=${_spec%%:*}
  _rest=${_spec#*:}
  _state=${_rest%%:*}
  _port=${_rest##*:}
  _q=units/quadlet/agent-facade-$_deployment.container
  registered "$_q declares exactly one network" declares_exactly_one_network "$_q"
  registered "the $_deployment facade is on its own deployment's network only" \
    facade_is_on_its_own_network "$_spec"
  registered "$_q publishes nothing" quadlet_publishes_nothing "$_q"
  registered "$_q runs hardened as uid 1000 with a read-only root filesystem" \
    facade_runs_hardened "$_spec"
  registered "$_q bypasses the runtime entrypoint" quadlet_bypasses_the_runtime_entrypoint "$_q"
  for _want in '-m apps.agent_facade' '--transport http' "--deployment $_deployment" \
    "--token-file /run/secrets/agent-facade-$_deployment-token" \
    '--memory-root /memory' '--host 0.0.0.0' "--port $_port"; do
    registered "$_q runs the facade with $_want" facade_runs_with "$_spec" "$_want"
  done
  registered "$_q mounts its deployment token by name" facade_mounts_its_token "$_spec"
  registered "$_q mounts only the memory subdirectory of the $_state dataset" \
    facade_mounts_only_memory "$_spec"
  if [[ $_deployment == personal ]]; then
    for _source in mail calendar finance brave notes tasks photos music; do
      registered "$_q serves $_source from its replica state" \
        facade_serves_replica_state "$_spec" "$_source"
    done
    registered "$_q mounts the personal replica tree read-only" \
      facade_mounts_personal_replica_read_only "$_spec"
    registered "$_q indexes the replicas in the $_state dataset's index directory" \
      facade_indexes_the_replicas "$_spec"
  else
    registered "$_q carries no index root and no personal replica" \
      facade_carries_no_index_or_replica "$_spec"
  fi
  registered "the $_state template wires the $_deployment facade at $_port with no token in it" \
    template_wires_the_facade "$_spec"
  registered "the seed unit substitutes the $_deployment placeholder" \
    seed_substitutes_the_placeholder "$_spec"
done
unset _spec _deployment _rest _state _port _q _want _source

# 13b. The two shell transports (T17/T18, SDLC #859/#860). `shell.run` exists in
#      a facade only when the process was given a bridge socket, and each class
#      gets its own directory, bridge and class-fixed dispatcher. The control is
#      the mount: a container can only dial the socket whose directory it mounts,
#      and a bridge's class is a constant in its unit, so neither transport can
#      ask for the other class. Both gateways, the model server and both web UIs
#      must name neither path.
readonly general_facade=units/quadlet/agent-facade-general.container
readonly personal_facade=units/quadlet/agent-facade-personal.container
readonly general_bridge=units/systemd/smortress-agent-shell-bridge.service
readonly personal_bridge=units/systemd/smortress-agent-shell-bridge-personal.service
readonly general_dir=/run/smortress/agent-shell-general
readonly personal_dir=/run/smortress/agent-shell-personal

@test "the general facade runs with the general bridge socket" {
  local exec_line
  exec_line=$(sed -n 's/^Exec=//p' "$general_facade")
  if ! grep -qF -- '--shell-socket /run/agent-shell/general.sock ' <<<"$exec_line "; then
    printf '%s\n' "$exec_line" >&2
    return 1
  fi
}

@test "the personal facade runs with the personal bridge socket" {
  local exec_line
  exec_line=$(sed -n 's/^Exec=//p' "$personal_facade")
  if ! grep -qF -- '--shell-socket /run/agent-shell/personal.sock ' <<<"$exec_line "; then
    printf '%s\n' "$exec_line" >&2
    return 1
  fi
}

# One directory per class, and each facade mounts only its own: the socket a
# container can dial is the one its mount exposes, so a shared directory would
# put both sockets behind one mount. Read-write because connect(2) needs the write
# bit on the socket inode.
@test "each facade mounts only its own socket directory" {
  grep -qxF "Volume=$general_dir:/run/agent-shell:z" "$general_facade" &&
    grep -qxF "Volume=$personal_dir:/run/agent-shell:z" "$personal_facade"
}

@test "neither facade names the other class: no socket path, no bridge unit" {
  local named connect_line
  named=$(grep -h 'agent-shell' "$general_facade" "$personal_facade" || true)
  if grep -qF "$personal_dir" "$general_facade" ||
    grep -qF "$general_dir" "$personal_facade" ||
    grep -qF 'agent-shell-bridge-personal' "$general_facade" ||
    grep -qF 'smortress-agent-shell-bridge.service' "$personal_facade"; then
    printf '%s\n' "$named" >&2
    return 1
  fi
  # The unit's own socket and bridge are the ones it must name, not the other's.
  connect_line=$(grep -E 'agent-shell' "$general_facade" "$personal_facade" || true)
  assert_contains "$connect_line" "$general_dir"
}

@test "each facade starts after its own bridge" {
  local ordering
  ordering=$(grep -hE '^(Requires|After)=' "$general_facade" "$personal_facade" || true)
  if ! grep -qE '^Requires=.*smortress-agent-shell-bridge\.service$' "$general_facade" ||
    ! grep -qE '^After=.*smortress-agent-shell-bridge\.service$' "$general_facade" ||
    ! grep -qE '^Requires=.*smortress-agent-shell-bridge-personal\.service$' "$personal_facade" ||
    ! grep -qE '^After=.*smortress-agent-shell-bridge-personal\.service$' "$personal_facade"; then
    printf '%s\n' "$ordering" >&2
    return 1
  fi
}

# A socket path belongs to exactly one facade and one bridge. Anything else that
# named it would be a second client or a second server for the same inode.
@test "only the two facades and the two bridges name a socket path" {
  local allowed mentioning
  allowed=$(printf '%s\n' "$general_facade" "$personal_facade" "$general_bridge" "$personal_bridge")
  mentioning=$(grep -lF -e '/run/agent-shell' -e '/run/smortress/agent-shell-' \
    units/quadlet/*.container units/systemd/*.service || true)
  if [[ -n $(grep -vxF -f <(printf '%s\n' "$allowed") <<<"$mentioning" || true) ]]; then
    printf '%s\n' "$mentioning" >&2
    return 1
  fi
}

# The two processes that can run a job are root and own no container: a unit that
# gained a Podman socket would be a second, unfiltered way to run one. The class
# and the socket are literals, so the unit, not a request, picks the dispatcher.
@test "each bridge runs as root with its own fixed class and socket" {
  local exec_lines
  exec_lines=$(grep -h '^ExecStart' "$general_bridge" "$personal_bridge" || true)
  if ! grep -qx 'UMask=0077' "$general_bridge" ||
    ! grep -qE '^ExecStart=/usr/libexec/agent-shell-bridge --class general --socket '"$general_dir"'/general\.sock --socket-group 1000$' "$general_bridge" ||
    ! grep -qx 'UMask=0077' "$personal_bridge" ||
    ! grep -qE '^ExecStart=/usr/libexec/agent-shell-bridge --class personal --socket '"$personal_dir"'/personal\.sock --socket-group 1000$' "$personal_bridge"; then
    printf '%s\n' "$exec_lines" >&2
    return 1
  fi
}

@test "neither bridge names the other class dispatcher" {
  ! grep -qE 'agent-job-general' "$personal_bridge" &&
    ! grep -qE 'agent-job-personal' "$general_bridge"
}

@test "the bridges publish nothing and hold no Podman socket" {
  local unit
  for unit in "$general_bridge" "$personal_bridge"; do
    if grep -qE '^(PublishPort|Network)=' "$unit" ||
      grep -qE 'podman\.sock|CONTAINER_HOST' "$unit"; then
      printf '%s publishes or holds a Podman socket\n' "$unit" >&2
      return 1
    fi
  done
}

# The directories are tmpfiles' so a bridge restart keeps the inode the container
# already mounted; 0710 with the facade's gid is the traversal, and the parent
# /run/smortress stays root 0700 so no host uid reaches either path.
@test "tmpfiles owns both socket directories, 0710 root:1000 under a root 0700 parent" {
  local shell_tmpfiles=bootc/server/rootfs/etc/tmpfiles.d/smortress-agent-shell.conf
  grep -qx "d $general_dir 0710 root 1000 -" "$shell_tmpfiles" &&
    grep -qx "d $personal_dir 0710 root 1000 -" "$shell_tmpfiles" &&
    grep -qx 'd /run/smortress 0700 root root -' "$tmpfiles"
}

# A Unix socket's connectto check is against the domain of the process that
# created it, not the file's label, so a container may not connect to an
# unconfined system service's socket without a rule. One rule covers both bridges
# (same two domains), and each bridge orders itself after the unit that loads it.
@test "one CIL rule permits both socket connects and each bridge loads it first" {
  local shell_cil=bootc/server/rootfs/usr/share/selinux/smortress/agent-shell.cil
  local shell_selinux_unit=units/systemd/smortress-selinux-agent-shell.service
  local head_of_cil
  head_of_cil=$(head -3 "$shell_cil" 2>/dev/null || true)
  if ! grep -qE '^\(allow container_t unconfined_service_t \(unix_stream_socket \(connectto ' "$shell_cil" ||
    ! grep -qx 'Before=smortress-agent-shell-bridge.service smortress-agent-shell-bridge-personal.service' "$shell_selinux_unit" ||
    ! grep -qx 'ExecStart=/usr/bin/semodule -i /usr/share/selinux/smortress/agent-shell.cil' "$shell_selinux_unit" ||
    ! grep -qx 'Wants=smortress-selinux-agent-shell.service' "$general_bridge" ||
    ! grep -qx 'After=smortress-selinux-agent-shell.service' "$personal_bridge"; then
    printf '%s\n' "$head_of_cil" >&2
    return 1
  fi
}

# 13c. The two live general sources (T9, SDLC #851): `repos` reads the clean-bare
#      clones under /var/srv/git and `books` the OPDShelf library under
#      /var/srv/books. Both are live mounts of the general facade only, read-only,
#      and labeled by their datasets: a :z/:Z here would rewrite a shared label,
#      which is why the acceptance forbids it. The personal facade names neither.
@test "the general facade reads the two live trees" {
  local exec_line
  exec_line=$(sed -n 's/^Exec=//p' "$general_facade")
  if ! grep -qF -- '--repo-root /srv/git --books-root /srv/books ' <<<"$exec_line "; then
    printf '%s\n' "$exec_line" >&2
    return 1
  fi
}

@test "both general trees are mounted read-only" {
  local mounts
  mounts=$(grep -h '/var/srv' "$general_facade" || true)
  if ! grep -qxF 'Volume=/var/srv/git:/srv/git:ro' "$general_facade" ||
    ! grep -qxF 'Volume=/var/srv/books:/srv/books:ro' "$general_facade"; then
    printf '%s\n' "$mounts" >&2
    return 1
  fi
}

@test "the tree mounts relabel nothing" {
  ! grep -E '^Volume=/var/srv/(git|books):' "$general_facade" | grep -qE ':(z|Z)($|,)' &&
    ! grep -E '^(Volume|Exec)=' "$general_facade" | grep -qF 'label=disable'
}

@test "the personal facade names neither general tree" {
  local named
  named=$(grep -hE 'repo-root|books-root|/var/srv' "$personal_facade" || true)
  if grep -qF -- '--repo-root' "$personal_facade" ||
    grep -qF -- '--books-root' "$personal_facade" ||
    grep -qF '/var/srv/git' "$personal_facade" ||
    grep -qF '/var/srv/books' "$personal_facade"; then
    printf '%s\n' "$named" >&2
    return 1
  fi
}

@test "only the general facade mounts the general trees" {
  local naming
  naming=$(grep -lF -e '/var/srv/git' -e '/var/srv/books' units/quadlet/*.container || true)
  if [[ -n $(grep -vxF -- "$general_facade" <<<"$naming" || true) ]]; then
    printf '%s\n' "$naming" >&2
    return 1
  fi
}

# A module the runtime image does not copy is an ImportError at the first start,
# not a review note: the list is explicit, so every module has to be on it.

for _module in apps/agent_facade/*.py; do
  registered "the runtime image installs ${_module#apps/agent_facade/}" runtime_image_installs "$_module"
done
unset _module

# A token in a template would be a credential in an image both gateways share, and
# the placeholder is only safe while it is exactly the placeholder.
@test "no agent config template carries a facade token" {
  ! grep -rhn 'X-Deployment-Token:' "${agent_templates[@]}" | grep -qvE ': __FACADE_TOKEN__$'
}
