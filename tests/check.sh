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

# The base is the moving release tag, not a digest: quay collects the manifests
# behind that tag within hours, so a written-down digest rots into
# `manifest unknown`. The build resolves the tag and records the digest in the
# image's org.opencontainers.image.base.digest label instead.
if [[ $pins =~ ^quay\.io/fedora/fedora-bootc:[0-9]+$ ]]; then
  ok "BASE_IMAGE is the fedora-bootc release tag"
else
  bad "BASE_IMAGE is the fedora-bootc release tag" "$pins"
fi

if [[ ! $pins =~ @sha256: && ! $pins =~ :latest$ ]]; then
  ok "BASE_IMAGE is neither digest-pinned nor a latest tag"
else
  bad "BASE_IMAGE is neither digest-pinned nor a latest tag" "$pins"
fi

# FEDORA_VERSION is the knob; a tag that drifts from it would track a release
# nobody chose.
fedora_version=$(bash -c 'set -euo pipefail; source "$1"; printf "%s\n" "$FEDORA_VERSION"' _ image/pins.env 2>/dev/null)
if [[ -n $fedora_version && $pins == "quay.io/fedora/fedora-bootc:${fedora_version}" ]]; then
  ok "BASE_IMAGE tracks the FEDORA_VERSION release"
else
  bad "BASE_IMAGE tracks the FEDORA_VERSION release" "FEDORA_VERSION=${fedora_version:-none} BASE_IMAGE=$pins"
fi

# --- Containerfile ----------------------------------------------------------

# shellcheck disable=SC2016 # the literal ${BASE_IMAGE} is what must appear
if grep -qx 'FROM ${BASE_IMAGE}' image/Containerfile; then
  ok "Containerfile builds from the base argument"
else
  bad "Containerfile builds from the base argument"
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

if grep -qx 'ARG BASE_DIGEST' image/Containerfile; then
  ok "the Containerfile takes the resolved base digest as a build arg"
else
  bad "the Containerfile takes the resolved base digest as a build arg" "without it the build has no digest to record"
fi

# The tag moves, so the labels are the only place a built image still says which
# base it came from; an arg nobody passes would ship an empty digest.
# shellcheck disable=SC2016 # the literal ${BASE_IMAGE} and ${BASE_DIGEST} must appear
if grep -qF 'org.opencontainers.image.base.name="${BASE_IMAGE}"' image/Containerfile \
    && grep -qF 'org.opencontainers.image.base.digest="${BASE_DIGEST}"' image/Containerfile; then
  ok "the Containerfile labels its base name and digest"
else
  bad "the Containerfile labels its base name and digest"
fi

# A digest would pin a manifest quay collects within hours; latest would track a
# release nobody chose.
if grep -qF '*@sha256:*)' image/Containerfile \
    && grep -qF 'quay.io/fedora/fedora-bootc:latest)' image/Containerfile; then
  ok "the build refuses a base digest and a latest tag"
else
  bad "the build refuses a base digest and a latest tag"
fi

# Both the local build and the publish workflow resolve the tag themselves, so
# both have to pass the result along.
if grep -qF "skopeo inspect --format '{{.Digest}}' \"docker://\$BASE_IMAGE\"" scripts/build-image.sh \
    && grep -qF -- '--build-arg "BASE_DIGEST=' scripts/build-image.sh; then
  ok "build-image.sh resolves the base digest and passes it"
else
  bad "build-image.sh resolves the base digest and passes it"
fi

if grep -qF "skopeo inspect --format '{{.Digest}}' \"docker://\$BASE_IMAGE\"" .github/workflows/publish.yml \
    && grep -qF -- '--build-arg "BASE_DIGEST=' .github/workflows/publish.yml; then
  ok "publish.yml resolves the base digest and passes it"
else
  bad "publish.yml resolves the base digest and passes it"
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

# Syncthing is the vault's second copy. It is a user service, so the unit is
# enabled globally at build time: there is no logged-in user to preset it for,
# and without the symlink the first login would start nothing. The folder root
# is a tmpfiles entry so bootc regenerates it with the right owner instead of
# carrying unpacked /var content in the image.
if grep -qE '^ +(.* )?syncthing[ ;]' image/Containerfile \
    && grep -q 'systemctl --global enable syncthing.service' image/Containerfile \
    && grep -qxF 'd /var/srv/files 0700 smores smores -' image/rootfs/usr/lib/tmpfiles.d/smorespro.conf; then
  ok "syncthing is installed, enabled globally, and /var/srv/files is declared"
