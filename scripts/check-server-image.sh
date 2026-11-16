#!/usr/bin/env bash
# Static checks for the derived image, Ignition template, Quadlets and SOPS
# layout. No registry, no cosign key and no operator secret is required.
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo"
# shellcheck source=../image/pins.env disable=SC1091
source image/pins.env

fail=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }
check() { local name=$1; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
has() { grep -qF -- "$1" "$2"; }
lacks() { ! grep -qF -- "$1" "$2"; }
count() { grep -cF -- "$1" "$2" || true; }
probe() { local name=$1; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }

if [[ $UCORE_IMAGE =~ @sha256:[0-9a-f]{64}$ ]]; then ok "base image is digest-pinned"; else bad "base image is digest-pinned"; fi
if [[ -n ${IMAGE_REPO:-} ]]; then ok "image repository is set"; else bad "image repository is set"; fi
for pin in SOPS_SHA256 AGE_SHA256 RESTIC_SHA256 BUTANE_SHA256 COSIGN_SHA256; do
  if [[ ${!pin} =~ ^[0-9a-f]{64}$ ]]; then ok "$pin format"; else bad "$pin format"; fi
done

check "Containerfile takes a base argument" has "FROM \${BASE_IMAGE}" image/Containerfile
check "Containerfile rejects a floating base" lacks ':latest' image/Containerfile
check "Containerfile installs the public key" has 'image/cosign.pub /etc/pki/containers/smortress.pub' image/Containerfile
check "Containerfile masks Podman auto-update" has 'podman-auto-update.timer' image/Containerfile
check "Containerfile masks bootc auto-update" has 'bootc-fetch-apply-updates.timer' image/Containerfile
check "Containerfile sets the default firewall zone to drop" has '--set-default-zone=drop' image/Containerfile

probe "policy rejects by default" jq -e '.default[0].type == "reject"' image/rootfs/etc/containers/policy.json
# An empty docker scope is the transport default and shadows the global reject
# for every registry reference, so it must not exist.
probe "no docker transport-wide accept" jq -e '.transports.docker[""] == null' image/rootfs/etc/containers/policy.json
check "firewalld is enabled in the image" has "firewalld.service" image/Containerfile
probe "policy trusts the smortress key by path" jq -e \
  '.transports.docker["ghcr.io/smores56/homelab-platform"][0].keyPath == "/etc/pki/containers/smortress.pub"' \
  image/rootfs/etc/containers/policy.json
check "signature attachments enabled for our repo" has 'use-sigstore-attachments: true' \
  image/rootfs/etc/containers/registries.d/ghcr.io-smortress.yaml

if [[ -f image/cosign.pub ]]; then
  check "operator public key is PEM" has 'BEGIN PUBLIC KEY' image/cosign.pub
else
  printf 'warn %s\n' "image/cosign.pub is not provisioned yet (docs/manual-steps.md section 37)"
fi
if grep -rIl --exclude-dir=.git --exclude=check-server-image.sh \
    -e '-----BEGIN [A-Z ]*PRIVATE KEY-----' -e 'AGE-SECRET-KEY-1[A-Z0-9]{10,}' \
    -e 'tskey-[A-Za-z0-9]{20,}' \
    image ignition units secrets .github scripts docs 2>/dev/null | grep -q .; then
  bad "no private key, age identity or tailscale key in the tree"
else
  ok "no private key, age identity or tailscale key in the tree"
fi

if git ls-files -- 'ignition/*.ign' 'ignition/operator/*' 2>/dev/null | grep -q .; then
  bad "no rendered Ignition or operator value is tracked"
else
  ok "no rendered Ignition or operator value is tracked"
fi

# Quadlets: digest-pinned images, loopback-only publication, dependency wiring.
shopt -s nullglob
quadlets=(units/quadlet/*.container)
if ((${#quadlets[@]} == 0)); then
  bad "at least one Quadlet pattern exists"
fi
for q in "${quadlets[@]}"; do
  while IFS= read -r line; do
    ref=${line#Image=}
    if [[ $ref =~ @sha256:[0-9a-f]{64}$ ]]; then
      ok "$q image is digest-pinned"
    else
      bad "$q image is digest-pinned: $ref"
    fi
  done < <(grep -E '^Image=' "$q" || true)
  while IFS= read -r line; do
    port=${line#PublishPort=}
    if [[ $port =~ ^(127\.0\.0\.1|\[::1\]):[0-9]+:[0-9]+(/tcp|/udp)?$ ]]; then
      ok "$q publishes on loopback: $port"
    elif [[ $port == *0.0.0.0* || $port == *'[::]'* || $port == ::* || $port =~ ^[0-9]+:[0-9]+ ]]; then
      bad "$q publishes a wildcard or unspecified address: $port"
    elif [[ $port =~ ^100\.(6[4-9]|[7-9][0-9]|1[0-2][0-7])\.[0-9]{1,3}\.[0-9]{1,3}:[0-9]+:[0-9]+ ]] \
      || [[ $port =~ ^\[fd7a:115c:a1e0:[0-9a-f:]*\]:[0-9]+:[0-9]+ ]]; then
      ok "$q publishes on a Tailscale address: $port"
    else
      bad "$q publishes outside loopback and the Tailscale ranges: $port"
    fi
  done < <(grep -E '^PublishPort=' "$q" || true)
  check "$q requires the decrypt unit" grep -qE '^Requires=.*sops-decrypt\.service' "$q"
  check "$q starts after the decrypt unit" grep -qE '^After=.*sops-decrypt\.service' "$q"
  check "$q requires its readiness group" grep -qE '^Requires=.*zfs-ready@[a-z]+\.service' "$q"
done

check "readiness unit exists" has 'ExecStart=/usr/libexec/zfs-ready %i' 'units/systemd/zfs-ready@.service'
# /usr/local is a symlink into /var on bootc: a helper installed there does not
# exist at runtime, which is how the first install failed with 203/EXEC.
check "no unit runs from /usr/local" lacks '/usr/local/libexec' units/systemd/

# systemd units have no HOME; restic must be told where its cache lives.
for u in units/systemd/smortress-restic-backup@.service units/systemd/smortress-restic-verify.service units/systemd/smortress-restic-init.service; do
  check "$u sets RESTIC_CACHE_DIR" has "RESTIC_CACHE_DIR" "$u"
done
for group in photos books notes music wallpapers; do
  check "image enables zfs-ready@$group" has "zfs-ready@$group.service" image/Containerfile
done
check "decrypt unit is ordered after local-fs" has 'After=local-fs.target' units/systemd/sops-decrypt.service
check "zpool unit follows the data cryptsetup unit" has 'After=systemd-cryptsetup@data.service' units/systemd/smortress-zpool.service
check "HDD unlock cannot block boot" has 'ExecStart=-/usr/libexec/open-hdd' units/systemd/smortress-cryptsetup-hdd.service

# Restic plane (T3). A mount unit that is not installed, a retention filter
# missing one tag, or a job ordered before its dataset is ready all fail
# silently on the host, so the shape is asserted here.
for m in var-lib-restic-ssd.mount var-lib-restic-hdd.mount; do
  check "Restic mount unit $m exists" test -s "units/systemd/$m"
  check "image enables $m" has "$m" image/Containerfile
done
check "SSD mount is keyed by the wiped disk UUID" has 'What=/dev/disk/by-uuid/e040eab7-3df0-4b7d-96e0-71fb9a5eff93' units/systemd/var-lib-restic-ssd.mount
check "HDD mount is keyed by its UUID" has 'What=/dev/disk/by-uuid/973b7492-bb88-43c7-bac3-772384e45220' units/systemd/var-lib-restic-hdd.mount
check "HDD mount bounds the device wait" has 'JobTimeoutSec=45' units/systemd/var-lib-restic-hdd.mount
check "HDD mount bounds the mount command" has 'TimeoutSec=30' units/systemd/var-lib-restic-hdd.mount

backup_after=$(sed -e :a -e '/\\$/N; s/\\\n/ /; ta' 'units/systemd/smortress-restic-backup@.service' | grep '^After=')
for group in photos books notes music wallpapers; do
  if [[ $backup_after == *"zfs-ready@$group.service"* ]]; then
    ok "backup driver is ordered after zfs-ready@$group"
  else
    bad "backup driver is ordered after zfs-ready@$group"
  fi
done
check "backup driver requires the decrypt unit" grep -qE '^Requires=.*sops-decrypt\.service' 'units/systemd/smortress-restic-backup@.service'
check "verifier requires the decrypt unit" grep -qE '^Requires=.*sops-decrypt\.service' units/systemd/smortress-restic-verify.service
check "init requires the decrypt unit" grep -qE '^Requires=.*sops-decrypt\.service' units/systemd/smortress-restic-init.service

retention_ok=1
while IFS= read -r retention_line; do
  [[ $retention_line == *--keep-* ]] || continue
  if [[ $retention_line != *'--tag group:'* && $retention_line != *'--tag "group:'* ]] ||
    [[ $retention_line != *'--tag verified'* ]]; then
    retention_ok=0
  fi
done < <(sed -e :a -e '/\\$/N; s/\\\n/ /; ta' scripts/smortress-restic-backup.sh)
check "retention requires both group and verified tags" test "$retention_ok" -eq 1
check "no wildcard retention bucket" lacks '--keep-last' scripts/smortress-restic-backup.sh
check "no time-window retention bucket" lacks '--keep-within' scripts/smortress-restic-backup.sh
if grep -qE '(^|[[:space:]])unlock([[:space:]]|$)' scripts/smortress-restic-*.sh; then
  bad "no routine restic unlock"
else
  ok "no routine restic unlock"
fi
if grep -qE -- 'forget .*\*|rm -rf[^#]*(/var/lib/restic|/var/lib/smortress/restic)' scripts/smortress-restic-*.sh; then
  bad "no bulk deletion of snapshots or repository roots"
else
  ok "no bulk deletion of snapshots or repository roots"
fi
check "failed snapshots are reaped by recorded ID" grep -q 'pending_reap' scripts/smortress-restic-backup.sh
if grep -qE -- '--password[= ]' scripts/smortress-restic-*.sh; then
  bad "no restic password on a command line"
else
  ok "no restic password on a command line"
fi
check "all plane state lives under /var/lib/smortress" has '/var/lib/smortress/restic' scripts/restic-plane-common.sh
check "state directories are created 0700" has 'install -d -m 0700' scripts/restic-plane-common.sh
check "R2 uses the new repository path" has 'homelab-restic/smortress' scripts/restic-plane-common.sh
check "the plane never names the legacy R2 bucket" lacks 'restic-backup' scripts/restic-plane-common.sh
for unit in smortress-restic-backup-ssd.timer smortress-restic-backup-hdd.timer \
  smortress-restic-backup-r2.timer smortress-restic-verify.timer \
  smortress-restic-init.service; do
  check "image enables $unit" has "$unit" image/Containerfile
done
check "R2 timer is daily at midnight" has 'OnCalendar=*-*-* 00:00:00' units/systemd/smortress-restic-backup-r2.timer
check "local backups run hourly" has 'OnCalendar=*-*-* *:05:00' units/systemd/smortress-restic-backup-ssd.timer
check "the verifier runs after the hourly driver" has 'OnCalendar=*-*-* *:40:00' units/systemd/smortress-restic-verify.timer

check "ignition sets both image references" test "$(count '@DERIVED_IMAGE@' ignition/smortress.bu)" -ge 2
check "ignition uses the unverified first stage" has 'ostree-unverified-registry:@DERIVED_IMAGE@' ignition/smortress.bu
check "ignition uses the signed second stage" has 'ostree-image-signed:docker://@DERIVED_IMAGE@' ignition/smortress.bu
check "root unlock is Tang+TPM2 threshold 2" has 'threshold: 2' ignition/smortress.bu
check "root clevis enables tpm2" has 'tpm2: true' ignition/smortress.bu
check "root clevis configures Tang" has "url: '@TANG_URL@'" ignition/smortress.bu
check "root clevis pins the Tang thumbprint" has "thumbprint: '@TANG_THUMBPRINT@'" ignition/smortress.bu
check "both storage devices carry an inline key" test "$(count 'key_file:' ignition/smortress.bu)" -eq 2
check "ignition has no mutable git checkout" lacks 'git clone' ignition/smortress.bu
check "ignition installs the verification policy" has '/etc/containers/policy.json' ignition/smortress.bu
check "ignition creates the autorebase marker directory" has '/etc/ucore-autorebase' ignition/smortress.bu
check "stage 1 runs only before the marker" has 'ConditionPathExists=!/etc/ucore-autorebase/unverified' ignition/smortress.bu
check "stage 2 runs only after stage 1" has 'ConditionPathExists=/etc/ucore-autorebase/unverified' ignition/smortress.bu
check "ignition has no git pull" lacks 'git pull' ignition/smortress.bu

for cipher in secrets/server/*.yaml; do
  [[ -f $cipher ]] || continue
  name=$(basename "$cipher")
  check "$name is SOPS-encrypted" grep -q '^sops:' "$cipher"
  check "$name is ciphertext" grep -q 'ENC\[' "$cipher"
  if grep -q 'sops-decrypt-ok' "$cipher"; then bad "$name leaks plaintext"; else ok "$name has no plaintext canary"; fi
  check "$name is in the decrypt manifest" grep -qE "^${name//./\\.}[[:space:]]" image/rootfs/etc/smortress/secrets.manifest
done

check "firewall binds tailscale0" has '<interface name="tailscale0"/>' image/rootfs/etc/firewalld/zones/tailscale.xml
check "firewall permits ssh only on that zone" has '<service name="ssh"/>' image/rootfs/etc/firewalld/zones/tailscale.xml
if grep -rInE '0\.0\.0\.0|\[::\]' units image/rootfs 2>/dev/null | grep -v 'PublishPort=127.0.0.1' | grep -q .; then
  bad "no wildcard listener address in units or rootfs"
else
  ok "no wildcard listener address in units or rootfs"
fi

# Repository-wide CI rules that new files must not evade.
probe "workflow actions are SHA-pinned" scripts/check-action-pins.sh
probe "PR workflows hold no secrets" scripts/check-pr-secret-boundary.sh

if ((fail)); then
  echo "server image static checks failed" >&2
  exit 1
fi
echo "server image static checks passed"
