#!/usr/bin/env bash
# Static checks for the image repository. No container build, no registry, no
# credentials: everything here reads files.
#
#   tests/check.sh
set -uo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo" || exit 1

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

# --- pins -------------------------------------------------------------------

if pins=$(bash -c 'set -euo pipefail; source "$1"; printf "%s\n" "$BASE_IMAGE"' _ image/pins.env 2>/dev/null); then
  ok "image/pins.env sources"
else
  bad "image/pins.env sources"
  pins=""
fi

if [[ $pins =~ ^[^[:space:]]+@sha256:[0-9a-f]{64}$ ]]; then
  ok "BASE_IMAGE is digest-pinned"
else
  bad "BASE_IMAGE is digest-pinned" "$pins"
fi

if [[ ! $pins =~ :latest@ ]]; then
  ok "BASE_IMAGE is not a latest tag"
else
  bad "BASE_IMAGE is not a latest tag" "$pins"
fi

# --- Containerfile ----------------------------------------------------------

# shellcheck disable=SC2016 # the literal ${BASE_IMAGE} is what must appear
if grep -qx 'FROM ${BASE_IMAGE}' image/Containerfile; then
  ok "Containerfile builds from the pinned base argument"
else
  bad "Containerfile builds from the pinned base argument"
fi

if [[ $(grep -c '^FROM ' image/Containerfile) -eq 1 ]]; then
  ok "Containerfile has exactly one FROM"
else
  bad "Containerfile has exactly one FROM"
fi

if ! grep -qE '(^|[^/-])dnf[[:space:]]' image/Containerfile; then
  ok "Containerfile uses dnf5, not dnf"
else
  bad "Containerfile uses dnf5, not dnf"
fi

if grep -q 'bootc container lint' image/Containerfile; then
  ok "Containerfile runs bootc container lint"
else
  bad "Containerfile runs bootc container lint"
fi

if ! grep -qE 'curl .*\| *(ba)?sh' image/Containerfile; then
  ok "Containerfile never pipes curl into a shell"
else
  bad "Containerfile never pipes curl into a shell"
fi

# --- signing ----------------------------------------------------------------

if grep -q 'BEGIN PUBLIC KEY' image/cosign.pub 2>/dev/null; then
  ok "image/cosign.pub is a PEM public key"
else
  bad "image/cosign.pub is a PEM public key"
fi

if [[ -f image/rootfs/etc/containers/policy.json ]]; then
  if jq -e '.default[0].type == "reject"' image/rootfs/etc/containers/policy.json >/dev/null 2>&1; then
    ok "policy.json rejects by default"
  else
    bad "policy.json rejects by default"
  fi
  if jq -e '.transports.docker["ghcr.io/smores56/smorespro-image"][0].signedIdentity.type == "matchRepository"' \
      image/rootfs/etc/containers/policy.json >/dev/null 2>&1; then
    ok "policy.json scopes the signing key to this repository"
  else
    bad "policy.json scopes the signing key to this repository"
  fi
  if jq -e '.transports | to_entries | all(.value | type == "object")' \
      image/rootfs/etc/containers/policy.json >/dev/null 2>&1; then
    ok "policy.json transport values are objects"
  else
    bad "policy.json transport values are objects" "each transport maps a repository name to requirements"
  fi
  if jq -e '.transports.docker["ghcr.io/smores56/smorespro-image"][0].keyPath == "/etc/pki/containers/smorespro.pub"' \
      image/rootfs/etc/containers/policy.json >/dev/null 2>&1; then
    ok "policy.json points at the shipped public key"
  else
    bad "policy.json points at the shipped public key"
  fi
else
  bad "image/rootfs/etc/containers/policy.json exists"
fi

if grep -q 'use-sigstore-attachments: true' \
    image/rootfs/etc/containers/registries.d/ghcr.io-smorespro-image.yaml 2>/dev/null; then
  ok "registries.d enables sigstore attachments for the image repository"
else
  bad "registries.d enables sigstore attachments for the image repository"
fi

if grep -q 'spawn-at-startup "noctalia"' image/rootfs/etc/niri/config.kdl 2>/dev/null; then
  ok "the fallback niri config starts Noctalia"
else
  bad "the fallback niri config starts Noctalia"
fi

if grep -q 'spawn "kitty"' image/rootfs/etc/niri/config.kdl 2>/dev/null \
    && grep -q 'spawn "brave-origin"' image/rootfs/etc/niri/config.kdl \
    && grep -q 'spawn "dolphin"' image/rootfs/etc/niri/config.kdl \
    && ! grep -q 'wezterm' image/rootfs/etc/niri/config.kdl; then
  ok "the fallback session opens the image's apps"
