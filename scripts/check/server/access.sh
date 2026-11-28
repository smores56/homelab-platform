# shellcheck shell=bash
# shellcheck disable=SC2016,SC2034,SC2154  # helpers and globals come from the entrypoint
# The sudo key file is the image's second authorised-keys list, and the two may
# never mix: the touch option is fixed at enrollment, so the login credential is
# no-touch-required and the sudo credential asks for the tap. A plain
# ssh-ed25519 line here would let sudo accept a key that never asks for a touch,
# so two shapes are checked below: every line is an sk line, and no line carries
# the `no-touch-required` option text. Neither check proves the credential is
# touch-required, and nothing read from the file could: the public half does not
# record a touch policy, and pam_rssh at the pinned commit (bootc/lib/pins.env,
# e8dd046) rebuilds the signed message with sig.flags but never reads the
# user-presence bit, so a credential minted with `-O no-touch-required` looks
# identical here. The only proof of the property is the cover-the-sensor drill
# in docs/manual-steps.md section 44, which fails exactly when the credential
# signs without a tap. An empty file is allowed and expected until the owner
# enrolls the keys: pam_rssh finds no matching key, returns PAM_AUTH_ERR, and the
# password is the way in until the public halves are committed.
sudo_keys=bootc/server/rootfs/etc/ssh/sudo_authorized_keys
check "the image ships the sudo key file" test -e "$sudo_keys"
if grep -qvE '^sk-ssh-ed25519@openssh\.com [A-Za-z0-9+/]+[=]{0,2}([[:space:]].*)?$' "$sudo_keys"; then
  bad "every sudo key line is an sk-ssh-ed25519 line"
else
  ok "every sudo key line is an sk-ssh-ed25519 line"
fi
if grep -q 'no-touch-required' "$sudo_keys"; then
  bad "no sudo key line carries the no-touch-required option"
else
  ok "no sudo key line carries the no-touch-required option"
fi
# The build refuses the missing file, and the mode is the build's business:
# /etc/ssh is world-readable, and the sudo list names credentials that unlock
# root.
check "the build refuses a missing sudo key file" has 'test -e /etc/ssh/sudo_authorized_keys' bootc/server/Containerfile
check "the sudo key file is installed 0600" has 'chmod 0600 /etc/ssh/sudo_authorized_keys' bootc/server/Containerfile

# The SELinux half. The targeted policy grants sudo_t no access to the forwarded
# agent socket, which would cost the tap if sudo ran as sudo_t. It does not, and
# no local SELinux policy ships: sudo runs unconfined on this base (sudo_exec_t,
# process stays unconfined_t), so `sudo_t` does not resolve and an unconfined
# domain already holds the permission the agent socket needs. A module here would
# be dead code that fails to link; the AVC drill in manual-steps section 44 is
# the tripwire if a future base confines sudo.
# The permission to grant then is connectto, not connect: an AF_UNIX stream
# connect is checked as CONNECTTO on the peer socket's label, and `connect` only
# against the caller's own socket, which sudodomain already allows -- a rule
# asking for connect grants nothing and looks like a policy that never loaded.
check "no local sudo policy module ships" \
  test ! -e bootc/server/rootfs/usr/share/smortress/selinux/smortress_sudo_rssh.cil
check "no policy loader unit ships" \
  test ! -e units/systemd/smortress-selinux-sudo-rssh.service
check "no policy loader script ships" \
  test ! -e scripts/selinux-sudo-rssh-load.sh
check "the image wires no policy loader" lacks 'smortress-selinux-sudo-rssh' bootc/server/Containerfile

