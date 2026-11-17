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
    && ! grep -q 'wezterm' image/rootfs/etc/niri/config.kdl; then
  ok "the fallback session opens the image's kitty"
else
  bad "the fallback session opens the image's kitty"
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
