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
one_login_key() {
  [[ $(grep -c '^ssh-ed25519 ' "$edge/authorized_keys") == 1 ]]
}
sites_are_three() {
  local got
  got=$(grep -E '^[a-z0-9.-]+[[:space:]]*\{' "$edge/Caddyfile" \
    | sed 's/[[:space:]]*{$//' | sort | tr '\n' ' ')
  [[ $got == 'opds.sammohr.dev photos.sammohr.dev recovery.sammohr.dev ' ]]
}
# A site address that starts with http:// is a listener without TLS. An http://
# upstream inside a TLS site is the opposite and is expected here: the guard
# listens on loopback.
no_plain_http_site() { ! grep -qE '^http://' "$edge/Caddyfile"; }
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
check "the edge proxies Immich to a Service upstream" has 'reverse_proxy {$IMMICH_UPSTREAM}' "$edge/Caddyfile"
check "the edge proxies OPDShelf to a Service upstream" has 'reverse_proxy {$OPDS_UPSTREAM}' "$edge/Caddyfile"
check "the edge declares no plain HTTP site" no_plain_http_site
# The same question asked of the installed Caddyfile on the box: an unanchored
# `http://` there would match the recovery guard's loopback upstream and fail a
# healthy box.
check "the verify anchors its plain-HTTP check to a site address" \
  has "grep -qE '^http://'" "$edge/verify.sh"
# Caddy's home cannot be created by the caddy user, and a missing one costs every
# certificate: the bootstrap makes it and the verify proves it is writable.
check "the bootstrap creates Caddy's storage directory for its user" \
  has 'install -d -o caddy -g caddy -m 0750 /var/lib/caddy' "$edge/bootstrap.sh"
check "the verify proves Caddy can write its storage directory" \
  has 'runuser -u caddy -- test -w /var/lib/caddy' "$edge/verify.sh"
# The upstreams are variables now, so the Caddyfile names no host and no port at
# all: this pin is what keeps a literal 443 from being typed back in, and the
# derivation below is what keeps the target off the host's own address.
check "the edge never proxies 443" lacks ':443' "$edge/Caddyfile"
check "the edge serves exactly the three names" sites_are_three
check "the edge firewall drops by default" has 'policy drop' "$edge/nftables.conf"
check "the edge firewall admits 443" has 'tcp dport 443 accept' "$edge/nftables.conf"
check "the edge firewall admits WireGuard" has 'udp dport 41641 accept' "$edge/nftables.conf"
check "the edge firewall trusts the tailnet interface" has 'iifname "tailscale0" accept' "$edge/nftables.conf"
check "the edge firewall never admits 22 publicly" lacks 'tcp dport 22 accept' "$edge/nftables.conf"
check "the bootstrap joins with the edge tag" has '--advertise-tags=tag:vps' "$edge/bootstrap.sh"
check "the bootstrap fixes the node hostname" has '--hostname=smoresnet' "$edge/bootstrap.sh"
check "the bootstrap sets the OS hostname" has 'hostnamectl set-hostname smoresnet' "$edge/bootstrap.sh"
check "the bootstrap disables the template's unused daemons" has 'multipathd ModemManager udisks2 upower rsyslog' "$edge/bootstrap.sh"
check "the bootstrap installs the repository login key" has 'authorized_keys' "$edge/bootstrap.sh"
check "the bootstrap validates the ruleset before applying it" has 'nft -c -f /etc/nftables.conf' "$edge/bootstrap.sh"
check "the bootstrap validates the Caddyfile before enabling Caddy" has 'caddy validate --config /etc/caddy/Caddyfile' "$edge/bootstrap.sh"
check "the Caddy config directory is traversable by the caddy user" has 'install -d -m 0755 /etc/caddy' "$edge/bootstrap.sh"
check "sshd hardening sorts before cloud-init" has '05-edge-hardening.conf' "$edge/bootstrap.sh"
check "the bootstrap refuses a Caddy older than 2.6" has 'is too old; the Caddyfile needs 2.6' "$edge/bootstrap.sh"
check "the bootstrap unmasks the packaged Caddy unit" has 'systemctl unmask caddy' "$edge/bootstrap.sh"
check "the bootstrap restores the kit's host key" has 'EDGE_HOST_KEY' "$edge/bootstrap.sh"
check "the bootstrap drops the template's other host keys" has 'rm -f /etc/ssh/ssh_host_rsa_key' "$edge/bootstrap.sh"
check "the verify proves the node carries the edge tag" has 'tag:vps' "$edge/verify.sh"
check "the verify proves the tailnet name" has 'startswith("smoresnet.")' "$edge/verify.sh"
check "the repository login key is one ed25519 line" one_login_key
check "the verify proves nothing listens on 80" has 'sport = :80' "$edge/verify.sh"
# The upstream half of the edge is two Tailscale Services, so what the bootstrap
# must derive and what the verify must probe are pinned here: a Service name is
# `<service>.<tailnet>.ts.net`, and the tailnet domain is the one SMORTRESS_FQDN
# already carries, never a second name typed into either file.
check "the bootstrap derives the Immich upstream from the tailnet domain" has 'IMMICH_UPSTREAM=https://immich.$tailnet_domain' "$edge/bootstrap.sh"
check "the bootstrap derives the OPDShelf upstream from the tailnet domain" has 'OPDS_UPSTREAM=https://opds.$tailnet_domain' "$edge/bootstrap.sh"
check "the bootstrap refuses a hostname with no tailnet domain" has 'has no tailnet domain' "$edge/bootstrap.sh"
# The host's own name and 443 must stay out of the upstream list: a Service is a
# different address, and that one also carries the agent paths and /wallpapers.
check "the bootstrap never points an upstream at the host's own name" lacks '_UPSTREAM=https://$SMORTRESS_FQDN' "$edge/bootstrap.sh"
check "the bootstrap writes the Immich upstream to the Caddy environment" has 'IMMICH_UPSTREAM=$IMMICH_UPSTREAM' "$edge/bootstrap.sh"
check "the bootstrap writes the OPDShelf upstream to the Caddy environment" has 'OPDS_UPSTREAM=$OPDS_UPSTREAM' "$edge/bootstrap.sh"
check "the verify probes the Service names on 443" has '-connect "$immich_name:443"' "$edge/verify.sh"
check "the verify refuses an environment file without the upstreams" has 'has no IMMICH_UPSTREAM' "$edge/verify.sh"

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