# The retired TOTP stack may not leave a trace: the skill moved to a touch, and a
# leftover usersfile, enrollment script or package reference would be state
# nothing reads and the runbooks would still describe. A checker names the
# patterns it refuses, so the checkers are outside the scan for the same reason
# the server's own is: the laptop's sudo stack asserts the module is absent.
check "the enrollment script is gone" test ! -e scripts/enroll-yubikey-totp.sh
if git grep -qF -e 'pam_oath' -e 'users.oath' -e 'HOTP/T30' -- . \
    ':(exclude)scripts/check-server-image.sh' ':(exclude)scripts/check/server/*' \
    ':(exclude)bootc/server/Containerfile' ':(exclude)hosts/laptop/tests/*'; then
  bad "no TOTP artifact is left anywhere"
else
  ok "no TOTP artifact is left anywhere"
fi
# Neither the old PIN database nor a usersfile may enter the repository: anything
# the agent account can read is a factor an agent holds.
if git ls-files | grep -qE 'sudopin|users\.oath|\.db$'; then
  bad "no PIN database or usersfile is tracked"
else
  ok "no PIN database or usersfile is tracked"
fi
if grep -rIlE "\$6\$[./A-Za-z0-9]{8,}\$" image ignition units secrets 2>/dev/null | grep -q .; then
  bad "no sha512crypt hash is tracked in the image or ignition tree"
else
  ok "no sha512crypt hash is tracked in the image or ignition tree"
fi

probe "policy rejects by default" jq -e '.default[0].type == "reject"' bootc/server/rootfs/etc/containers/policy.json
# An empty docker scope is the transport default and shadows the global reject
# for every registry reference, so it must not exist.
probe "no docker transport-wide accept" jq -e '.transports.docker[""] == null' bootc/server/rootfs/etc/containers/policy.json
check "firewalld is enabled in the image" has "firewalld.service" bootc/server/Containerfile
probe "policy trusts the smortress key by path" jq -e \
  '.transports.docker["ghcr.io/smores56/homelab-platform"][0].keyPath == "/etc/pki/containers/smortress.pub"' \
  bootc/server/rootfs/etc/containers/policy.json
check "signature attachments enabled for our repo" has 'use-sigstore-attachments: true' \
  bootc/server/rootfs/etc/containers/registries.d/ghcr.io-smortress.yaml

if [[ -f bootc/server/cosign.pub ]]; then
  check "operator public key is PEM" has 'BEGIN PUBLIC KEY' bootc/server/cosign.pub
else
  printf 'warn %s\n' "bootc/server/cosign.pub is not provisioned yet (docs/manual-steps.md section 37)"
fi
if grep -rIl --exclude-dir=.git --exclude=check-server-image.sh --exclude-dir=check \
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
  # A container that mounts a decrypted secret, directly or as a Podman secret,
  # must never start before the decrypt unit; one that uses no secret (the
  # machine learning cache, Syncthing's own config) has nothing to wait for.
  if grep -qE '^(Secret=|Volume=/run/smortress/secrets)' "$q"; then
    check "$q requires the decrypt unit" grep -qE '^Requires=.*sops-decrypt\.service' "$q"
    check "$q starts after the decrypt unit" grep -qE '^After=.*sops-decrypt\.service' "$q"
  fi
  if grep -q '^Secret=' "$q"; then
    check "$q requires the app-secrets unit" grep -qE '^Requires=.*smortress-app-secrets\.service' "$q"
  fi
  # The generator's RequiresMountsFor is satisfied by an empty directory; the
  # readiness instance is what checks /proc/self/mountinfo. Every volume that is
  # a dataset in the storage table must therefore have its instance required
  # here, and a volume that is not a dataset (a cache, valkey's AOF) has none.
  while IFS= read -r volume; do
    instance=${mount_to_instance[$volume]:-}
    [[ -n $instance ]] || continue
    check "$q requires zfs-ready@$instance" grep -qE "^Requires=.*zfs-ready@$instance\.service" "$q"
  done < <(sed -n 's|^Volume=\([^:]*\).*|\1|p' "$q" | sort -u)
done

check "readiness unit exists" has 'ExecStart=/usr/libexec/zfs-ready %i' 'units/systemd/zfs-ready@.service'
# /usr/local is a symlink into /var on bootc: a helper installed there does not
# exist at runtime, which is how the first install failed with 203/EXEC.
check "no unit runs from /usr/local" lacks '/usr/local/libexec' units/systemd/

