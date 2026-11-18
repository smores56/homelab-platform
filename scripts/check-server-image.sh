#!/usr/bin/env bash
# shellcheck disable=SC2154  # dataset values come from the storage table
# Static checks for the derived image, Ignition template, Quadlets and SOPS
# layout. No registry, no cosign key and no operator secret is required.
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# The storage table is the only list of datasets: a volume is a dataset iff its
# mountpoint is in the table, and the readiness instance is derived from it.
# shellcheck source=/dev/null
source "$repo/scripts/storage-layout.sh"
declare -A mount_to_instance=()
for _key in "${dataset_order[@]}"; do
  for _alias in $(mountpoint_aliases "$_key"); do
    mount_to_instance[$_alias]=$(readiness_instance "$_key")
  done
done
unset _key
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
for pin in SOPS_SHA256 AGE_SHA256 RESTIC_SHA256 CLOUDFLARED_SHA256 BUTANE_SHA256 COSIGN_SHA256; do
  if [[ ${!pin} =~ ^[0-9a-f]{64}$ ]]; then ok "$pin format"; else bad "$pin format"; fi
done

check "Containerfile takes a base argument" has "FROM \${BASE_IMAGE}" image/Containerfile
check "Containerfile rejects a floating base" lacks ':latest' image/Containerfile
check "Containerfile installs the public key" has 'image/cosign.pub /etc/pki/containers/smortress.pub' image/Containerfile
check "Containerfile masks Podman auto-update" has 'podman-auto-update.timer' image/Containerfile
check "Containerfile masks bootc auto-update" has 'bootc-fetch-apply-updates.timer' image/Containerfile
check "Containerfile sets the default firewall zone to drop" has '--set-default-zone=drop' image/Containerfile

# The SSH tunnel connector. Its token is image ciphertext, so it must never
# reach argv, and the unit must not start before the decrypt unit has written
# that ciphertext.
check "image pins the cloudflared release" has 'CLOUDFLARED_SHA256' image/Containerfile
check "image ships the connector unit" has 'smortress-cloudflared.service' image/Containerfile
check "the connector reads the token from a credential file" has 'LoadCredential=tunnel:/run/smortress/secrets/cloudflared-tunnel.yaml' units/systemd/smortress-cloudflared.service
if grep -qE -- '--token([= ]|$)' units/systemd/smortress-cloudflared.service; then
  bad "the connector keeps the token off argv"
else
  ok "the connector keeps the token off argv"
fi
check "the connector requires the decrypt unit" grep -qE '^Requires=.*sops-decrypt\.service' units/systemd/smortress-cloudflared.service
check "the connector is skipped without its ciphertext" has 'ConditionPathExists=/run/smortress/secrets/cloudflared-tunnel.yaml' units/systemd/smortress-cloudflared.service
check "the tunnel token is in the decrypt manifest" grep -qE '^cloudflared-tunnel\.yaml[[:space:]]' image/rootfs/etc/smortress/secrets.manifest

