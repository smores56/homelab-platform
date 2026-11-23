#!/usr/bin/env bash
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
#
#   tests/core/app-quadlets.sh
set -uo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root" || exit 1
# shellcheck source=../scripts/app-images.sh disable=SC1091
source scripts/app-images.sh

pass=0
fail=0
ok() {
  pass=$((pass + 1))
  printf 'ok   %s\n' "$1"
}
bad() {
  fail=$((fail + 1))
  printf 'FAIL %s\n' "$1"
  [[ -n ${2:-} ]] && printf '     %s\n' "${2//$'\n'/$'\n'     }"
  return 0
}
eq() {
  if [[ $1 == "$2" ]]; then ok "$3"; else bad "$3" "got '$1' want '$2'"; fi
}

readonly app_quadlets=(
  units/quadlet/immich-server.container
  units/quadlet/immich-postgres.container
  units/quadlet/immich-valkey.container
  units/quadlet/immich-machine-learning.container
  units/quadlet/opdshelf.container
  units/quadlet/syncthing.container
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

app_names=$(app_image_names)

# 1. Every application image is our namespace at the pinned digest, and the pin
#    preserves the upstream digest the mirror verified.
for q in "${app_quadlets[@]}"; do
  if [[ ! -f $q ]]; then
    bad "$q exists"
    continue
  fi
  mapfile -t images < <(sed -n 's/^Image=//p' "$q")
  eq "${#images[@]}" 1 "$q declares one image"
  if app_image_matches "${images[0]}"; then
    ok "$q runs the pinned signed mirror"
  else
    bad "$q runs the pinned signed mirror" "${images[0]}"
  fi
done

for name in $app_names; do
  digest=$(app_image_digest "$name")
  if [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]]; then
    ok "$name pin is a digest"
  else
    bad "$name pin is a digest" "$digest"
  fi
  upstream=$(app_image_upstream "$name")
  # A built row names the Containerfile this repository builds and signs itself
  # (publish-agent-webui.yml). The bytes are ours, so there is no upstream digest
  # to preserve and nothing for the mirror to copy -- only the Containerfile has
  # to exist, and the digest has to be the one that run printed.
  if built=$(app_image_built "$name"); then
    if [[ -f $built ]]; then
      ok "$name builds from $built"
    else
      bad "$name builds from an existing Containerfile" "$built"
    fi
    if [[ $(app_image_source "$name" 2>/dev/null) == "" ]]; then
      ok "$name built row has no copyable source"
    else
      bad "$name built row has no copyable source" "$(app_image_source "$name" 2>&1)"
    fi
    continue
  fi
  if [[ $upstream == *@sha256:* ]]; then
    eq "${upstream##*@}" "$digest" "$name upstream digest equals the pin"
  fi
  # A pin that already names our namespace would make the mirror a no-op and the
  # signature check meaningless.
  if [[ $upstream != "$(app_image_ref "$name")" ]]; then
    ok "$name pin is upstream"
  else
    bad "$name pin is upstream" "$upstream"
  fi
done

# 1b. The reference handed to skopeo is the upstream repository at the pinned
#     digest and carries no tag: skopeo refuses a name with both ("Docker
#     references with both a tag and digest are currently not supported"), which
#     is how the first publish run failed after merge. Built rows are skipped:
#     their workflow pushes them by digest and nothing copies them.
for name in $app_names; do
  if app_image_built "$name" >/dev/null; then
    continue
  fi
  digest=$(app_image_digest "$name")
  upstream=$(app_image_upstream "$name")
  # Independent of app_image_source: strip the digest and then the tag with sed.
  want_repo=$(printf '%s\n' "$upstream" | sed -E 's/@sha256:[0-9a-f]+$//; s/:[^/:]+$//')
  eq "$(app_image_source "$name")" "docker://$want_repo@$digest" \
    "$name skopeo source is repo@digest"
done

# 1b'. The refusal is what protects a built row from the mirror: with a
#      `built:` upstream there is no repository to copy, so a source that
#      silently stripped the prefix would hand skopeo a name that cannot resolve.
probe=("probe|built:images/agent-webui/Containerfile|sha256:$(printf 'a%.0s' {1..64})")
if ( app_images=("${probe[@]}"); app_image_source probe >/dev/null 2>&1 ); then
  bad "a built row has no copyable source" "app_image_source accepted built:"
else
  ok "a built row has no copyable source"
fi
# shellcheck disable=SC2034  # the sourced helpers read this table
built_containerfile=$(app_images=("${probe[@]}"); app_image_built probe)
eq "$built_containerfile" "images/agent-webui/Containerfile" \
  "a built row names its Containerfile"
# shellcheck disable=SC2034  # the sourced helpers read this table
built_ref=$(app_images=("${probe[@]}"); app_image_ref probe)
eq "$built_ref" "ghcr.io/smores56/homelab-platform/probe@sha256:$(printf 'a%.0s' {1..64})" \
  "a built row is referenced by our namespace at the pinned digest"

# 1c. containers/image verifies the platform manifest it copies, not the index
#     digest, so the mirror has to sign every pullable manifest of an index and
#     not just the index. Signing the index alone left every Quadlet pull on the
#     first T5 boot failing with "A signature was required, but no signature
#     exists".
fixture='{"manifests":[
  {"digest":"sha256:aa","platform":{"os":"linux","architecture":"amd64"}},
  {"digest":"sha256:bb","platform":{"os":"linux","architecture":"arm64"}},
  {"digest":"sha256:cc","platform":{"os":"unknown","architecture":"unknown"}}]}'
eq "$(printf '%s' "$fixture" | app_image_platform_digests | paste -sd' ')" \
  "sha256:aa sha256:bb" "platform digests skip attestation manifests"
eq "$(printf '{"schemaVersion":2,"layers":[]}' | app_image_platform_digests)" "" \
  "a single-manifest image yields no platform digests"

