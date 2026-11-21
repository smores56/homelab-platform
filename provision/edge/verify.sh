#!/usr/bin/env bash
# Runtime proof for the edge box (design #725). bootstrap.sh ends by running
# this, and it is the one command to paste after any change made by hand.
#
# It proves the shape the design depends on and nothing it cannot see: the
# certificate, the two public names and the origin parity are checked from
# outside by scripts/verify-public-edge.sh, not here.
set -uo pipefail

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
check() { # description command...
  local name=$1
  shift
  if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi
}
check_not() {
  local name=$1
  shift
  if "$@" >/dev/null 2>&1; then bad "$name"; else ok "$name"; fi
}
eq() {
  if [[ $1 == "$2" ]]; then ok "$3"; else bad "$3" "got '$1' want '$2'"; fi
}

[[ $(id -u) -eq 0 ]] || {
  printf 'edge: verify needs root for nftables and sshd -T\n' >&2
  exit 1
}

# The config on disk is the config that will load.
check "the installed Caddyfile validates" \
  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
check "Caddy serves photos.sammohr.dev" grep -qxF 'photos.sammohr.dev {' /etc/caddy/Caddyfile
check "Caddy serves opds.sammohr.dev" grep -qxF 'opds.sammohr.dev {' /etc/caddy/Caddyfile
check "Caddy never answers HTTP-01" grep -qF 'disable_http_challenge' /etc/caddy/Caddyfile
check "Caddy has no admin API" grep -qxF 'admin off' /etc/caddy/Caddyfile
eq "$(stat -c '%a' /etc/caddy/edge.env)" 640 "the Caddy environment file is root-readable only"

for unit in caddy nftables tailscaled unattended-upgrades; do
  check "$unit is enabled" systemctl is-enabled --quiet "$unit"
done

# The firewall is the second layer, so what it allows is part of the design.
rules=$(nft list ruleset 2>/dev/null || true)
check "the input policy is drop" grep -qF 'policy drop' <<<"$rules"
check "the tailnet interface is accepted" grep -qF 'iifname "tailscale0" accept' <<<"$rules"
check "443 is the only public service" grep -qF 'tcp dport 443 accept' <<<"$rules"
check "41641 is open for direct WireGuard" grep -qF 'udp dport 41641 accept' <<<"$rules"
check_not "22 is never accepted from the public interface" \
  grep -qF 'tcp dport 22 accept' <<<"$rules"

# The login the design keeps tailnet-only: keys, no password, no root shell
# without a key, whatever cloud-init left in sshd_config.d.
eq "$(sshd -T | awk '$1 == "passwordauthentication" { print $2 }')" no \
  "sshd refuses passwords"
eq "$(sshd -T | awk '$1 == "permitrootlogin" { print $2 }')" prohibit-password \
  "sshd refuses a root password login"

eq "$(ss -ltnH 'sport = :80' | wc -l | tr -d ' ')" 0 "nothing listens on port 80"
check "Caddy listens on 443" ss -ltnH 'sport = :443'

status=$(tailscale status --json 2>/dev/null || true)
eq "$(jq -r '.BackendState // empty' <<<"$status")" Running "the tailnet link is up"
check "the node carries tag:vps" jq -e '.Self.Tags // [] | index("tag:vps")' <<<"$status"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
exit $((fail > 0))
