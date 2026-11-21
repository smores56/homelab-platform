#!/usr/bin/env bash
# Static checks for the smortress autoinstall artifact.
# Runtime proof lives in provision/smortress/verify.sh; this runs in CI.
# shellcheck disable=SC2016  # expectations are literal source text, not expansions
# shellcheck disable=SC2329  # has()/lacks() are called through check()
set -euo pipefail

root=$(cd -- "$(dirname -- "$0")/../.." && pwd)
art="$root/provision/smortress"
edge="$root/provision/edge"
fail=0

check() {
  local name=$1
  shift
  if "$@"; then
    printf 'ok   %s\n' "$name"
  else
    printf 'FAIL %s\n' "$name" >&2
    fail=1
  fi
}

has() { grep -qF -- "$1" "$2"; }
lacks() { ! grep -qF -- "$1" "$2"; }

[ -d "$art" ] || { echo "missing $art" >&2; exit 1; }
[ -d "$edge" ] || { echo "missing $edge" >&2; exit 1; }

check "user-data keeps the disk-serial placeholder" has '__DISK_SERIAL__' "$art/user-data"
check "user-data has no spike-only serial" lacks 'SMORTRESS980' "$art/user-data"
check "user-data installs clevis-tpm2" has 'clevis-tpm2' "$art/user-data"
check "user-data wipes the whole disk" has 'wipe: superblock-recursive' "$art/user-data"
check "user-data adds the data keyslot" has 'luksAddKey' "$art/user-data"
check "user-data backs up the data header" has 'luks-data.header' "$art/user-data"
check "user-data fails a missing ip=dhcp" has "grep -q 'ip=dhcp'" "$art/user-data"
check "provision unit follows the cryptsetup unit" has 'systemd-cryptsetup@luks\x2ddata.service' "$art/user-data"
check "provision unit skips without the mapper" has 'ConditionPathExists=/dev/mapper/luks-data' "$art/user-data"
check "data crypttab entry carries nofail" has 'luks,discard,nofail' "$art/user-data"
check "pool creation sets cachefile=none" has 'zpool create -o cachefile=none' "$art/user-data"
check "installer logs are scrubbed" has '/var/log/installer/*autoinstall*' "$art/user-data"
check "user-data carries the host-key placeholder" has '__HOST_KEY_ESCAPED__' "$art/user-data"
check "user-data derives the host-key pubfile" has 'ssh_host_ed25519_key.pub' "$art/user-data"
check "user-data drops generated rsa/ecdsa host keys" has 'ssh_host_rsa*' "$art/user-data"
check "seed builder requires the host key" has 'SMORTRESS_HOST_KEY is required' "$art/build-seed.sh"
check "seed builder rejects a protected host key" has 'passphrase-protected' "$art/build-seed.sh"
check "seed builder rejects leftover placeholders" has 'unsubstituted placeholder' "$art/build-seed.sh"
check "seed builder writes the seed 0600" has 'chmod 600 "$seed"' "$art/build-seed.sh"
check "seed defaults outside the repo" has '$HOME/.cache/smortress' "$art/build-seed.sh"
check "seed builder verifies the ISO signature" has 'VALIDSIG' "$art/build-seed.sh"
check "spike waits for the swtpm socket" has 'swtpm did not create' "$art/spike.sh"
check "spike passes swtpm not-need-init" has 'not-need-init' "$art/spike.sh"

# The public edge (design #725). Its bootstrap is the only provisioning step a
# panel with no cloud-init will ever get, so the properties the design depends
# on are pinned here rather than trusted to a console session.
check "the edge serves photos" has 'photos.sammohr.dev {' "$edge/Caddyfile"
check "the edge serves opds" has 'opds.sammohr.dev {' "$edge/Caddyfile"
check "the edge refuses HTTP-01" has 'disable_http_challenge' "$edge/Caddyfile"
check "the edge has no admin API" has 'admin off' "$edge/Caddyfile"
check "the edge proxies Immich on its own Serve port" has 'https://{$SMORTRESS_FQDN}:8446' "$edge/Caddyfile"
check "the edge proxies OPDShelf on its own Serve port" has 'https://{$SMORTRESS_FQDN}:8447' "$edge/Caddyfile"
check "the edge declares no plain HTTP site" lacks 'http://' "$edge/Caddyfile"
check "the edge firewall drops by default" has 'policy drop' "$edge/nftables.conf"
check "the edge firewall admits 443" has 'tcp dport 443 accept' "$edge/nftables.conf"
check "the edge firewall admits WireGuard" has 'udp dport 41641 accept' "$edge/nftables.conf"
check "the edge firewall trusts the tailnet interface" has 'iifname "tailscale0" accept' "$edge/nftables.conf"
check "the edge firewall never admits 22 publicly" lacks 'tcp dport 22 accept' "$edge/nftables.conf"
check "the bootstrap joins with the edge tag" has '--advertise-tags=tag:vps' "$edge/bootstrap.sh"
check "the bootstrap fixes the node hostname" has '--hostname=edge' "$edge/bootstrap.sh"
check "the bootstrap validates the ruleset before applying it" has 'nft -c -f /etc/nftables.conf' "$edge/bootstrap.sh"
check "the bootstrap validates the Caddyfile before enabling Caddy" has 'caddy validate --config /etc/caddy/Caddyfile' "$edge/bootstrap.sh"
check "sshd hardening sorts after cloud-init" has '99-edge-hardening.conf' "$edge/bootstrap.sh"
check "the bootstrap restores the kit's host key" has 'EDGE_HOST_KEY' "$edge/bootstrap.sh"
check "the verify proves the node carries the edge tag" has 'tag:vps' "$edge/verify.sh"
check "the verify proves nothing listens on 80" has 'sport = :80' "$edge/verify.sh"

if command -v shellcheck >/dev/null 2>&1; then
  # has/lacks are invoked through check(), and the grep patterns are literal.
  check "shellcheck clean" shellcheck -e SC2329,SC2016 "$art"/*.sh "$edge"/*.sh "$root/tests/provision/check.sh"
else
  echo "skip shellcheck (not installed)"
fi

if command -v yamllint >/dev/null 2>&1; then
  check "yamllint parses user-data" yamllint -c "$root/.yamllint.yaml" "$art/user-data"
else
  echo "skip yamllint (not installed)"
fi

exit "$fail"