# sshd (design #748). Access through the tunnel is the only route in, so the
# listener is loopback-only. The drop-in must also sort ahead of uCore's
# 90-enable-localhost-passwords.conf: sshd reads its config twice, and the
# second pass re-reads only the matching Match blocks with first-obtained-value
# semantics, so a file sorting after 90- cannot undo uCore's
# `PasswordAuthentication yes` for loopback.
sshd_dir=image/rootfs/etc/ssh/sshd_config.d
sshd_dropin=$sshd_dir/05-deny-loopback-passwords.conf
sshd_dropins=("$sshd_dir"/*.conf)
check "sshd ships exactly one drop-in" test "${#sshd_dropins[@]}" -eq 1
check "the drop-in sorts ahead of uCore's 90- localhost-passwords file" \
  test "$(basename "$sshd_dropin")" = 05-deny-loopback-passwords.conf
check "sshd binds loopback for IPv4" has 'ListenAddress 127.0.0.1' "$sshd_dropin"
check "sshd binds loopback for IPv6" has 'ListenAddress ::1' "$sshd_dropin"
check "sshd binds no other address" test "$(count 'ListenAddress ' "$sshd_dropin")" -eq 2
check "the loopback pair is exempt from the shared penalty counter" \
  has 'PerSourcePenaltyExemptList 127.0.0.1,::1' "$sshd_dropin"
check "ssh accepts keys from the Ignition file" \
  has 'AuthorizedKeysFile /var/lib/homelab/.ssh/authorized_keys' "$sshd_dropin"
# The dotted directory is what file_contexts maps to ssh_home_t; a plain
# /var/lib/homelab/ssh would be var_lib_t and sshd could not read the file.
check "the authorised set lives under a dot-prefixed directory" grep -qF '/.ssh/authorized_keys' "$sshd_dropin"
check "ssh never accepts a password" has 'PasswordAuthentication no' "$sshd_dropin"
# Comment lines are dropped: the file explains uCore's block by name.
if grep -vE '^[[:space:]]*#' "$sshd_dropin" | grep -qF 'PasswordAuthentication yes'; then
  bad "ssh never re-enables a password for loopback"
else
  ok "ssh never re-enables a password for loopback"
fi
check "keyboard-interactive stays off" has 'KbdInteractiveAuthentication no' "$sshd_dropin"
check "root never logs in over ssh" has 'PermitRootLogin no' "$sshd_dropin"
check "one account may log in" has 'AllowUsers smores' "$sshd_dropin"
check "no TCP forwarding" has 'AllowTcpForwarding no' "$sshd_dropin"
check "no stream-local forwarding" has 'AllowStreamLocalForwarding no' "$sshd_dropin"
check "no agent forwarding" has 'AllowAgentForwarding no' "$sshd_dropin"
check "no user rc file runs at login" has 'PermitUserRC no' "$sshd_dropin"
check "auth tries are bounded" has 'MaxAuthTries 10' "$sshd_dropin"
check "the grace time is bounded" has 'LoginGraceTime 60' "$sshd_dropin"
# PubkeyAuthOptions stays unset (default `none`). verify-required is a hard
# requirement, not a permission: with it set, sshd rejects every FIDO signature
# without the UV assertion, and authorized_keys has no no-verify-required to
# cancel it per key, so the touch-free resident sk- login could never work.
# touch-required is refused for the mirror-image reason: it pins the opposite
# decision where only the authorized_keys line should make it. Comments name the
# options, so the directives are what is checked.
for option in verify-required touch-required; do
  if grep -vE '^[[:space:]]*#' "$sshd_dropin" | grep -qF -- "$option"; then
    bad "ssh never pins sk signatures to $option"
  else
    ok "ssh never pins sk signatures to $option"
  fi
done
# Everything that is not a comment after the Match line is inside the block, so
# a global directive appended below it would silently become loopback-only.
check "the loopback block comes last and re-denies passwords" test \
  "$(awk '/^[[:space:]]*(#|$)/ {next} /^Match Address 127\.0\.0\.1,::1$/ {inblock=1; next} inblock' "$sshd_dropin" | tr -d '[:space:]')" \
  = PasswordAuthenticationno

# The authorised set (design #748, Entry). bootc does not reconcile /var, so the
# file sshd points at arrives from Ignition inlining a committed repo file: an
# image-baked copy would never appear on an installed host and a hand-written one
# would drift. The resident sk- handle is generated with the token, so nothing in
# the tree may carry real key material and the file ships as instructions only.
ignition_bu=ignition/smortress.bu
keys_source=ignition/smortress-authorized-keys
# The list item for one path, up to the next item: a mode asserted inside it is
# that file's mode and not a neighbour's.
bu_block() {
  awk -v head="    - path: $1" '
    $0 == head { inblock = 1; next }
    inblock && /^    - / { exit }
    inblock { print }
  ' "$ignition_bu"
}
in_block() { printf '%s\n' "$2" | grep -qF -- "$1"; }
ak_path=$(sed -nE 's/^AuthorizedKeysFile[[:space:]]+([^[:space:]]+)$/\1/p' "$sshd_dropin")
check "the drop-in names one authorised-keys file" test "$(printf '%s\n' "$ak_path" | grep -c .)" -eq 1
check "Ignition writes the file the drop-in points at" grep -qF "path: $ak_path" "$ignition_bu"
ak_block=$(bu_block "$ak_path")
check "Ignition inlines the committed key file" in_block "local: $keys_source" "$ak_block"
check "the delivered file is owner-readable only" in_block 'mode: 0600' "$ak_block"
# sshd opens AuthorizedKeysFile with the target user's uid, so ownership and the
# path's traversal both have to belong to that account.
check "the delivered file is smores-owned twice over" \
  test "$(printf '%s\n' "$ak_block" | grep -cF 'name: smores')" -eq 2
ak_dir=$(dirname -- "$ak_path")
check "Ignition creates the directory that file lives in" grep -qF "path: $ak_dir" "$ignition_bu"
dir_block=$(bu_block "$ak_dir")
check "the key directory belongs to the same account" \
  test "$(printf '%s\n' "$dir_block" | grep -cF 'name: smores')" -eq 2
check "the key directory is 0700" in_block 'mode: 0700' "$dir_block"
# 0711 is the traversal sshd needs as smores; every child stays root-only.
check "the key path is traversable by that account" \
  has 'd /var/lib/homelab 0711 root root -' image/rootfs/etc/tmpfiles.d/smortress.conf
check "the enrollment unit keeps the same traversal mode" \
  has 'install -d -m 0711 /var/lib/homelab' units/systemd/smortress-tailscale-up.service
check "the committed key file exists" test -s "$keys_source"
if grep -qvE '^[[:space:]]*(#|$)' "$keys_source"; then
  bad "the committed key file carries no key line"
else
  ok "the committed key file carries no key line"
fi
# git grep reads the index, so the exclusion is only the check's own pattern.
if git grep -qF -- 'sk-ssh-ed25519@openssh.com' -- . ':(exclude)scripts/check-server-image.sh'; then
  bad "no sk- handle is committed anywhere"
else
  ok "no sk- handle is committed anywhere"
fi
# Tailscale SSH stays off (design #748). Removing the flag from the enrollment
# unit only fixes the first boot; the preference lives in tailscaled's state and
# a separate unit re-asserts it every boot, which is why it must be enabled and
# must not run before there is a state to write to.
tailscale_up=units/systemd/smortress-tailscale-up.service
tailscale_off=units/systemd/smortress-tailscale-ssh-off.service
check "enrollment no longer asks for Tailscale SSH" has 'tailscale up --hostname=smortress' "$tailscale_up"
if grep -vE '^[[:space:]]*#' "$tailscale_up" | grep -qE -- '--ssh([= ]|$)'; then
  bad "enrollment never passes --ssh"
else
  ok "enrollment never passes --ssh"
fi
check "a unit re-asserts the preference at boot" has 'ExecStart=/usr/bin/tailscale set --ssh=false' "$tailscale_off"
check "the preference is re-asserted after tailscaled starts" grep -qE '^Requires=tailscaled\.service' "$tailscale_off"
check "the preference is re-asserted after enrollment" grep -qE '^After=.*smortress-tailscale-up\.service' "$tailscale_off"
# Before `tailscale up` writes its state there is no preference to set, and the
# enrollment unit's own exec is what creates it.
check "the preference is not set before there is a state file" \
  has 'ConditionPathExists=/var/lib/tailscale/tailscaled.state' "$tailscale_off"
check "image enables the preference unit" has 'smortress-tailscale-ssh-off.service' image/Containerfile
if grep -qE '^ExecStart=.*tailscale (up|set).*--ssh(=true)?([[:space:]]|$)' "$tailscale_off"; then
  bad "the preference unit only ever disables Tailscale SSH"
else
  ok "the preference unit only ever disables Tailscale SSH"
fi

# sudo PIN gate (design #748, T6). Asserted line by line because order and jump
# counts are the meaning: a matching PIN skips pam_unix and the authfail row, a
# mistyped one falls to pam_unix with the same string cached, and only then does
# the failure reach faillock. The last three auth rows carry `deny=5` for the
# same tally; a bare `authsucc` stops clearing it at three rows.
pam_sudo=image/rootfs/etc/pam.d/sudo
expected_pam='auth required pam_faillock.so preauth deny=5 unlock_time=300
auth [success=2 default=ignore] pam_userdb.so crypt=crypt db=/etc/security/sudopin.db
auth [success=1 default=ignore] pam_unix.so try_first_pass
auth [default=die] pam_faillock.so authfail deny=5 unlock_time=300
auth sufficient pam_faillock.so authsucc deny=5 unlock_time=300
account include system-auth
password include system-auth
session optional pam_keyinit.so revoke
session required pam_limits.so
session include system-auth'
actual_pam=$(sed -E 's/[[:space:]]+/ /g; s/ $//' "$pam_sudo" | grep -Ev '^(#|$)' || true)
if [[ $actual_pam == "$expected_pam" ]]; then
  ok "the sudo stack is the reviewed ten rows in order"
else
  bad "the sudo stack is the reviewed ten rows in order: $(printf '%s' "$actual_pam" | tr '\n' ';')"
fi
# `db=` is opened literally: Linux-PAM never appends `.db`, so `/etc/security/sudopin`
# would make pam_userdb open a file that does not exist and fail every time.
check "pam_userdb opens the .db path literally" \
  has 'db=/etc/security/sudopin.db' "$pam_sudo"
# Without crypt=crypt the stored value is compared as plaintext, so the database
# would have to hold the PIN itself.
check "the stored PIN is compared as a crypt hash" has 'crypt=crypt' "$pam_sudo"
check "the account phase is still declared" grep -qE '^account[[:space:]]+include[[:space:]]+system-auth$' "$pam_sudo"
check "the password phase is still declared" grep -qE '^password[[:space:]]+include[[:space:]]+system-auth$' "$pam_sudo"
check "the session phase is still declared" grep -qE '^session[[:space:]]+include[[:space:]]+system-auth$' "$pam_sudo"
# pam_userdb matches the PAM username, not a fixed key, so the account that runs
# sudo is the key the operator must put in the database.
check "the only login account is smores" grep -qE '^[[:space:]]*- name: smores$' ignition/smortress.bu
check "the stack documents that account as the pam_userdb key" grep -qF 'That account is smores' "$pam_sudo"

sudoers_dropin=image/rootfs/etc/sudoers.d/10-human-gate
expected_sudoers='Defaults timestamp_timeout=30
Defaults timestamp_type=tty
Defaults log_subcmds'
actual_sudoers=$(grep -E '^Defaults[[:space:]]' "$sudoers_dropin")
if [[ $actual_sudoers == "$expected_sudoers" ]]; then
  ok "the sudoers gate is the reviewed three defaults in order"
else
  bad "the sudoers gate is the reviewed three defaults in order" "$actual_sudoers"
fi
check "the sudoers drop-in is installed 0440" has 'chmod 0440 /etc/sudoers.d/10-human-gate' image/Containerfile
check "the sudoers drop-in is parsed at build time" has 'visudo -cf /etc/sudoers.d/10-human-gate' image/Containerfile
# Access through the tunnel is the only route in, so a drop-in sshd refuses to
# parse would cost a console recovery; the build parses the shipped config
# instead of leaving the host to find out at boot.
check "the sshd configuration is parsed at build time" has 'sshd -t -o HostKey=' image/Containerfile
check "the build fails if pam_userdb is missing" has 'test -f /usr/lib64/security/pam_userdb.so' image/Containerfile
check "tmpfiles declares the PIN database owner and mode" \
  has 'f /etc/security/sudopin.db 0600 root root -' image/rootfs/etc/tmpfiles.d/smortress.conf
# Neither the PIN, its hash nor its database may enter the repository: anything
# the agent account can read is a PIN an agent recovers in seconds.
if git ls-files | grep -qE 'sudopin|\.db$'; then
  bad "no PIN database is tracked"
else
  ok "no PIN database is tracked"
fi
if grep -rIlE "\$6\$[./A-Za-z0-9]{8,}\$" image ignition units secrets 2>/dev/null | grep -q .; then
  bad "no sha512crypt hash is tracked in the image or ignition tree"
else
  ok "no sha512crypt hash is tracked in the image or ignition tree"
fi

probe "policy rejects by default" jq -e '.default[0].type == "reject"' image/rootfs/etc/containers/policy.json
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
  check "image enables zfs-ready@$instance" has "zfs-ready@$instance.service" image/Containerfile
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
# The reverse direction matters just as much: the boot decrypt fails closed on
# the first manifest entry without its ciphertext, and every unit that requires
# sops-decrypt goes down with it.
while read -r name; do
  check "$name has committed ciphertext" test -s "secrets/server/$name"
done < <(awk '!/^[[:space:]]*(#|$)/ { print $1 }' image/rootfs/etc/smortress/secrets.manifest)

check "firewall binds tailscale0" has '<interface name="tailscale0"/>' image/rootfs/etc/firewalld/zones/tailscale.xml
check "firewall permits ssh only on that zone" has '<service name="ssh"/>' image/rootfs/etc/firewalld/zones/tailscale.xml
# A wildcard *listener* binds every address; `0.0.0.0` inside a CIDR
# (10.0.0.0/8) is a destination and must not trip this.
if grep -rInE '\b0\.0\.0\.0\b|\[::\]' units image/rootfs 2>/dev/null | grep -v 'PublishPort=127.0.0.1' | grep -q .; then
  bad "no wildcard listener address in units or rootfs"
else
  ok "no wildcard listener address in units or rootfs"
fi

# Applications (T5). The image ships the Quadlets and the units that make them
# work, and every application image must be our signed mirror at the pinned
# digest: the default-reject policy has no other path to a running container.
# The list is derived, not written out: a network file left out of the image
# makes the generator drop the container that requests it, which is how
# opdshelf.network reached the first T5 boot missing.
shopt -s nullglob
for q in units/quadlet/*.container units/quadlet/*.network; do
  unit=${q#units/quadlet/}
  [[ $unit == pattern.container ]] && continue
  check "image installs units/quadlet/$unit" has "units/quadlet/$unit" image/Containerfile
done
check "quadlets live where the generator scans" has '/usr/share/containers/systemd/' image/Containerfile
check "the placeholder is not installed as a runnable quadlet" \
  lacks 'units/quadlet/pattern.container /usr/share/containers/systemd' image/Containerfile
for unit in smortress-app-secrets.service smortress-tailscale-serve.service \
  smortress-immich-dump.timer; do
  check "image enables $unit" has "$unit" image/Containerfile
done
# shellcheck source=app-images.sh disable=SC1091
source scripts/app-images.sh
for name in $(app_image_names); do
  if grep -qF -- "Image=$(app_image_ref "$name")" units/quadlet/*.container; then
    ok "$name runs the signed mirror at its pinned digest"
  else
    bad "$name runs the signed mirror at its pinned digest"
  fi
done
check "Syncthing's sync port is permitted on the tailscale zone" \
  has '<port port="22000" protocol="tcp"/>' image/rootfs/etc/firewalld/zones/tailscale.xml
check "Syncthing's QUIC port is permitted on the tailscale zone" \
  has '<port port="22000" protocol="udp"/>' image/rootfs/etc/firewalld/zones/tailscale.xml

# Repository-wide CI rules that new files must not evade.
probe "workflow actions are SHA-pinned" scripts/check-action-pins.sh
probe "PR workflows hold no secrets" scripts/check-pr-secret-boundary.sh

if ((fail)); then
  echo "server image static checks failed" >&2
  exit 1
fi
echo "server image static checks passed"
