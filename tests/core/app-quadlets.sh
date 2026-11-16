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
)

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

# 2. A container that mounts a recovery group is ordered after that group's
#    readiness unit, and requires nothing it does not mount. One that mounts no
#    group (the machine learning cache) needs no readiness at all.
for q in "${app_quadlets[@]}"; do
  while IFS= read -r group; do
    [[ -n $group ]] || continue
    if grep -q "zfs-ready@$group.service" "$q"; then
      ok "$q requires zfs-ready@$group"
    else
      bad "$q requires zfs-ready@$group"
    fi
  done < <(grep -oE '^Volume=/var/tank/[a-z]+' "$q" | sed 's|^Volume=/var/tank/||' | sort -u)

  while IFS= read -r unit; do
    [[ -n $unit ]] || continue
    group=${unit#zfs-ready@}
    group=${group%.service}
    if ! grep -qE "^Volume=/var/tank/${group}([/:][^ ]*)?:" "$q"; then
      bad "$q requires $unit for a dataset it does not mount"
    fi
  done < <(grep -o 'zfs-ready@[a-z]*\.service' "$q" | sort -u)
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
  if grep -qE "\[[0-9]+\]=${port}$" scripts/tailscale-serve.sh; then
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
done < <(grep -oE '\[[0-9]+\]=[0-9]+' scripts/tailscale-serve.sh | cut -d= -f2 | sort -u)

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

# 6. The logical Immich dump lands in the photos group and completes before the
#    daily offsite snapshot.
if grep -q '/var/tank/photos/db-dumps' scripts/immich-dump.sh; then
  ok 'immich dump writes inside the photos group'
else
  bad 'immich dump writes inside the photos group'
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
if grep -q 'Requires=.*zfs-ready@photos.service' units/systemd/smortress-immich-dump.service; then
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

# 7. The recovery-group vocabulary is one list in three places.
zp=$(grep -oP '^readonly groups=\(\K[^)]+' scripts/init-zpool.sh | tr ' ' '\n' | sort)
rp=$(grep -oP '^groups=\(\K[^)]+' scripts/restic-plane-common.sh | tr ' ' '\n' | sort)
eq "$zp" "$rp" 'zpool groups and Restic groups agree'
# The pool unit gives every group root to the uid the applications run as; a
# restore is root-owned, so this is what lets a dump-only group create the
# directories the containers need.
# The matched text is the source line, so $group is deliberately literal here.
# shellcheck disable=SC2016
if grep -q 'chown 1000:1000 "/var/tank/$group"' scripts/init-zpool.sh; then
  ok 'the pool unit gives each group root to uid 1000'
else
  bad 'the pool unit gives each group root to uid 1000'
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

for group in $zp; do
  if grep -q "zfs-ready@$group.service" image/Containerfile; then
    ok "image enables zfs-ready@$group"
  else
    bad "image enables zfs-ready@$group"
  fi
  if grep -q "zfs-ready@$group.service" units/systemd/smortress-restic-backup@.service; then
    ok "backup driver is ordered after zfs-ready@$group"
  else
    bad "backup driver is ordered after zfs-ready@$group"
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

printf '\n%d checks, %d failed\n' "$((pass + fail))" "$fail"
((fail == 0))