else
  bad "syncthing is installed, enabled globally, and /var/srv/files is declared"
fi

# Chromium and every other PulseAudio client in the session link libpulse. With
# no server they fall back to pipewire-alsa, which still plays but drops stream
# restore, pactl and the PA interface; the fallback is a log line, not a
# failure, so anchor the check to the install line and the preset-enabled
# socket rather than to a comment.
if grep -qE '^ +pipewire .*pipewire-pulseaudio' image/Containerfile \
    && grep -q 'test -L /etc/systemd/user/sockets.target.wants/pipewire-pulse.socket' image/Containerfile; then
  ok "the image ships the PulseAudio server the session's clients expect"
else
  bad "the image ships the PulseAudio server the session's clients expect"
fi

# Intel Xe has no VA-API driver in mesa: iHD is a separate package. Without it
# vaInitialize fails and Chromium cannot hardware-decode HEVC at all, which
# shows up as a black video element rather than an error.
if grep -qE '^ +libva-intel-media-driver' image/Containerfile \
    && grep -q 'test -f /usr/lib64/dri/iHD_drv_video.so' image/Containerfile \
    && grep -q 'test -f /usr/lib64/libva.so.2' image/Containerfile; then
  ok "the image ships the iHD VA-API driver Xe needs"
else
  bad "the image ships the iHD VA-API driver Xe needs"
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

# --- display (DP EDID re-probe) ---------------------------------------------

# The dock's DP link can be up before its EDID reads, which leaves niri on
# 640x480 until the hub is re-plugged. The unit has to finish before greetd
# starts niri, and has to be a oneshot or that ordering is empty.
unit=image/rootfs/usr/lib/systemd/system/dp-edid-reprobe.service
dropin=image/rootfs/usr/lib/systemd/system/greetd.service.d/10-dp-edid-reprobe.conf
if grep -qx 'ExecStart=/usr/libexec/smorespro/dp-edid-reprobe' "$unit" 2>/dev/null \
    && grep -qx 'Type=oneshot' "$unit" \
    && grep -qx 'Before=greetd.service' "$unit" \
    && grep -qx 'WantedBy=graphical.target' "$unit" \
    && ! grep -qE '^[A-Za-z]+=.*systemd-udev-settle' "$unit" \
    && grep -qx 'Wants=dp-edid-reprobe.service' "$dropin" \
    && grep -qx 'After=dp-edid-reprobe.service' "$dropin" \
    && grep -qE '^ +dp-edid-reprobe\.service \\$' image/Containerfile; then
  ok "the DP EDID re-probe is a boot oneshot that greetd always waits for"
else
  bad "the DP EDID re-probe is a boot oneshot that greetd always waits for"
fi

# The script is the whole recovery: only a connector without a valid EDID is
# probed, and a probe that never works must fail the unit, not exit 0.
script=image/rootfs/usr/libexec/smorespro/dp-edid-reprobe
# shellcheck disable=SC2016 # the literal $connector must appear in the script
if [[ -x $script ]] \
    && grep -qF 'echo detect >"$connector/status"' "$script" \
    && grep -qx 'readonly edid_header=00ffffffffffff00' "$script" \
    && grep -qx 'exit 1' "$script"; then
  ok "the re-probe writes detect only without a valid EDID and fails loudly"
else
  bad "the re-probe writes detect only without a valid EDID and fails loudly"
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

# A missing module is caught above; a mapping pam_u2f cannot use is the other
# silent way sudo loses the tap, since every failure of the module falls through
# to the password. The build has to assert what git cannot: ownership, and the
# shape of the lines it shipped.
if grep -q 'test -s /etc/u2f_mappings' image/Containerfile \
    && grep -q 'stat -c %U:%G /etc/u2f_mappings' image/Containerfile \
    && grep -q 'stat -c %a /etc/u2f_mappings' image/Containerfile \
    && grep -qF "grep -qE '^[^#:]+:[^:]*,.*' /etc/u2f_mappings" image/Containerfile \
    && grep -qF "! grep -qF '+pin' /etc/u2f_mappings" image/Containerfile; then
  ok "the build proves the shipped mapping is root-owned 0644, populated and PIN-free"
