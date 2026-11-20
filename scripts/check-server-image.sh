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
has() { grep -rqF -- "$1" "$2"; }
lacks() { ! grep -rqF -- "$1" "$2"; }
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

# sshd (design #767). The tailnet is the only route in and the firewall is the
# filter, so the drop-in carries no ListenAddress at all: sshd listens on every
# local address, the default zone is `drop`, and only tailscale0 accepts ssh. The
# tailnet address is per node, so no address could be bound at build time. The
# drop-in must still sort ahead of uCore's 90-enable-localhost-passwords.conf:
# sshd reads its config twice, and the second pass re-reads only the matching
# Match blocks with first-obtained-value semantics, so a file sorting after 90-
# cannot undo uCore's `PasswordAuthentication yes` for loopback.
sshd_dir=image/rootfs/etc/ssh/sshd_config.d
sshd_dropin=$sshd_dir/05-tailnet-ssh.conf
sshd_dropins=("$sshd_dir"/*.conf)
check "sshd ships exactly one drop-in" test "${#sshd_dropins[@]}" -eq 1
check "the drop-in is the tailnet one" test "$(basename "$sshd_dropin")" = 05-tailnet-ssh.conf
# A ListenAddress would either name one interface's address (impossible: the
# tailnet address is per node) or hard-code every address, which the tree-wide
# wildcard scan below forbids.
if grep -qE '^[[:space:]]*ListenAddress' "$sshd_dropin"; then
  bad "sshd leaves the listen addresses at its default"
else
  ok "sshd leaves the listen addresses at its default"
fi
# Tailnet clients arrive from their own addresses, so there is no single shared
# penalty counter left to exempt.
check "no address is exempt from the penalty counter" lacks 'PerSourcePenaltyExemptList' "$sshd_dropin"
# The key ships in the image at a path root reads: /etc/ssh is etc_t and
# world-readable, so sshd needs no uid switch, no traversal mode of its own and
# no Ignition run.
check "ssh reads the image-shipped key file" \
  has 'AuthorizedKeysFile /etc/ssh/authorized_keys.d/smores' "$sshd_dropin"
# Directive lines only: the file names the retired path in a comment, which must
# not read as a directive. Nothing may point AuthorizedKeysFile back into /var,
# where bootc reconciles nothing and only Ignition can write.
if grep -vE '^[[:space:]]*#' "$sshd_dropin" | grep -qF '/var/lib/homelab'; then
  bad "no authorised keys are delivered through /var"
else
  ok "no authorised keys are delivered through /var"
fi
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
# Agent forwarding is the one channel that is on, and it is load-bearing: sshd
# creates ~/.ssh/agent and exports SSH_AUTH_SOCK only for a session that
# forwarded an agent, and pam_rssh reads that socket, so `no` here leaves every
# sudo prompt at PAM_AUTHINFO_UNAVAIL and the password as the only factor. It is
# its own directive: AllowStreamLocalForwarding does not gate it either way.
check "agent forwarding is on for the sudo tap" has 'AllowAgentForwarding yes' "$sshd_dropin"
check "no user rc file runs at login" has 'PermitUserRC no' "$sshd_dropin"
check "auth tries are bounded" has 'MaxAuthTries 10' "$sshd_dropin"
check "the grace time is bounded" has 'LoginGraceTime 60' "$sshd_dropin"
# PubkeyAuthOptions stays unset (default `none`). verify-required is a hard
# requirement, not a permission: with it set, sshd rejects every FIDO signature
# without the UV assertion, and authorized_keys has no no-verify-required to
# cancel it per key, so a touch-free resident sk- login could never work.
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

# The authorised set ships in the image (design #767): one ed25519 line, root
# owned 0644 under /etc/ssh, so sshd opens it as root and a key change arrives
# with `bootc upgrade`. It replaces the Ignition-delivered /var/lib/homelab/.ssh
# pair, which had to be smores-owned under a 0711 parent because sshd switches to
# the target uid before opening AuthorizedKeysFile, and which could only be
# written once, at install time, by an Ignition config that then drifted from the
# token in the operator's pocket.
ak_path=$(sed -nE 's/^AuthorizedKeysFile[[:space:]]+([^[:space:]]+)$/\1/p' "$sshd_dropin")
check "the drop-in names one authorised-keys file" test "$(printf '%s\n' "$ak_path" | grep -c .)" -eq 1
keys_file=image/rootfs$ak_path
check "the image ships the file the drop-in points at" test -s "$keys_file"
if grep -qvE '^ssh-ed25519 [A-Za-z0-9+/]+[=]{0,2}([[:space:]].*)?$' "$keys_file"; then
  bad "the shipped key file carries only ed25519 key lines"
else
  ok "the shipped key file carries only ed25519 key lines"
fi
if grep -q 'sk-' "$keys_file"; then
  bad "the shipped key file carries no FIDO handle"
else
  ok "the shipped key file carries no FIDO handle"
fi
check "the shipped set is one key" test "$(grep -c '^ssh-ed25519 ' "$keys_file")" -eq 1
# The build refuses the same two mistakes, so a bad edit never reaches a host
# whose only other way in is the console.
check "the build refuses an empty key file" has 'test -s /etc/ssh/authorized_keys.d/smores' image/Containerfile
check "the build refuses a FIDO handle in the key file" \
  has "grep -q 'sk-ssh-ed25519' /etc/ssh/authorized_keys.d/smores" image/Containerfile
# Nothing delivers a key through Ignition any more. The operator's rollback key
# in smortress.bu is a different path and stays.
check "ignition no longer writes an authorised-keys file" lacks 'path: /var/lib/homelab/.ssh' ignition/smortress.bu
check "the Ignition key source is gone" test ! -e ignition/smortress-authorized-keys
# /var/lib/homelab keeps 0711 for its other tenants (the age identity, app and
# Tailscale state); no key path lives under it now.
check "the state directory keeps its traversal mode" \
  has 'd /var/lib/homelab 0711 root root -' image/rootfs/etc/tmpfiles.d/smortress.conf
check "the enrollment unit creates the state directory at the same mode" \
  has 'install -d -m 0711 /var/lib/homelab' units/systemd/smortress-tailscale-up.service
# git grep reads the index, so the exclusion is only the check's own pattern and
# the sudo key file: the sudo credentials' public halves are committed there by
# design, and the sk-only rule above is what keeps them touch-required.
if git grep -qF -- 'sk-ssh-ed25519@openssh.com' -- . \
    ':(exclude)scripts/check-server-image.sh' \
    ':(exclude)image/rootfs/etc/ssh/sudo_authorized_keys'; then
  bad "no sk- handle is committed anywhere but the sudo key file"
else
  ok "no sk- handle is committed anywhere but the sudo key file"
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

# sudo gate (design #767, T8): a touch on the agent sshd forwards, with the
# account password behind it. Asserted line by line because the order and the
# jump counts are the meaning: a successful touch skips the password and the
# failure counter and lands on authsucc, a failed touch falls through to
# pam_unix, and only a failed password reaches authfail. A bare `sufficient` on
# the touch row would terminate dispatch before authsucc ran and leave the
# faillock tally uncleared forever, so the counts are not cosmetic.
pam_sudo=image/rootfs/etc/pam.d/sudo
expected_pam='auth required pam_faillock.so preauth deny=5 unlock_time=300
auth [success=2 default=ignore] libpam_rssh.so auth_key_file=/etc/ssh/sudo_authorized_keys cue
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
# The touch row reads its own file, not AuthorizedKeysFile: the login credential
# is minted no-touch-required and must never satisfy sudo.
check "the touch is checked against the sudo key file" \
  has 'auth_key_file=/etc/ssh/sudo_authorized_keys' "$pam_sudo"
# success=2 is what reaches authsucc past pam_unix and the failure counter; a
# `sufficient` here would succeed the stack without ever clearing the tally.
check "the touch row jumps to authsucc instead of terminating" \
  grep -qE '^auth[[:space:]]+\[success=2 default=ignore\][[:space:]]+libpam_rssh\.so' "$pam_sudo"
# success=1 on the password reaches the same authsucc: either factor clears the
# tally, which is why both rows carry the count rather than a bare sufficient.
check "the password row jumps to authsucc too" \
  grep -qE '^auth[[:space:]]+\[success=1 default=ignore\][[:space:]]+pam_unix\.so' "$pam_sudo"
# The password fallback is the break-glass everywhere now, so there is no console
# row to match against.
check "no console break-glass row remains" lacks 'pam_succeed_if' "$pam_sudo"
# pam_rssh reads SSH_AUTH_SOCK with getenv(), and sudo drops it before the PAM
# stack runs: without the keep the module logs "SSH agent socket address not
# configured" and every escalation falls back to the password (verified on the
# host 2026-11-20). It is the only variable kept, and it is deliberate.
check "the agent socket is kept for pam_rssh" \
  has 'Defaults env_keep += "SSH_AUTH_SOCK"' image/rootfs/etc/sudoers.d/10-human-gate
check "no other variable is kept across the sudo boundary" \
  test "$(grep -c '^Defaults env_keep' image/rootfs/etc/sudoers.d/10-human-gate)" = 1
check "the PIN database is gone from the stack" lacks 'pam_userdb' "$pam_sudo"
check "the account phase is still declared" grep -qE '^account[[:space:]]+include[[:space:]]+system-auth$' "$pam_sudo"
check "the password phase is still declared" grep -qE '^password[[:space:]]+include[[:space:]]+system-auth$' "$pam_sudo"
check "the session phase is still declared" grep -qE '^session[[:space:]]+include[[:space:]]+system-auth$' "$pam_sudo"
# pam_unix authenticates the PAM username, so the account that runs sudo is the
# account whose password the fallback takes.
check "the only login account is smores" grep -qE '^[[:space:]]*- name: smores$' ignition/smortress.bu

sudoers_dropin=image/rootfs/etc/sudoers.d/10-human-gate
expected_sudoers='Defaults timestamp_timeout=30
Defaults timestamp_type=tty
Defaults log_subcmds
Defaults env_keep += "SSH_AUTH_SOCK"'
actual_sudoers=$(grep -E '^Defaults[[:space:]]' "$sudoers_dropin")
if [[ $actual_sudoers == "$expected_sudoers" ]]; then
  ok "the sudoers gate is the reviewed four defaults in order"
else
  bad "the sudoers gate is the reviewed four defaults in order" "$actual_sudoers"
fi
check "the sudoers drop-in is installed 0440" has 'chmod 0440 /etc/sudoers.d/10-human-gate' image/Containerfile
check "the sudoers drop-in is parsed at build time" has 'visudo -cf /etc/sudoers.d/10-human-gate' image/Containerfile
check "the sops env drop-in is installed 0440" has 'chmod 0440 /etc/sudoers.d/10-human-gate /etc/sudoers.d/20-sops-env' image/Containerfile
check "the sops env drop-in is parsed at build time" has 'visudo -cf /etc/sudoers.d/20-sops-env' image/Containerfile
check "the sops env drop-in drops every identity source" grep -q '^Defaults env_delete += ' image/rootfs/etc/sudoers.d/20-sops-env
# Access through the tunnel is the only route in, so a drop-in sshd refuses to
# parse would cost a console recovery; the build parses the shipped config
# instead of leaving the host to find out at boot.
check "the sshd configuration is parsed at build time" has 'sshd -t -o HostKey=' image/Containerfile

# pam_rssh is not packaged for Fedora, so the image builds it: the tag it clones
# and the commit it must land on are both pinned, the agent submodule is required
# (the crate vendors its protocol there) and the cdylib lands where PAM looks.
check "the image builds pam_rssh in a build stage" has 'AS sudo-build' image/Containerfile
check "the build pins a pam_rssh tag" has 'PAM_RSSH_VERSION' image/pins.env
if [[ ${PAM_RSSH_COMMIT:-} =~ ^[0-9a-f]{40}$ ]]; then ok "PAM_RSSH_COMMIT format"; else bad "PAM_RSSH_COMMIT format"; fi
check "the build refuses a retagged release" has 'rev-parse HEAD^{commit}' image/Containerfile
check "the build takes the agent submodule" has '--recurse-submodules' image/Containerfile
check "the build uses the committed lockfile" has 'cargo build --release --locked' image/Containerfile
check "the build installs the build dependencies" has 'openssl-devel pam-devel' image/Containerfile
check "the module lands where PAM loads it" has '/usr/lib64/security/libpam_rssh.so' image/Containerfile
check "the build fails if libpam_rssh is missing" has 'test -f /usr/lib64/security/libpam_rssh.so' image/Containerfile
# The retired TOTP module must not come back through a stale package layer.
check "no package installs pam_oath" lacks 'install pam_oath' image/Containerfile
check "the build fails if the OATH module is present" has 'test -f /usr/lib64/security/pam_oath.so' image/Containerfile
check "no pam_userdb assert remains" lacks 'pam_userdb' image/Containerfile
check "no gdbmtool assert remains" lacks 'gdbmtool' image/Containerfile
check "tmpfiles no longer creates a sudo usersfile directory" \
  lacks '/var/lib/homelab/sudo' image/rootfs/etc/tmpfiles.d/smortress.conf

# The sudo key file is the image's second authorised-keys list, and the two may
# never mix: the touch option is fixed at enrollment, so the login credential is
# no-touch-required and the sudo credential asks for the tap. A plain
# ssh-ed25519 line here would let sudo accept a key that never asks for a touch,
# and `no-touch-required` would do the same per key. An empty file is allowed and
# expected until the owner enrolls the keys (docs/manual-steps.md section 45):
# pam_rssh finds no matching key, returns PAM_AUTH_ERR, and the password is the
# way in until the public halves are committed.
sudo_keys=image/rootfs/etc/ssh/sudo_authorized_keys
check "the image ships the sudo key file" test -e "$sudo_keys"
if grep -qvE '^sk-ssh-ed25519@openssh\.com [A-Za-z0-9+/]+[=]{0,2}([[:space:]].*)?$' "$sudo_keys"; then
  bad "the sudo key file carries only touch-required sk lines"
else
  ok "the sudo key file carries only touch-required sk lines"
fi
if grep -q 'no-touch-required' "$sudo_keys"; then
  bad "no sudo credential is minted touch-free"
else
  ok "no sudo credential is minted touch-free"
fi
# The build refuses the missing file, and the mode is the build's business:
# /etc/ssh is world-readable, and the sudo list names credentials that unlock
# root.
check "the build refuses a missing sudo key file" has 'test -e /etc/ssh/sudo_authorized_keys' image/Containerfile
check "the sudo key file is installed 0600" has 'chmod 0600 /etc/ssh/sudo_authorized_keys' image/Containerfile

# The SELinux half. The targeted policy grants sudo_t no access to the forwarded
# agent socket, so the image ships a local module and a unit that loads it; the
# permission set is unproven until the host drill (`ausearch -m avc -c sudo`),
# which is why the module is a file to edit rather than a script to renumber.
# The permission is connectto, not connect: an AF_UNIX stream connect is checked
# as CONNECTTO on the peer socket's label, and `connect` only against the
# caller's own socket, which sudodomain already allows -- a module asking for
# connect grants nothing and is indistinguishable from a missing one at the tap.
# No local SELinux policy ships: sudo runs unconfined on this base (sudo_exec_t,
# process stays unconfined_t), so `sudo_t` does not resolve and an unconfined
# domain already holds the permission the agent socket needs. A module here would
# be dead code that fails to link; the drill in manual-steps section 45 is the
# tripwire if a future base confines sudo.
check "no local sudo policy module ships" \
  test ! -e image/rootfs/usr/share/smortress/selinux/smortress_sudo_rssh.cil
check "no policy loader unit ships" \
  test ! -e units/systemd/smortress-selinux-sudo-rssh.service
check "no policy loader script ships" \
  test ! -e scripts/selinux-sudo-rssh-load.sh
check "the image wires no policy loader" lacks 'smortress-selinux-sudo-rssh' image/Containerfile
check "sudo keeps the forwarded agent socket for pam_rssh" \
  has 'Defaults env_keep += "SSH_AUTH_SOCK"' image/rootfs/etc/sudoers.d/10-human-gate

# The retired TOTP stack may not leave a trace: the skill moved to a touch, and a
# leftover usersfile, enrollment script or package reference would be state
# nothing reads and the runbooks would still describe.
check "the enrollment script is gone" test ! -e scripts/enroll-yubikey-totp.sh
if git grep -qF -e 'pam_oath' -e 'users.oath' -e 'HOTP/T30' -- . \
    ':(exclude)scripts/check-server-image.sh' ':(exclude)image/Containerfile'; then
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
check "SSD mount is keyed by the wiped disk label" has 'What=/dev/disk/by-label/restic-ssd' units/systemd/var-lib-restic-ssd.mount
check "SSD mount cannot block boot" has 'nofail' units/systemd/var-lib-restic-ssd.mount
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

# The smores account password (design #767, T3). It was an operator file Ignition
# read at install time; bootc never reconciles /var, so the value ships as
# ciphertext instead and is consumed twice -- by the renderer for the install and
# by a boot unit for the reconcile. Both readers must name the same file, the
# manifest entry must stay `value` (chpasswd -e takes the bare hash), and the
# operator file must be gone from every reader: a leftover requirement would make
# a reinstall fail where the design says it must not.
check "the account hash is a manifest value" \
  grep -qE '^smores-password-hash\.yaml[[:space:]]+root[[:space:]]+root[[:space:]]+0400[[:space:]]+value$' \
  image/rootfs/etc/smortress/secrets.manifest
check "the renderer reads the hash from ciphertext" \
  has 'secrets/server/smores-password-hash.yaml' scripts/render-ignition.sh
if grep -rIl --exclude=check-server-image.sh 'ignition/operator/smores-password-hash' \
    scripts units image docs ignition >/dev/null 2>&1; then
  bad "the operator hash file is required nowhere"
else
  ok "the operator hash file is required nowhere"
fi
check "the password unit exists" test -s units/systemd/smortress-password.service
check "image enables smortress-password.service" has 'smortress-password.service' image/Containerfile
check "the password unit requires the decrypt unit" \
  grep -qE '^Requires=.*sops-decrypt\.service' units/systemd/smortress-password.service
check "the password unit is ordered after the decrypt unit" \
  grep -qE '^After=.*sops-decrypt\.service' units/systemd/smortress-password.service
check "the password unit is skipped without its ciphertext" \
  has 'ConditionPathExists=/run/smortress/secrets/smores-password-hash.yaml' \
  units/systemd/smortress-password.service
# The hash belongs in exactly one place outside /etc/shadow, and never in argv:
# chpasswd reads it on stdin. A value in the unit file would be readable by every
# local user, and an argument would be readable from /proc by any of them.
check "the password unit runs the installed guard" \
  has 'ExecStart=/usr/libexec/smortress-password' units/systemd/smortress-password.service
check "the image installs the password guard" has 'scripts/smortress-password.sh' image/Containerfile
if grep -vE '^[[:space:]]*#' units/systemd/smortress-password.service | grep -qE 'usermod|chpasswd'; then
  bad "the password unit carries no usermod of its own"
else
  ok "the password unit carries no usermod of its own"
fi
# shellcheck disable=SC2016  # the matched text is the guard's own line
check "the guard applies the hash through chpasswd" \
  has '| chpasswd -e' scripts/smortress-password.sh
check "the hash never reaches argv" lacks 'usermod -p' scripts/smortress-password.sh
check "the guard changes only smores" has 'account=smores' scripts/smortress-password.sh
check "the guard refuses a non-sha512crypt value" \
  has 'does not hold a sha512crypt hash' scripts/smortress-password.sh

check "firewall binds tailscale0" has '<interface name="tailscale0"/>' image/rootfs/etc/firewalld/zones/tailscale.xml
check "firewall permits ssh only on that zone" has '<service name="ssh"/>' image/rootfs/etc/firewalld/zones/tailscale.xml
# A wildcard *listener* binds every address; `0.0.0.0` inside a CIDR
# (10.0.0.0/8) is a destination and must not trip this.
#
# A Quadlet `Exec=` or `Environment=` address is inside the container's own
# network namespace and is reachable only through a published port (checked
# above) -- unless the unit joins the host network, where the same address is a
# host listener again and nothing may excuse it.
wildcard_hits=
while IFS= read -r line; do
  [[ -n $line ]] || continue
  if [[ $line == *PublishPort=127.0.0.1* ]]; then
    continue
  fi
  file=${line%%:*}
  if [[ $line =~ :[0-9]+:(Exec|Environment)= ]] && ! grep -q '^Network=host' "$file"; then
    continue
  fi
  wildcard_hits+=$line$'\n'
done < <(grep -rInE '\b0\.0\.0\.0\b|\[::\]' units image/rootfs 2>/dev/null)
if [[ -n $wildcard_hits ]]; then
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
for unit in smortress-app-secrets.service smortress-tailscale-serve.service; do
  check "image enables $unit" has "$unit" image/Containerfile
done
# Every timer this image ships must be enabled here, or it silently never fires.
for timer in units/systemd/*.timer; do
  unit=${timer#units/systemd/}
  pattern="^[[:space:]]*${unit//./\\.}([[:space:]]|;)"
  check "image enables $unit" grep -qE "$pattern" image/Containerfile
done

# Serve topology (review finding G1 of design #748). The wallpaper library is the
# fourth core route and the only one that is not a loopback port: an absolute
# directory target on 443 makes Serve publish it as static files, and a client
# that carries no credential fetches it as `<tailnet>/wallpapers/`. The route
# therefore has to be declared here rather than in a runbook, and the stale-route
# pruning has to stay scoped to the tenant paths.
serve_script=scripts/tailscale-serve.sh
check "Serve declares the wallpaper library as static files" \
  has "serve --bg --https=443 --set-path=/wallpapers \"\$wallpapers\"" "$serve_script"
check "the wallpaper library is the dataset mount point" has 'WALLPAPERS_DIR:-/srv/wallpapers' "$serve_script"
check "stale-route pruning only considers tenant handlers" \
  has 'select(startswith("/apps/"))' "$serve_script"
if grep -qE -- '--set-path=/wallpapers[^ ]* .*off' "$serve_script"; then
  bad "pruning never removes the wallpaper route"
else
  ok "pruning never removes the wallpaper route"
fi
check "the Serve unit is ordered after the wallpapers dataset is ready" \
  grep -qE '^After=.*zfs-ready@raw-wallpapers\.service' units/systemd/smortress-tailscale-serve.service

# shellcheck source=app-images.sh disable=SC1091
source scripts/app-images.sh
# A table entry is used either as a Quadlet's Image= or as an argument of a
# hand-written unit that runs podman itself (the collectors), and both must name
# the signed mirror at the pinned digest rather than a tag.
for name in $(app_image_names); do
  ref=$(app_image_ref "$name")
  # A hand-written unit names the image on its own continuation line, so the
  # match is anchored: a comment that mentions the reference is not a run.
  pattern="^[[:space:]]+$(printf '%s' "$ref" | sed 's/\\./\\\\./g')[[:space:]]+\\\\$"
  if grep -qF -- "Image=$ref" units/quadlet/*.container ||
     grep -qE "$pattern" units/systemd/*.service; then
    ok "$name runs the signed mirror at its pinned digest"
  else
    bad "$name runs the signed mirror at its pinned digest"
  fi
done
# Agent deployments (#711). The hosted proxy is the one program that holds a
# provider credential, so the checks that matter are that it is the program the
# image ships, that its upstream cannot be moved at runtime, and that the GPU
# device is declared with the SELinux type the driver needs.
check "image installs the agent proxy" \
  has 'apps/agent_proxy/proxy.py /usr/libexec/agent-proxy' image/Containerfile
check "the image makes the agent proxy executable" has 'chmod 0755 /usr/libexec/apps-schema /usr/libexec/agent-proxy' image/Containerfile
# `COPY image/rootfs/ /` is what puts these in the image, so a template that is
# missing from the tree is missing from the image.
check "image rootfs carries the agent config templates" \
  test -s image/rootfs/etc/smortress/agent/local-config.yaml -a -s image/rootfs/etc/smortress/agent/general-config.yaml
for template in local-config.yaml general-config.yaml; do
  # The image ships them through `COPY image/rootfs/ /`, so a template that is not
  # tracked here is not in the image either.
  check "the agent template $template exists" test -s "image/rootfs/etc/smortress/agent/$template"
  # Any `api_key:` with a value would put a credential in a template that both
  # gateways receive.
  if grep -qE '^[[:space:]]*api_key:[[:space:]]*[^[:space:]]' \
      "image/rootfs/etc/smortress/agent/$template"; then
    bad "the agent template $template carries no api key"
  else
    ok "the agent template $template carries no api key"
  fi
done
check "the proxy pins its upstream as a constant" has 'UPSTREAM_HOST = "api.neuralwatt.com"' apps/agent_proxy/proxy.py
# A runtime knob for the host would be the same hole as a request field.
if grep -qE 'environ\[.*(UPSTREAM|PROVIDER)' apps/agent_proxy/proxy.py ||
  grep -qE 'os\.environ\.get\("AGENT_PROXY_UPSTREAM' apps/agent_proxy/proxy.py; then
  bad "the proxy's upstream is not configurable at runtime"
else
  ok "the proxy's upstream is not configurable at runtime"
fi
check "the proxy reads its key from a file" has 'DEFAULT_KEY_FILE = "/run/secrets/agent-hosted-key"' apps/agent_proxy/proxy.py
check "the model container requires the CDI spec unit" \
  grep -qE '^Requires=.*smortress-nvidia-cdi\.service' units/quadlet/agent-model.container
check "the model container is ordered after the CDI spec unit" \
  grep -qE '^After=.*smortress-nvidia-cdi\.service' units/quadlet/agent-model.container
check "the CDI unit runs the documented command" \
  has 'nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml' units/systemd/smortress-nvidia-cdi.service
for unit in smortress-nvidia-cdi.service smortress-agent-config.service; do
  check "image enables $unit" has "$unit" image/Containerfile
done
# shellcheck disable=SC2016  # the matched text is a line of the seed script
probe "agent config seeding is idempotent" grep -qF 'cp -n "$template" "$config"' scripts/agent-config-seed.sh
# The seed work moved from an ExecStart one-liner into the script, because splicing
# a token into a YAML file from a unit line would put it in the process table.
check "the image installs the seed script" has 'scripts/agent-config-seed.sh' image/Containerfile
check "the seed unit runs the installed script" \
  has 'ExecStart=/usr/libexec/agent-config-seed' units/systemd/smortress-agent-config.service

# The source facades (T2b). They run in the agent-runtime image, which carries
# neither the program nor the libraries it imports, so the image installs both under
# /usr/lib/agent-facade and the Quadlets bind-mount that tree read-only. Every
# module is listed: a new file that is not in the COPY list is an import error in
# the container, and tests/ must not reach the host image.
check "image installs the facade libraries" \
  has 'libs/data_plane/ /usr/lib/agent-facade/libs/data_plane/' image/Containerfile
for module in apps/agent_facade/*.py; do
  check "image installs ${module#apps/agent_facade/}" has "$module" image/Containerfile
done
if grep -qF 'apps/agent_facade/tests' image/Containerfile; then
  bad "the image ships no facade test suite"
else
  ok "the image ships no facade test suite"
fi
for q in units/quadlet/agent-facade-personal.container units/quadlet/agent-facade-general.container; do
  check "$q mounts the installed tree" \
    has 'Volume=/usr/lib/agent-facade:/usr/lib/agent-facade:ro' "$q"
done
# The other half of the same delivery: a program the image installs on the HOST has
# to be mounted into the container that runs it. agent-proxy shipped its `Exec=`
# with no mount, so python3 exited on a path that was not in its namespace.
check "the proxy unit mounts its own program" \
  has 'Volume=/usr/libexec/agent-proxy:/usr/libexec/agent-proxy:ro' units/quadlet/agent-proxy.container
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