else
  bad "the fallback session opens the image's apps"
fi

if grep -q 'install brave-origin' image/Containerfile \
    && grep -q 'gpgcheck=1' image/Containerfile \
    && grep -q "sed -i 's/^enabled=1\$/enabled=0/'" image/Containerfile \
    && grep -qE ' dolphin ImageMagick jq' image/Containerfile; then
  ok "Brave Origin comes from the vendor repo, disabled after install"
else
  bad "Brave Origin must come from the vendor repo, disabled after install"
fi

if ! grep -qE 'tuned-ppd|playerctl|brightnessctl|grim|slurp|wl-clipboard|gvfs-mtp|iwlwifi-mvm-firmware|rsync|alsa-utils|foot|tuigreet' image/Containerfile; then
  ok "no package the session never calls"
else
  bad "no package the session never calls"
fi

if grep -qE '^u[[:space:]]+greeter[[:space:]]' image/rootfs/usr/lib/sysusers.d/smorespro-greeter.conf 2>/dev/null; then
  ok "the image creates the greeter user greetd validates"
else
  bad "the image creates the greeter user greetd validates"
fi

if grep -q '^\[initial_session\]' image/rootfs/etc/greetd/config.toml 2>/dev/null \
    && grep -q '^user = "smores"' image/rootfs/etc/greetd/config.toml; then
  ok "greetd autologins through initial_session"
else
  bad "greetd autologins through initial_session"
fi

# --- NymVPN -----------------------------------------------------------------