else
  bad "the build proves the shipped mapping is root-owned 0644, populated and PIN-free"
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
    && grep -q 'pamu2fcfg -n -u smores' docs/manual-steps.md; then
  ok "manual-steps.md carries the token enrolment commands"
else
  bad "manual-steps.md carries the token enrolment commands"
fi

# /etc is a three-way merge, so a mapping this host wrote by hand survives an
# upgrade and sudo silently keeps using the old credentials -- either straight
# through to the password, or into the FIDO2 PIN prompt the rotation exists to
# avoid.
if grep -q 'diff /usr/etc/u2f_mappings /etc/u2f_mappings' docs/manual-steps.md; then
  ok "manual-steps.md says to reconcile the runtime mapping after an upgrade"
else
  bad "manual-steps.md says to reconcile the runtime mapping after an upgrade"
fi

# login is pinverification=1, so the lock screen's PIN prompt hands whatever is
# typed to the token: eight wrong entries block it, and unblocking it is a reset
# that erases every resident credential, the step-1 keyslot included. The
# passage that meets a locked screen has to say so before it says how to fall
# back, or an operator reads that prompt as an account-password prompt and
# spends the keyslot's budget on it.
if grep -q 'burns one of its attempts' docs/manual-steps.md; then
  ok "manual-steps.md warns that a wrong lock-screen PIN spends a token attempt"
else
  bad "manual-steps.md warns that a wrong lock-screen PIN spends a token attempt" \
    "the lock screen's PIN prompt goes to the token; only a failed pam_u2f reaches the password"
fi

# --- escalation (sudo: touch, password as fallback) --------------------------

# Another repository gates sudo on its own stack (design #767), so this laptop's
# file is compared directive for directive with the design: a
# dropped module or a jump index one line off is escalation an agent can reach,
# and the failure is silent. Comments are deliberately outside the comparison:
# they carry the reasoning, and a rationale that needs no test edit gets written.
directives() { grep -vE '^[[:space:]]*(#|$)' "$1"; }
sudo_pam=image/rootfs/etc/pam.d/sudo
expected=$(cat <<'EOT'
auth required                   pam_faillock.so preauth deny=5 unlock_time=300
auth [success=2 default=ignore] pam_u2f.so authfile=/etc/u2f_mappings cue userpresence=1 pinverification=0
auth [success=1 default=ignore] pam_unix.so try_first_pass
auth [default=die]              pam_faillock.so authfail deny=5 unlock_time=300
auth sufficient                 pam_faillock.so authsucc deny=5 unlock_time=300
account    include system-auth
password   include system-auth
session    optional pam_keyinit.so revoke
session    required  pam_limits.so
session    include system-auth
EOT
EOT
)
if [[ $(directives "$sudo_pam" 2>/dev/null) == "$expected" ]] \
    && [[ $(directives "$sudo_pam" 2>/dev/null | wc -l) -eq 10 ]]; then
  ok "the shipped sudo PAM stack is the design's directives"
else
  bad "the shipped sudo PAM stack is the design's directives" \
    "$(diff <(printf '%s
' "$expected") <(directives "$sudo_pam") 2>&1)"
fi

# The tap first, in the order a human meets it, with the tally controls wrapping
# the fallback: a refused or absent tap must reach pam_unix, a wrong password
# must reach authfail, and only a factor that succeeds may reach authsucc.
preauth=$(grep -n 'pam_faillock\.so preauth' "$sudo_pam" 2>/dev/null | cut -d: -f1)
u2f_line=$(grep -n 'pam_u2f\.so' "$sudo_pam" 2>/dev/null | cut -d: -f1)
unix_line=$(grep -n 'pam_unix\.so' "$sudo_pam" 2>/dev/null | cut -d: -f1)
authfail=$(grep -n 'pam_faillock\.so authfail' "$sudo_pam" 2>/dev/null | cut -d: -f1)
authsucc=$(grep -n 'pam_faillock\.so authsucc' "$sudo_pam" 2>/dev/null | cut -d: -f1)
if [[ -n $preauth && -n $unix_line && -n $u2f_line && -n $authfail && -n $authsucc ]] \
    && ((preauth < u2f_line && u2f_line < unix_line && unix_line < authfail && authfail < authsucc)); then
  ok "preauth, touch, password, authfail and authsucc run in that order"
