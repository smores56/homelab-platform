#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2154  # the storage table's values and the source text quoted below are literal
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
no_file_exists() { [[ ! -e $1 ]]; }

# The base is the moving uCore stream tag, not a digest: upstream publishes new
# streams constantly and ghcr garbage-collects superseded digests within hours, so
# a pinned digest rots into "manifest unknown". What the build records instead is
# the digest the tag resolved to, in the image's base.digest label.
if [[ $UCORE_IMAGE =~ ^[a-z0-9][a-z0-9./_-]*:[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  ok "base image tracks a stream tag"
else
  bad "base image tracks a stream tag: $UCORE_IMAGE"
fi
if [[ $UCORE_IMAGE == *:latest || $UCORE_IMAGE == *@sha256:* ]]; then
  bad "base image is neither :latest nor digest-pinned: $UCORE_IMAGE"
else
  ok "base image is neither :latest nor digest-pinned"
fi
if [[ -n ${IMAGE_REPO:-} ]]; then ok "image repository is set"; else bad "image repository is set"; fi
# One repository string in three places: the pins, the `bootc switch` reference
# and the verifier's registry scope. A rename that misses one leaves a host that
# resolves a digest in a repository it then cannot switch to.
image_repo_agrees() { # <pins.env> <stage script> <verifier>
  local pins=$1 stage=$2 verify=$3 repo bare
  repo=$(sed -nE 's/^IMAGE_REPO=//p' "$pins" | head -n 1)
  repo=${repo%\"}; repo=${repo#\"}; repo=${repo%\'}; repo=${repo#\'}
  [[ -n $repo ]] || return 1
  # The verifier names the repository below its registry host: it builds the API
  # path from its own REGISTRY constant.
  bare=${repo#*/}
  grep -qF -- "$repo" "$stage" || return 1
  grep -qF -- "IMAGE_REPO = \"$bare\"" "$verify"
}
check "the image repository agrees across the pins, the stage and the verifier" \
  image_repo_agrees image/pins.env scripts/deploy-platform.sh image/rootfs/usr/libexec/deploy-verify.py
# bootc's first act in a mutation is to remount /sysroot writable; with
# ProtectSystem=strict that remount is the failure unless the unit re-opens
# /sysroot itself. `/sysroot/ostree` alone produced "Initializing storage:
# Read-only file system" on every deploy.
for unit in units/systemd/smortress-deploy.service units/systemd/smortress-boot-gate.service; do
  check "$unit lets bootc remount /sysroot" grep -qxF 'ReadWritePaths=/sysroot' "$unit"
done
# The same assertion on a drifted copy: a check that only ever sees the tree it
# was written for cannot fail for the reason it exists.
repo_fixture=$(mktemp -d)
sed -E 's|^IMAGE_REPO=.*$|IMAGE_REPO=ghcr.io/example/other/server|' image/pins.env \
  >"$repo_fixture/pins.env"
if image_repo_agrees "$repo_fixture/pins.env" scripts/deploy-platform.sh \
  image/rootfs/usr/libexec/deploy-verify.py; then
  bad "a drifted image repository is refused"
else
  ok "a drifted image repository is refused"
fi
rm -rf "$repo_fixture"
for pin in SOPS_SHA256 AGE_SHA256 RESTIC_SHA256 BUTANE_SHA256 COSIGN_SHA256; do
  if [[ ${!pin} =~ ^[0-9a-f]{64}$ ]]; then ok "$pin format"; else bad "$pin format"; fi
done

check "Containerfile takes a base argument" has "FROM \${BASE_IMAGE}" image/Containerfile
check "Containerfile rejects a floating base" \
  has '*:latest) echo "BASE_IMAGE must be a stream tag, not :latest' image/Containerfile
check "Containerfile rejects a digest-pinned base" \
  has 'BASE_IMAGE must be a stream tag, not a digest' image/Containerfile
check "Containerfile requires a tagged base" \
  has 'BASE_IMAGE must be a tagged reference' image/Containerfile
check "Containerfile takes the resolved base digest" has 'ARG BASE_DIGEST' image/Containerfile
check "the image records the base tag" \
  has 'org.opencontainers.image.base.name="${BASE_IMAGE}"' image/Containerfile
check "the image records the resolved base digest" \
  has 'org.opencontainers.image.base.digest="${BASE_DIGEST}"' image/Containerfile
check "the build resolves a base digest" has 'BASE_DIGEST' scripts/build-image.sh
check "the publish workflow resolves a base digest" \
  has 'BASE_DIGEST' .github/workflows/publish-server-image.yml
check "nothing rewrites a base pin" lacks 'sed -i' scripts/refresh-pins.sh
check "Containerfile installs the public key" has 'image/cosign.pub /etc/pki/containers/smortress.pub' image/Containerfile
check "Containerfile masks Podman auto-update" has 'podman-auto-update.timer' image/Containerfile
check "Containerfile masks bootc auto-update" has 'bootc-fetch-apply-updates.timer' image/Containerfile
check "Containerfile sets the default firewall zone to drop" has '--set-default-zone=drop' image/Containerfile

# No Cloudflare SSH route (design #767 T6). SSH is tailnet-only, so the connector
# unit, its release pin, its build step, its token and the tofu objects that
# fronted it must not come back: each assertion here fails on a re-introduction.
check "no tunnel connector unit ships" test ! -e units/systemd/smortress-cloudflared.service
check "the image enables no tunnel connector" lacks 'smortress-cloudflared' image/Containerfile
check "no release pin installs a tunnel connector" lacks 'CLOUDFLARED' image/pins.env
check "the build fetches no tunnel connector" lacks 'cloudflared' image/Containerfile
check "the build script passes no tunnel connector pin" lacks 'CLOUDFLARED' scripts/build-image.sh
check "no tunnel ciphertext ships" test ! -e secrets/server/cloudflared-tunnel.yaml
check "the decrypt manifest lists no tunnel ciphertext" \
  test -z "$(grep -E '^cloudflared-tunnel\.yaml[[:space:]]' image/rootfs/etc/smortress/secrets.manifest)"
check "no tofu object plans an ssh tunnel" lacks 'ssh_tunnel' tofu
check "no tofu object routes an ssh hostname" \
  test -z "$(grep -rE 'uri[[:space:]]*=[[:space:]]*"ssh\.\$\{var\.domain\}"' tofu)"
check "no ssh service token is authored" lacks '"cloudflare_zero_trust_access_service_token" "ssh"' tofu

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
  has "! grep -q 'sk-ssh-ed25519' /etc/ssh/authorized_keys.d/smores" image/Containerfile
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
# git grep exits 1 for "no match" and >1 for "could not search", and only the
# first means clean: reading both as ok would pass a tree the grep never read.
sk_status=0
git grep -qF -- 'sk-ssh-ed25519@openssh.com' -- . \
  ':(exclude)scripts/check-server-image.sh' \
  ':(exclude)image/rootfs/etc/ssh/sudo_authorized_keys' || sk_status=$?
case $sk_status in
  1) ok "no sk- handle is committed anywhere but the sudo key file" ;;
  0) bad "a sk- handle is committed outside the sudo key file" ;;
  *) bad "git grep failed while looking for a committed sk- handle (exit $sk_status)" ;;
esac
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
# The marker is a ConditionPathExists=! gate on the enrollment unit, so it has to
# be the last thing the unit writes: access-lockdown is what moves the wired NICs
# out of the `bootstrap` zone, and a marker written before a failed lockdown
# would record the host as enrolled with sshd still answering the LAN.
marker_line=$(grep -nF -m1 'ExecStart=/usr/bin/touch /var/lib/homelab/tailscale-enrolled' "$tailscale_up" |
  cut -d: -f1 || true)
lockdown_line=$(grep -nF -m1 'ExecStart=/usr/libexec/access-lockdown' "$tailscale_up" |
  cut -d: -f1 || true)
if [[ -n $marker_line && -n $lockdown_line ]] && ((marker_line > lockdown_line)); then
  ok "the enrollment marker is written after the LAN is closed"
else
  bad "the enrollment marker is written after the LAN is closed"
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
# The base ships %sudo ALL=(ALL) NOPASSWD: ALL. NOPASSWD skips
# pam_authenticate, so the touch, the password and the tally all stop applying;
# the build deletes the file and the guard above refuses a regression.
check "the build deletes the base's NOPASSWD grant" \
  has 'rm -f /etc/sudoers.d/coreos-sudo-group' image/Containerfile
check "the NOPASSWD guard still inspects the finished tree" \
  has "grep -rhvE '^[[:space:]]*#' /etc/sudoers /etc/sudoers.d" image/Containerfile
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
  bad "the sudoers gate is the reviewed four defaults in order"
  printf '     got: %s\n' "$(printf '%s' "$actual_sudoers" | tr '\n' ';')" >&2
fi
check "the sudoers drop-in is installed 0440" has 'chmod 0440 /etc/sudoers.d/10-human-gate' image/Containerfile
check "the sudoers drop-in is parsed at build time" has 'visudo -cf /etc/sudoers.d/10-human-gate' image/Containerfile
check "the sops env drop-in is installed 0440" has 'chmod 0440 /etc/sudoers.d/10-human-gate /etc/sudoers.d/20-sops-env' image/Containerfile
check "the sops env drop-in is parsed at build time" has 'visudo -cf /etc/sudoers.d/20-sops-env' image/Containerfile
check "the sops env drop-in drops every identity source" grep -q '^Defaults env_delete += ' image/rootfs/etc/sudoers.d/20-sops-env
# Nothing proves the base ships no NOPASSWD grant unless the build asserts it, so
# the Containerfile carries the grep and this check refuses a build that lost it.
# A NOPASSWD line would bypass pam_authenticate: no touch, no password, no tally.
check "the build fails on a NOPASSWD grant" \
  has "! grep -rhvE '^[[:space:]]*#' /etc/sudoers /etc/sudoers.d | grep -q 'NOPASSWD'" image/Containerfile
# The tailnet is the only route in, so a drop-in sshd refuses to
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
# Both are `required` rows of the sudo stack, so their absence fails closed and
# leaves every non-root account unable to escalate at all.
check "the build fails if the failure counter is missing" has 'test -f /usr/lib64/security/pam_faillock.so' image/Containerfile
check "the build fails if the password fallback is missing" has 'test -f /usr/lib64/security/pam_unix.so' image/Containerfile
# The retired TOTP module must not come back through a stale package layer.
check "no package installs pam_oath" lacks 'install pam_oath' image/Containerfile
check "the build fails if the OATH module is present" has '! test -f /usr/lib64/security/pam_oath.so' image/Containerfile
check "no pam_userdb assert remains" lacks 'pam_userdb' image/Containerfile
check "no gdbmtool assert remains" lacks 'gdbmtool' image/Containerfile
check "tmpfiles no longer creates a sudo usersfile directory" \
  lacks '/var/lib/homelab/sudo' image/rootfs/etc/tmpfiles.d/smortress.conf

# The sudo key file is the image's second authorised-keys list, and the two may
# never mix: the touch option is fixed at enrollment, so the login credential is
# no-touch-required and the sudo credential asks for the tap. A plain
# ssh-ed25519 line here would let sudo accept a key that never asks for a touch,
# so two shapes are checked below: every line is an sk line, and no line carries
# the `no-touch-required` option text. Neither check proves the credential is
# touch-required, and nothing read from the file could: the public half does not
# record a touch policy, and pam_rssh at the pinned commit (image/pins.env,
# e8dd046) rebuilds the signed message with sig.flags but never reads the
# user-presence bit, so a credential minted with `-O no-touch-required` looks
# identical here. The only proof of the property is the cover-the-sensor drill
# in docs/manual-steps.md section 44, which fails exactly when the credential
# signs without a tap. An empty file is allowed and expected until the owner
# enrolls the keys: pam_rssh finds no matching key, returns PAM_AUTH_ERR, and the
# password is the way in until the public halves are committed.
sudo_keys=image/rootfs/etc/ssh/sudo_authorized_keys
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
check "the build refuses a missing sudo key file" has 'test -e /etc/ssh/sudo_authorized_keys' image/Containerfile
check "the sudo key file is installed 0600" has 'chmod 0600 /etc/ssh/sudo_authorized_keys' image/Containerfile

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
  test ! -e image/rootfs/usr/share/smortress/selinux/smortress_sudo_rssh.cil
check "no policy loader unit ships" \
  test ! -e units/systemd/smortress-selinux-sudo-rssh.service
check "no policy loader script ships" \
  test ! -e scripts/selinux-sudo-rssh-load.sh
check "the image wires no policy loader" lacks 'smortress-selinux-sudo-rssh' image/Containerfile

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
check "zpool unit requires the data formatting oneshot" has 'Requires=smortress-data-init.service' units/systemd/smortress-zpool.service
check "the data formatting oneshot runs before the pool" has 'Before=smortress-zpool.service' units/systemd/smortress-data-init.service
check "the data formatting oneshot is installed" has 'ExecStart=/usr/libexec/init-data-luks' units/systemd/smortress-data-init.service
check "the image enables the data formatting oneshot" has 'smortress-data-init.service' image/Containerfile
check "the image installs the data formatting helper" has 'scripts/init-data-luks.sh' image/Containerfile
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
  check "image enables $m" has "$m" image/Containerfile
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

# The ciphertext moved from the image to /var: a rotation is an operator write and
# a restart of the decrypt unit, not an OS image and a reboot. The baked set is
# only the seed for a host that has none yet.
check "the boot decrypt reads the host ciphertext" \
  has 'SMORTRESS_SECRETS_SRC:-/var/lib/smortress/secrets' scripts/sops-decrypt.sh
check "the boot decrypt seeds the host copy first" \
  has 'ExecStartPre=/usr/libexec/smortress-secrets-seed' units/systemd/sops-decrypt.service

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
for unit in smortress-app-secrets.service smortress-tailscale-serve.service \
  smortress-boot-gate.service; do
  check "image enables $unit" has "$unit" image/Containerfile
done

# Deploy receiver (#798). A platform deploy ends in a reboot, so the pieces that
# decide whether the new deployment stays are asserted here: the units the image
# starts, the gate unit and its ordering, the counter that is the only rollback
# before userspace, and the list of units the gate requires. A missing unit in
# that list is a gate that checks nothing; a listed unit that is not active on a
# healthy host is a gate that rolls every deployment back.
gate_unit=units/systemd/smortress-boot-gate.service
check "the boot gate unit exists" test -s "$gate_unit"
check "the boot gate runs before boot-complete" \
  grep -qE '^Before=boot-complete\.target' "$gate_unit"
check "the boot gate runs late in boot" grep -qE '^After=.*multi-user\.target' "$gate_unit"
check "the boot gate waits for the decrypt step" \
  grep -qE '^After=.*sops-decrypt\.service' "$gate_unit"
# A template glob is not a valid ordering dependency in systemd, so the apps
# instance is named and multi-user.target carries the rest.
check "the boot gate waits for the apps dataset" \
  grep -qE '^After=.*zfs-ready@raw-apps\.service' "$gate_unit"
check "the boot gate waits for the network" \
  grep -qE '^After=.*network-online\.target' "$gate_unit"
check "the boot gate waits for the Serve routes" \
  grep -qE '^After=.*smortress-tailscale-serve\.service' "$gate_unit"
check "the boot gate wants its inputs without requiring them" \
  grep -qE '^Wants=.*sops-decrypt\.service' "$gate_unit"
check "the boot gate is installed where the loop puts it" \
  has 'ExecStart=/usr/libexec/smortress-boot-gate' "$gate_unit"
check "the image installs the boot gate" has 'scripts/smortress-boot-gate.sh' image/Containerfile
check "the boot gate is sandboxed" grep -qE '^ProtectSystem=strict' "$gate_unit"
# The gate mutates the grubenv and the ostree deployment it rolls back to, and
# nothing else: a wider writable tree would let a compromised gate rewrite a unit.
check "the boot gate widens /boot and the sysroot tree only" \
  grep -qE '^ReadWritePaths=(-)?/sysroot' "$gate_unit"
check "the drain waits for the boot gate" \
  grep -qE '^After=.*smortress-boot-gate\.service' units/systemd/smortress-deploy.service
check "the drain can write the boot it stages" \
  grep -qE '^ReadWritePaths=(-)?/boot$' units/systemd/smortress-deploy.service
# RestrictSUIDSGID made tar's mode-restoring chmod on directories fail with
# ENOSYS ("Cannot mkdir/open: Function not implemented"), which broke every
# tenant extraction (#824). Both units run as root and execute arbitrary tooling,
# so the filter bought little beyond a false sense of containment.
for unit in units/systemd/smortress-deploy.service units/systemd/smortress-boot-gate.service; do
  check "$unit does not set RestrictSUIDSGID" lacks 'RestrictSUIDSGID=yes' "$unit"
done
suidgid_fixture=$(mktemp)
printf 'RestrictSUIDSGID=yes\n' >"$suidgid_fixture"
if lacks 'RestrictSUIDSGID=yes' "$suidgid_fixture"; then
  bad "a unit that sets RestrictSUIDSGID is refused"
else
  ok "a unit that sets RestrictSUIDSGID is refused"
fi
rm -f "$suidgid_fixture"

# Every program a unit or a script names under /usr/libexec has to be installed by
# the image, and the set is derived rather than listed: the `smortress-src` loop
# installs only what its COPY line names and strips the `.sh`, so `deploy-apps`
# was written in T5 and never listed and the drain's apps child was a path the
# image did not have. A program is installed by one of the three deliveries: the
# rootfs copy, an explicit `/usr/libexec/<name>` destination, or the `.sh` loop --
# except the operator CLI, which is staged under the name the runbook uses.
# A comment that names a retired helper is not a dependency on it; a directive or
# a command that names one is. The derivation is a function so the fixture check
# below can hold both halves: the comment passes, the reference still fails.
libexec_programs() { # <paths...>
  grep -rnE --exclude=check-server-image.sh \
    '/usr/libexec/[A-Za-z0-9._-]*[A-Za-z0-9_-]' "$@" |
    awk '{ line = $0; sub(/^([^:]*:)?[0-9]+:/, "", line); if (line !~ /^[[:space:]]*#/) print line }' |
    grep -oE '/usr/libexec/[A-Za-z0-9._-]*[A-Za-z0-9_-]' | sed 's|.*/||' | sort -u
}
program_fixture=$(mktemp -d)
printf '# /usr/libexec/ghost-helper was retired with the old plane\n' \
  >"$program_fixture/comment.txt"
if [[ -n $(libexec_programs "$program_fixture/comment.txt") ]]; then
  bad "a comment naming /usr/libexec/<name> is not a dependency" \
    "$(libexec_programs "$program_fixture/comment.txt")"
else
  ok "a comment naming /usr/libexec/<name> is not a dependency"
fi
printf 'ExecStart=/usr/libexec/ghost-helper\n' >"$program_fixture/code.txt"
if [[ $(libexec_programs "$program_fixture/code.txt") == ghost-helper ]]; then
  ok "a real /usr/libexec/<name> reference is still a dependency"
else
  bad "a real /usr/libexec/<name> reference is still a dependency" \
    "$(libexec_programs "$program_fixture/code.txt")"
fi
rm -rf "$program_fixture"
# shellcheck disable=SC2013  # the derived names are paths and contain no blanks
for program in $(libexec_programs units image/rootfs scripts/*.sh); do
  if [[ -f image/rootfs/usr/libexec/$program ]]; then
    check "the image ships /usr/libexec/$program" test -x "image/rootfs/usr/libexec/$program"
  elif [[ $program == smortress-deploy ]]; then
    check "the image installs /usr/libexec/$program" \
      has 'scripts/deploy-cli.sh /usr/libexec/smortress-src/smortress-deploy.sh' image/Containerfile
  elif grep -qF "/usr/libexec/$program" image/Containerfile; then
    ok "the image installs /usr/libexec/$program"
  elif grep -qF "/usr/libexec/$program" images/agent-runtime/Containerfile; then
    # The agent programs ship in their own image (publish-agent-runtime).
    ok "the runtime image installs /usr/libexec/$program"
  else
    check "the image installs /usr/libexec/$program" has "scripts/$program.sh" image/Containerfile
  fi
done
# `COPY` preserves the mode, so a rootfs program committed non-executable is a
# unit that fails with 203/EXEC at the first boot rather than at review time. The
# same holds for every shell helper: the install loop strips the `.sh` and the
# unit runs the result, which is how smortress-boot-gate.sh shipped 100644 and
# would have failed the boot gate with 203/EXEC on the first boot after a deploy.
for program in image/rootfs/usr/libexec/deploy-receiver.py \
  image/rootfs/usr/libexec/deploy-verify.py scripts/*.sh; do
  check "$program is committed executable" \
    test "$(git ls-files -s "$program" | cut -d' ' -f1)" = 100755
done
check "the loop installs every staged helper 0755" \
  has 'install -m 0755 "$f" "/usr/libexec/$(basename "${f%.sh}")"' image/Containerfile
# The deploy's own programs: the two python helpers ship in the rootfs (the loop
# would drop them), and the shell helpers go through it.
for program in deploy-state deploy-drain deploy-platform deploy-apps deploy-poll deploy-heartbeat; do
  check "the image installs scripts/$program.sh" has "scripts/$program.sh" image/Containerfile
done
for program in deploy-poll deploy-heartbeat; do
  check "a unit runs the installed $program" has "/usr/libexec/$program" units/systemd
done
# deploy-apps has no unit of its own: the drain runs it for a queued apps request.
# It reaches it through the library's one resolver now, so the assertion follows
# the call, not a literal path that only the old inline probe carried.
check "the drain resolves the installed deploy-apps" has 'deploy_resolve' scripts/deploy-drain.sh
check "the resolver searches /usr/libexec" has '/usr/libexec' scripts/deploy-state.sh

# The units the image starts at boot. The drain is the exception and is asserted
# as such: it is a queue-triggered oneshot with no [Install] section, so enabling
# it would fail the build and starting it at boot would drain an empty queue.
receiver_unit=units/systemd/smortress-deploy-listener.service
check "the receiver unit exists" test -s "$receiver_unit"
check "the receiver runs the installed program" \
  has 'ExecStart=/usr/bin/python3 /usr/libexec/deploy-receiver.py' "$receiver_unit"
check "the receiver refuses to start without the decrypt step" \
  grep -qE '^Requires=sops-decrypt\.service' "$receiver_unit"
for unit in smortress-deploy-listener.service smortress-deploy.path \
  smortress-boot-gate.service smortress-deploy-poll.timer \
  smortress-deploy-heartbeat.timer smortress-deploy-retry.timer; do
  check "image enables $unit" has "$unit" image/Containerfile
done
check "the queue path triggers the drain" \
  grep -qxF 'Unit=smortress-deploy.service' units/systemd/smortress-deploy.path
check "the queue path watches the receiver's queue" \
  grep -qxF 'DirectoryNotEmpty=/var/lib/homelab/deploy/queue' units/systemd/smortress-deploy.path
check "the drain is triggered by the queue, not enabled at boot" \
  lacks 'WantedBy=' units/systemd/smortress-deploy.service
# A oneshot that its own trigger starts must not also be enabled: an enabled
# drain runs its snapshot gate on an empty queue, and an enabled poll service
# fires once at boot with no timer behind it.
for unit in smortress-deploy.service smortress-deploy-poll.service \
  smortress-deploy-heartbeat.service; do
  check "the image leaves $unit to its trigger" lacks "$unit" image/Containerfile
done
check "the poll timer starts the poll service" \
  grep -qxF 'Unit=smortress-deploy-poll.service' units/systemd/smortress-deploy-poll.timer
check "the heartbeat timer starts the heartbeat service" \
  grep -qxF 'Unit=smortress-deploy-heartbeat.service' units/systemd/smortress-deploy-heartbeat.timer
# The tenant prober is a timer and a timer-triggered oneshot: enabling the timer
# is the whole delivery, because a timer the image does not enable never fires.
# Enabling the service instead would run it once at boot and never again, which is
# the coupling this split removes.
check "the image enables the tenant prober's timer" \
  grep -qE '^[[:space:]]*smortress-apps-health\.timer([[:space:]]|;)' image/Containerfile
check "the image leaves the tenant prober to its timer" \
  lacks 'smortress-apps-health.service' image/Containerfile
check "the prober timer starts the prober" \
  grep -qxF 'Unit=smortress-apps-health.service' units/systemd/smortress-apps-health.timer
# A deferred entry is retried by this timer, not by the path unit re-firing the
# drain: without it a rate-limited deploy would wait for the next event.
check "the retry timer starts the drain service" \
  grep -qxF 'Unit=smortress-deploy.service' units/systemd/smortress-deploy-retry.timer
check "the retry timer fires every five minutes" \
  grep -qxF 'OnCalendar=*-*-* *:0/5:00' units/systemd/smortress-deploy-retry.timer
check "the tmpfiles entry creates the queue" \
  has 'd /var/lib/homelab/deploy/queue 0700 root root -' image/rootfs/etc/tmpfiles.d/smortress.conf

# The three secrets the deploy path reads are `value` scalars: the listener
# compares the raw key, the heartbeat hands the bare URL to curl and sops-decrypt
# writes the scalar alone, so a `yaml` entry would compare a document.
for name in webhook-secret webhook-secret-next deploy-ping-url; do
  check "$name is a manifest value" \
    grep -qE "^${name//./\\.}\.yaml[[:space:]]+root[[:space:]]+root[[:space:]]+0400[[:space:]]+value$" \
    image/rootfs/etc/smortress/secrets.manifest
done

# The gate's list is only meaningful if every line is active on a healthy host:
# a unit the image does not enable is inactive at every boot, and so is one that
# skips itself through a negated condition (the enrollment unit, after its
# marker). Both are a gate that rolls back every deployment.
units_file=image/rootfs/usr/share/smortress/deploy-units.txt
check "the gate's unit list ships in the image" test -s "$units_file"
check "the unit list is shipped by the rootfs copy" has 'COPY image/rootfs/ /' image/Containerfile
check "the gate requires the decrypt step" grep -qxF 'sops-decrypt.service' "$units_file"
check "the gate requires the pool" grep -qxF 'smortress-zpool.service' "$units_file"
if grep -vE '^[[:space:]]*#' "$units_file" | grep -qiE 'deploy'; then
  bad "the gate requires no deploy unit (its secret is seeded after the first deploy)"
else
  ok "the gate requires no deploy unit (its secret is seeded after the first deploy)"
fi
# A unit that reads the tenant's plan must not be judged here: both of them exit 1
# on an app definition, and `is-failed` on one would denylist the platform digest
# and roll a healthy host back for an app's fault.
for unit in smortress-tailscale-serve.service smortress-apps-quota.service; do
  check "the gate judges no unit that reads the tenant's plan: $unit" lacks "$unit" "$units_file"
done
while IFS= read -r unit; do
  [[ -n $unit ]] || continue
  pattern="(^|[[:space:]])${unit//./\\.}([[:space:]]|;)"
  check "the gate lists only units the image enables: $unit" grep -qE "$pattern" image/Containerfile
  if [[ -f units/systemd/$unit ]] &&
    grep -qE '^ConditionPathExists=!' "units/systemd/$unit"; then
    bad "the gate lists no unit that skips itself: $unit"
  else
    ok "the gate lists no unit that skips itself: $unit"
  fi
done < <(awk '!/^[[:space:]]*#/ { print $1 }' "$units_file")
count_cfg=image/rootfs/usr/lib/bootupd/grub2-static/configs.d/10-smortress-count.cfg
check "the boot counter snippet ships where bootupd reads it" test -s "$count_cfg"
check "the snippet clears boot_success on every boot" has 'set boot_success=0' "$count_cfg"
check "the snippet counts three attempts" has 'set boot_counter=3' "$count_cfg"
check "the snippet selects the previous deployment at zero" has 'set default=1' "$count_cfg"
check "a hung PID 1 reboots" \
  has 'RuntimeWatchdogSec=1min' image/rootfs/etc/systemd/system.conf.d/10-watchdog.conf
# A panic must not reboot until a bootloader counter can fall back: otherwise a
# kernel panic loops the same image forever with no userspace to roll back.
check "no panic reboot without a counter" no_file_exists image/rootfs/etc/sysctl.d/10-panic.conf

# The feature installs no distribution package: graph and signature questions are
# answered by the GitHub API and bootc's own policy, so the only dnf run in the
# build is the discarded sudo-build stage.
# The last `FROM ${BASE_IMAGE}` is the image, and it may be named (`AS runtime`);
# the earlier one is a discarded build stage, so taking the first match -- or
# refusing to match a named stage -- looks for a package install in the wrong half
# of the file, or fails a correct edit.
runtime_stage_is_clean() { # <containerfile>
  local line
  line=$(grep -nE '^FROM \$\{BASE_IMAGE\}([[:space:]]+AS[[:space:]]+[A-Za-z0-9_.-]+)?[[:space:]]*$' "$1" |
    tail -n 1 | cut -d: -f1)
  [[ -n $line ]] || return 1
  ! awk -v start="$line" 'NR > start && /dnf/' "$1" | grep -q .
}
check "the runtime stage installs no distribution package" \
  runtime_stage_is_clean image/Containerfile
stage_fixture=$(mktemp -d)
printf 'FROM ${BASE_IMAGE} AS sudo-build\nRUN dnf install -y git\nFROM ${BASE_IMAGE} AS runtime\nCOPY image/rootfs/ /\n' \
  >"$stage_fixture/Containerfile"
if runtime_stage_is_clean "$stage_fixture/Containerfile"; then
  ok "a named final stage is still the runtime stage"
else
  bad "a named final stage is still the runtime stage"
fi
printf 'RUN dnf install -y git\n' >>"$stage_fixture/Containerfile"
if runtime_stage_is_clean "$stage_fixture/Containerfile"; then
  bad "a package install in the runtime stage is still refused"
else
  ok "a package install in the runtime stage is still refused"
fi
rm -rf "$stage_fixture"

# A deploy change that does not rebuild the image ships a commit whose host code
# is the previous build's, because the image is the only delivery. Every file the
# receiver ships must therefore sit under a publish path filter. The entry may be
# quoted, single-quoted or bare -- the YAML quoting is not the assertion, the
# coverage is -- so the match is on the glob, not on one spelling of it.
publish_covers() { # <workflow> <top-level dir>
  grep -qE "^[[:space:]]*-[[:space:]]*[\"']?$2/\\*\\*[\"']?[[:space:]]*$" "$1"
}
path_fixture=$(mktemp -d)
for entry in '"scripts/**"' "'scripts/**'" 'scripts/**'; do
  printf '    paths:\n      - %s\n' "$entry" >"$path_fixture/workflow.yml"
  if publish_covers "$path_fixture/workflow.yml" scripts; then
    ok "the path filter accepts the entry $entry"
  else
    bad "the path filter accepts the entry $entry"
  fi
done
printf '    paths:\n      - "scripts/deploy-*.sh"\n' >"$path_fixture/workflow.yml"
if publish_covers "$path_fixture/workflow.yml" scripts; then
  bad "a partial path entry does not cover the directory"
else
  ok "a partial path entry does not cover the directory"
fi
rm -rf "$path_fixture"
publish=.github/workflows/publish-server-image.yml
deploy_files=()
while IFS= read -r file; do deploy_files+=("$file"); done < <(
  printf '%s\n' scripts/deploy-*.sh scripts/smortress-boot-gate.sh image/rootfs/usr/libexec/deploy-*.py \
    image/rootfs/usr/share/smortress/deploy-units.txt \
    image/rootfs/usr/lib/bootupd/grub2-static/configs.d/10-smortress-count.cfg \
    units/systemd/smortress-deploy* units/systemd/smortress-boot-gate.service \
    secrets/server/webhook-secret.yaml secrets/server/webhook-secret-next.yaml \
    secrets/server/deploy-ping-url.yaml
)
unpublished=
for file in "${deploy_files[@]}"; do
  if [[ ! -e $file ]]; then
    unpublished+="$file(missing) "
    continue
  fi
  publish_covers "$publish" "${file%%/*}" || unpublished+="$file "
done
if [[ -n $unpublished ]]; then
  bad "every file the receiver ships rebuilds the image: $unpublished"
else
  ok "every file the receiver ships rebuilds the image"
fi

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
# The receiver's forward is declared with the core routes: a CI notification has to
# arrive on a host whose tenant plan is unreadable, and a `--tcp` forward is not a
# Web handler, so the `/apps/` prune below cannot remove it.
check "Serve forwards the deploy receiver's loopback port" \
  has 'serve --bg --tcp=8484 tcp://127.0.0.1:8484' "$serve_script"
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
# provider credential, so the checks that matter are that it is the program its
# own image ships, that its upstream cannot be moved at runtime, and that the GPU
# device is declared with the SELinux type the driver needs.
check "the runtime image installs the agent proxy" \
  has 'apps/agent_proxy/proxy.py /usr/libexec/agent-proxy' images/agent-runtime/Containerfile
check "the runtime image makes the agent proxy executable" \
  has 'chmod 0755 /usr/libexec/agent-proxy' images/agent-runtime/Containerfile
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
for unit in smortress-nvidia-cdi.service smortress-agent-config.service \
  smortress-selinux-nvidia-map.service; do
  check "image enables $unit" has "$unit" image/Containerfile
done
# shellcheck disable=SC2016  # the matched text is a line of the seed script
probe "agent config seeding is idempotent" grep -qF 'cp -n "$template" "$config"' scripts/agent-config-seed.sh
# The hledger projection's account mapping is seeded from the image the same way,
# so the template is what an operator's copy starts from and must ship with it.
check "image rootfs carries the hledger account mapping" \
  test -s image/rootfs/etc/smortress/agent/hledger-accounts.json
# shellcheck disable=SC2016  # the matched text is a line of the seed script
probe "the hledger mapping is seeded once and never overwritten" \
  grep -qF 'cp -n "$template_dir/hledger-accounts.json"' scripts/agent-config-seed.sh
# The seed work moved from an ExecStart one-liner into the script, because splicing
# a token into a YAML file from a unit line would put it in the process table.
check "the image installs the seed script" has 'scripts/agent-config-seed.sh' image/Containerfile
check "the seed unit runs the installed script" \
  has 'ExecStart=/usr/libexec/agent-config-seed' units/systemd/smortress-agent-config.service

# The source facades (T2b), the collectors and the hosted proxy live in the
# agent-runtime image (images/agent-runtime/Containerfile, publish-agent-runtime.yml),
# not here: this image must carry no copy of them, which is what keeps an agent-code
# change off the OS rebuild path. The units import them from the image and mount
# nothing from the host, so there is no second copy to drift.
for path in 'apps/agent_facade' 'apps/brave_ingest' 'apps/agent_proxy' \
  'libs/data_plane' '/usr/lib/agent-facade' '/usr/libexec/agent-proxy'; do
  check "the host image ships no $path" lacks "$path" image/Containerfile
done
for q in units/quadlet/agent-facade-personal.container units/quadlet/agent-facade-general.container; do
  check "$q mounts no host copy of the facade" lacks 'Volume=/usr/lib/agent-facade' "$q"
done
check "the proxy unit mounts no host copy of its program" \
  lacks 'Volume=/usr/libexec/agent-proxy' units/quadlet/agent-proxy.container
for unit in units/systemd/smortress-agent-brave-seed.service \
  units/systemd/smortress-agent-collect-brave.service; do
  check "$unit mounts no host copy of the tree" lacks '--volume /usr/lib/agent-facade' "$unit"
done
# The programs' own list has to be complete in the image that does carry them: a
# module left out is an import error at the first start.
for module in apps/agent_facade/*.py apps/brave_ingest/*.py; do
  check "the runtime image installs ${module#apps/}" \
    has "$module" images/agent-runtime/Containerfile
done
check "the runtime image installs the facade libraries" \
  has 'libs/data_plane/ /usr/lib/agent-facade/libs/data_plane/' images/agent-runtime/Containerfile
check "the runtime image installs the proxy" \
  has 'apps/agent_proxy/proxy.py /usr/libexec/agent-proxy' images/agent-runtime/Containerfile
if grep -qE '^COPY.*apps/(agent_facade|agent_proxy)/tests' \
  images/agent-runtime/Containerfile; then
  bad "the runtime image ships no test suite"
else
  ok "the runtime image ships no test suite"
fi
check "the browser unit ships with the egress gate it depends on" \
  has 'units/quadlet/agent-brave.container' image/Containerfile
check "Syncthing's sync port is permitted on the tailscale zone" \
  has '<port port="22000" protocol="tcp"/>' image/rootfs/etc/firewalld/zones/tailscale.xml
check "Syncthing's QUIC port is permitted on the tailscale zone" \
  has '<port port="22000" protocol="udp"/>' image/rootfs/etc/firewalld/zones/tailscale.xml
# The deploy receiver is the one service whose caller is a CI job, so its port has
# to be open on the tailnet zone or the notify path silently times out.
check "the deploy receiver's port is permitted on the tailscale zone" \
  has '<port port="8484" protocol="tcp"/>' image/rootfs/etc/firewalld/zones/tailscale.xml
# The public edge (design #725) reaches Immich and OPDShelf through Serve's two
# dedicated ports. An ACL accept that the zone drops is a route that never
# works, and the failure looks like an edge bug rather than a firewall one.
check "the edge's Immich route is permitted on the tailscale zone" \
  has '<port port="8446" protocol="tcp"/>' image/rootfs/etc/firewalld/zones/tailscale.xml
check "the edge's OPDShelf route is permitted on the tailscale zone" \
  has '<port port="8447" protocol="tcp"/>' image/rootfs/etc/firewalld/zones/tailscale.xml

# The apps tenant (#726) is named everywhere and numbered nowhere. sysusers
# allocates its id, so anything that named 1001 — the dataset owner, the user
# manager drop-ins — went stale the moment the id moved, silently.
check "the tenant id is allocated, not demanded" \
  grep -qx 'u apps - "apps tenant" /var/home/apps /usr/sbin/nologin' \
  image/rootfs/etc/sysusers.d/smortress-apps.conf
check "the tenant dataset owner is the account name" test "$(dataset_owner_for raw/apps)" = apps:apps
check "the image ships no per-uid manager drop-in" lacks 'user@1001.service.d' image/Containerfile
check "the image ships no per-uid slice drop-in" lacks 'user-1001.slice.d' image/Containerfile
for gate in smortress-apps-deny smortress-apps-user smortress-apps-egress smortress-apps-quota; do
  check "$gate finishes before a user manager can start" \
    grep -q '^Before=.*systemd-logind.service' "units/systemd/$gate.service"
done

# Every directory the Containerfile copies is baked into the image, so a change
# under it has to rebuild that image. `libs/` was absent from the publish
# workflow's path filter and a collector fix merged without ever being built.
copied=$(awk '/^COPY / { for (i = 2; i <= NF; i++) print $i }' image/Containerfile |
  grep -v '^--' | grep / | cut -d/ -f1 | sort -u)
for directory in $copied; do
  check "the publish workflow rebuilds on ${directory}/ changes" \
    publish_covers .github/workflows/publish-server-image.yml "$directory"
done
# And the reverse, because this is how the reboot loop started: `apps/**` and
# `libs/**` were on that path filter, so every app commit rebuilt and redeployed
# the OS image. Nothing in this Containerfile copies from them any more (the agent
# programs build into agent-runtime, every other app has its own publish workflow),
# so listing them again would republish the host for code it does not carry.
for directory in apps libs; do
  if grep -qF "\"$directory/**\"" .github/workflows/publish-server-image.yml; then
    bad "the publish workflow does not rebuild on ${directory}/ changes"
  else
    ok "the publish workflow does not rebuild on ${directory}/ changes"
  fi
done

# Repository-wide CI rules that new files must not evade.
probe "workflow actions are SHA-pinned" scripts/check-action-pins.sh
probe "PR workflows hold no secrets" scripts/check-pr-secret-boundary.sh

if ((fail)); then
  echo "server image static checks failed" >&2
  exit 1
fi
echo "server image static checks passed"