if nympins=$(bash -c 'set -euo pipefail; source "$1"; printf "%s %s %s\n" "$NYM_VERSION" "$NYM_SHA256_AMD64" "$NYM_SHA256_ARM64"' _ image/pins.env 2>/dev/null); then
  read -r nymver nymamd nymarm <<<"$nympins"
  if [[ $nymver =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
      && [[ $nymamd =~ ^[0-9a-f]{64}$ ]] && [[ $nymarm =~ ^[0-9a-f]{64}$ ]]; then
    ok "the NymVPN pin is a stable version and two tarball hashes"
  else
    bad "the NymVPN pin is a stable version and two tarball hashes" "$nympins"
  fi
else
  bad "the NymVPN pin is a stable version and two tarball hashes"
fi

# shellcheck disable=SC2016 # the literal ${NYM_VERSION} is what must appear
if grep -qF 'nym-vpn-core-v${NYM_VERSION}_linux_${arch}.tar.gz' image/Containerfile \
    && grep -qF 'sha256sum -c -' image/Containerfile \
    && grep -q 'aarch64)' image/Containerfile \
    && grep -q -- '--location' image/Containerfile \
    && grep -q -- '--strip-components=1' image/Containerfile; then
  ok "the Containerfile fetches the pinned tarball per arch and verifies its hash"
else
  bad "the Containerfile fetches the pinned tarball per arch and verifies its hash"
fi

# The install line is the allowlist: the tarball also ships nym-exclude (a
# setuid split-tunnel helper), nym-diagnostic and the NetworkManager plugin.
if grep -qF 'install -m 0755 /tmp/nym/nym-vpnd /tmp/nym/nym-vpnc /tmp/nym/nym-socks5-proxy /usr/bin/' \
    image/Containerfile; then
  ok "the Containerfile installs exactly the daemon, CLI and SOCKS5 proxy"
else
  bad "the Containerfile installs exactly the daemon, CLI and SOCKS5 proxy"
fi

unit=image/rootfs/usr/lib/systemd/system/nym-vpnd.service
if grep -qx 'ExecStart=/usr/bin/nym-vpnd run-as-service' "$unit" 2>/dev/null \
    && grep -qx 'NoNewPrivileges=true' "$unit" \
    && grep -qx 'ProtectSystem=strict' "$unit" \
    && grep -qx 'StateDirectory=nym-vpnd' "$unit" \
    && grep -qx 'LimitCORE=0' "$unit" \
    && grep -q '^WantedBy=multi-user.target$' "$unit" \
    && grep -q 'nym-vpnd.service' image/Containerfile; then
  ok "the shipped daemon unit is hardened and enabled by the build"
else
  bad "the shipped daemon unit is hardened and enabled by the build"
fi

# This release has no DNS env override: the daemon detects its backend, so
# ordering on resolved and shipping resolved enabled are what choose it.
if grep -q '^After=.*systemd-resolved.service' "$unit" 2>/dev/null \
    && grep -q '^Wants=.*systemd-resolved.service' "$unit" \
    && grep -q 'systemd-resolved nftables' image/Containerfile \
    && grep -q 'systemd-resolved.service' image/Containerfile \
    && ! grep -q 'NYM_DNS_MODULE' "$unit"; then
  ok "the daemon is ordered after systemd-resolved, which the image installs and enables"
else
  bad "the daemon is ordered after systemd-resolved, which the image installs and enables"
fi

if grep -q 'nft delete table inet nym' "$unit" 2>/dev/null \
    && grep -q 'vendor-manifest' image/Containerfile; then
  ok "the unit clears a stale kill-switch and the build records the vendor binaries"
else
  bad "the unit clears a stale kill-switch and the build records the vendor binaries"
fi

policy=image/rootfs/usr/share/polkit-1/actions/com.nymvpn.vpnd.unix-access.policy
if grep -q 'com.nymvpn.vpnd.unix-access' "$policy" 2>/dev/null \
    && grep -q '<allow_active>auth_admin</allow_active>' "$policy" \
    && ! grep -q 'auth_self' "$policy"; then
  ok "the baked polkit action demands admin auth, never the caller's own"
else
  bad "the baked polkit action demands admin auth, never the caller's own"
fi

if ! grep -q '^g[[:space:]]*nym-vpn' image/rootfs/usr/lib/sysusers.d/*.conf 2>/dev/null; then
  ok "no nym-vpn group gives passwordless control of a root daemon"
else
  bad "no nym-vpn group gives passwordless control of a root daemon"
fi

if grep -q 'NYM_SHA256_AMD64' scripts/refresh-pins.sh \
    && grep -q 'curl_opts=' scripts/refresh-pins.sh; then
  ok "refresh-pins.sh watches the NymVPN pin with bounded fetches"
else
  bad "refresh-pins.sh watches the NymVPN pin with bounded fetches"
fi

# --- unlock (pam_u2f) -------------------------------------------------------

login=image/rootfs/etc/pam.d/login
if [[ $(grep -c 'pam_u2f\.so' "$login" 2>/dev/null) -eq 1 ]] \
    && grep -qxE 'auth +sufficient +pam_u2f\.so pinverification=1 cue' "$login"; then
  ok "login's one u2f line asks for the key and its PIN"
else
  bad "login's one u2f line asks for the key and its PIN" "pinverification=1 is what keeps a docked token from unlocking the machine alone"
fi

# Noctalia's lock screen authenticates against the "login" service (its
# pam_service build option defaults to login) and a TTY reads the same file, so
# this one line covers both. Behind system-auth's pam_unix it would never run:
# pam_unix succeeds first and the stack stops.
u2f_line=$(grep -n 'pam_u2f\.so' "$login" 2>/dev/null | cut -d: -f1)
pw_line=$(grep -nE '^auth +substack +system-auth' "$login" 2>/dev/null | cut -d: -f1)
if [[ -n $u2f_line && -n $pw_line && $u2f_line -lt $pw_line ]]; then
  ok "the u2f line runs ahead of the password stack"
else
  bad "the u2f line runs ahead of the password stack"
fi

# The rest of the file is util-linux's, so a base refresh is the only reason to
# change it; these are the lines that would silently vanish with a rewrite.
if grep -qx 'account    required     pam_nologin.so' "$login" \
    && grep -qx 'password   include      system-auth' "$login" \
    && grep -qx 'session    required     pam_selinux.so open' "$login" \
    && grep -qx 'session    required     pam_namespace.so' "$login" \
    && grep -qx '\-session   optional     pam_ck_connector.so' "$login"; then
  ok "the shipped login stack keeps util-linux's lines"
else
  bad "the shipped login stack keeps util-linux's lines"
fi

# The greeter must stay password-only: greetd ships its service files in
# /usr/lib/pam.d, so anything under /etc/pam.d/greetd* is this image's doing.
if [[ ! -e image/rootfs/etc/pam.d/greetd && ! -e image/rootfs/etc/pam.d/greetd-greeter ]]; then
  ok "the greeter's PAM service is left to greetd"
else
  bad "the greeter's PAM service is left to greetd"
fi

if grep -qE '^ +pam-u2f pamu2fcfg' image/Containerfile \
    && grep -q 'test -f /usr/lib64/security/pam_u2f.so' image/Containerfile; then
  ok "the image installs pam-u2f and pamu2fcfg and proves the module is there"
else
  bad "the image installs pam-u2f and pamu2fcfg and proves the module is there"
fi

# FIDO2 is HID through libfido2 everywhere in this design; a smartcard stack
# would add a daemon and a PIN cache for nothing.
if ! grep -qE '^ +(pcsc-lite|pcscd|opensc) ' image/Containerfile; then
  ok "no PC/SC or smartcard stack enters the image"
else
  bad "no PC/SC or smartcard stack enters the image"
fi

if [[ -f docs/manual-steps.md ]] \
    && grep -q 'systemd-cryptenroll --fido2-device=auto --fido2-with-client-pin=yes' docs/manual-steps.md \
    && grep -q 'pamu2fcfg -N -u smores' docs/manual-steps.md; then
  ok "manual-steps.md carries the token enrolment commands"
else
  bad "manual-steps.md carries the token enrolment commands"
fi

# --- escalation (sudo PIN) --------------------------------------------------

# The same stack runs on smortress, so this file is compared byte for byte with
# the design rather than by keyword: drift here means two hosts that gate
# differently, which is the one thing the design says must not happen.
sudo_pam=image/rootfs/etc/pam.d/sudo
expected=$(cat <<'EOT'
auth  required      pam_faillock.so preauth deny=5 unlock_time=300
auth  [success=2 default=ignore] pam_userdb.so crypt=crypt db=/etc/security/sudopin.db
auth  [success=1 default=ignore] pam_unix.so try_first_pass
auth  [default=die] pam_faillock.so authfail deny=5 unlock_time=300
auth  sufficient    pam_faillock.so authsucc deny=5 unlock_time=300
account    include system-auth
password   include system-auth
session    optional pam_keyinit.so revoke
session    required  pam_limits.so
session    include system-auth
EOT
)
if [[ $(cat "$sudo_pam" 2>/dev/null) == "$expected" ]] \
    && [[ $(wc -l <"$sudo_pam" 2>/dev/null) -eq 10 ]]; then
  ok "the shipped sudo PAM stack is the design's ten lines, byte for byte"
else
  bad "the shipped sudo PAM stack is the design's ten lines, byte for byte" \
    "$(diff <(printf '%s\n' "$expected") "$sudo_pam" 2>&1)"
fi

# Without crypt=crypt pam_userdb compares the stored value as plaintext, so the
# database would hold the PIN itself. db= is opened literally too: Linux-PAM
# never appends .db, so the name in the stack is the whole file name.
if grep -qx 'auth  \[success=2 default=ignore\] pam_userdb\.so crypt=crypt db=/etc/security/sudopin\.db' \
    "$sudo_pam" 2>/dev/null; then
  ok "the PIN is compared as a hash against the literal .db path"
else
  bad "the PIN is compared as a hash against the literal .db path" \
    "crypt=crypt is what makes the file a hash; db= is opened as given"
fi

# A bare authsucc stops clearing the tally at three rows, and interspersed typos
# then lock out an account whose every invocation succeeded.
if grep -qx 'auth  sufficient    pam_faillock\.so authsucc deny=5 unlock_time=300' \
    "$sudo_pam" 2>/dev/null; then
  ok "authsucc carries the same deny and unlock_time as preauth and authfail"
else
  bad "authsucc carries the same deny and unlock_time as preauth and authfail" \
    "a bare authsucc stops clearing the tally at three rows"
fi

# try_first_pass is what makes one prompt serve both credentials: pam_userdb
# caches the value typed there and pam_unix re-verifies it, so the account
# password is the fallback the design promises.
if grep -qx 'auth  \[success=1 default=ignore\] pam_unix\.so try_first_pass' \
    "$sudo_pam" 2>/dev/null; then
  ok "the account password is the fallback at the same prompt"
else
  bad "the account password is the fallback at the same prompt"
fi

if grep -qx 'account    include system-auth' "$sudo_pam" 2>/dev/null \
    && grep -qx 'password   include system-auth' "$sudo_pam" \
    && grep -qx 'session    optional pam_keyinit.so revoke' "$sudo_pam" \
    && grep -qx 'session    required  pam_limits.so' "$sudo_pam" \
    && grep -qx 'session    include system-auth' "$sudo_pam"; then
  ok "the sudo stack keeps the stock account, password and session phases"
else
  bad "the sudo stack keeps the stock account, password and session phases"
fi

# The PIN is what an agent lacks. A token line or a permitting module here would
# put escalation back within reach of whatever the session already holds.
if ! grep -qE 'pam_u2f|pam_permit' "$sudo_pam" 2>/dev/null; then
  ok "the sudo stack asks for the PIN, not the token"
else
  bad "the sudo stack asks for the PIN, not the token"
fi

expected=$(cat <<'EOT'
# /etc/sudoers.d/10-human-gate
Defaults timestamp_timeout=30
Defaults timestamp_type=tty
Defaults log_subcmds
EOT
)
if [[ $(cat image/rootfs/etc/sudoers.d/10-human-gate 2>/dev/null) == "$expected" ]]; then
  ok "the shipped sudoers drop-in is the design's, byte for byte"
else
  bad "the shipped sudoers drop-in is the design's, byte for byte"
fi

if grep -qx 'f /etc/security/sudopin.db 0600 root root -' \
    image/rootfs/usr/lib/tmpfiles.d/smorespro.conf 2>/dev/null; then
  ok "tmpfiles declares the PIN database root-only"
else
  bad "tmpfiles declares the PIN database root-only"
fi

# The db= name has to be the path tmpfiles declares, and nothing else may stand
# in for it: an extensionless symlink under the old name would mean the stack
# and the declaration disagree about which file holds the PIN.
dbpath=$(sed -n 's/.*pam_userdb\.so .*db=\([^ ]*\).*/\1/p' "$sudo_pam" 2>/dev/null)
dbdecl=$(awk '$1 == "f" && $2 ~ /sudopin/ { print $2 }' \
  image/rootfs/usr/lib/tmpfiles.d/smorespro.conf 2>/dev/null)
if [[ -n $dbpath && $dbpath == "$dbdecl" ]] \
    && [[ ! -e image/rootfs/etc/security/sudopin && ! -L image/rootfs/etc/security/sudopin ]]; then
  ok "the db= path is the declared PIN database and no symlink shadows it"
else
  bad "the db= path is the declared PIN database and no symlink shadows it" \
    "stack: ${dbpath:-none}, tmpfiles: ${dbdecl:-none}"
fi

if grep -q 'chmod 0440 /etc/sudoers.d/10-human-gate' image/Containerfile \
    && grep -q 'visudo -c' image/Containerfile; then
  ok "the build sets the drop-in's mode and proves it parses"
else
  bad "the build sets the drop-in's mode and proves it parses"
fi

if ! grep -rqF 'NOPASSWD' image docs README.md scripts 2>/dev/null; then
  ok "nothing in the tree grants NOPASSWD"
else
  bad "nothing in the tree grants NOPASSWD"
fi

# The PIN, its hash and the database are never in the tree: an eight-digit
# space is 10^8 candidates, so a committed hash is a leaked PIN. Only the steps
# that build it by hand are.
# shellcheck disable=SC2016 # the literal $6$ is what must not appear
if ! grep -rqF '$6$' image docs README.md \
    && [[ -z $(find . \( -path ./.git -o -path ./.worktrees \) -prune -o \
        \( -name 'sudopin*' -o -name '*.gdbm' \) -type f -print) ]]; then
  ok "no PIN hash or database is committed"
else
  bad "no PIN hash or database is committed"
fi

if grep -q 'read -rsp .new sudo PIN' docs/manual-steps.md \
    && grep -q 'openssl passwd -6 -stdin' docs/manual-steps.md \
    && grep -q 'store smores' docs/manual-steps.md \
    && grep -q 'fetch smores' docs/manual-steps.md \
    && grep -q 'chmod 0600 /etc/security/sudopin.db' docs/manual-steps.md \
    && grep -q 'faillock --user smores --reset' docs/manual-steps.md \
    && ! grep -qE '^[[:space:]]*(sudo[[:space:]]+)?db_load' docs/manual-steps.md; then
  ok "manual-steps.md hashes the PIN with openssl and stores it with gdbmtool"
else
  bad "manual-steps.md hashes the PIN with openssl and stores it with gdbmtool" \
    "pam_userdb links libgdbm, so db_load -T -t hash writes a database it cannot read"
fi

# --- shell ------------------------------------------------------------------

if command -v shellcheck >/dev/null 2>&1 && shellcheck --version >/dev/null 2>&1; then
  if shellcheck -x scripts/*.sh tests/*.sh; then
    ok "shellcheck"
  else
    bad "shellcheck"
  fi
else
  printf 'skip shellcheck (not installed)\n'
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