# systemd units have no HOME; restic must be told where its cache lives.
for u in units/systemd/smortress-restic-backup@.service units/systemd/smortress-restic-verify.service units/systemd/smortress-restic-init.service; do
  check "$u sets RESTIC_CACHE_DIR" has "RESTIC_CACHE_DIR" "$u"
done
for key in "${dataset_order[@]}"; do
  instance=$(readiness_instance "$key")
  check "image enables zfs-ready@$instance" has "zfs-ready@$instance.service" bootc/server/Containerfile
done
check "decrypt unit is ordered after local-fs" has 'After=local-fs.target' units/systemd/sops-decrypt.service
check "zpool unit follows the data cryptsetup unit" has 'After=systemd-cryptsetup@data.service' units/systemd/smortress-zpool.service
check "zpool unit requires the data formatting oneshot" has 'Requires=smortress-data-init.service' units/systemd/smortress-zpool.service
check "the data formatting oneshot runs before the pool" has 'Before=smortress-zpool.service' units/systemd/smortress-data-init.service
check "the data formatting oneshot is installed" has 'ExecStart=/usr/libexec/init-data-luks' units/systemd/smortress-data-init.service
check "the image enables the data formatting oneshot" has 'smortress-data-init.service' bootc/server/Containerfile
check "the image installs the data formatting helper" has 'scripts/init-data-luks.sh' bootc/server/Containerfile
check "the data key is generated on the host" has 'head -c 64 /dev/urandom' scripts/init-data-luks.sh
check "the data key is root-only" has 'chmod 0400 "$keyfile.new"' scripts/init-data-luks.sh
check "the data partition is formatted by the oneshot" has 'cryptsetup luksFormat' scripts/init-data-luks.sh
check "the data crypttab entry stays out of the initramfs" lacks 'x-initrd.attach' scripts/init-data-luks.sh
check "the data crypttab entry cannot block boot" has 'luks,discard,nofail' scripts/init-data-luks.sh
check "HDD unlock cannot block boot" has 'ExecStart=-/usr/libexec/open-hdd' units/systemd/smortress-cryptsetup-hdd.service

# Restic plane (T3). A mount unit that is not installed, a retention filter
# missing one tag, or a job ordered before its dataset is ready all fail
# silently on the host, so the shape is asserted here.
for m in var-lib-restic-ssd.mount var-lib-restic-hdd.mount; do
  check "Restic mount unit $m exists" test -s "units/systemd/$m"
  check "image enables $m" has "$m" bootc/server/Containerfile
done
check "SSD mount is keyed by the wiped disk label" has 'What=/dev/disk/by-label/restic-ssd' units/systemd/var-lib-restic-ssd.mount
check "SSD mount cannot block boot" has 'nofail' units/systemd/var-lib-restic-ssd.mount
check "HDD mount is keyed by its UUID" has 'What=/dev/disk/by-uuid/973b7492-bb88-43c7-bac3-772384e45220' units/systemd/var-lib-restic-hdd.mount
check "HDD mount cannot block boot" has 'noexec,nofail' units/systemd/var-lib-restic-hdd.mount
check "HDD mount bounds the device wait" has 'JobTimeoutSec=45' units/systemd/var-lib-restic-hdd.mount
check "HDD mount bounds the mount command" has 'TimeoutSec=30' units/systemd/var-lib-restic-hdd.mount

backup_after=$(sed -e :a -e '/\\$/N; s/\\\n/ /; ta' 'units/systemd/smortress-restic-backup@.service' | grep '^After=')
for key in "${dataset_order[@]}"; do
  instance=$(readiness_instance "$key")
  if [[ $backup_after == *"zfs-ready@$instance.service"* ]]; then
    ok "backup driver is ordered after zfs-ready@$instance"
  else
    bad "backup driver is ordered after zfs-ready@$instance"
  fi