# 1d. Every unit the generator has to convert ships in the image. A network file
#     left out of the Containerfile makes the generator drop the container that
#     requests it, and opdshelf.network did exactly that on the first T5 boot.
for u in units/quadlet/*.container units/quadlet/*.network; do
  unit=${u#units/quadlet/}
  [[ $unit == pattern.container ]] && continue
  if grep -qF "units/quadlet/$unit" image/Containerfile; then
    ok "image installs $unit"
  else
    bad "image installs $unit"
  fi
done

# 2. A container that mounts a dataset is ordered after that dataset's
#    readiness instance, and requires no instance for a dataset it does not
#    mount. One that mounts no dataset (the machine learning cache) needs no
#    readiness at all. The table maps a volume path to an instance.
# shellcheck source=/dev/null
source scripts/storage-layout.sh
declare -A mount_to_instance=()
# shellcheck disable=SC2154  # the storage table is sourced here
for _key in "${dataset_order[@]}"; do
  for _alias in $(mountpoint_aliases "$_key"); do
    mount_to_instance[$_alias]=$(readiness_instance "$_key")
  done
done
unset _key
# A volume may name the dataset root or a directory inside it (the facades mount
# `state/agent-*/memory`, because the gateway's sessions and .env are one level
# up), so containment is what decides which instance a volume needs.
instance_for_volume() {
  local volume=$1 alias
  for alias in "${!mount_to_instance[@]}"; do
    if [[ $volume == "$alias" || $volume == "$alias"/* ]]; then
      printf '%s\n' "${mount_to_instance[$alias]}"
      return 0
    fi
  done
  return 1
}
for q in "${app_quadlets[@]}"; do
  volumes=$(sed -n 's|^Volume=\([^:]*\).*|\1|p' "$q" | sort -u)
  for volume in $volumes; do
    instance=$(instance_for_volume "$volume") || continue
    if grep -qE "^Requires=.*zfs-ready@$instance.service" "$q"; then
      ok "$q requires zfs-ready@$instance"
    else
      bad "$q requires zfs-ready@$instance"
    fi
  done
  while IFS= read -r instance; do
    [[ -n $instance ]] || continue
    found=0
    for volume in $volumes; do
      [[ $(instance_for_volume "$volume") == "$instance" ]] && found=1
    done
    ((found)) || bad "$q requires zfs-ready@$instance for a dataset it does not mount"
  done < <(grep -o 'zfs-ready@[a-z-]*\.service' "$q" | sed 's/zfs-ready@//; s/\.service//' | sort -u)
done

# 3. A Podman secret only exists because a decrypted file produced it.
declared=$(grep -h '^Secret=' "${app_quadlets[@]}" | cut -d= -f2 | cut -d, -f1 | sort -u)
for secret in $declared; do
  if grep -qE "^readonly names=\(.*\b${secret}\b" scripts/app-secrets.sh; then
    ok "secret $secret is created from a decrypted file"
  else
    bad "secret $secret is created from a decrypted file"
  fi
  if grep -qE "^${secret//./\\.}\.yaml[[:space:]]" image/rootfs/usr/share/smortress/secrets.manifest; then
    ok "secret $secret has a decrypt manifest entry"
  else
    bad "secret $secret has a decrypt manifest entry"
  fi
done

# 4. Every loopback listener is fronted by a Serve route, and there is no route
#    to nothing. The Syncthing GUI is a listener too, even though it is not a
#    published port: it runs in the host network namespace.
published=$(
  {
    grep -h '^PublishPort=127\.0\.0\.1:' "${app_quadlets[@]}" | cut -d: -f2
    grep -h '^Environment=STGUIADDRESS=127\.0\.0\.1:' "${app_quadlets[@]}" | cut -d: -f2
  } | sort -u
)
for port in $published; do
  if [[ " ${no_serve_ports[*]} " == *" $port "* ]]; then
    ok "port $port is loopback-only diagnostics, not a Serve route"
  elif grep -qE "\[[^]]*\]=${port}$" scripts/tailscale-serve.sh; then
    ok "port $port has a Serve route"
  else
    bad "port $port has a Serve route"
  fi
done
while IFS= read -r port; do
  [[ -n $port ]] || continue
  if ! grep -qw "$port" <<<"$published"; then
    bad "Serve port $port belongs to a loopback listener"
  fi
done < <(grep -oE '\[[^]]*\]=[0-9]+' scripts/tailscale-serve.sh | cut -d= -f2 | sort -u)

# 5. The one non-HTTP container publishes nothing and is bounded by the
#    firewall instead; nothing may auto-update a pinned application image.
if grep -q '^Network=host' units/quadlet/syncthing.container; then
  ok 'syncthing uses host networking'
else
  bad 'syncthing uses host networking'
fi
if grep -q '^PublishPort=' units/quadlet/syncthing.container; then
  bad 'syncthing publishes no port'
else
  ok 'syncthing publishes no port'
fi
if grep -q '<port port="22000" protocol="tcp"/>' image/rootfs/etc/firewalld/zones/tailscale.xml &&
  grep -q '<port port="22000" protocol="udp"/>' image/rootfs/etc/firewalld/zones/tailscale.xml &&
  grep -q '<interface name="tailscale0"/>' image/rootfs/etc/firewalld/zones/tailscale.xml; then
  ok 'firewall permits 22000 on the tailscale zone only'
else
  bad 'firewall permits 22000 on the tailscale zone only'
fi
if grep -qE '^(AutoUpdate=|Pull=always)' "${app_quadlets[@]}"; then
  bad 'no application image auto-updates'
else
  ok 'no application image auto-updates'
fi
# A quadlet is a generated unit: [Install] is the only thing that starts it, and
# the check has to be per file or one good file hides five that never start.
for q in "${app_quadlets[@]}"; do
  if grep -q '^\[Install\]' "$q" && grep -q '^WantedBy=multi-user.target' "$q"; then
    ok "$q starts from [Install]"
  else
    bad "$q starts from [Install]"
  fi
done
if grep -qE 'systemctl enable (immich|opdshelf|syncthing)' image/Containerfile; then
  bad 'no application unit is enabled at build time'
else
  ok 'no application unit is enabled at build time'
fi

# 2. Every published port is loopback only, and the Serve route matches the host
#    port rather than the container port.
if grep -h '^PublishPort=' "${app_quadlets[@]}" | grep -qv '^PublishPort=127\.0\.0\.1:'; then
  bad 'every publish is loopback-only' "$(grep -h '^PublishPort=' "${app_quadlets[@]}" | grep -v '^PublishPort=127\.0\.0\.1:')"
else
  ok 'every publish is loopback-only'
fi

# 6. The logical Immich dump lands in the photos unit's dump dataset and
#    completes before the daily offsite snapshot.
if grep -q '/var/lib/immich/dumps' scripts/immich-dump.sh; then
  ok 'immich dump writes inside the photos unit'
else
  bad 'immich dump writes inside the photos unit'
fi
dump_hour=$(sed -n 's/^OnCalendar=\*-\*-\* \([0-9][0-9]\):[0-9][0-9]:00$/\1/p' \
  units/systemd/smortress-immich-dump.timer)
r2_hour=$(sed -n 's/^OnCalendar=\*-\*-\* \([0-9][0-9]\):[0-9][0-9]:00$/\1/p' \
  units/systemd/smortress-restic-backup-r2.timer)
# The R2 job is at midnight, so "before" means a small positive distance across
# the day boundary: 21:00 -> 00:00 is three hours, 01:00 -> 00:00 is twenty-three.
if [[ -n $dump_hour && -n $r2_hour ]]; then
  gap=$(((10#$r2_hour - 10#$dump_hour + 24) % 24))
  if ((gap >= 1 && gap <= 4)); then
    ok "immich dump (${dump_hour}:00) precedes the R2 job (${r2_hour}:00) by ${gap}h"
  else
    bad 'immich dump precedes the R2 job' "gap=${gap}h dump=$dump_hour r2=$r2_hour"
  fi
else
  bad 'immich dump precedes the R2 job' "dump=$dump_hour r2=$r2_hour"
fi
if grep -q 'Requires=.*zfs-ready@raw-photos.service' units/systemd/smortress-immich-dump.service; then
  ok 'immich dump requires its dataset'
else
  bad 'immich dump requires its dataset'
fi

# 6b. The dump is the whole database, and OPDShelf must not share Immich's
#    bridge; Syncthing must let its entrypoint do the privilege drop.
if grep -q '^UMask=0077' units/systemd/smortress-immich-dump.service; then
  ok 'immich dump is root-only'
else
  bad 'immich dump is root-only'
fi
if grep -q '^Network=opdshelf.network' units/quadlet/opdshelf.container &&
  grep -q '^Description=Smortress OPDShelf network' units/quadlet/opdshelf.network; then
  ok 'opdshelf has its own network'
else
  bad 'opdshelf has its own network'
fi
if grep -q '^User=' units/quadlet/syncthing.container; then
  bad 'syncthing lets its entrypoint drop privileges'
else
  ok 'syncthing lets its entrypoint drop privileges'
fi

# 7. The storage table is the only list: the pool and the readiness check read
# it rather than restating dataset names, and a dataset root belongs to the uid
# the applications run as, which is what lets a restored tree be written
# without a manual chown.
# The matched text is the source line, so $layout is deliberately literal.
# shellcheck disable=SC2016
if ! grep -q '^groups=(' scripts/init-zpool.sh &&
  grep -q 'source "$layout"' scripts/init-zpool.sh &&
  grep -q 'source "$layout"' scripts/zfs-ready.sh; then
  ok 'the pool and readiness scripts read the storage table'
else
  bad 'the pool and readiness scripts read the storage table'
fi
# The matched text is the source line, so $mountpoint is deliberately literal.
# shellcheck disable=SC2016
if grep -q 'chown "$(dataset_owner_for "$key")" "$mountpoint"' scripts/init-zpool.sh; then
  ok 'the pool unit takes each dataset root owner from the table'
else
  bad 'the pool unit takes each dataset root owner from the table'
fi

# Quadlet drops an empty Exec argument, so valkey's `--save ""` must stay inside
# a shell command or the container refuses to start on the host only.
if grep -q "Exec=/bin/sh -c 'exec valkey-server" units/quadlet/immich-valkey.container &&
  grep -qF -- '--save ""' units/quadlet/immich-valkey.container; then
  ok 'valkey disables snapshots through a shell wrapper'
else
  bad 'valkey disables snapshots through a shell wrapper'
fi
if grep -q -- '--dir /data --appendonly yes' units/quadlet/immich-valkey.container; then
  ok 'valkey keeps its AOF in the dataset root'
else
  bad 'valkey keeps its AOF in the dataset root'
fi

instances=$(scripts/init-zpool.sh --print-plan | awk '{print $1}' | sed 's|^[^/]*/||; s|/|-|')
for instance in $instances; do
  if grep -q "zfs-ready@$instance.service" image/Containerfile; then
    ok "image enables zfs-ready@$instance"
  else
    bad "image enables zfs-ready@$instance"
  fi
  if grep -q "zfs-ready@$instance.service" units/systemd/smortress-restic-backup@.service; then
    ok "backup driver is ordered after zfs-ready@$instance"
  else
    bad "backup driver is ordered after zfs-ready@$instance"
  fi
done

# 8. The trust boundary itself: no upstream application registry may creep into
#    the policy just to make a pull succeed.
for registry in $(for name in $app_names; do app_image_upstream "$name"; done |
  cut -d/ -f1 | sort -u); do
  if grep -q "\"$registry\"" image/rootfs/etc/containers/policy.json; then
    bad "policy trusts upstream $registry"
  else
    ok "policy does not trust upstream $registry"
  fi
done

# 9. The state directories the containers mount outside a recovery group are
#    created by tmpfiles, and every container runs as uid 1000. An entry naming
#    a login the image never creates is dropped ("Failed to resolve user
#    'smores': Unknown user") and podman then fails the unit with
#    "statfs <path>: no such file or directory", which is how the second T5 boot
#    lost immich-machine-learning and syncthing.
tmpfiles=image/rootfs/etc/tmpfiles.d/smortress.conf
for dir in /var/lib/immich/ml-cache /var/lib/immich/valkey /var/lib/syncthing/versions; do
  line=$(grep -E "^d[[:space:]]+${dir}[[:space:]]" "$tmpfiles" || true)
  read -r _kind _path mode owner group _rest <<<"$line"
  eq "$mode/$owner/$group" "0750/1000/1000" "tmpfiles creates $dir for uid 1000"
done
known_owners="root 0 1000"
for conf in image/rootfs/etc/sysusers.d/*.conf; do
  [[ -f $conf ]] || continue
  while read -r name _rest; do
    [[ -n $name ]] && known_owners="$known_owners $name"
  done < <(sed -nE 's/^[ug] ([^ ]+).*/\1/p' "$conf")
done
while read -r kind _path _mode owner _group _rest; do
  [[ $kind == d ]] || continue
  case " $known_owners " in
    *" $owner "*) ok "tmpfiles entry $_path names a real owner" ;;
    *) bad "tmpfiles entry $_path names a real owner" "$owner" ;;
  esac
done < <(grep -vE '^#|^$' "$tmpfiles")

# 10. A stopped container leaves a SIGTERM exit behind, and the applications exit
#     143 for it (immich-server did: "Main process exited, code=exited,
#     status=143"). Without declaring that as success, `systemctl stop` marks the
#     unit failed and it sits in `systemctl --failed` next to real failures.
for q in "${app_quadlets[@]}"; do
  if grep -q '^SuccessExitStatus=143$' "$q"; then
    ok "$q treats a SIGTERM stop as success"
  else
    bad "$q treats a SIGTERM stop as success"
  fi
done

# 11. The agent deployments (#711). Two networks split by authority: the personal
#     side denies egress with a route and therefore has no way off the host, the
#     general side has egress and is the only side that can spend a hosted key --
#     which it does not hold. These are the properties a misread of the units
#     would silently undo.
agent_local=units/quadlet/agent-local.container
agent_general=units/quadlet/agent-general.container
agent_model=units/quadlet/agent-model.container
agent_proxy=units/quadlet/agent-proxy.container
agent_templates=(image/rootfs/etc/smortress/agent/local-config.yaml
  image/rootfs/etc/smortress/agent/general-config.yaml)

# `Internal=true` cannot be the personal side's answer: netavark skips port
# forwarding entirely for internal networks, so the gateway and the web UI would
# listen while their published ports stayed dead. Egress is denied by the route.
if grep -qxF 'Options=no_default_route=true' units/quadlet/agent-local.network; then
  ok 'the personal network has no default route'
else
  bad 'the personal network has no default route'
fi
if grep -q '^Internal=' units/quadlet/agent-local.network; then
  bad 'the personal network is not an internal network' \
    'Internal=true disables the published ports'
else
  ok 'the personal network is not an internal network'
fi
# `podman network create --ignore` leaves an existing network's config alone, so
# an option change without this is silently ignored until someone deletes the
# network by hand.
if grep -qxF 'NetworkDeleteOnStop=true' units/quadlet/agent-local.network; then
  ok 'the personal network is recreated from this file at every boot'
else
  bad 'the personal network is recreated from this file at every boot'
fi
if grep -q '^Internal=' units/quadlet/agent-general.network; then
  bad 'the general network has egress'
else
  ok 'the general network has egress'
fi
for q in "$agent_local" "$agent_general" "$agent_model" "$agent_proxy"; do
  eq "$(grep -c '^Network=' "$q")" 1 "$q declares exactly one network"
done
eq "$(sed -n 's/^Network=//p' "$agent_local")" agent-local.network \
  'the personal gateway is on the sealed network only'
eq "$(sed -n 's/^Network=//p' "$agent_general")" agent-general.network \
  'the general gateway is on the egress network only'
eq "$(sed -n 's/^Network=//p' "$agent_proxy")" agent-general.network \
  'the proxy is on the egress network only'
eq "$(sed -n 's/^Network=//p' "$agent_model")" agent-local.network \
  'the model server is on the sealed network only'

# The stateful runtimes cannot be read-only; the model server can, and the proxy
# holds the credential file, so it is.
if grep -q '^ReadOnly=true$' "$agent_model" && grep -q '^ReadOnly=true$' "$agent_proxy"; then
  ok 'the model server and the proxy have a read-only root filesystem'
else
  bad 'the model server and the proxy have a read-only root filesystem'
fi
for q in "$agent_local" "$agent_general"; do
  if grep -q '^ReadOnly=false$' "$q" && grep -q '^NoNewPrivileges=true$' "$q"; then
    ok "$q is writable state under the same hardening"
  else
    bad "$q is writable state under the same hardening"
  fi
  # The runtime image refuses `--user <arbitrary uid>` ("not supported") and asks
  # for HERMES_UID/HERMES_GID, which remap its internal account to the platform uid
  # and chown the volume. A `User=` here would be a container that cannot start, so
  # the uid-1000 convention is reached the way the image supports.
  if grep -q '^Environment=HERMES_UID=1000$' "$q" &&
    grep -q '^Environment=HERMES_GID=1000$' "$q" &&
    ! grep -q '^User=' "$q"; then
    ok "$q remaps the runtime to uid 1000 instead of forcing --user"
  else
    bad "$q remaps the runtime to uid 1000 instead of forcing --user"
  fi
done

# GPU access is a device plus the SELinux type the device nodes carry: without the
# type, NVML answers "Insufficient Permissions" instead of a GPU.
if grep -q '^AddDevice=nvidia.com/gpu=all$' "$agent_model" &&
  grep -q '^SecurityLabelType=nvidia_container_t$' "$agent_model"; then
  ok 'the model server addresses the GPU through the CDI device and its label'
else
  bad 'the model server addresses the GPU through the CDI device and its label'
fi
# The CDI spec only hands the container a device node; SELinux decides whether
# llama.cpp may mmap it. crun creates that node as container_file_t and
# nvidia_container_t has no `map` on the type, so the server silently ran on CPU
# with nvidia-smi showing nothing. The rule ships as a CIL file and is loaded
# before the model server starts.
map_cil=image/rootfs/usr/share/selinux/smortress/agent-nvidia-map.cil
map_unit=units/systemd/smortress-selinux-nvidia-map.service
if grep -qF '(allow nvidia_container_t container_file_t (chr_file (map)))' "$map_cil"; then
  ok 'the rule that lets the model server map the GPU ships'
else
  bad 'the rule that lets the model server map the GPU ships'
fi
if grep -qxF 'Before=agent-model.service' "$map_unit" &&
  grep -qF 'semodule -i /usr/share/selinux/smortress/agent-nvidia-map.cil' "$map_unit"; then
  ok 'the rule is loaded before the model server starts'
else
  bad 'the rule is loaded before the model server starts'
fi
if grep -q 'nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml' units/systemd/smortress-nvidia-cdi.service &&
  grep -q '^Before=agent-model.service$' units/systemd/smortress-nvidia-cdi.service &&
  grep -qE '^(Requires|After)=.*smortress-nvidia-cdi.service' "$agent_model"; then
  ok 'the CDI spec is generated before the model container starts'
else
  bad 'the CDI spec is generated before the model container starts'
fi

# The provider key is one file, read by one program. Nothing else may name it.
key_mentioning=$(grep -l 'agent-hosted-key' units/quadlet/*.container "${agent_templates[@]}" 2>/dev/null |
  sort | paste -sd' ')
eq "$key_mentioning" "$agent_proxy" 'only the proxy names the hosted key'
if grep -rqE '^[[:space:]]*api_key:' "${agent_templates[@]}"; then
  bad 'no agent config template carries an api key'
else
  ok 'no agent config template carries an api key'
fi
if grep -q '^Exec=/usr/libexec/agent-proxy$' "$agent_proxy" &&
  grep -qF 'apps/agent_proxy/proxy.py /usr/libexec/agent-proxy' \
    images/agent-runtime/Containerfile; then
  ok 'the proxy unit runs the shipped program'
else
  bad 'the proxy unit runs the shipped program'
fi
# The runtime image's entrypoint is a dispatcher into an s6 tree that boots the
# gateway; the proxy is one program, and it also refuses an arbitrary --user.
if grep -q '^Entrypoint=python3$' "$agent_proxy" && grep -q '^User=1000:1000$' "$agent_proxy"; then
  ok 'the proxy bypasses the runtime entrypoint and runs as uid 1000'
else
  bad 'the proxy bypasses the runtime entrypoint and runs as uid 1000'
fi

# The runtime refuses a model under 64,000 tokens, so the server's window and the
# config's pin are one decision in two files.
# `-c` is the TOTAL context and llama.cpp divides it across --parallel slots, so
# the config's context_length is one slot: c / parallel, never c itself. A unit
# that changes --parallel without -c shrinks every slot under the runtime's floor.
model_context=$(sed -n 's/^Exec=.*-c \([0-9]*\).*/\1/p' "$agent_model")
slot_parallel=$(sed -n 's/^Exec=.*--parallel \([0-9]*\).*/\1/p' "$agent_model")
config_context=$(sed -n 's/^  context_length: //p' image/rootfs/etc/smortress/agent/local-config.yaml)
if [[ -n $model_context && -n $slot_parallel && $slot_parallel -gt 0 ]] &&
  ((model_context % slot_parallel == 0)) &&
  ((model_context / slot_parallel == config_context)) && ((config_context >= 64000)); then
  ok "each model slot is pinned to $config_context tokens like the config"
else
  bad 'each model slot is pinned like the config' \
    "model=$model_context parallel=$slot_parallel config=$config_context"
fi
if grep -qE '^Exec=.*-fa on' "$agent_model" &&
  grep -qE '^Exec=.*-ctk q8_0' "$agent_model"; then
  ok 'the model server runs flash attention with a quantized cache'
else
  bad 'the model server runs flash attention with a quantized cache'
fi
local_disabled=$(sed -n '/^  disabled_toolsets:/,/^[^ -]/p' image/rootfs/etc/smortress/agent/local-config.yaml)
for toolset in web search browser terminal file memory code_execution catalog \
  computer_use cronjob skills image_gen connections; do
  if grep -qE "^[[:space:]]+- ${toolset}$" <<<"$local_disabled"; then
    ok "the personal config disables the $toolset toolset"
  else
    bad "the personal config disables the $toolset toolset"
  fi
done

# Subagents are wanted, and they are the one runtime default the personal side
# keeps on purpose: a child inherits this process's provider and MCP toolsets, so
# it adds concurrency, not authority. The cap is what keeps it inside four llama.cpp
# slots, and the flat depth is what stops a spawn tree.
if grep -qE '^delegation:$' image/rootfs/etc/smortress/agent/local-config.yaml; then
  ok 'the personal config enables subagents'
else
  bad 'the personal config enables subagents'
fi
local_delegation=$(sed -n '/^delegation:/,/^[^ ]/p' image/rootfs/etc/smortress/agent/local-config.yaml)
if grep -qE '^  max_concurrent_children: [1-2]$' <<<"$local_delegation" &&
  grep -qE '^  max_spawn_depth: 1$' <<<"$local_delegation"; then
  ok 'the personal subagents are capped at two concurrent and one level'
else
  bad 'the personal subagents are capped at two concurrent and one level' "$local_delegation"
fi
general_delegation=$(sed -n '/^delegation:/,/^[^ ]/p' image/rootfs/etc/smortress/agent/general-config.yaml)
if grep -qE '^  max_concurrent_children: [1-3]$' <<<"$general_delegation" &&
  grep -qE '^  max_spawn_depth: 1$' <<<"$general_delegation"; then
  ok 'the general subagents are capped at three concurrent and one level'
else
  bad 'the general subagents are capped at three concurrent and one level' "$general_delegation"
fi

# The runtime has no _FILE variant, so the key reaches it through .env written by
# the seed unit -- from the decrypted ciphertext, at the container's uid. The unit
# delegates to a script now that seeding also splices a token into a YAML file: a
# value built inside an `ExecStart` line is a value in the process table.
seed_script=scripts/agent-config-seed.sh
# shellcheck disable=SC2016  # the matched text is the seed script's own source line
if grep -qF 'for spec in personal:local general:general; do' "$seed_script" &&
  grep -qF 'api_key=$secrets_dir/agent-$state-api-key.yaml' "$seed_script" &&
  grep -q 'ExecStart=/usr/libexec/agent-config-seed' units/systemd/smortress-agent-config.service; then
  ok 'the seed unit derives both gateway keys from their ciphertext'
else
  bad 'the seed unit derives both gateway keys from their ciphertext'
fi
# shellcheck disable=SC2016  # the matched text is the seed script's own source line
if grep -qF -- '-m 0400' "$seed_script" &&
  grep -qF 'cp -n "$template" "$config"' "$seed_script"; then
  ok 'the seed unit is idempotent and keeps the key owner-only'
else
  bad 'the seed unit is idempotent and keeps the key owner-only'
fi
# The facade token must not travel through argv or a command substitution: the
# script reads it with `read` and splices it with parameter expansion.
if grep -qF 'while IFS= read -r line' "$seed_script" &&
  ! grep -vE '^[[:space:]]*#' "$seed_script" | grep -qE '\$\(cat|sed .*\$\(|awk -v token'; then
  ok 'the facade token is read into a variable, never into argv'
else
  bad 'the facade token is read into a variable, never into argv'
fi
# The personal facade bind-mounts its index directory, and a bind source podman
# has to create would land root-owned inside the dataset, so the seed unit creates
# it at the container's uid -- on the personal side only, where the replicas are.
# shellcheck disable=SC2016  # the matched text is the seed script's own source line
if grep -qF 'if [[ $state == local ]]; then' "$seed_script" &&
  grep -qF 'install -d -o 1000 -g 1000 -m 0750 "$home/index"' "$seed_script"; then
  ok 'the seed unit creates the personal index directory at the container uid'
else
  bad 'the seed unit creates the personal index directory at the container uid'
fi

# 12. Code delivery. A Quadlet hands `Exec=`/`Entrypoint=` a program that has to
#     exist inside the container's own filesystem. The agent-runtime image is ours
#     now (images/agent-runtime/Containerfile), so a path is delivered when that
#     image installs it, when a Volume= or Secret= puts it there, or when it is one
#     of the interpreters every image carries. agent-proxy once shipped
#     `Exec=/usr/libexec/agent-proxy` with neither a mount nor the program, and
#     python3 started against a path that was not there -- this is the assertion
#     that would have caught it.
readonly image_interpreters=(/bin/sh /bin/bash /usr/bin/python3 /usr/bin/env /usr/bin/sh)
readonly runtime_containerfile=images/agent-runtime/Containerfile
runtime_image_paths() { # the destinations the runtime image COPYs into place
  awk '/^COPY / { line = $0
                 while (line ~ /\\$/) { getline nxt; line = line " " nxt }
                 n = split(line, f, /[[:space:]]+/)
                 if (f[n] ~ /^\//) print f[n] }' "$runtime_containerfile"
}
baked_by_runtime_image() { # path
  local dest
  while IFS= read -r dest; do
    [[ -n $dest ]] || continue
    # A parent directory is delivered too: installing a file creates it, which is
    # how /usr/lib/agent-facade resolves though only its children are COPYed.
    [[ $1 == "$dest" || $1 == "$dest"/* || $dest == "$1"/* ]] && return 0
  done < <(runtime_image_paths)
  return 1
}
volume_container_paths() { sed -n 's|^Volume=[^:]*:\([^:]*\).*|\1|p' "$1"; }
secret_targets() { sed -n 's/^Secret=.*target=\([^,]*\).*/\1/p' "$1"; }
covered_by_volume() { # quadlet path
  local container_path
  while IFS= read -r container_path; do
    [[ -n $container_path ]] || continue
    [[ $2 == "$container_path" || $2 == "$container_path"/* ]] && return 0
  done < <(volume_container_paths "$1")
  return 1
}
covered_by_secret() { # quadlet path
  local target
  while IFS= read -r target; do
    [[ -n $target && $2 == "$target" ]] && return 0
  done < <(secret_targets "$1")
  return 1
}
for q in "${app_quadlets[@]}"; do
  while IFS= read -r path; do
    [[ -n $path ]] || continue
    accounted=0
    for interpreter in "${image_interpreters[@]}"; do
      [[ $path == "$interpreter" ]] && accounted=1
    done
    if ((!accounted)) && baked_by_runtime_image "$path"; then accounted=1; fi
    if ((!accounted)) && covered_by_volume "$q" "$path"; then accounted=1; fi
    if ((!accounted)) && covered_by_secret "$q" "$path"; then accounted=1; fi
    if ((accounted)); then
      ok "$q delivers $path"
    else
      bad "$q delivers $path" "neither the runtime image nor a Volume=/Secret= puts it inside the container"
    fi
  done < <(sed -n 's/^\(Exec\|Entrypoint\)=//p' "$q" | tr ' ' '\n' |
    grep -E '^/[A-Za-z0-9._/-]+$' | sort -u)
done
# The same rule for the facade in particular: its program is a Python package, so
# what has to be inside the container is the directory PYTHONPATH names.
for q in units/quadlet/agent-facade-personal.container units/quadlet/agent-facade-general.container; do
  if [[ $(sed -n 's/^Environment=PYTHONPATH=//p' "$q") == /usr/lib/agent-facade/libs:/usr/lib/agent-facade ]] &&
    baked_by_runtime_image /usr/lib/agent-facade; then
    ok "$q names a tree its own image carries"
  else
    bad "$q names a tree its own image carries"
  fi
done
# The collectors run the same package through a plain podman unit, where the
# environment is a podman argument rather than Quadlet's Environment=. The rule
# above covered only the Quadlet, so both collectors shipped a PYTHONPATH one
# directory too high and could not import data_plane at all — the image puts the
# package under /usr/lib/agent-facade/libs.
collector_pythonpath=0
for u in units/systemd/smortress-agent-collect-finance.service \
  units/systemd/smortress-agent-mail-stream.service; do
  if ! grep -qF -- '--env PYTHONPATH=/usr/lib/agent-facade/libs:/usr/lib/agent-facade' "$u"; then
    bad "$u names the package root in PYTHONPATH" "$(grep -F -- '--env PYTHONPATH=' "$u")"
    collector_pythonpath=1
  fi
done
((collector_pythonpath)) || ok 'the collector units name the package root in PYTHONPATH'

# 13. The two source facades (T2b). They complete the deployment split: each
#     gateway reads its sources and its memory through one facade process of its
#     own deployment, whose only client is that gateway. Container name, port and
#     deployment are one decision in two files (the unit and the gateway template),
#     so both sides are checked against each other.
for spec in personal:local:18004 general:general:18005; do
  deployment=${spec%%:*}
  rest=${spec#*:}
  state=${rest%%:*}
  port=${rest##*:}
  q=units/quadlet/agent-facade-$deployment.container
  template=image/rootfs/etc/smortress/agent/$state-config.yaml

  eq "$(grep -c '^Network=' "$q")" 1 "$q declares exactly one network"
  eq "$(sed -n 's/^Network=//p' "$q")" "agent-$state.network" \
    "the $deployment facade is on its own deployment's network only"
  if grep -q '^PublishPort=' "$q"; then
    bad "$q publishes nothing" "$(grep '^PublishPort=' "$q")"
  else
    ok "$q publishes nothing"
  fi
  if grep -q '^ReadOnly=true$' "$q" && grep -q '^NoNewPrivileges=true$' "$q" &&
    grep -q '^DropCapability=ALL$' "$q" && grep -q '^User=1000:1000$' "$q"; then
    ok "$q runs hardened as uid 1000 with a read-only root filesystem"
  else
    bad "$q runs hardened as uid 1000 with a read-only root filesystem"
  fi
  if grep -q '^Entrypoint=python3$' "$q"; then
    ok "$q bypasses the runtime entrypoint"
  else
    bad "$q bypasses the runtime entrypoint"
  fi
  exec_line=$(sed -n 's/^Exec=//p' "$q")
  for want in '-m apps.agent_facade' '--transport http' "--deployment $deployment" \
    "--token-file /run/secrets/agent-facade-$deployment-token" \
    '--memory-root /memory' '--host 0.0.0.0' "--port $port"; do
    if [[ " $exec_line " == *" $want "* ]]; then
      ok "$q runs the facade with $want"
    else
      bad "$q runs the facade with $want" "$exec_line"
    fi
  done
  eq "$(sed -n 's/^Secret=//p' "$q" | cut -d, -f1)" "agent-facade-$deployment-token" \
    "$q mounts its deployment token by name"
  if grep -q "^Volume=/var/lib/agent/$state/memory:/memory:z$" "$q"; then
    ok "$q mounts only the memory subdirectory of the $state dataset"
  else
    bad "$q mounts only the memory subdirectory of the $state dataset"
  fi
  # The derived source index is personal: every raw collector is, so the general
  # deployment has no replica to index and takes neither the flag nor the mount.
  if [[ $deployment == personal ]]; then
    if [[ " $exec_line " == *' --index-root /index '* ]] &&
      grep -qxF 'Volume=/var/lib/agent/local/index:/index:z' "$q"; then
      ok "$q indexes the replicas in the $state dataset's index directory"
    else
      bad "$q indexes the replicas in the $state dataset's index directory" "$exec_line"
    fi
  elif [[ " $exec_line " != *'--index-root'* ]] &&
    ! grep -qE '^Volume=.*:/index(:z)?$' "$q"; then
    ok "$q carries no index root"
  else
    bad "$q carries no index root" "$exec_line"
  fi
  # The gateway is the facade's only client, so its template must name the facade's
  # container and port, carry the placeholder rather than a token, and trust it.
  mcp_block=$(sed -n '/^mcp_servers:/,$p' "$template")
  if grep -qE "^  $deployment:\$" <<<"$mcp_block" &&
    grep -qF "url: http://smortress-agent-facade-$deployment:$port/mcp" <<<"$mcp_block" &&
    grep -qE '^ +X-Deployment-Token: __FACADE_TOKEN__$' <<<"$mcp_block" &&
    grep -qE '^    trust: full$' <<<"$mcp_block"; then
    ok "the $state template wires the $deployment facade at $port with no token in it"
  else
    bad "the $state template wires the $deployment facade at $port with no token in it" "$mcp_block"
  fi
  # shellcheck disable=SC2016  # the matched text is the seed script's own source line
  if grep -qF 'agent-facade-$deployment-token.yaml' "$seed_script" &&
    grep -qF '__FACADE_TOKEN__' "$seed_script"; then
    ok "the seed unit substitutes the $deployment placeholder"
  else
    bad "the seed unit substitutes the $deployment placeholder"
  fi
done
# A token in a template would be a credential in an image both gateways share, and
# the placeholder is only safe while it is exactly the placeholder.
if grep -rhn 'X-Deployment-Token:' "${agent_templates[@]}" | grep -qvE ': __FACADE_TOKEN__$'; then
  bad 'no agent config template carries a facade token'
else
  ok 'no agent config template carries a facade token'
fi

# 7. Each web UI is a client of its own deployment's gateway and nothing else. It
#    shares the gateway's network -- the personal one internal, so the UI has no
#    route off the host either -- and the pairing is asserted in both directions:
#    a UI that named the other deployment's gateway would answer from the wrong
#    authority domain while looking healthy.
for spec in \
  personal:local:18006:agent-local.network:smortress-agent-local:18001 \
  general:general:18007:agent-general.network:smortress-agent-general:18002; do
  IFS=: read -r deployment state port network gateway gport <<<"$spec"
  q=units/quadlet/agent-webui-$deployment.container
  mapfile -t nets < <(sed -n 's/^Network=//p' "$q")
  eq "${#nets[@]}" 1 "$q declares exactly one network"
  eq "${nets[0]:-}" "$network" "$q joins only $network"
  eq "$(sed -n 's/^PublishPort=//p' "$q")" "127.0.0.1:$port:8787" \
    "$q publishes loopback $port, the UI's own port"
  eq "$(sed -n 's/^Image=//p' "$q")" "$(app_image_ref agent-webui)" \
    "$q runs the built web UI at the pinned digest"
  eq "$(sed -n 's/^EnvironmentFile=//p' "$q")" "/var/lib/agent/$state/webui.env" \
    "$q takes its key and password from the seeded file"
  eq "$(sed -n 's/^Volume=//p' "$q")" "/var/lib/agent/$state/webui:/data:z" \
    "$q mounts only its deployment's UI directory"
  if grep -qxF "Environment=HERMES_WEBUI_GATEWAY_BASE_URL=http://$gateway:$gport" "$q"; then
    ok "$q points at its own deployment's gateway"
  else
    bad "$q points at its own deployment's gateway" "$(grep -F 'GATEWAY_BASE_URL' "$q")"
  fi
  if ! grep -qE '^Environment=(HERMES_WEBUI_PASSWORD|HERMES_WEBUI_GATEWAY_API_KEY)=' "$q"; then
    ok "$q carries no credential in the unit"
  else
    bad "$q carries no credential in the unit"
  fi
  if grep -qF 'agent-hosted-key' "$q"; then
    bad "$q never names the hosted provider key"
  else
    ok "$q never names the hosted provider key"
  fi
done

# 7b. A static peer address is all-or-nothing per network. Podman's IPAM hands
#     out the lowest free address, so an unpinned container that starts first
#     takes the address a peer asked for and the peer fails with "IPAM error:
#     requested ip address ... is already allocated" until its restart limit
#     trips. That happened at boot: the browser took 10.89.73.2 before the
#     egress proxy claimed it. Two containers may also never pin the same one.
#     The rule is generic: a network with any pinned container pins every
#     container on it.
declare -A net_pins=() net_unpinned=()
for q in units/quadlet/*.container; do
  while IFS= read -r spec; do
    net=${spec%%:*}
    if [[ $spec == *':ip='* ]]; then
      ip=${spec##*:ip=}
      if [[ " ${net_pins[$net]:-} " == *" $ip "* ]]; then
        bad "static addresses on $net are unique" "$q also pins $ip"
      fi
      net_pins[$net]+="$ip "
    else
      net_unpinned[$net]+="$q "
    fi
  done < <(sed -n 's/^Network=//p' "$q")
done
for net in "${!net_pins[@]}"; do
  if [[ -z ${net_unpinned[$net]:-} ]]; then
    ok "every container on $net pins its address"
  else
    bad "every container on $net pins its address" \
      "${net_unpinned[$net]}unpinned, would race for ${net_pins[$net]%% *}"
  fi
done

# 7c. A published port on an internal network is silently dead: netavark skips
#     DNAT (`if !setup_portfw.internal`) and adds bidirectional isolation drops.
#     The container listens, the unit is green, and the host cannot connect --
#     the personal gateway and web UI were unreachable this way. Any container
#     that publishes must therefore be off every `Internal=true` network.
for q in units/quadlet/*.container; do
  grep -q '^PublishPort=' "$q" || continue
  while IFS= read -r spec; do
    net=${spec%%:*}
    if grep -qxF 'Internal=true' "units/quadlet/$net"; then
      bad "$q publishes from a network that forwards" "$net is Internal=true"
    fi
  done < <(sed -n 's/^Network=//p' "$q")
done

# 8. The collectors: the only processes with egress that write into the personal
#    dataset. Each runs the repository's own code out of the booted image, as uid
#    1000, with a read-only root, on the collectors' network -- never a
#    deployment's, because the general network carries the provider key.
collector_cases=(
  "finance|units/systemd/smortress-agent-collect-finance.service|units/systemd/smortress-agent-collect-finance.timer|simplefin-access-url"
)
for collector_case in "${collector_cases[@]}"; do
  IFS='|' read -r name collector collector_timer secret <<<"$collector_case"
  if [[ -f $collector ]]; then
    ok "$collector exists"
  else
    bad "$collector exists"
    continue
  fi
  # Two stages reach two different places: the collector is on the Quadlet's
  # network, the projection reads what it published and gets `none` because it
  # needs no socket at all. Anything else is a unit that quietly grew egress.
  eq "$(grep -cE -- '--network systemd-agent-collect' "$collector")" 1 \
    "$name collector names the network Quadlet actually creates"
  unexpected_network=$(grep -E -- '^[[:space:]]*--network ' "$collector" |
    grep -vE -- '--network (systemd-agent-collect|none)([[:space:]\\]|$)')
  if [[ -n $unexpected_network ]]; then
    bad "$name collector reaches only its own network and none" "$unexpected_network"
  else
    ok "$name collector reaches only its own network and none"
  fi
  if grep -qE '^Requires=.*agent-collect-network\.service' "$collector" &&
     grep -qE '^After=.*agent-collect-network\.service' "$collector"; then
    ok "$name collector starts the generated network unit"
  else
    bad "$name collector starts the generated network unit"
  fi
  if grep -qE -- '--network agent-(local|general)\.network' "$collector"; then
    bad "$name collector is not on a deployment network"
  else
    ok "$name collector is not on a deployment network"
  fi
  for flag in '--read-only' '--cap-drop=all' '--security-opt no-new-privileges' '--user 1000:1000'; do
    if grep -qF -- "$flag" "$collector"; then
      ok "$name collector runs with $flag"
    else
      bad "$name collector runs with $flag"
    fi
  done
  if grep -qF -- "--secret $secret,type=mount,uid=1000,gid=1000,mode=0400" "$collector"; then
    ok "$name collector mounts only its own credential"
  else
    bad "$name collector mounts only its own credential"
  fi
  if grep -qE -- 'agent-(hosted-key|facade-(personal|general)-token)' "$collector"; then
    bad "$name collector never names another deployment's secret"
  else
    ok "$name collector never names another deployment's secret"
  fi
  while IFS= read -r image; do
    if app_image_matches "$image"; then
      ok "$name collector runs a pinned image from the table"
    else
      bad "$name collector runs a pinned image from the table" "$image"
    fi
  done < <(grep -oE 'ghcr\.io/smores56/homelab-platform/[a-z-]+@sha256:[0-9a-f]{64}' "$collector")
  if baked_by_runtime_image /usr/lib/agent-facade &&
    ! grep -qF -- '/usr/lib/agent-facade:/usr/lib/agent-facade:ro' "$collector"; then
    ok "$name collector runs the code its own image ships"
  else
    bad "$name collector runs the code its own image ships"
  fi
  if [[ -f $collector_timer ]]; then
    eq "$(sed -n 's/^Unit=//p' "$collector_timer")" "$(basename "$collector")" \
      "$collector_timer runs the collector"
    if grep -qxF 'Persistent=true' "$collector_timer"; then
      ok "$collector_timer closes a missed run on the next boot"
    else
      bad "$collector_timer closes a missed run on the next boot"
    fi
  else
    bad "$collector_timer exists"
  fi
done

# 8.1. The finance collector's third stage: the hledger projection. It is derived
#     state, so it reads the replica read-only and writes one directory under the
#     personal index -- the same directory the seed unit creates at uid 1000.
finance_unit=units/systemd/smortress-agent-collect-finance.service
eq "$(grep -cE '^ExecStart=' "$finance_unit")" 2 "$finance_unit is collect then project"
if grep -qF -- '--volume /var/lib/agent/local/replica:/replica:ro' "$finance_unit" &&
  grep -qF -- '--volume /var/lib/agent/local/index:/index:z' "$finance_unit" &&
  grep -qF -- '--out /index/hledger/finance.journal' "$finance_unit"; then
  ok "$finance_unit projects the replica into the personal index"
else
  bad "$finance_unit projects the replica into the personal index"
fi
if [[ $(grep -cF -- '--secret ' "$finance_unit") == 1 ]]; then
  ok "$finance_unit holds its credential in one stage only"
else
  bad "$finance_unit holds its credential in one stage only"
fi

# 8a. The calendar pair: our own exporter (session held on a volume, no secret)
#     followed by the collector. The session is the account's access, so it is
#     mounted read-write only into stage 1 and never into the collector.
calendar=units/systemd/smortress-agent-collect-calendar.service
calendar_timer=units/systemd/smortress-agent-collect-calendar.timer
if [[ -f $calendar ]]; then
  ok "$calendar exists"
  eq "$(grep -cE '^ExecStart=' "$calendar")" 2 "$calendar is dump then collect"
  eq "$(grep -cE -- '--network systemd-agent-collect' "$calendar")" \
    "$(grep -cE -- '--network ' "$calendar")" "$calendar names the collector network"
  if grep -qE -- '--secret ' "$calendar"; then
    bad "the calendar pass holds no Podman secret"
  else
    ok "the calendar pass holds no Podman secret"
  fi
  if grep -qE '^ConditionPathExists=.*quarantine/tuta-calendar/session\.gpg' "$calendar"; then
    ok "the calendar pass waits for the sealed session"
  else
    bad "the calendar pass waits for the sealed session"
  fi
  if [[ $(grep -cF -- '/var/lib/agent/local/quarantine/tuta-calendar:/data:z' "$calendar") == 1 ]]; then
    ok "the session volume is mounted once, read-write"
  else
    bad "the session volume is mounted once, read-write"
  fi
  if grep -qE -- '/var/lib/agent/local/quarantine/calendar:/entities:ro' "$calendar"; then
    ok "the collector reads the dump read-only"
  else
    bad "the collector reads the dump read-only"
  fi
  while IFS= read -r image; do
    if app_image_matches "$image"; then
      ok "the calendar pass runs a pinned image from the table"
    else
      bad "the calendar pass runs a pinned image from the table" "$image"
    fi
  done < <(grep -oE 'ghcr\.io/smores56/homelab-platform/[a-z-]+@sha256:[0-9a-f]{64}' "$calendar")
  if [[ -f $calendar_timer ]]; then
    eq "$(sed -n 's/^Unit=//p' "$calendar_timer")" "$(basename "$calendar")" \
      "$calendar_timer runs the calendar pass"
    if grep -qxF 'Persistent=true' "$calendar_timer"; then
      ok "$calendar_timer closes a missed run on the next boot"
    else
      bad "$calendar_timer closes a missed run on the next boot"
    fi
  else
    bad "$calendar_timer exists"
  fi
else
  bad "$calendar exists"
fi

# 8b. The bridge: the provider half. It holds the Tuta session, so its volume is
#     the account, and it sits on the collectors' network rather than a
#     deployment's.
bridge=units/quadlet/agent-tmail.container
if [[ -f $bridge ]]; then
  ok "$bridge exists"
  image=$(grep -oE '^Image=.*' "$bridge" | cut -d= -f2-)
  if app_image_matches "$image"; then
    ok "the bridge runs a pinned image from the table"
  else
    bad "the bridge runs a pinned image from the table" "$image"
  fi
  eq "$(grep -cE '^Network=' "$bridge")" 1 "the bridge names exactly one network"
  if grep -qxF 'Network=agent-collect.network' "$bridge"; then
    ok "the bridge is on the collectors' network"
  else
    bad "the bridge is on the collectors' network"
  fi
  if grep -qxF 'Volume=/var/lib/agent/local/quarantine/tmail:/data:z' "$bridge"; then
    ok "the bridge's session volume is the one dataset path"
  else
    bad "the bridge's session volume is the one dataset path"
  fi
  if grep -qxF 'ReadOnly=true' "$bridge"; then
    ok "the bridge has a read-only root"
  else
    bad "the bridge has a read-only root"
  fi
  if grep -qxF 'User=1000:1000' "$bridge"; then
    ok "the bridge runs as the uid that owns its certificate"
  else
    bad "the bridge runs as the uid that owns its certificate"
  fi
  if grep -qE '^Tmpfs=/tmp:' "$bridge"; then
    ok "the bridge has a writable tmpfs for its runtime dir"
  else
    bad "the bridge has a writable tmpfs for its runtime dir"
  fi
  for flag in 'NoNewPrivileges=true' 'DropCapability=ALL'; do
    if grep -qxF "$flag" "$bridge"; then
      ok "the bridge sets $flag"
    else
      bad "the bridge sets $flag"
    fi
  done
  if grep -qE '^PublishPort=' "$bridge"; then
    bad "the bridge publishes nothing"
  else
    ok "the bridge publishes nothing"
  fi
else
  bad "$bridge exists"
fi

# 8c. The mail stream collector: the one process that reads the bridge. It is a
#     long-running service, not a timer, and it must never hold the bridge's
#     session volume -- only the certificate it verifies.
stream=units/systemd/smortress-agent-mail-stream.service
if [[ -f $stream ]]; then
  ok "$stream exists"
  eq "$(grep -cE -- '--network ' "$stream")" 1 "$stream names exactly one network"
  if grep -qE -- '--network systemd-agent-collect' "$stream"; then
    ok "the mail stream runs on the collectors' network"
  else
    bad "the mail stream runs on the collectors' network"
  fi
  if grep -qE '^(Requires|After)=.*agent-tmail\.service' "$stream"; then
    ok "the mail stream requires the Quadlet-generated bridge unit"
  else
    bad "the mail stream requires the Quadlet-generated bridge unit"
  fi
  if grep -qxF 'ConditionPathExists=/var/lib/agent/local/quarantine/tmail/config/tutabridge/cert.pem' "$stream"; then
    ok "the mail stream waits for the certificate that init creates"
  else
    bad "the mail stream waits for the certificate that init creates"
  fi
  if grep -qF -- '--secret tmail-bridge-password,type=mount,uid=1000,gid=1000,mode=0400' "$stream"; then
    ok "the mail stream mounts only the bridge password"
  else
    bad "the mail stream mounts only the bridge password"
  fi
  if grep -qE -- '--volume [^ ]*quarantine/tmail(:|/data)' "$stream"; then
    bad "the mail stream never mounts the bridge's session volume"
  else
    ok "the mail stream never mounts the bridge's session volume"
  fi
  if grep -qF -- 'cert.pem:/bridge/cert.pem:ro' "$stream"; then
    ok "the mail stream verifies the bridge certificate"
  else
    bad "the mail stream verifies the bridge certificate"
  fi
  if grep -qE '^Restart=on-failure' "$stream" && grep -qE '^Type=simple' "$stream"; then
    ok "the mail stream is a supervised long-running service"
  else
    bad "the mail stream is a supervised long-running service"
  fi
  if grep -qF 'smortress-agent-mail-stream.service' image/Containerfile; then
    ok "the image enables the mail stream"
  else
    bad "the image enables the mail stream"
  fi
else
  bad "$stream exists"
fi

# 8d. The egress gate: an internal network with exactly two peers, and a policy
#     that lives in the image. A collector's reach is a reviewed fact, not
#     something a container can edit, and nothing is published.
brave_net=units/quadlet/agent-brave.network
if [[ -f $brave_net ]] && grep -qxF 'Internal=true' "$brave_net" &&
   grep -qE '^Subnet=' "$brave_net"; then
  ok "the browsing network is internal and addressed"
else
  bad "the browsing network is internal and addressed"
fi
policy=image/rootfs/etc/smortress/agent/egress-policy.json
if python3 - "$policy" <<'PYJSON'
import json, sys
document = json.load(open(sys.argv[1], encoding="utf-8"))
allow = document["sources"]["brave"]["allow"]
assert "sync-v2.brave.com:443" in allow
PYJSON
then
  ok "the egress policy is a document that grants exactly the sync host"
else
  bad "the egress policy is a document that grants exactly the sync host"
fi
for gate in proxy dns; do
  unit=units/quadlet/agent-egress-$gate.container
  if [[ ! -f $unit ]]; then
    bad "$unit exists"
    continue
  fi
  ok "$unit exists"
  eq "$(sed -n 's/^Network=agent-brave\.network.*//p' "$unit" | grep -c .)" 0 \
    "$unit joins the internal network"
  if grep -qE '^Network=agent-brave\.network(:ip=[0-9.]+)?$' "$unit"; then
    ok "$unit is on the internal network"
  else
    bad "$unit is on the internal network"
  fi
  if grep -qxF 'Network=agent-collect.network' "$unit"; then
    ok "$unit reaches upstream on the collectors' network"
  else
    bad "$unit reaches upstream on the collectors' network"
  fi
  if grep -qF 'egress-policy.json:/etc/smortress/agent/egress-policy.json:ro' "$unit"; then
    ok "$unit reads the policy read-only"
  else
    bad "$unit reads the policy read-only"
  fi
  if grep -qE '^PublishPort=' "$unit"; then
    bad "$unit publishes nothing"
  else
    ok "$unit publishes nothing"
  fi
  image=$(grep -oE '^Image=.*' "$unit" | cut -d= -f2-)
  if app_image_matches "$image"; then
    ok "$unit runs a pinned image from the table"
  else
    bad "$unit runs a pinned image from the table" "$image"
  fi
  if grep -qF "units/quadlet/$(basename "$unit")" image/Containerfile; then
    ok "the image installs $(basename "$unit")"
  else
    bad "the image installs $(basename "$unit")"
  fi
done
if grep -qxF 'AddCapability=NET_BIND_SERVICE' units/quadlet/agent-egress-dns.container &&
   grep -qxF 'DropCapability=ALL' units/quadlet/agent-egress-dns.container; then
  ok "the DNS responder holds only the capability it needs"
else
  bad "the DNS responder holds only the capability it needs"
fi

if grep -qF 'units/quadlet/agent-collect.network' image/Containerfile; then
  ok "the collector network ships in the image"
else
  bad "the collector network ships in the image"
fi
for secret in simplefin-access-url tmail-bridge-password; do
  if grep -qE "^${secret//./\\.}\\.yaml[[:space:]]" image/rootfs/usr/share/smortress/secrets.manifest; then
    ok "$secret has a decrypt manifest entry"
  else
    bad "$secret has a decrypt manifest entry"
  fi
  if grep -qF "$secret" scripts/app-secrets.sh; then
    ok "$secret becomes a Podman secret"
  else
    bad "$secret becomes a Podman secret"
  fi
done

# 8e. The browsing collector (#713): a real browser whose only egress is the gate
#     above, a profile seeded before it starts, a snapshot the collector can
#     accept, and a watcher on the profile's own database. The peer addresses are
#     derived from the two gate Quadlets rather than repeated here: moving the
#     proxy or the resolver has to fail this section too.
brave=units/quadlet/agent-brave.container
brave_seed=units/systemd/smortress-agent-brave-seed.service
brave_collect=units/systemd/smortress-agent-collect-brave.service
brave_path=units/systemd/smortress-agent-collect-brave.path
brave_timer=units/systemd/smortress-agent-collect-brave.timer
proxy_ip=$(sed -n 's/^Network=agent-brave\.network:ip=\([0-9.]*\)$/\1/p' units/quadlet/agent-egress-proxy.container)
proxy_port=$(sed -n 's/^Exec=proxy .*--listen [0-9.]*:\([0-9]*\)$/\1/p' units/quadlet/agent-egress-proxy.container)
dns_ip=$(sed -n 's/^Network=agent-brave\.network:ip=\([0-9.]*\)$/\1/p' units/quadlet/agent-egress-dns.container)
if [[ -n $proxy_ip && -n $proxy_port && -n $dns_ip && $proxy_ip != "$dns_ip" ]]; then
  ok "the egress gate names two distinct peers"
else
  bad "the egress gate names two distinct peers" "proxy=$proxy_ip:$proxy_port dns=$dns_ip"
fi
if [[ -f $brave ]]; then
  ok "$brave exists"
  eq "$(grep -cE '^Network=' "$brave")" 1 "$brave joins exactly one network"
  if grep -qE '^Network=agent-brave\.network(:ip=[0-9.]+)?$' "$brave"; then
    ok "the browser is on the internal network and nowhere else"
  else
    bad "the browser is on the internal network and nowhere else"
  fi
  if grep -qE '^PublishPort=' "$brave"; then
    bad "the browser publishes nothing"
  else
    ok "the browser publishes nothing"
  fi
  image=$(grep -oE '^Image=.*' "$brave" | cut -d= -f2-)
  if app_image_matches "$image"; then
    ok "the browser runs a pinned image from the table"
  else
    bad "the browser runs a pinned image from the table" "$image"
  fi
  if grep -qxF 'Volume=/var/lib/agent/local/quarantine/brave-profile:/data:z' "$brave"; then
    ok "the profile volume is the chain membership, label-shared"
  else
    bad "the profile volume is the chain membership, label-shared"
  fi
  for flag in 'ReadOnly=true' 'User=1000:1000' 'NoNewPrivileges=true' 'DropCapability=ALL'; do
    if grep -qxF "$flag" "$brave"; then
      ok "the browser sets $flag"
    else
      bad "the browser sets $flag"
    fi
  done
  if grep -qE '^Tmpfs=/tmp:' "$brave"; then
    ok "the browser has a writable tmpfs for its scratch space"
  else
    bad "the browser has a writable tmpfs for its scratch space"
  fi
  if grep -qE -- "--dns=$dns_ip( |$)" "$brave"; then
    ok "the browser resolves through the allowlist responder"
  else
    bad "the browser resolves through the allowlist responder" "want --dns=$dns_ip"
  fi
  if grep -qE -- "--proxy-server=http://$proxy_ip:$proxy_port( |\$)" "$brave"; then
    ok "the browser's only egress is the allowlist proxy"
  else
    bad "the browser's only egress is the allowlist proxy" "want http://$proxy_ip:$proxy_port"
  fi
  if grep -qE -- '--memory=640m' "$brave" && grep -qE -- '--memory-swap=800m' "$brave"; then
    ok "the browser is bounded at 640/800 MiB"
  else
    bad "the browser is bounded at 640/800 MiB"
  fi
  for flag in '--headless=new' '--no-sandbox' '--password-store=basic' '--user-data-dir=/data'; do
    if grep -qF -- "$flag" "$brave"; then
      ok "the browser runs with $flag"
    else
      bad "the browser runs with $flag"
    fi
  done
  if grep -qxF 'Restart=always' "$brave" && grep -qxF 'SuccessExitStatus=143' "$brave"; then
    ok "the browser restarts except on a deliberate stop"
  else
    bad "the browser restarts except on a deliberate stop"
  fi
  if grep -qE '^After=.*smortress-agent-brave-seed\.service' "$brave"; then
    ok "the browser starts after its profile is seeded"
  else
    bad "the browser starts after its profile is seeded"
  fi
else
  bad "$brave exists"
fi

if [[ -f $brave_seed ]]; then
  ok "$brave_seed exists"
  if grep -qE '^Before=.*agent-brave\.service' "$brave_seed"; then
    ok "the seed is planted before the Quadlet-generated browser unit"
  else
    bad "the seed is planted before the Quadlet-generated browser unit"
  fi
  eq "$(grep -cF -- '--secret brave-sync-seed,type=mount,uid=1000,gid=1000,mode=0400' "$brave_seed")" 1 \
    "the seed is a Podman secret at uid 1000 mode 0400"
  if grep -qxF 'ConditionPathExists=/var/lib/agent/local/quarantine/brave-profile' "$brave_seed"; then
    ok "the seed unit waits for the profile directory the seeder creates"
  else
    bad "the seed unit waits for the profile directory the seeder creates"
  fi
  if [[ $(grep -cE '^ *--network ' "$brave_seed") == 1 ]] &&
     grep -qE '^ *--network none' "$brave_seed" &&
     grep -qF -- '-m apps.brave_ingest.seed' "$brave_seed"; then
    ok "the seeder is a local one-shot with no address"
  else
    bad "the seeder is a local one-shot with no address"
  fi
  if grep -qE -- '/var/lib/agent/local/quarantine/brave-profile:/data:z' "$brave_seed"; then
    ok "the seeder is the second process that may write the profile"
  else
    bad "the seeder is the second process that may write the profile"
  fi
  if grep -qF 'smortress-agent-brave-seed.service' image/Containerfile; then
    ok "the image enables the seed unit"
  else
    bad "the image enables the seed unit"
  fi
else
  bad "$brave_seed exists"
fi

if [[ -f $brave_collect ]]; then
  ok "$brave_collect exists"
  eq "$(grep -cE '^ExecStart=' "$brave_collect")" 2 "$brave_collect is snapshot then collect"
  snapshot_line=$(grep -nF 'apps.brave_ingest.snapshot' "$brave_collect" | cut -d: -f1)
  collect_line=$(grep -nF 'data_plane.collectors.raw' "$brave_collect" | cut -d: -f1)
  if [[ -n $snapshot_line && -n $collect_line && $snapshot_line -lt $collect_line ]]; then
    ok "the snapshot stage runs before the collector stage"
  else
    bad "the snapshot stage runs before the collector stage" \
      "snapshot=$snapshot_line collect=$collect_line"
  fi
  if grep -qE -- '/var/lib/agent/local/quarantine/brave-profile:/profile:ro' "$brave_collect" &&
     grep -qE -- '/var/lib/agent/local/quarantine/brave:/quarantine:z' "$brave_collect"; then
    ok "only the snapshot writes the quarantine copy"
  else
    bad "only the snapshot writes the quarantine copy"
  fi
  if grep -qE -- '/var/lib/agent/local/quarantine/brave:/quarantine:ro' "$brave_collect"; then
    ok "the collector reads the copy read-only"
  else
    bad "the collector reads the copy read-only"
  fi
  if grep -qF -- 'brave --database /quarantine/History --device smortress --profile default' \
    "$brave_collect"; then
    ok "the collector names the device and profile the replica is keyed by"
  else
    bad "the collector names the device and profile the replica is keyed by"
  fi
  if [[ $(grep -cE -- '--network none' "$brave_collect") == 2 ]]; then
    ok "neither stage has a network"
  else
    bad "neither stage has a network"
  fi
  if grep -qE -- '--secret ' "$brave_collect"; then
    bad "the collection pass holds no Podman secret"
  else
    ok "the collection pass holds no Podman secret"
  fi
  while IFS= read -r image; do
    if app_image_matches "$image"; then
      ok "the collection pass runs a pinned image from the table"
    else
      bad "the collection pass runs a pinned image from the table" "$image"
    fi
  done < <(grep -oE 'ghcr\.io/smores56/homelab-platform/[a-z-]+@sha256:[0-9a-f]{64}' "$brave_collect")
  for unit in smortress-agent-collect-brave.path smortress-agent-collect-brave.timer; do
    if grep -qF "$unit" image/Containerfile; then
      ok "the image enables $unit"
    else
      bad "the image enables $unit"
    fi
  done
else
  bad "$brave_collect exists"
fi

if [[ -f $brave_path ]]; then
  ok "$brave_path exists"
  eq "$(sed -n 's/^Unit=//p' "$brave_path")" "$(basename "$brave_collect")" \
    "the watcher runs the collection pass"
  eq "$(grep -cE '^PathModified=/var/lib/agent/local/quarantine/brave-profile/Default/History$' "$brave_path")" 1 \
    "the watcher follows the profile's History"
  if grep -qxF 'PathModified=/var/lib/agent/local/quarantine/brave-profile/Default/History-wal' "$brave_path"; then
    ok "the watcher also follows the sidecar a write appears in first"
  else
    bad "the watcher also follows the sidecar a write appears in first"
  fi
else
  bad "$brave_path exists"
fi

if [[ -f $brave_timer ]]; then
  eq "$(sed -n 's/^Unit=//p' "$brave_timer")" "$(basename "$brave_collect")" \
    "the reconcile timer runs the collection pass"
  if grep -qxF 'Persistent=true' "$brave_timer"; then
    ok "the reconcile timer closes a missed pass on the next boot"
  else
    bad "the reconcile timer closes a missed pass on the next boot"
  fi
  if grep -qE '^OnCalendar=\*-\*-\* 00/6:' "$brave_timer"; then
    ok "the reconcile timer is six-hourly"
  else
    bad "the reconcile timer is six-hourly"
  fi
else
  bad "$brave_timer exists"
fi

# shellcheck disable=SC2016  # the matched text is a line of the seed script
if grep -qF 'install -d -o 1000 -g 1000 -m 0700 "$home/quarantine/brave-profile"' scripts/agent-config-seed.sh &&
  grep -qF 'install -d -o 1000 -g 1000 -m 0750 "$home/quarantine/brave"' scripts/agent-config-seed.sh; then
  ok "the seeder creates the profile 0700 and the copy 0750, personal only"
else
  bad "the seeder creates the profile 0700 and the copy 0750, personal only"
fi
for module in apps/brave_ingest/*.py; do
  if grep -qF "$module" images/agent-runtime/Containerfile; then
    ok "the runtime image installs ${module#apps/brave_ingest/}"
  else
    bad "the runtime image installs ${module#apps/brave_ingest/}"
  fi
done
if grep -qE '^brave-sync-seed\.yaml[[:space:]]+root[[:space:]]+root[[:space:]]+0400[[:space:]]+value' \
  image/rootfs/usr/share/smortress/secrets.manifest; then
  ok "brave-sync-seed has a decrypt manifest entry"
else
  bad "brave-sync-seed has a decrypt manifest entry"
fi
if grep -qF 'brave-sync-seed' scripts/app-secrets.sh; then
  ok "brave-sync-seed becomes a Podman secret"
else
  bad "brave-sync-seed becomes a Podman secret"
fi

# `systemctl enable` on a unit with no [Install] section is a silent no-op: the
# build succeeds, `is-enabled` reports "static", and nothing starts it at boot.
# The mail stream and the Brave seed shipped that way and stayed dead until an
# operator started them by hand on every boot, so every unit the image enables
# has to be enableable. Template instances in the list come from packaged units
# and are skipped.
enable_block=$(sed -n '/systemctl enable \\$/,/;[[:space:]]*\\$/p' image/Containerfile)
never_starts=()
while read -r unit; do
  [[ $unit == *@* ]] && continue
  [[ -f units/systemd/$unit ]] || continue
  grep -qx '\[Install\]' "units/systemd/$unit" || never_starts+=("$unit")
done < <(grep -oE 'smortress-[a-z0-9.-]+\.(service|timer|path)' <<<"$enable_block" | sort -u)
if ((${#never_starts[@]} == 0)); then
  ok 'every smortress unit the image enables declares [Install]'
else
  bad 'every smortress unit the image enables declares [Install]' "${never_starts[*]}"
fi

# A unit that runs the data plane has to hand the container the package, not
# only the facade tree: `-m data_plane` with `/usr/lib/agent-facade` alone is
# `No module named data_plane` on every tick. The calendar collector shipped
# that way and failed its first real run after a clean dump.
for unit in units/systemd/*.service; do
  grep -q -- '-m data_plane' "$unit" || continue
  if grep -q -- '--env PYTHONPATH=/usr/lib/agent-facade/libs:/usr/lib/agent-facade' "$unit"; then
    ok "$unit puts the data plane on PYTHONPATH"
  else
    bad "$unit puts the data plane on PYTHONPATH" \
      "$(grep -n 'PYTHONPATH' "$unit" || echo 'no PYTHONPATH at all')"
  fi
done

printf '\n%d checks, %d failed\n' "$((pass + fail))" "$fail"
((fail == 0))
