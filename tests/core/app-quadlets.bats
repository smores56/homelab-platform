#!/usr/bin/env bats
# Offline checks for the application Quadlets (SDLC #708, T5).
#
# The host half — real containers, a real restore, a real tailnet — is in
# docs/manual-steps.md section 40. This proves the half that needs no root and no
# network: every application image is our signed mirror at the pinned digest,
# every container is ordered after the recovery group it actually mounts, every
# loopback listener has a Serve route, every Podman secret is created from a
# decrypted file, and the one host-networked container has an explicit firewall
# boundary instead of a published port.
#
# Agent deployments (#711): the personal gateway and its model server share one
# internal network with no egress, the general gateway and the hosted proxy share
# the egress network, and only the proxy may name the provider key.
load ../helpers

# bats sources this file, and runs each test, inside a function: a table's
# `declare -A` arrays are local to that function and gone by the test body, so
# every test and every checker here sources the tables it exercises itself. A
# plain assignment survives (the immutable lists below are such), an array
# declared with `declare -A` does not. Forgetting this is the one mistake that
# makes a check pass without reading anything, so each one names its own tables.
#
# `register` is a @test bats only understands as a loop: its description is the
# text the shell suite printed after `ok `, which tests/parity.sh diffs. bats
# also refuses two tests with the same description and the same body, and this
# suite registers one check over one item more than once -- one image in two
# stages of a unit, one readiness instance for three volumes of a facade -- so
# `registered` appends a counter to the body. Every checker ignores an argument
# past the ones it reads.
registered_count=0
registered() { # description command...
  registered_count=$((registered_count + 1))
  register "$1" "${@:2}" "#$registered_count"
}

readonly app_quadlets=(
  units/quadlet/immich-server.container
  units/quadlet/immich-postgres.container
  units/quadlet/immich-valkey.container
  units/quadlet/immich-machine-learning.container
  units/quadlet/opdshelf.container
  units/quadlet/syncthing.container
  units/quadlet/navidrome.container
  units/quadlet/agent-model.container
  units/quadlet/agent-local.container
  units/quadlet/agent-general.container
  units/quadlet/agent-proxy.container
  units/quadlet/agent-facade-personal.container
  units/quadlet/agent-facade-general.container
  units/quadlet/agent-webui-personal.container
  units/quadlet/agent-webui-general.container
  units/quadlet/agent-tmail.container
  units/quadlet/agent-brave.container
)

# Ports that are published on loopback for the operator's own curl and are
# deliberately not a Serve route. 18003 is the hosted proxy: the gateway reaches
# it by container name on agent-general.network, so a tailnet path to it would
# only widen who can spend the provider key.
readonly no_serve_ports=(18003)

readonly image_interpreters=(/bin/sh /bin/bash /usr/bin/python3 /usr/bin/env /usr/bin/sh)
readonly runtime_containerfile=images/agent-runtime/Containerfile

# The file-scope sources below exist only to enumerate the items a register loop
# fans over, never to serve a test body. The loops parse those tables directly
# instead of calling their helpers: bats re-evaluates this whole file in every
# one of its ~570 test processes, so a fork per row costs a second of wall clock
# per hundred rows, and the loops are the only thing here that runs 570 times.
# shellcheck source=../scripts/app-images.sh disable=SC1091
source scripts/app-images.sh
# shellcheck source=../scripts/storage-layout.sh disable=SC1091
source scripts/storage-layout.sh

quadlet_images() { # quadlet
  sed -n 's/^Image=//p' "$1"
}

# The checks a register loop can name directly: one statement each, so the loop
# carries no per-item logic of its own.
file_exists() { # path
  [[ -f $1 ]]
}

quadlet_sets() { # quadlet key=value
  grep -qxF "$2" "$1"
}

image_enables() { # unit basename
  grep -qF "$1" bootc/server/Containerfile
}

image_is_pinned_in_the_table() { # image reference
  # shellcheck source=/dev/null
  source scripts/app-images.sh
  if ! app_image_matches "$1"; then
    printf '%s\n' "$1" >&2
    return 1
  fi
}

# 1. Every application image is our namespace at the pinned digest, and the pin
#    preserves the upstream digest the mirror verified.
declares_one_image() { # quadlet
  local images
  mapfile -t images < <(quadlet_images "$1")
  assert_equal "${#images[@]}" 1
}

runs_the_pinned_signed_mirror() { # quadlet
  # shellcheck source=/dev/null
  source scripts/app-images.sh
  local images
  mapfile -t images < <(quadlet_images "$1")
  printf '%s\n' "${images[0]:-}" >&2
  app_image_matches "${images[0]:-}"
}

for _q in "${app_quadlets[@]}"; do
  registered "$_q declares one image" declares_one_image "$_q"
  registered "$_q runs the pinned signed mirror" runs_the_pinned_signed_mirror "$_q"
done
unset _q

pin_is_a_digest() { # name
  # shellcheck source=/dev/null
  source scripts/app-images.sh
  local digest
  digest=$(app_image_digest "$1")
  printf '%s\n' "$digest" >&2
  [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]]
}

builds_from_an_existing_containerfile() { # name
  # shellcheck source=/dev/null
  source scripts/app-images.sh
  local built
  built=$(app_image_built "$1") || return 1
  if [[ ! -f $built ]]; then
    printf 'missing Containerfile %s\n' "$built" >&2
    return 1
  fi
}

built_row_has_no_copyable_source() { # name
  # shellcheck source=/dev/null
  source scripts/app-images.sh
  [[ $(app_image_source "$1" 2>/dev/null) == "" ]]
}

upstream_digest_equals_the_pin() { # name
  # shellcheck source=/dev/null
  source scripts/app-images.sh
  local digest upstream
  digest=$(app_image_digest "$1")
  upstream=$(app_image_upstream "$1")
  assert_equal "${upstream##*@}" "$digest"
}

pin_is_upstream() { # name
  # shellcheck source=/dev/null
  source scripts/app-images.sh
  local upstream
  upstream=$(app_image_upstream "$1")
  printf '%s\n' "$upstream" >&2
  [[ $upstream != "$(app_image_ref "$1")" ]]
}