done
check "backup driver requires the decrypt unit" grep -qE '^Requires=.*sops-decrypt\.service' 'units/systemd/smortress-restic-backup@.service'
check "verifier requires the decrypt unit" grep -qE '^Requires=.*sops-decrypt\.service' units/systemd/smortress-restic-verify.service
check "init requires the decrypt unit" grep -qE '^Requires=.*sops-decrypt\.service' units/systemd/smortress-restic-init.service

retention_ok=1
while IFS= read -r retention_line; do
  [[ $retention_line == *--keep-* ]] || continue
  if [[ $retention_line != *'--tag "unit:'* || $retention_line != *',verified'* ]]; then
    retention_ok=0
  fi
done < <(sed -e :a -e '/\\$/N; s/\\\n/ /; ta' scripts/smortress-restic-backup.sh)
check "retention requires both unit and verified tags" test "$retention_ok" -eq 1
check "no wildcard retention bucket" lacks '--keep-last' scripts/smortress-restic-backup.sh
check "no time-window retention bucket" lacks '--keep-within' scripts/smortress-restic-backup.sh
if grep -qE '(^|[[:space:]])unlock([[:space:]]|$)' scripts/smortress-restic-*.sh; then
  bad "no routine restic unlock"
else
  ok "no routine restic unlock"
fi
if grep -qE -- 'forget .*\*|rm -rf[^#]*(/var/lib/restic|/var/lib/homelab/restic)' scripts/smortress-restic-*.sh; then
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
check "all plane state lives under /var/lib/homelab" has '/var/lib/homelab/restic' scripts/restic-plane-common.sh
check "state directories are created 0700" has 'install -d -m 0700' scripts/restic-plane-common.sh
check "R2 uses the new repository path" has 'homelab-restic/smortress' scripts/restic-plane-common.sh
check "the plane never names the legacy R2 bucket" lacks 'restic-backup' scripts/restic-plane-common.sh
for unit in smortress-restic-backup-ssd.timer smortress-restic-backup-hdd.timer \
  smortress-restic-backup-r2.timer smortress-restic-verify.timer \
  smortress-restic-init.service; do
  check "image enables $unit" has "$unit" bootc/server/Containerfile
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
# Design #701: no secret enters Ignition or the installer media. An inline or
# local key_file is a LUKS keyslot keyed from the config; the recovery
# passphrases are added on the host after the install instead. The data
# partition is created here unformatted and formatted by the first-boot oneshot.
check "ignition carries no LUKS key file" lacks 'key_file:' ignition/smortress.bu
check "ignition carries no root recovery passphrase" lacks 'ROOT_RECOVERY_PASSPHRASE' ignition/smortress.bu
check "ignition carries no data recovery passphrase" lacks 'DATA_RECOVERY_PASSPHRASE' ignition/smortress.bu
check "ignition labels the root LUKS volume" has 'label: luks-root' ignition/smortress.bu
check "ignition does not format the data partition" lacks 'device: /dev/disk/by-partlabel/luks-data' ignition/smortress.bu
check "ignition still creates the data partition" has '- label: luks-data' ignition/smortress.bu
check "ignition has no mutable git checkout" lacks 'git clone' ignition/smortress.bu
check "ignition installs the verification policy" has '/etc/containers/policy.json' ignition/smortress.bu
check "ignition creates the autorebase marker directory" has '/etc/ucore-autorebase' ignition/smortress.bu
check "stage 1 runs only before the marker" has 'ConditionPathExists=!/etc/ucore-autorebase/unverified' ignition/smortress.bu
check "stage 2 runs only after stage 1" has 'ConditionPathExists=/etc/ucore-autorebase/unverified' ignition/smortress.bu
check "ignition has no git pull" lacks 'git pull' ignition/smortress.bu

