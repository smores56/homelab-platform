# shellcheck shell=bash
# shellcheck disable=SC2016,SC2034,SC2154  # helpers and globals come from the entrypoint
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
check "no tunnel ciphertext ships" test ! -e secrets/cloudflared-tunnel.yaml
check "the decrypt manifest lists no tunnel ciphertext" \
  test -z "$(grep -E '^cloudflared-tunnel\.yaml[[:space:]]' image/rootfs/usr/share/smortress/secrets.manifest)"
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