for _row in "${app_images[@]}"; do
  IFS='|' read -r _name _upstream _digest <<<"$_row"
  if [[ -z $_name ]]; then
    continue
  fi
  registered "$_name pin is a digest" pin_is_a_digest "$_name"
  # A built row names the Containerfile this repository builds and signs itself
  # (publish-agent-webui.yml). The bytes are ours, so there is no upstream digest
  # to preserve and nothing for the mirror to copy -- only the Containerfile has
  # to exist, and the digest has to be the one that run printed.
  if [[ $_upstream == built:* ]]; then
    _built=${_upstream#built:}
    registered "$_name builds from $_built" builds_from_an_existing_containerfile "$_name"
    registered "$_name built row has no copyable source" built_row_has_no_copyable_source "$_name"
    continue
  fi
  if [[ $_upstream == *@sha256:* ]]; then
    registered "$_name upstream digest equals the pin" upstream_digest_equals_the_pin "$_name"
  fi
  # A pin that already names our namespace would make the mirror a no-op and the
  # signature check meaningless.
  registered "$_name pin is upstream" pin_is_upstream "$_name"
done
unset _row _name _upstream _digest _built

# 1b. The reference handed to skopeo is the upstream repository at the pinned
#     digest and carries no tag: skopeo refuses a name with both ("Docker
#     references with both a tag and digest are currently not supported"), which
#     is how the first publish run failed after merge. Built rows are skipped:
#     their workflow pushes them by digest and nothing copies them.
skopeo_source_is_repo_at_digest() { # name
  # shellcheck source=/dev/null
  source scripts/app-images.sh
  local digest upstream want_repo
  digest=$(app_image_digest "$1")
  upstream=$(app_image_upstream "$1")
  # Independent of app_image_source: strip the digest and then the tag with sed.
  want_repo=$(printf '%s\n' "$upstream" | sed -E 's/@sha256:[0-9a-f]+$//; s/:[^/:]+$//')
  assert_equal "$(app_image_source "$1")" "docker://$want_repo@$digest"
}

for _row in "${app_images[@]}"; do
  IFS='|' read -r _name _upstream _digest <<<"$_row"
  if [[ -z $_name || $_upstream == built:* ]]; then
    continue
  fi
  registered "$_name skopeo source is repo@digest" skopeo_source_is_repo_at_digest "$_name"
done
unset _row _name _upstream _digest

# 1b'. The refusal is what protects a built row from the mirror: with a
#      `built:` upstream there is no repository to copy, so a source that
#      silently stripped the prefix would hand skopeo a name that cannot resolve.
built_row_probe() {
  # shellcheck disable=SC2034  # the sourced helpers read this table
  app_images=("probe|built:images/agent-webui/Containerfile|sha256:$(printf 'a%.0s' {1..64})")
}

@test "a built row has no copyable source" {
  # shellcheck source=/dev/null
  source scripts/app-images.sh
  built_row_probe
  run app_image_source probe
  assert_failure
}

@test "a built row names its Containerfile" {
  # shellcheck source=/dev/null
  source scripts/app-images.sh
  built_row_probe
  assert_equal "$(app_image_built probe)" images/agent-webui/Containerfile
}

@test "a built row is referenced by our namespace at the pinned digest" {
  # shellcheck source=/dev/null
  source scripts/app-images.sh
  built_row_probe
  assert_equal "$(app_image_ref probe)" \
    "ghcr.io/smores56/homelab-platform/probe@sha256:$(printf 'a%.0s' {1..64})"
}

# 1c. containers/image verifies the platform manifest it copies, not the index
#     digest, so the mirror has to sign every pullable manifest of an index and
#     not just the index. Signing the index alone left every Quadlet pull on the
#     first T5 boot failing with "A signature was required, but no signature
#     exists".
@test "platform digests skip attestation manifests" {
  # shellcheck source=/dev/null
  source scripts/app-images.sh
  local fixture
  fixture='{"manifests":[
  {"digest":"sha256:aa","platform":{"os":"linux","architecture":"amd64"}},
  {"digest":"sha256:bb","platform":{"os":"linux","architecture":"arm64"}},
  {"digest":"sha256:cc","platform":{"os":"unknown","architecture":"unknown"}}]}'
  assert_equal "$(printf '%s' "$fixture" | app_image_platform_digests | paste -sd' ')" \
    "sha256:aa sha256:bb"
}

@test "a single-manifest image yields no platform digests" {
  # shellcheck source=/dev/null
  source scripts/app-images.sh
  assert_equal "$(printf '{"schemaVersion":2,"layers":[]}' | app_image_platform_digests)" ""
}

# 1d. Every unit the generator has to convert ships in the image. A network file
#     left out of the Containerfile makes the generator drop the container that
#     requests it, and opdshelf.network did exactly that on the first T5 boot.
image_installs() { # unit basename
  grep -qF "units/quadlet/$1" bootc/server/Containerfile
}