for cipher in secrets/*.yaml secrets/*.json; do
  [[ -f $cipher ]] || continue
  name=$(basename "$cipher")
  case $name in index.json | index.bundles.json) continue ;; esac
  if [[ $name == *.json ]]; then
    check "$name is SOPS-encrypted" grep -q '"sops"' "$cipher"
  else
    check "$name is SOPS-encrypted" grep -q '^sops:' "$cipher"
  fi
  check "$name is ciphertext" grep -q 'ENC\[' "$cipher"
  if grep -q 'sops-decrypt-ok' "$cipher"; then bad "$name leaks plaintext"; else ok "$name has no plaintext canary"; fi
  if [[ $name == *.json ]]; then
    check "$name is a declared bundle" grep -qE "[[:space:]]${name//./\\.}[[:space:]]" bootc/server/rootfs/usr/share/smortress/secrets.manifest
  fi
done
# The reverse direction matters just as much: the boot decrypt fails closed on
# the first manifest entry without its ciphertext, and every unit that requires
# sops-decrypt goes down with it.
while read -r name bundle; do
  check "$name has committed ciphertext" test -s "secrets/$bundle"
done < <(awk '!/^[[:space:]]*(#|$)/ && NF >= 7 { print $1, $2 }' bootc/server/rootfs/usr/share/smortress/secrets.manifest)

# The ciphertext moved from the image to /var: a rotation is an operator write and
# a restart of the decrypt unit, not an OS image and a reboot. The baked set is
# only the seed for a host that has none yet.
check "the boot decrypt reads the host ciphertext" \
  has 'SMORTRESS_SECRETS_SRC:-/var/lib/smortress/secrets' scripts/sops-decrypt.sh
check "the boot decrypt seeds the host copy first" \
  has 'ExecStartPre=/usr/libexec/smortress-secrets-seed' units/systemd/sops-decrypt.service

# The manifest is metadata, not a secret, so the image owns it and the seed
# refreshes the /etc copy on every run. It must NOT ship under /etc: bootc merges
# /etc once per deployment and keeps what the host already had, which is how the
# 2026-11-22 incident stranded a host manifest behind the ciphertext set. The
# seed reads the bootc-owned path, and the /etc path stays the decrypt's default
# so a rollback to an image that only read /etc still finds a manifest.
check "the manifest ships at the bootc-owned path" \
  test -s bootc/server/rootfs/usr/share/smortress/secrets.manifest
check "no manifest ships under /etc" no_file_exists bootc/server/rootfs/etc/smortress/secrets.manifest
check "the build makes the manifest world-readable" \
  has 'chmod 0644 /etc/pki/containers/smortress.pub /usr/share/smortress/secrets.manifest' \
  bootc/server/Containerfile
check "the seed reads the bootc-owned manifest" \
  has 'SMORTRESS_SECRETS_IMAGE_MANIFEST:-/usr/share/smortress/secrets.manifest' \
  scripts/smortress-secrets-seed.sh
check "the seed refreshes the manifest the decrypt reads" \
  has 'SMORTRESS_SECRETS_MANIFEST:-/etc/smortress/secrets.manifest' \
  scripts/smortress-secrets-seed.sh
check "the boot decrypt still reads the /etc copy" \
  has 'SMORTRESS_SECRETS_MANIFEST:-/etc/smortress/secrets.manifest' scripts/sops-decrypt.sh

# The two machine credentials are agent-only (docs/secrets.md): a bare
# value, root-only, because the dispatcher hands the file's bytes to one general
# job as GH_TOKEN. Absent is a valid state -- until the T5 dispatcher exists the
# general agent has no GitHub identity -- and the ciphertext/manifest set check
# above keeps a staged file and its line together either way.
for name in agent-github-token.yaml sdlc-github-token.yaml; do
  check "$name is a root-only manifest value" \
    grep -qE "^${name//./\\.}[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+root[[:space:]]+root[[:space:]]+0400[[:space:]]+value$" \
    bootc/server/rootfs/usr/share/smortress/secrets.manifest
done