else
  bad "preauth, touch, password, authfail and authsucc run in that order" \
    "preauth=${preauth:-none} u2f=${u2f_line:-none} password=${unix_line:-none} authfail=${authfail:-none} authsucc=${authsucc:-none}"
fi

# The order alone proves nothing: a module spliced between two rows keeps every
# inequality above true, and the byte compare is a copy of the file, so an
# arithmetic error edited into both would hide itself. pam's success=N skips N
# stacked modules (pam_dispatch.c), and these rows are adjacent, so the row a
# jump lands on is its own line + N + 1. Both factors must land exactly on
# authsucc: short of it and a success is spent on the wrong row, past it and the
# tally goes uncleared.
u2f_skip=$(sed -n "${u2f_line:-0}p" "$sudo_pam" 2>/dev/null | grep -oE 'success=[0-9]+' | cut -d= -f2)
unix_skip=$(sed -n "${unix_line:-0}p" "$sudo_pam" 2>/dev/null | grep -oE 'success=[0-9]+' | cut -d= -f2)
if [[ -n $u2f_skip && -n $unix_skip && -n $authsucc ]] \
    && ((u2f_line + u2f_skip + 1 == authsucc && unix_line + unix_skip + 1 == authsucc)); then
  ok "the touch and password rows jump to authsucc, not past it or short of it"
else
  bad "the touch and password rows jump to authsucc, not past it or short of it" \
    "u2f: line=${u2f_line:-none} success=${u2f_skip:-none}; password: line=${unix_line:-none} success=${unix_skip:-none}; authsucc: line=${authsucc:-none}"
fi

# A failed pam_unix falls through to the next row, whatever its jump, so a module
# parked between the password and authfail would take that failure somewhere
# other than the tally.
if [[ -n $unix_line && -n $authfail ]] && ((authfail == unix_line + 1)); then
  ok "authfail is the row immediately after pam_unix"
else
  bad "authfail is the row immediately after pam_unix" \
    "password=${unix_line:-none} authfail=${authfail:-none}: a failed password must land on the tally"
fi

# success=2 jumps over pam_unix and authfail to authsucc, and default=ignore is
# what routes every non-success touch to the password rather than to authfail:
# PAM_AUTH_ERR for a device or touch failure, PAM_USER_UNKNOWN for a key holding
# no credential for this user, PAM_AUTHINFO_UNAVAIL for an authfile pam_u2f
# cannot use.
if grep -qx 'auth \[success=2 default=ignore\] pam_u2f\.so authfile=/etc/u2f_mappings cue userpresence=1 pinverification=0' \
    "$sudo_pam" 2>/dev/null; then
  ok "a tap alone reaches authsucc, and a failed tap falls through to the password"
else
  bad "a tap alone reaches authsucc, and a failed tap falls through to the password" \
    "a bare sufficient here would terminate dispatch and authsucc would never clear the tally"
fi

# pam_unix is the fallback and only the fallback: success=1 skips authfail into
# authsucc, so a password after earlier typos clears the tally too, and a failure
# falls into authfail, which dies. try_first_pass is a no-op today -- pam_u2f
# sets no PAM_AUTHDATA, so pam_unix prompts -- and would become a stale-token
# reuse if a prompt-setting module were ever put ahead of this row.
if grep -qx 'auth \[success=1 default=ignore\] pam_unix\.so try_first_pass' "$sudo_pam" 2>/dev/null; then
  ok "a correct password reaches authsucc and a wrong one lands on authfail"
else
  bad "a correct password reaches authsucc and a wrong one lands on authfail" \
    "success=1 is what keeps a good password out of authfail's default=die"
fi

# pinverification=0 is the reason this file is not /etc/pam.d/login: the FIDO2
# PIN is shared with the disk keyslot, and eight wrong PINs wipe every
# credential on the token. Any process running as smores can make sudo prompt,
# so that budget is not one sudo may spend. userpresence=1 is what makes the
# factor a tap rather than possession of a docked key.
if grep -q 'pinverification=0' "$sudo_pam" 2>/dev/null \
    && grep -q 'userpresence=1' "$sudo_pam" \
    && ! grep -q 'pinverification=1' "$sudo_pam"; then
  ok "sudo asks for a touch and never for the FIDO2 PIN"