for _u in units/quadlet/*.container units/quadlet/*.network; do
  _unit=${_u#units/quadlet/}
  if [[ $_unit == pattern.container ]]; then
    continue
  fi
  registered "image installs $_unit" image_installs "$_unit"
done
unset _u _unit

# 2. A container that mounts a dataset is ordered after that dataset's
#    readiness instance, and requires no instance for a dataset it does not
#    mount. One that mounts no dataset (the machine learning cache) needs no
#    readiness at all. The table maps a volume path to an instance.
#
# A volume may name the dataset root or a directory inside it (the facades mount
# `state/agent-*/memory`, because the gateway's sessions and .env are one level
# up), so containment is what decides which instance a volume needs.
#
# The loop below asks that question once per volume, and the table answers it per
# dataset, so the map is built once for the whole pass. A `declare -A` is local
# to the scope bats sources this file into -- exactly the scope this loop runs
# in -- and no test body reads it: a checker sources the table and builds its own.
declare -A readiness_of_alias=()
for _key in "${dataset_order[@]}"; do
  _mountpoint=${dataset_mount[$_key]}
  readiness_of_alias[$_mountpoint]=${_key//\//-}
  case $_mountpoint in
    # The two spellings `mountpoint_aliases` prints. A checker calls that helper
    # rather than restating the rule, so a disagreement shows up as a failure
    # rather than as a quiet mis-mapping.
    */var/srv/*) readiness_of_alias[${_mountpoint/\/var\/srv//srv}]=${_key//\//-} ;;
  esac
done
unset _key _mountpoint

requires_readiness() { # quadlet instance
  # shellcheck source=/dev/null
  source scripts/storage-layout.sh
  local q=$1 instance=$2 key alias volume mounts=0
  local -A readiness_of_alias=()
  for key in "${dataset_order[@]}"; do
    while IFS= read -r alias; do
      readiness_of_alias[$alias]=${key//\//-}
    done < <(mountpoint_aliases "$key")
  done
  while IFS= read -r line; do
    case $line in
      Volume=*) ;;
      *) continue ;;
    esac
    volume=${line#Volume=}
    volume=${volume%%:*}
    for alias in "${!readiness_of_alias[@]}"; do
      if [[ $volume == "$alias" || $volume == "$alias"/* ]] &&
        [[ ${readiness_of_alias[$alias]} == "$instance" ]]; then
        mounts=1
      fi
    done
  done <"$q"
  if ((!mounts)); then
    printf '%s mounts no dataset that needs zfs-ready@%s\n' "$q" "$instance" >&2
    return 1
  fi
  grep -qE "^Requires=.*zfs-ready@$instance.service" "$q"
}

for _q in "${app_quadlets[@]}"; do
  _needed=' '
  _volumes=' '
  _declared=' '
  while IFS= read -r _line; do
    _rest=$_line
    # The instances the file declares, whether or not it mounts their dataset.
    while [[ $_rest =~ zfs-ready@([a-z-]*)\.service ]]; do
      _instance=${BASH_REMATCH[1]}
      _rest=${_rest#*"${BASH_REMATCH[0]}"}
      case $_declared in
        *" $_instance "*) ;;
        *) _declared="$_declared$_instance " ;;
      esac
    done
    case $_line in
      Volume=*) ;;
      *) continue ;;
    esac
    _volume=${_line#Volume=}
    _volume=${_volume%%:*}
    case " $_volumes " in
      *" $_volume "*) continue ;;
    esac
    _volumes="$_volumes $_volume"
    _instance=''
    for _alias in "${!readiness_of_alias[@]}"; do
      if [[ $_volume == "$_alias" || $_volume == "$_alias"/* ]]; then
        _instance=${readiness_of_alias[$_alias]}
        break
      fi
    done
    if [[ -z $_instance ]]; then
      continue
    fi
    _needed="$_needed$_instance "
    registered "$_q requires zfs-ready@$_instance" requires_readiness "$_q" "$_instance"
  done <"$_q"
  # A requirement for a dataset the file does not mount is dead, and the shell
  # suite only spoke up when it found one; the same check covers it here, and a
  # tree with none registers nothing.
  for _instance in $_declared; do
    if [[ $_needed != *" $_instance "* ]]; then
      registered "$_q requires zfs-ready@$_instance" requires_readiness "$_q" "$_instance"
    fi
  done
done
unset _q _line _rest _volume _volumes _declared _instance _needed _alias

# 3. A Podman secret only exists because a decrypted file produced it.
secret_is_created_from_a_decrypted_file() { # secret
  grep -qE "^readonly names=\(.*\b$1\b" scripts/app-secrets.sh
}

secret_has_a_decrypt_manifest_entry() { # secret
  grep -qE "^${1//./\\.}\.yaml[[:space:]]" bootc/server/rootfs/usr/share/smortress/secrets.manifest
}

declared=$(grep -h '^Secret=' "${app_quadlets[@]}" | cut -d= -f2 | cut -d, -f1 | sort -u)
for _secret in $declared; do
  registered "secret $_secret is created from a decrypted file" \
    secret_is_created_from_a_decrypted_file "$_secret"
  registered "secret $_secret has a decrypt manifest entry" \
    secret_has_a_decrypt_manifest_entry "$_secret"
done
unset _secret declared

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

# Both directions of the listener/Serve map live in this check: the shell suite
# only printed a line when a route pointed at no listener, so the reverse
# direction rides along here rather than standing as an ok of its own.
port_has_a_serve_route() { # port
  local port=$1 stray route_port
  if [[ " ${no_serve_ports[*]} " != *" $port "* ]]; then
    if ! grep -qE "\[[^]]*\]=${port}$" scripts/tailscale-serve.sh; then
      printf 'no Serve route for %s\n' "$port" >&2
      return 1
    fi
  fi
  stray=''
  for route_port in $(serve_route_ports); do
    if ! grep -qw "$route_port" <<<"$(published_ports)"; then
      stray="$stray $route_port"
    fi
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

# 6. The logical Immich dump lands in the photos unit's dump dataset and
#    completes before the daily offsite snapshot.
@test "immich dump writes inside the photos unit" {
  grep -q '/var/lib/immich/dumps' scripts/immich-dump.sh
}

calendar_hour() { # timer
  sed -n 's/^OnCalendar=\*-\*-\* \([0-9][0-9]\):[0-9][0-9]:00$/\1/p' "$1"
}

# The R2 job is at midnight, so "before" means a small positive distance across
# the day boundary: 21:00 -> 00:00 is three hours, 01:00 -> 00:00 is twenty-three.
dump_precedes_the_r2_job() {
  local dump_hour r2_hour gap
  dump_hour=$(calendar_hour units/systemd/smortress-immich-dump.timer)
  r2_hour=$(calendar_hour units/systemd/smortress-restic-backup-r2.timer)
  if [[ -z $dump_hour || -z $r2_hour ]]; then
    printf 'dump=%s r2=%s\n' "$dump_hour" "$r2_hour" >&2
    return 1
  fi
  gap=$(((10#$r2_hour - 10#$dump_hour + 24) % 24))
  if ((gap < 1 || gap > 4)); then
    printf 'gap=%sh dump=%s r2=%s\n' "$gap" "$dump_hour" "$r2_hour" >&2
    return 1
  fi
}

_dump_at=$(calendar_hour units/systemd/smortress-immich-dump.timer)
_r2_at=$(calendar_hour units/systemd/smortress-restic-backup-r2.timer)
if [[ -n $_dump_at && -n $_r2_at ]]; then
  registered "immich dump (${_dump_at}:00) precedes the R2 job (${_r2_at}:00) by $(((10#$_r2_at - 10#$_dump_at + 24) % 24))h" \
    dump_precedes_the_r2_job
else
  registered 'immich dump precedes the R2 job' dump_precedes_the_r2_job
fi
unset _dump_at _r2_at

@test "immich dump requires its dataset" {
  grep -q 'Requires=.*zfs-ready@raw-photos.service' units/systemd/smortress-immich-dump.service
}

# 6b. The dump is the whole database, and OPDShelf must not share Immich's
#    bridge; Syncthing must let its entrypoint do the privilege drop.
@test "immich dump is root-only" {
  grep -q '^UMask=0077' units/systemd/smortress-immich-dump.service
}

@test "opdshelf has its own network" {
  grep -q '^Network=opdshelf.network' units/quadlet/opdshelf.container &&
    grep -q '^Description=Smortress OPDShelf network' units/quadlet/opdshelf.network
}

@test "syncthing lets its entrypoint drop privileges" {
  ! grep -q '^User=' units/quadlet/syncthing.container
}

# 7. The storage table is the only list: the pool and the readiness check read
#    it rather than restating dataset names, and a dataset root belongs to the uid
#    the applications run as, which is what lets a restored tree be written
#    without a manual chown.
# The matched text is the source line, so $layout is deliberately literal.
# shellcheck disable=SC2016
@test "the pool and readiness scripts read the storage table" {
  ! grep -q '^groups=(' scripts/init-zpool.sh &&
    grep -q 'source "$layout"' scripts/init-zpool.sh &&
    grep -q 'source "$layout"' scripts/zfs-ready.sh
}

# The matched text is the source line, so $mountpoint is deliberately literal.
# shellcheck disable=SC2016
@test "the pool unit takes each dataset root owner from the table" {
  grep -q 'chown "$(dataset_owner_for "$key")" "$mountpoint"' scripts/init-zpool.sh
}

# Quadlet drops an empty Exec argument, so valkey's `--save ""` must stay inside
# a shell command or the container refuses to start on the host only.
@test "valkey disables snapshots through a shell wrapper" {
  grep -q "Exec=/bin/sh -c 'exec valkey-server" units/quadlet/immich-valkey.container &&
    grep -qF -- '--save ""' units/quadlet/immich-valkey.container
}

@test "valkey keeps its AOF in the dataset root" {
  grep -q -- '--dir /data --appendonly yes' units/quadlet/immich-valkey.container
}

# The readiness instances the image has to enable and the backup driver has to
# wait for. The shell suite read this list off init-zpool's plan; the plan is
# printed from the storage table, so the table answers the same.
instances=$( (source scripts/storage-layout.sh; printf '%s\n' "${dataset_order[@]}") | tr / -)

image_enables_readiness_instance() { # instance
  grep -q "zfs-ready@$1.service" bootc/server/Containerfile
}

backup_driver_waits_for_readiness_instance() { # instance
  grep -q "zfs-ready@$1.service" units/systemd/smortress-restic-backup@.service
}

for _instance in $instances; do
  registered "image enables zfs-ready@$_instance" image_enables_readiness_instance "$_instance"
  registered "backup driver is ordered after zfs-ready@$_instance" \
    backup_driver_waits_for_readiness_instance "$_instance"
done
unset _instance

# 8. The trust boundary itself: no upstream application registry may creep into
#    the policy just to make a pull succeed.
policy_does_not_trust_upstream() { # registry
  ! grep -q "\"$1\"" bootc/server/rootfs/etc/containers/policy.json
}

_registries=' '
for _row in "${app_images[@]}"; do
  IFS='|' read -r _name _upstream _digest <<<"$_row"
  if [[ -z $_name ]]; then
    continue
  fi
  _registry=${_upstream%%/*}
  case $_registries in
    *" $_registry "*) continue ;;
  esac
  _registries="$_registries$_registry "
  registered "policy does not trust upstream $_registry" policy_does_not_trust_upstream "$_registry"
done
unset _row _name _upstream _digest _registry _registries

# 9. The state directories the containers mount outside a recovery group are
#    created by tmpfiles, and every container runs as uid 1000. An entry naming
#    a login the image never creates is dropped ("Failed to resolve user
#    'smores': Unknown user") and podman then fails the unit with
#    "statfs <path>: no such file or directory", which is how the second T5 boot
#    lost immich-machine-learning and syncthing.
readonly tmpfiles=bootc/server/rootfs/etc/tmpfiles.d/smortress.conf

tmpfiles_creates_for_uid_1000() { # dir
  local line mode owner group
  line=$(grep -E "^d[[:space:]]+$1[[:space:]]" "$tmpfiles" || true)
  read -r _kind _path mode owner group _rest <<<"$line"
  assert_equal "$mode/$owner/$group" "0750/1000/1000"
}

for _dir in /var/lib/immich/ml-cache /var/lib/immich/valkey /var/lib/syncthing/versions; do
  registered "tmpfiles creates $_dir for uid 1000" tmpfiles_creates_for_uid_1000 "$_dir"
done
unset _dir

known_tmpfiles_owners() {
  printf '%s\n' root 0 1000
  local conf
  for conf in bootc/server/rootfs/etc/sysusers.d/*.conf; do
    if [[ ! -f $conf ]]; then
      continue
    fi
    sed -nE 's/^[ug] ([^ ]+).*/\1/p' "$conf"
  done
}

tmpfiles_entry_names_a_real_owner() { # path
  local line owner
  line=$(grep -E "^d[[:space:]]+$1[[:space:]]" "$tmpfiles" || true)
  read -r _kind _path _mode owner _group _rest <<<"$line"
  if [[ " $(known_tmpfiles_owners | paste -sd' ') " != *" $owner "* ]]; then
    printf '%s names uid %q, which no sysusers entry creates\n' "$1" "$owner" >&2
    return 1
  fi
}

while read -r _kind _path _mode _owner _group _rest; do
  if [[ $_kind != d ]]; then
    continue
  fi
  registered "tmpfiles entry $_path names a real owner" tmpfiles_entry_names_a_real_owner "$_path"
done < <(grep -vE '^#|^$' "$tmpfiles")
unset _kind _path _mode _owner _group _rest

# 10. A stopped container leaves a SIGTERM exit behind, and the applications exit
#     143 for it (immich-server did: "Main process exited, code=exited,
#     status=143"). Without declaring that as success, `systemctl stop` marks the
#     unit failed and it sits in `systemctl --failed` next to real failures.
treats_sigterm_stop_as_success() { # quadlet
  grep -q '^SuccessExitStatus=143$' "$1"
}

for _q in "${app_quadlets[@]}"; do
  registered "$_q treats a SIGTERM stop as success" treats_sigterm_stop_as_success "$_q"
done
unset _q

# 11. The agent deployments (#711). Two networks split by authority: the personal
#     side denies egress with a route and therefore has no way off the host, the
#     general side has egress and is the only side that can spend a hosted key --
#     which it does not hold. These are the properties a misread of the units
#     would silently undo.
readonly agent_local=units/quadlet/agent-local.container
readonly agent_general=units/quadlet/agent-general.container
readonly agent_model=units/quadlet/agent-model.container
readonly agent_proxy=units/quadlet/agent-proxy.container
readonly agent_templates=(bootc/server/rootfs/etc/smortress/agent/local-config.yaml
  bootc/server/rootfs/etc/smortress/agent/general-config.yaml)

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

declares_exactly_one_network() { # quadlet
  assert_equal "$(grep -c '^Network=' "$1")" 1
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

for _toolset in web search browser terminal file memory code_execution catalog \
  computer_use cronjob skills image_gen connections; do
  registered "the personal config disables the $_toolset toolset" personal_config_disables_toolset "$_toolset"
done
unset _toolset

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
# delegates to a script now that seeding also splices a token into a YAML file: a
# value built inside an `ExecStart` line is a value in the process table.
readonly seed_script=scripts/agent-config-seed.sh

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

# The facade token must not travel through argv or a command substitution: the
# script reads it with `read` and splices it with parameter expansion.
@test "the facade token is read into a variable, never into argv" {
  grep -qF 'while IFS= read -r line' "$seed_script" &&
    ! grep -vE '^[[:space:]]*#' "$seed_script" | grep -qE '\$\(cat|sed .*\$\(|awk -v token'
}

# The personal facade bind-mounts its index directory, and a bind source podman
# has to create would land root-owned inside the dataset, so the seed unit creates
# it at the container's uid -- on the personal side only, where the replicas are.
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
runtime_image_paths() { # the destinations the runtime image COPYs into place
  awk '/^COPY / { line = $0
                 while (line ~ /\\$/) { getline nxt; line = line " " nxt }
                 n = split(line, f, /[[:space:]]+/)
                 if (f[n] ~ /^\//) print f[n] }' "$runtime_containerfile"
}

baked_by_runtime_image() { # path
  local dest
  while IFS= read -r dest; do
    if [[ -z $dest ]]; then
      continue
    fi
    # A parent directory is delivered too: installing a file creates it, which is
    # how /usr/lib/agent-facade resolves though only its children are COPYed.
    if [[ $1 == "$dest" || $1 == "$dest"/* || $dest == "$1"/* ]]; then
      return 0
    fi
  done < <(runtime_image_paths)
  return 1
}

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

# The same rule for the facade in particular: its program is a Python package, so
# what has to be inside the container is the directory PYTHONPATH names.
names_a_tree_its_own_image_carries() { # quadlet
  [[ $(sed -n 's/^Environment=PYTHONPATH=//p' "$1") == /usr/lib/agent-facade/libs:/usr/lib/agent-facade ]] &&
    baked_by_runtime_image /usr/lib/agent-facade
}

for _q in units/quadlet/agent-facade-personal.container units/quadlet/agent-facade-general.container; do
  registered "$_q names a tree its own image carries" names_a_tree_its_own_image_carries "$_q"
done
unset _q

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

quadlet_publishes_nothing() { # quadlet
  if grep -q '^PublishPort=' "$1"; then
    printf '%s\n' "$(grep '^PublishPort=' "$1")" >&2
    return 1
  fi
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
runtime_image_installs() { # path in the repository
  grep -qF "$1" images/agent-runtime/Containerfile
}

for _module in apps/agent_facade/*.py; do
  registered "the runtime image installs ${_module#apps/agent_facade/}" runtime_image_installs "$_module"
done
unset _module

# A token in a template would be a credential in an image both gateways share, and
# the placeholder is only safe while it is exactly the placeholder.
@test "no agent config template carries a facade token" {
  ! grep -rhn 'X-Deployment-Token:' "${agent_templates[@]}" | grep -qvE ': __FACADE_TOKEN__$'
}

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

# 8. The collectors: the only processes with egress that write into the personal
#    dataset. Each runs the repository's own code out of the booted image, as uid
#    1000, with a read-only root, on the collectors' network -- never a
#    deployment's, because the general network carries the provider key.
collector_cases=(
  "finance|units/systemd/smortress-agent-collect-finance.service|units/systemd/smortress-agent-collect-finance.timer|simplefin-access-url"
)

collector_field() { # spec field number
  cut -d'|' -f"$2" <<<"$1"
}

collector_names_the_quadlet_network() { # spec
  assert_equal "$(grep -cE -- '--network systemd-agent-collect' "$(collector_field "$1" 2)")" 1
}

# Two stages reach two different places: the collector is on the Quadlet's
# network, the projection reads what it published and gets `none` because it
# needs no socket at all. Anything else is a unit that quietly grew egress.
collector_reaches_only_its_network_and_none() { # spec
  local unexpected
  unexpected=$(grep -E -- '^[[:space:]]*--network ' "$(collector_field "$1" 2)" |
    grep -vE -- '--network (systemd-agent-collect|none)([[:space:]\\]|$)' || true)
  if [[ -n $unexpected ]]; then
    printf '%s\n' "$unexpected" >&2
    return 1
  fi
}

collector_starts_the_generated_network_unit() { # spec
  local collector
  collector=$(collector_field "$1" 2)
  grep -qE '^Requires=.*agent-collect-network\.service' "$collector" &&
    grep -qE '^After=.*agent-collect-network\.service' "$collector"
}

collector_is_not_on_a_deployment_network() { # spec
  ! grep -qE -- '--network agent-(local|general)\.network' "$(collector_field "$1" 2)"
}

collector_runs_with() { # spec flag
  grep -qF -- "$2" "$(collector_field "$1" 2)"
}

collector_mounts_only_its_own_credential() { # spec
  grep -qF -- "--secret $(collector_field "$1" 4),type=mount,uid=1000,gid=1000,mode=0400" \
    "$(collector_field "$1" 2)"
}

collector_never_names_another_secret() { # spec
  ! grep -qE -- 'agent-(hosted-key|facade-(personal|general)-token)' "$(collector_field "$1" 2)"
}

collector_runs_a_pinned_image() { # spec image
  image_is_pinned_in_the_table "$2"
}

collector_runs_the_code_its_own_image_ships() { # spec
  baked_by_runtime_image /usr/lib/agent-facade &&
    ! grep -qF -- '/usr/lib/agent-facade:/usr/lib/agent-facade:ro' "$(collector_field "$1" 2)"
}

collector_timer_runs_the_collector() { # spec
  assert_equal "$(sed -n 's/^Unit=//p' "$(collector_field "$1" 3)")" \
    "$(basename "$(collector_field "$1" 2)")"
}

collector_timer_closes_a_missed_run() { # spec
  grep -qxF 'Persistent=true' "$(collector_field "$1" 3)"
}

for _case in "${collector_cases[@]}"; do
  IFS='|' read -r _name _collector _timer _secret <<<"$_case"
  registered "$_collector exists" file_exists "$_collector"
  registered "$_name collector names the network Quadlet actually creates" \
    collector_names_the_quadlet_network "$_case"
  registered "$_name collector reaches only its own network and none" \
    collector_reaches_only_its_network_and_none "$_case"
  registered "$_name collector starts the generated network unit" \
    collector_starts_the_generated_network_unit "$_case"
  registered "$_name collector is not on a deployment network" \
    collector_is_not_on_a_deployment_network "$_case"
  for _flag in '--read-only' '--cap-drop=all' '--security-opt no-new-privileges' '--user 1000:1000'; do
    registered "$_name collector runs with $_flag" collector_runs_with "$_case" "$_flag"
  done
  registered "$_name collector mounts only its own credential" \
    collector_mounts_only_its_own_credential "$_case"
  registered "$_name collector never names another deployment's secret" \
    collector_never_names_another_secret "$_case"
  while IFS= read -r _image; do
    registered "$_name collector runs a pinned image from the table" \
      collector_runs_a_pinned_image "$_case" "$_image"
  done < <(grep -oE 'ghcr\.io/smores56/homelab-platform/[a-z-]+@sha256:[0-9a-f]{64}' "$_collector")
  registered "$_name collector runs the code its own image ships" \
    collector_runs_the_code_its_own_image_ships "$_case"
  registered "$_timer runs the collector" collector_timer_runs_the_collector "$_case"
  registered "$_timer closes a missed run on the next boot" collector_timer_closes_a_missed_run "$_case"
done
unset _case _name _collector _timer _secret _flag _image

# 8.0. The two local-file collectors: a vault and a todo directory need no
#      provider, no network and no secret, so none of the shared case above
#      applies. What they must never grow is exactly that -- an address, a
#      credential, or a writable source -- and what they must carry is the
#      read-only source mount and the writable replica tree.
local_collectors=(
  "notes|units/systemd/smortress-agent-collect-notes.service|units/systemd/smortress-agent-collect-notes.timer|/srv/files/vault"
  "tasks|units/systemd/smortress-agent-collect-tasks.service|units/systemd/smortress-agent-collect-tasks.timer|/srv/files/notes"
  "photos|units/systemd/smortress-agent-collect-photos.service|units/systemd/smortress-agent-collect-photos.timer|/srv/photos"
  "music|units/systemd/smortress-agent-collect-music.service|units/systemd/smortress-agent-collect-music.timer|/srv/music"
)

local_collector_field() { # spec field number
  cut -d'|' -f"$2" <<<"$1"
}

local_collector_runs_with() { # spec flag
  grep -qF -- "$2" "$(local_collector_field "$1" 2)"
}

local_collector_is_one_stage() { # spec
  assert_equal "$(grep -cE '^ExecStart=' "$(local_collector_field "$1" 2)")" 1
}

local_collector_has_no_address() { # spec
  grep -qE -- '--network none([[:space:]\\]|$)' "$(local_collector_field "$1" 2)"
}

local_collector_names_no_network() { # spec
  ! grep -qE -- '--network (systemd-agent-collect|agent-(local|general))\b' \
    "$(local_collector_field "$1" 2)"
}

local_collector_mounts_its_source_read_only() { # spec
  grep -qF -- "--volume $(local_collector_field "$1" 4):/entities:ro" \
    "$(local_collector_field "$1" 2)"
}

local_collector_writes_one_replica_tree() { # spec
  grep -qF -- '--volume /var/lib/agent/local/replica:/replica:z' "$(local_collector_field "$1" 2)"
}

local_collector_holds_no_secret() { # spec
  ! grep -qE -- '--secret|/run/secrets|-e [A-Z_]+=' "$(local_collector_field "$1" 2)"
}

local_collector_runs_the_subcommand() { # spec
  local unit
  unit=$(local_collector_field "$1" 2)
  grep -qE -- '--entrypoint python3' "$unit" &&
    grep -qF -- "$(local_collector_field "$1" 1) --entities /entities" "$unit"
}

local_collector_waits_for_the_replica_dataset() { # spec
  local unit
  unit=$(local_collector_field "$1" 2)
  grep -qE '^Requires=.*zfs-ready@state-agent-local\.service' "$unit" &&
    grep -qE '^After=.*zfs-ready@state-agent-local\.service' "$unit"
}

local_collector_timer_runs_and_closes_a_missed_run() { # spec
  local timer
  timer=$(local_collector_field "$1" 3)
  [[ -f $timer ]] &&
    [[ $(sed -n 's/^Unit=//p' "$timer") == "$(basename "$(local_collector_field "$1" 2)")" ]] &&
    grep -qxF 'Persistent=true' "$timer"
}

for _case in "${local_collectors[@]}"; do
  IFS='|' read -r _name _unit _timer _source_dir <<<"$_case"
  registered "$_unit exists" file_exists "$_unit"
  registered "$_name collector is one stage" local_collector_is_one_stage "$_case"
  registered "$_name collector has no address at all" local_collector_has_no_address "$_case"
  registered "$_name collector names no network" local_collector_names_no_network "$_case"
  registered "$_name collector mounts its source read-only" \
    local_collector_mounts_its_source_read_only "$_case"
  registered "$_name collector writes one replica tree" local_collector_writes_one_replica_tree "$_case"
  for _flag in '--read-only' '--cap-drop=all' '--security-opt no-new-privileges' '--user 1000:1000'; do
    registered "$_name collector runs with $_flag" local_collector_runs_with "$_case" "$_flag"
  done
  registered "$_name collector holds no secret" local_collector_holds_no_secret "$_case"
  registered "$_name collector waits for the replica dataset" \
    local_collector_waits_for_the_replica_dataset "$_case"
  registered "$_name collector runs the collector subcommand" local_collector_runs_the_subcommand "$_case"
  while IFS= read -r _image; do
    registered "$_name collector runs a pinned image from the table" \
      collector_runs_a_pinned_image "$_case" "$_image"
  done < <(grep -oE 'ghcr\.io/smores56/homelab-platform/[a-z-]+@sha256:[0-9a-f]{64}' "$_unit")
  registered "$_timer runs the collector and closes a missed run" \
    local_collector_timer_runs_and_closes_a_missed_run "$_case"
done
unset _case _name _unit _timer _source_dir _flag _image

# 8.1. The finance collector's third stage: the hledger projection. It is derived
#     state, so it reads the replica read-only and writes one directory under the
#     personal index -- the same directory the seed unit creates at uid 1000.
readonly finance_unit=units/systemd/smortress-agent-collect-finance.service

@test "units/systemd/smortress-agent-collect-finance.service is collect then project" {
  assert_equal "$(grep -cE '^ExecStart=' "$finance_unit")" 2
}

@test "units/systemd/smortress-agent-collect-finance.service projects the replica into the personal index" {
  grep -qF -- '--volume /var/lib/agent/local/replica:/replica:ro' "$finance_unit" &&
    grep -qF -- '--volume /var/lib/agent/local/index:/index:z' "$finance_unit" &&
    grep -qF -- '--out /index/hledger/finance.journal' "$finance_unit"
}

@test "units/systemd/smortress-agent-collect-finance.service holds its credential in one stage only" {
  assert_equal "$(grep -cF -- '--secret ' "$finance_unit")" 1
}

# 8a. The calendar pair: our own exporter (session held on a volume, no secret)
#     followed by the collector. The session is the account's access, so it is
#     mounted read-write only into stage 1 and never into the collector.
readonly calendar=units/systemd/smortress-agent-collect-calendar.service
readonly calendar_timer=units/systemd/smortress-agent-collect-calendar.timer

@test "units/systemd/smortress-agent-collect-calendar.service exists" {
  [[ -f $calendar ]]
}

@test "units/systemd/smortress-agent-collect-calendar.service is dump then collect" {
  assert_equal "$(grep -cE '^ExecStart=' "$calendar")" 2
}

@test "units/systemd/smortress-agent-collect-calendar.service names the collector network" {
  assert_equal "$(grep -cE -- '--network systemd-agent-collect' "$calendar")" \
    "$(grep -cE -- '--network ' "$calendar")"
}

@test "the calendar pass holds no Podman secret" {
  ! grep -qE -- '--secret ' "$calendar"
}

@test "the calendar pass waits for the sealed session" {
  grep -qE '^ConditionPathExists=.*quarantine/tuta-calendar/session\.gpg' "$calendar"
}

@test "the session volume is mounted once, read-write" {
  assert_equal "$(grep -cF -- '/var/lib/agent/local/quarantine/tuta-calendar:/data:z' "$calendar")" 1
}

@test "the collector reads the dump read-only" {
  grep -qE -- '/var/lib/agent/local/quarantine/calendar:/entities:ro' "$calendar"
}

for _image in $(grep -oE 'ghcr\.io/smores56/homelab-platform/[a-z-]+@sha256:[0-9a-f]{64}' "$calendar"); do
  registered "the calendar pass runs a pinned image from the table" image_is_pinned_in_the_table "$_image"
done
unset _image

@test "units/systemd/smortress-agent-collect-calendar.timer runs the calendar pass" {
  assert_equal "$(sed -n 's/^Unit=//p' "$calendar_timer")" "$(basename "$calendar")"
}

@test "units/systemd/smortress-agent-collect-calendar.timer closes a missed run on the next boot" {
  grep -qxF 'Persistent=true' "$calendar_timer"
}

# 8b. The bridge: the provider half. It holds the Tuta session, so its volume is
#     the account, and it sits on the collectors' network rather than a
#     deployment's.
readonly bridge=units/quadlet/agent-tmail.container

@test "units/quadlet/agent-tmail.container exists" {
  [[ -f $bridge ]]
}

@test "the bridge runs a pinned image from the table" {
  # shellcheck source=/dev/null
  source scripts/app-images.sh
  local image
  image=$(grep -oE '^Image=.*' "$bridge" | cut -d= -f2-)
  if ! app_image_matches "$image"; then
    printf '%s\n' "$image" >&2
    return 1
  fi
}

@test "the bridge names exactly one network" {
  assert_equal "$(grep -cE '^Network=' "$bridge")" 1
}

@test "the bridge is on the collectors' network" {
  grep -qxF 'Network=agent-collect.network' "$bridge"
}

@test "the bridge's session volume is the one dataset path" {
  grep -qxF 'Volume=/var/lib/agent/local/quarantine/tmail:/data:z' "$bridge"
}

@test "the bridge has a read-only root" {
  grep -qxF 'ReadOnly=true' "$bridge"
}

@test "the bridge runs as the uid that owns its certificate" {
  grep -qxF 'User=1000:1000' "$bridge"
}

@test "the bridge has a writable tmpfs for its runtime dir" {
  grep -qE '^Tmpfs=/tmp:' "$bridge"
}

for _flag in 'NoNewPrivileges=true' 'DropCapability=ALL'; do
  registered "the bridge sets $_flag" quadlet_sets "$bridge" "$_flag"
done
unset _flag

@test "the bridge publishes nothing" {
  ! grep -qE '^PublishPort=' "$bridge"
}

# 8c. The mail stream collector: the one process that reads the bridge. It is a
#     long-running service, not a timer, and it must never hold the bridge's
#     session volume -- only the certificate it verifies.
readonly stream=units/systemd/smortress-agent-mail-stream.service

@test "units/systemd/smortress-agent-mail-stream.service exists" {
  [[ -f $stream ]]
}

@test "units/systemd/smortress-agent-mail-stream.service names exactly one network" {
  assert_equal "$(grep -cE -- '--network ' "$stream")" 1
}

@test "the mail stream runs on the collectors' network" {
  grep -qE -- '--network systemd-agent-collect' "$stream"
}

@test "the mail stream requires the Quadlet-generated bridge unit" {
  grep -qE '^(Requires|After)=.*agent-tmail\.service' "$stream"
}

@test "the mail stream waits for the certificate that init creates" {
  grep -qxF 'ConditionPathExists=/var/lib/agent/local/quarantine/tmail/config/tutabridge/cert.pem' \
    "$stream"
}

@test "the mail stream mounts only the bridge password" {
  grep -qF -- '--secret tmail-bridge-password,type=mount,uid=1000,gid=1000,mode=0400' "$stream"
}

@test "the mail stream never mounts the bridge's session volume" {
  ! grep -qE -- '--volume [^ ]*quarantine/tmail(:|/data)' "$stream"
}

@test "the mail stream verifies the bridge certificate" {
  grep -qF -- 'cert.pem:/bridge/cert.pem:ro' "$stream"
}

@test "the mail stream is a supervised long-running service" {
  grep -qE '^Restart=on-failure' "$stream" && grep -qE '^Type=simple' "$stream"
}

@test "the image enables the mail stream" {
  grep -qF 'smortress-agent-mail-stream.service' bootc/server/Containerfile
}

# 8d. The egress gate: an internal network with exactly two peers, and a policy
#     that lives in the image. A collector's reach is a reviewed fact, not
#     something a container can edit, and nothing is published.
@test "the browsing network is internal and addressed" {
  local brave_net=units/quadlet/agent-brave.network
  [[ -f $brave_net ]] && grep -qxF 'Internal=true' "$brave_net" && grep -qE '^Subnet=' "$brave_net"
}

@test "the egress policy is a document that grants exactly the sync host" {
  python3 - bootc/server/rootfs/etc/smortress/agent/egress-policy.json <<'PYJSON'
import json, sys
document = json.load(open(sys.argv[1], encoding="utf-8"))
allow = document["sources"]["brave"]["allow"]
assert "sync-v2.brave.com:443" in allow
PYJSON
}

egress_gate() { # gate (proxy or dns)
  printf 'units/quadlet/agent-egress-%s.container\n' "$1"
}

egress_gate_joins_only_the_internal_network() { # gate
  assert_equal "$(sed -n 's/^Network=agent-brave\.network.*//p' "$(egress_gate "$1")" | grep -c .)" 0
}

egress_gate_is_on_the_internal_network() { # gate
  grep -qE '^Network=agent-brave\.network(:ip=[0-9.]+)?$' "$(egress_gate "$1")"
}

egress_gate_reaches_upstream_on_the_collectors_network() { # gate
  grep -qxF 'Network=agent-collect.network' "$(egress_gate "$1")"
}

egress_gate_reads_the_policy_read_only() { # gate
  grep -qF 'egress-policy.json:/etc/smortress/agent/egress-policy.json:ro' "$(egress_gate "$1")"
}

quadlet_runs_a_pinned_image() { # quadlet
  # shellcheck source=/dev/null
  source scripts/app-images.sh
  local image
  image=$(grep -oE '^Image=.*' "$1" | cut -d= -f2-)
  image_is_pinned_in_the_table "$image"
}

for _gate in proxy dns; do
  _unit=units/quadlet/agent-egress-$_gate.container
  _base=${_unit##*/}
  registered "$_unit exists" file_exists "$_unit"
  registered "$_unit joins the internal network" egress_gate_joins_only_the_internal_network "$_gate"
  registered "$_unit is on the internal network" egress_gate_is_on_the_internal_network "$_gate"
  registered "$_unit reaches upstream on the collectors' network" \
    egress_gate_reaches_upstream_on_the_collectors_network "$_gate"
  registered "$_unit reads the policy read-only" egress_gate_reads_the_policy_read_only "$_gate"
  registered "$_unit publishes nothing" quadlet_publishes_nothing "$_unit"
  registered "$_unit runs a pinned image from the table" quadlet_runs_a_pinned_image "$_unit"
  registered "the image installs $_base" image_installs "$_base"
done
unset _gate _unit _base

@test "the DNS responder holds only the capability it needs" {
  grep -qxF 'AddCapability=NET_BIND_SERVICE' units/quadlet/agent-egress-dns.container &&
    grep -qxF 'DropCapability=ALL' units/quadlet/agent-egress-dns.container
}

@test "the collector network ships in the image" {
  grep -qF 'units/quadlet/agent-collect.network' bootc/server/Containerfile
}

secret_has_a_strict_manifest_entry() { # secret
  grep -qE "^${1//./\\.}\.yaml[[:space:]]" bootc/server/rootfs/usr/share/smortress/secrets.manifest
}

secret_becomes_a_podman_secret() { # secret
  grep -qF "$1" scripts/app-secrets.sh
}

for _secret in simplefin-access-url tmail-bridge-password; do
  registered "$_secret has a decrypt manifest entry" secret_has_a_strict_manifest_entry "$_secret"
  registered "$_secret becomes a Podman secret" secret_becomes_a_podman_secret "$_secret"
done
unset _secret

# 8e. The browsing collector (#713): a real browser whose only egress is the gate
#     above, a profile seeded before it starts, a snapshot the collector can
#     accept, and a watcher on the profile's own database. The peer addresses are
#     derived from the two gate Quadlets rather than repeated here: moving the
#     proxy or the resolver has to fail this section too.
readonly brave=units/quadlet/agent-brave.container
readonly brave_seed=units/systemd/smortress-agent-brave-seed.service
readonly brave_collect=units/systemd/smortress-agent-collect-brave.service
readonly brave_path=units/systemd/smortress-agent-collect-brave.path
readonly brave_timer=units/systemd/smortress-agent-collect-brave.timer

egress_proxy_ip() {
  sed -n 's/^Network=agent-brave\.network:ip=\([0-9.]*\)$/\1/p' units/quadlet/agent-egress-proxy.container
}
egress_proxy_port() {
  sed -n 's/^Exec=proxy .*--listen [0-9.]*:\([0-9]*\)$/\1/p' units/quadlet/agent-egress-proxy.container
}
egress_dns_ip() {
  sed -n 's/^Network=agent-brave\.network:ip=\([0-9.]*\)$/\1/p' units/quadlet/agent-egress-dns.container
}

@test "the egress gate names two distinct peers" {
  local proxy_ip proxy_port dns_ip
  proxy_ip=$(egress_proxy_ip)
  proxy_port=$(egress_proxy_port)
  dns_ip=$(egress_dns_ip)
  if [[ -z $proxy_ip || -z $proxy_port || -z $dns_ip || $proxy_ip == "$dns_ip" ]]; then
    printf 'proxy=%s:%s dns=%s\n' "$proxy_ip" "$proxy_port" "$dns_ip" >&2
    return 1
  fi
}

@test "units/quadlet/agent-brave.container exists" {
  [[ -f $brave ]]
}

@test "units/quadlet/agent-brave.container joins exactly one network" {
  assert_equal "$(grep -cE '^Network=' "$brave")" 1
}

@test "the browser is on the internal network and nowhere else" {
  grep -qE '^Network=agent-brave\.network(:ip=[0-9.]+)?$' "$brave"
}

@test "the browser publishes nothing" {
  ! grep -qE '^PublishPort=' "$brave"
}

@test "the browser runs a pinned image from the table" {
  quadlet_runs_a_pinned_image "$brave"
}

@test "the profile volume is the chain membership, label-shared" {
  grep -qxF 'Volume=/var/lib/agent/local/quarantine/brave-profile:/data:z' "$brave"
}

for _flag in 'ReadOnly=true' 'User=1000:1000' 'NoNewPrivileges=true' 'DropCapability=ALL'; do
  registered "the browser sets $_flag" quadlet_sets "$brave" "$_flag"
done
unset _flag

@test "the browser has a writable tmpfs for its scratch space" {
  grep -qE '^Tmpfs=/tmp:' "$brave"
}

@test "the browser resolves through the allowlist responder" {
  local dns_ip
  dns_ip=$(egress_dns_ip)
  if ! grep -qE -- "--dns=$dns_ip( |$)" "$brave"; then
    printf 'want --dns=%s\n' "$dns_ip" >&2
    return 1
  fi
}

@test "the browser's only egress is the allowlist proxy" {
  local proxy_ip proxy_port
  proxy_ip=$(egress_proxy_ip)
  proxy_port=$(egress_proxy_port)
  if ! grep -qE -- "--proxy-server=http://$proxy_ip:$proxy_port( |\$)" "$brave"; then
    printf 'want http://%s:%s\n' "$proxy_ip" "$proxy_port" >&2
    return 1
  fi
}

@test "the browser is bounded at 640/800 MiB" {
  grep -qE -- '--memory=640m' "$brave" && grep -qE -- '--memory-swap=800m' "$brave"
}

browser_runs_with() { # flag
  grep -qF -- "$1" "$brave"
}

for _flag in '--headless=new' '--no-sandbox' '--password-store=basic' '--user-data-dir=/data'; do
  registered "the browser runs with $_flag" browser_runs_with "$_flag"
done
unset _flag

@test "the browser restarts except on a deliberate stop" {
  grep -qxF 'Restart=always' "$brave" && grep -qxF 'SuccessExitStatus=143' "$brave"
}

@test "the browser starts after its profile is seeded" {
  grep -qE '^After=.*smortress-agent-brave-seed\.service' "$brave"
}

@test "units/systemd/smortress-agent-brave-seed.service exists" {
  [[ -f $brave_seed ]]
}

@test "the seed is planted before the Quadlet-generated browser unit" {
  grep -qE '^Before=.*agent-brave\.service' "$brave_seed"
}

@test "the seed is a Podman secret at uid 1000 mode 0400" {
  assert_equal "$(grep -cF -- '--secret brave-sync-seed,type=mount,uid=1000,gid=1000,mode=0400' "$brave_seed")" 1
}

@test "the seed unit waits for the profile directory the seeder creates" {
  grep -qxF 'ConditionPathExists=/var/lib/agent/local/quarantine/brave-profile' "$brave_seed"
}

@test "the seeder is a local one-shot with no address" {
  assert_equal "$(grep -cE '^ *--network ' "$brave_seed")" 1 &&
    grep -qE '^ *--network none' "$brave_seed" &&
    grep -qF -- '-m apps.brave_ingest.seed' "$brave_seed"
}

@test "the seeder is the second process that may write the profile" {
  grep -qE -- '/var/lib/agent/local/quarantine/brave-profile:/data:z' "$brave_seed"
}

@test "the image enables the seed unit" {
  grep -qF 'smortress-agent-brave-seed.service' bootc/server/Containerfile
}

@test "units/systemd/smortress-agent-collect-brave.service exists" {
  [[ -f $brave_collect ]]
}

@test "units/systemd/smortress-agent-collect-brave.service is snapshot then collect" {
  assert_equal "$(grep -cE '^ExecStart=' "$brave_collect")" 2
}

@test "the snapshot stage runs before the collector stage" {
  local snapshot_line collect_line
  snapshot_line=$(grep -nF 'apps.brave_ingest.snapshot' "$brave_collect" | cut -d: -f1)
  collect_line=$(grep -nF 'data_plane.collectors.raw' "$brave_collect" | cut -d: -f1)
  if [[ -z $snapshot_line || -z $collect_line || $snapshot_line -ge $collect_line ]]; then
    printf 'snapshot=%s collect=%s\n' "$snapshot_line" "$collect_line" >&2
    return 1
  fi
}

@test "only the snapshot writes the quarantine copy" {
  grep -qE -- '/var/lib/agent/local/quarantine/brave-profile:/profile:ro' "$brave_collect" &&
    grep -qE -- '/var/lib/agent/local/quarantine/brave:/quarantine:z' "$brave_collect"
}

@test "the collector reads the copy read-only" {
  grep -qE -- '/var/lib/agent/local/quarantine/brave:/quarantine:ro' "$brave_collect"
}

@test "the collector names the device and profile the replica is keyed by" {
  grep -qF -- 'brave --database /quarantine/History --device smortress --profile default' \
    "$brave_collect"
}

@test "neither stage has a network" {
  assert_equal "$(grep -cE -- '--network none' "$brave_collect")" 2
}

@test "the collection pass holds no Podman secret" {
  ! grep -qE -- '--secret ' "$brave_collect"
}

for _image in $(grep -oE 'ghcr\.io/smores56/homelab-platform/[a-z-]+@sha256:[0-9a-f]{64}' "$brave_collect"); do
  registered "the collection pass runs a pinned image from the table" image_is_pinned_in_the_table "$_image"
done
unset _image

for _unit in smortress-agent-collect-brave.path smortress-agent-collect-brave.timer; do
  registered "the image enables $_unit" image_enables "$_unit"
done
unset _unit

@test "units/systemd/smortress-agent-collect-brave.path exists" {
  [[ -f $brave_path ]]
}

@test "the watcher runs the collection pass" {
  assert_equal "$(sed -n 's/^Unit=//p' "$brave_path")" "$(basename "$brave_collect")"
}

@test "the watcher follows the profile's History" {
  assert_equal \
    "$(grep -cE '^PathModified=/var/lib/agent/local/quarantine/brave-profile/Default/History$' "$brave_path")" 1
}

@test "the watcher also follows the sidecar a write appears in first" {
  grep -qxF 'PathModified=/var/lib/agent/local/quarantine/brave-profile/Default/History-wal' \
    "$brave_path"
}

@test "the reconcile timer runs the collection pass" {
  assert_equal "$(sed -n 's/^Unit=//p' "$brave_timer")" "$(basename "$brave_collect")"
}

@test "the reconcile timer closes a missed pass on the next boot" {
  grep -qxF 'Persistent=true' "$brave_timer"
}

@test "the reconcile timer is six-hourly" {
  grep -qE '^OnCalendar=\*-\*-\* 00/6:' "$brave_timer"
}

# shellcheck disable=SC2016  # the matched text is a line of the seed script
@test "the seeder creates the profile 0700 and the copy 0750, personal only" {
  grep -qF 'install -d -o 1000 -g 1000 -m 0700 "$home/quarantine/brave-profile"' "$seed_script" &&
    grep -qF 'install -d -o 1000 -g 1000 -m 0750 "$home/quarantine/brave"' "$seed_script"
}

for _module in apps/brave_ingest/*.py; do
  registered "the runtime image installs ${_module#apps/brave_ingest/}" runtime_image_installs "$_module"
done
unset _module

@test "brave-sync-seed has a decrypt manifest entry" {
  grep -qE '^brave-sync-seed\.yaml[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+root[[:space:]]+root[[:space:]]+0400[[:space:]]+value' \
    bootc/server/rootfs/usr/share/smortress/secrets.manifest
}

@test "brave-sync-seed becomes a Podman secret" {
  grep -qF 'brave-sync-seed' scripts/app-secrets.sh
}

# `systemctl enable` on a unit with no [Install] section is a silent no-op: the
# build succeeds, `is-enabled` reports "static", and nothing starts it at boot.
# The mail stream and the Brave seed shipped that way and stayed dead until an
# operator started them by hand on every boot, so every unit the image enables
# has to be enableable. Template instances in the list come from packaged units
# and are skipped.
@test "every smortress unit the image enables declares [Install]" {
  local enable_block never_starts=() unit
  enable_block=$(sed -n '/systemctl enable \\$/,/;[[:space:]]*\\$/p' bootc/server/Containerfile)
  while read -r unit; do
    if [[ $unit == *@* ]]; then
      continue
    fi
    if [[ ! -f units/systemd/$unit ]]; then
      continue
    fi
    if ! grep -qx '\[Install\]' "units/systemd/$unit"; then
      never_starts+=("$unit")
    fi
  done < <(grep -oE 'smortress-[a-z0-9.-]+\.(service|timer|path)' <<<"$enable_block" | sort -u)
  if ((${#never_starts[@]} != 0)); then
    printf '%s\n' "${never_starts[*]}" >&2
    return 1
  fi
}

# A unit that runs the data plane has to hand the container the package, not
# only the facade tree: `-m data_plane` with `/usr/lib/agent-facade` alone is
# `No module named data_plane` on every tick. The calendar collector shipped
# that way and failed its first real run after a clean dump.
puts_the_data_plane_on_pythonpath() { # unit
  if ! grep -q -- '--env PYTHONPATH=/usr/lib/agent-facade/libs:/usr/lib/agent-facade' "$1"; then
    printf '%s\n' "$(grep -n 'PYTHONPATH' "$1" || echo 'no PYTHONPATH at all')" >&2
    return 1
  fi
}

for _unit in units/systemd/*.service; do
  _runs_data_plane=0
  while IFS= read -r _line; do
    case $_line in
      *'-m data_plane'*)
        _runs_data_plane=1
        break
        ;;
    esac
  done <"$_unit"
  if ((!_runs_data_plane)); then
    continue
  fi
  registered "$_unit puts the data plane on PYTHONPATH" puts_the_data_plane_on_pythonpath "$_unit"
done
unset _unit _line _runs_data_plane
