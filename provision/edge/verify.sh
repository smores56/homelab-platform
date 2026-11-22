#!/usr/bin/env bash
# Runtime proof for the edge box (design #725). bootstrap.sh ends by running
# this, and it is the one command to paste after any change made by hand.
#
# It proves the shape the design depends on and nothing it cannot see: the
# certificate, the two public names and the origin parity are checked from
# outside by scripts/verify-public-edge.sh, not here.
# shellcheck disable=SC2329  # helpers are invoked through check()
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
note() {
  printf 'skip %s\n' "$1"
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

# The upstream name lives in the Caddy environment file; the checks below need
# the same value Caddy proxies to, not a copy typed here.
[[ -r /etc/caddy/edge.env ]] || {
  printf 'edge: /etc/caddy/edge.env is missing\n' >&2
  exit 1
}
set -a
# shellcheck source=/dev/null
. /etc/caddy/edge.env
set +a

# The config on disk is the config that will load.
check "the installed Caddyfile validates" \
  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
check "Caddy serves photos.sammohr.dev" grep -qxF 'photos.sammohr.dev {' /etc/caddy/Caddyfile
check "Caddy serves opds.sammohr.dev" grep -qxF 'opds.sammohr.dev {' /etc/caddy/Caddyfile
check "Caddy never answers HTTP-01" grep -qF 'disable_http_challenge' /etc/caddy/Caddyfile
check "Caddy has no admin API" grep -qF 'admin off' /etc/caddy/Caddyfile
# Exactly two site blocks, never a third: a site added by hand is a name
# published by accident, and every positive grep above would still pass.
eq "$(grep -E '^[a-z0-9.-]+[[:space:]]*\{' /etc/caddy/Caddyfile \
  | sed 's/[[:space:]]*{$//' | sort | tr '\n' ' ')" \
  'opds.sammohr.dev photos.sammohr.dev ' "Caddy serves exactly the two names"
check_not "no site proxies 443" grep -qF ':443' /etc/caddy/Caddyfile
check_not "no site answers plain HTTP" grep -qF 'http://' /etc/caddy/Caddyfile
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
# without a key, whatever cloud-init left in sshd_config.d. sshd -T normalizes
# `prohibit-password` to its older synonym `without-password`, so both count.
eq "$(sshd -T | awk '$1 == "passwordauthentication" { print $2 }')" no \
  "sshd refuses passwords"
root_login_is_key_only() {
  sshd -T | awk '$1 == "permitrootlogin" { print $2 }' \
    | grep -qxE 'prohibit-password|without-password'
}
check "sshd refuses a root password login" root_login_is_key_only

eq "$(ss -ltnH 'sport = :80' | wc -l | tr -d ' ')" 0 "nothing listens on port 80"
check "Caddy listens on 443" ss -ltnH 'sport = :443'

eq "$(hostnamectl --static)" smoresnet "the OS hostname is smoresnet"

status=$(tailscale status --json 2>/dev/null || true)
eq "$(jq -r '.BackendState // empty' <<<"$status")" Running "the tailnet link is up"
check "the node carries tag:vps" jq -e '.Self.Tags // [] | index("tag:vps")' <<<"$status"
check "the tailnet name is smoresnet" jq -e '.Self.DNSName // "" | startswith("smoresnet.")' <<<"$status"

# The whole point of the panel's udp/41641 rule: a direct path, not DERP.
# `--until-direct` exits non-zero when every reply came back relayed, but the
# seconds right after a join or a peer reboot are still relayed while the path
# negotiates, so retry for a minute before calling it a finding.
direct_path() {
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    timeout 10 tailscale ping --c 3 --until-direct=true smortress >/dev/null 2>&1 && return 0
    sleep 5
  done
  return 1
}
check "the path to smortress is direct" direct_path

# The upstream half is a property of the pair, not of this box, and until the
# image that declares Serve 8446/8447 is on smortress it cannot pass. It is
# therefore opt-in and explicit: EXPECT_UPSTREAM=1 is the gate before a cutover,
# and an ordinary bootstrap run does not pretend to have proven it.
if [[ ${EXPECT_UPSTREAM:-0} == 1 ]]; then
    # The upstream is the tailnet's own certificate on Serve's dedicated ports.
    # Caddy verifies that chain against the public roots, so a chain that does not
    # verify here would be a 502 on every public request, not a warning.
    upstream_cert=$(openssl s_client -connect "$SMORTRESS_FQDN:8446" \
      -servername "$SMORTRESS_FQDN" -verify_return_error </dev/null 2>&1 || true)
    check "the upstream certificate verifies" grep -qF 'Verify return code: 0 (ok)' <<<"$upstream_cert"
    check "Serve fronts Immich on 8446" curl -sS -o /dev/null --max-time 10 \
      "https://$SMORTRESS_FQDN:8446/"
    check "Serve fronts OPDShelf on 8447" curl -sS -o /dev/null --max-time 10 \
      "https://$SMORTRESS_FQDN:8447/"
    check_not "the edge cannot reach the host on 443" curl -sS -o /dev/null --max-time 5 \
      "https://$SMORTRESS_FQDN:443/"
else
  note "upstream checks skipped; run EXPECT_UPSTREAM=1 $0 before a cutover"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
exit $((fail > 0))