else
  bad "sudo asks for a touch and never for the FIDO2 PIN" \
    "pinverification=0 keeps the disk keyslot's PIN budget out of sudo's reach"
fi

# Without nouserok pam_u2f reports a user missing from the authfile as a failed
# touch; with it the module returns PAM_IGNORE and never asks for the key at all,
# which reads as a deliberate skip rather than a fallback. Comments mention the
# word, so only the rule lines count.
if ! grep -vE '^[[:space:]]*#' "$sudo_pam" 2>/dev/null | grep -q 'nouserok'; then
  ok "a key with no credential falls through to the password instead of skipping"
else
  bad "a key with no credential falls through to the password instead of skipping" \
    "nouserok turns a missing credential into PAM_IGNORE instead of a reported failure"
fi

# A bare authsucc stops clearing the tally at three rows, and interspersed typos
# then lock out an account whose every invocation succeeded.
if grep -qx 'auth sufficient                 pam_faillock\.so authsucc deny=5 unlock_time=300' \
    "$sudo_pam" 2>/dev/null; then
  ok "authsucc carries the same deny and unlock_time as preauth and authfail"
else
  bad "authsucc carries the same deny and unlock_time as preauth and authfail" \
    "a bare authsucc stops clearing the tally at three rows"
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

# The PIN, the PIN database and a permitting module are all gone. Any of them
# back in this file would put escalation within reach of whatever the session
# already holds.
if ! grep -qE 'pam_permit|pam_userdb|sudopin|pam_oath' "$sudo_pam" 2>/dev/null; then
  ok "the sudo stack asks for a touch or a password, nothing else"
else
  bad "the sudo stack asks for a touch or a password, nothing else"
fi

expected=$(cat <<'EOT'
Defaults timestamp_timeout=30
Defaults timestamp_type=tty
Defaults log_subcmds
EOT
EOT
)
if [[ $(directives image/rootfs/etc/sudoers.d/10-human-gate 2>/dev/null) == "$expected" ]]; then
  ok "the shipped sudoers drop-in is the design's directives"
else
  bad "the shipped sudoers drop-in is the design's directives"
fi

# /etc/u2f_mappings is public credential data: a key handle and a public key per
# token, no secret. It ships so that a fresh host needs no hand-written file, and
# because the sudo stack names it. pam_u2f parses it as root and warns about one that
# group or other can write without failing sudo over it: the touch then finds no
# device and falls through to the password, so the mode is asserted here rather
# than left to a journal line nobody reads.
# The credential must carry no +pin option: pam_u2f turns +pin into a PIN
# request even when the stack says pinverification=0, and an enrolment run with
# pamu2fcfg -N writes exactly that, which would put the sudo prompt back in the
# business of spending the token's PIN budget.
# The line is username:keyHandle,publicKey,options[:keyHandle,publicKey,options]...
# One credential per key: the owner's three 5C Nanos (one per laptop, one
# spare) all authenticate the same account, so the count is a minimum, not an
# equality -- replacing a key changes it. Base64url and base64 both appear in
# real pamu2fcfg output, so the class carries +, / and =.
mappings=image/rootfs/etc/u2f_mappings
map_line=$(sed -n 1p "$mappings" 2>/dev/null)
cred_re='^[A-Za-z0-9_+/=-]{20,},[A-Za-z0-9_+/=-]{40,}(,[A-Za-z0-9_+-]*){0,3}$'
map_ok=0
if [[ -n $map_line && $(wc -l <"$mappings" 2>/dev/null) -eq 1 && $map_line == smores:* ]]; then
  map_ok=1
  map_count=0
  IFS=: read -r -a map_creds <<<"${map_line#smores:}"
  for cred in "${map_creds[@]}"; do
    [[ $cred =~ $cred_re ]] || map_ok=0
    map_count=$((map_count + 1))
  done
  [[ $map_count -ge 2 ]] || map_ok=0
  [[ $map_line =~ \+pin ]] && map_ok=0
