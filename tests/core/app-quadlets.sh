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
#     is how the first publish run failed after merge.
for name in $app_names; do
  digest=$(app_image_digest "$name")
  upstream=$(app_image_upstream "$name")
  # Independent of app_image_source: strip the digest and then the tag with sed.
  want_repo=$(printf '%s\n' "$upstream" | sed -E 's/@sha256:[0-9a-f]+$//; s/:[^/:]+$//')
  eq "$(app_image_source "$name")" "docker://$want_repo@$digest" \
    "$name skopeo source is repo@digest"
done

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
  if grep -qE "^${secret//./\\.}\.yaml[[:space:]]" image/rootfs/etc/smortress/secrets.manifest; then
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
#     side has one internal network and therefore no route off the host, the
#     general side has egress and is the only side that can spend a hosted key --
#     which it does not hold. These are the properties a misread of the units
#     would silently undo.
agent_local=units/quadlet/agent-local.container
agent_general=units/quadlet/agent-general.container
agent_model=units/quadlet/agent-model.container
agent_proxy=units/quadlet/agent-proxy.container
agent_templates=(image/rootfs/etc/smortress/agent/local-config.yaml
  image/rootfs/etc/smortress/agent/general-config.yaml)

if grep -q '^Internal=true$' units/quadlet/agent-local.network; then
  ok 'the personal network has no egress'
else
  bad 'the personal network has no egress'
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
  'the personal gateway is on the internal network only'
eq "$(sed -n 's/^Network=//p' "$agent_general")" agent-general.network \
  'the general gateway is on the egress network only'
eq "$(sed -n 's/^Network=//p' "$agent_proxy")" agent-general.network \
  'the proxy is on the egress network only'
eq "$(sed -n 's/^Network=//p' "$agent_model")" agent-local.network \
  'the model server is on the internal network only'

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
  grep -qF 'apps/agent_proxy/proxy.py /usr/libexec/agent-proxy' image/Containerfile; then
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
model_context=$(sed -n 's/^Exec=.*-c \([0-9]*\).*/\1/p' "$agent_model")
config_context=$(sed -n 's/^  context_length: //p' image/rootfs/etc/smortress/agent/local-config.yaml)
if [[ -n $model_context && $model_context == "$config_context" ]] && ((model_context >= 64000)); then
  ok "the local context window is pinned to $model_context on both sides"
else
  bad 'the local context window is pinned on both sides' "model=$model_context config=$config_context"
fi
local_disabled=$(sed -n '/^  disabled_toolsets:/,/^[^ -]/p' image/rootfs/etc/smortress/agent/local-config.yaml)
for toolset in web search browser terminal file memory code_execution catalog \
  computer_use cronjob delegation skills image_gen connections; do
  if grep -qE "^[[:space:]]+- ${toolset}$" <<<"$local_disabled"; then
    ok "the personal config disables the $toolset toolset"
  else
    bad "the personal config disables the $toolset toolset"
  fi
done

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

# 12. Code delivery. A Quadlet hands `Exec=`/`Entrypoint=` a program that has to
#     exist inside the container's own filesystem, and the agent-runtime image is
#     not ours: nothing this repository builds is in it. So every absolute path a
#     unit names is either bind-mounted from the host tree or one of the
#     interpreters every image carries. agent-proxy shipped
#     `Exec=/usr/libexec/agent-proxy` with no mount, and python3 started against a
#     path that was not there -- this is the assertion that would have caught it.
readonly image_interpreters=(/bin/sh /bin/bash /usr/bin/python3 /usr/bin/env /usr/bin/sh)
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
    if ((!accounted)) && covered_by_volume "$q" "$path"; then accounted=1; fi
    if ((!accounted)) && covered_by_secret "$q" "$path"; then accounted=1; fi
    if ((accounted)); then
      ok "$q delivers $path"
    else
      bad "$q delivers $path" "no Volume= or Secret= puts it inside the container"
    fi
  done < <(sed -n 's/^\(Exec\|Entrypoint\)=//p' "$q" | tr ' ' '\n' |
    grep -E '^/[A-Za-z0-9._/-]+$' | sort -u)
done
# The same rule for the facade in particular: its program is a Python package, so
# what has to be inside the container is the directory PYTHONPATH names.
for q in units/quadlet/agent-facade-personal.container units/quadlet/agent-facade-general.container; do
  if [[ $(sed -n 's/^Environment=PYTHONPATH=//p' "$q") == /usr/lib/agent-facade/libs:/usr/lib/agent-facade ]] &&
    covered_by_volume "$q" /usr/lib/agent-facade; then
    ok "$q mounts the tree its PYTHONPATH names"
  else
    bad "$q mounts the tree its PYTHONPATH names"
  fi
done

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

printf '\n%d checks, %d failed\n' "$((pass + fail))" "$fail"
((fail == 0))
