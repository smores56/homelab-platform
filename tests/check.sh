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