fi
[[ $(git ls-files -s -- "$mappings") == 100644* ]] || map_ok=0
if [[ $map_ok -eq 1 ]]; then
  ok "the shipped mapping is smores' per-key credentials, no +pin, group/other not writable"
else
  bad "the shipped mapping is smores' per-key credentials, no +pin, group/other not writable" \
    "$mappings is missing or malformed: plug in one 5C Nano at a time and run pamu2fcfg -u smores for the first and pamu2fcfg -n -u smores for each further key, then join them with ':' (docs/manual-steps.md section 2)"
fi

if grep -q 'chmod 0440 /etc/sudoers.d/10-human-gate' image/Containerfile \
    && grep -q 'visudo -c' image/Containerfile; then
  ok "the build sets the drop-in's mode and proves it parses"
else
  bad "the build sets the drop-in's mode and proves it parses"
fi

# A NOPASSWD rule skips pam_authenticate, so the touch row never runs and sudo
# is passwordless with nothing at the prompt to show it. The build has to refuse
# one rather than let a drop-in arrive unnoticed.
if grep -qF "grep -rqE '^[^#]*NOPASSWD' /etc/sudoers /etc/sudoers.d" image/Containerfile; then
  ok "the build refuses a sudoers rule that grants NOPASSWD"
else
  bad "the build refuses a sudoers rule that grants NOPASSWD"
fi

if grep -q 'chmod 0440 /etc/sudoers.d/10-human-gate /etc/sudoers.d/20-sops-env' image/Containerfile \
    && grep -q '^Defaults env_delete += ' image/rootfs/etc/sudoers.d/20-sops-env; then
  ok "the sops env drop-in is installed and drops every identity source"
else
  bad "the sops env drop-in is installed and drops every identity source"
fi

# The build's own assert names the word as the pattern it refuses, so that one
# line is the only occurrence allowed: a rule or a doc that grants NOPASSWD
# anywhere else is escalation that never reaches the touch stack.
if ! grep -rnF 'NOPASSWD' image docs README.md scripts 2>/dev/null \
    | grep -vF "NOPASSWD' /etc/sudoers" | grep -q .; then
  ok "nothing in the tree grants NOPASSWD"
else
  bad "nothing in the tree grants NOPASSWD"
fi

# The PIN database, its builder and any crypt hash of an account password are
# gone from the tree; a file named after them would be a leftover from a host
# that still had one. The scan stays, scoped to the tree that ships, so a
# re-introduction is caught where the removal is tested rather than nowhere.
# shellcheck disable=SC2016 # the literal $6$ is what must not appear
if ! grep -rqF '$6$' image docs README.md \
    && [[ -z $(find image docs scripts tests README.md \
        \( -name 'sudopin*' -o -name '*.gdbm' \) -type f -print 2>/dev/null) ]] \
    && ! grep -rqE 'pam_userdb|gdbmtool' image docs README.md; then
  ok "no PIN database, no crypt hash and no pam_userdb anywhere in the tree"
else
  bad "no PIN database, no crypt hash and no pam_userdb anywhere in the tree"
fi

if grep -q 'image/rootfs/etc/u2f_mappings' docs/manual-steps.md \
    && grep -q 'pamu2fcfg -n -u smores' docs/manual-steps.md \
    && grep -q 'bootc upgrade' docs/manual-steps.md \
    && ! grep -qE 'gdbmtool|sudopin' docs/manual-steps.md; then
  ok "manual-steps.md rotates the shipped mapping instead of building a PIN database"
else
  bad "manual-steps.md rotates the shipped mapping instead of building a PIN database"
fi

if grep -q 'sudo -k; sudo true' docs/manual-steps.md \
    && grep -q 'faillock --user smores --reset' docs/manual-steps.md \
    && grep -q 'unplugged' docs/manual-steps.md; then
  ok "manual-steps.md proves the tap-or-password gate and its recovery"
else
  bad "manual-steps.md proves the tap-or-password gate and its recovery"
fi

# --- shell ------------------------------------------------------------------

if command -v shellcheck >/dev/null 2>&1 && shellcheck --version >/dev/null 2>&1; then
  if shellcheck -x scripts/*.sh tests/*.sh image/rootfs/usr/libexec/smorespro/*; then
    ok "shellcheck"
  else
    bad "shellcheck"
  fi
else
  printf 'skip shellcheck (not installed)\n'
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
