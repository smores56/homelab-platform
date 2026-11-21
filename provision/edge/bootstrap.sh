#!/usr/bin/env bash
# Provision the public edge (design #725): a RackNerd KVM VPS joined to the
# tailnet as tag:vps that terminates TLS for photos and opds and proxies to the
# two dedicated Serve ports on smortress. Caddy is the only public listener.
#
# RackNerd's ctrl panel has no cloud-init, no API and no snapshots, so this
# script is the whole provisioning step. Run it from the panel's HTML5 console on
# a fresh Ubuntu template: port 22 is closed at the panel and stays closed until
# the tailnet is up, so there is no first SSH session to run it from.
#
# Idempotent: every step writes the same file or asks systemd for the same
# state. The tailnet join happens once, with a preauthorized, tagged key; after
# that TS_AUTHKEY is not needed and is never stored.
#
#   TS_AUTHKEY=tskey-auth-... \
#   SMORTRESS_FQDN=smortress.stonecat-jazz.ts.net \
#   EDGE_ACME_EMAIL=ops@example.com \
#     provision/edge/bootstrap.sh
set -euo pipefail

die() { printf 'edge: %s\n' "$*" >&2; exit 1; }
say() { printf 'edge: %s\n' "$*"; }

[[ $EUID -eq 0 ]] || die "run as root; the console session on the template is"
: "${SMORTRESS_FQDN:?set SMORTRESS_FQDN to the MagicDNS name of smortress (smortress.<tailnet>.ts.net)}"
: "${EDGE_ACME_EMAIL:?set EDGE_ACME_EMAIL for ACME expiry notices}"

here=$(cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=/dev/null
codename=$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")
[[ -n $codename ]] || die "cannot read VERSION_CODENAME from /etc/os-release"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates gnupg >/dev/null

# Tailscale is not in Ubuntu's archive; its own repository is signed by the key
# fetched here, so an apt install is a verified download rather than a curl|sh.
if [[ ! -s /usr/share/keyrings/tailscale-archive-keyring.gpg ]]; then
  install -d -m 0755 /usr/share/keyrings
  curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${codename}.noarmor.gpg" \
    -o /usr/share/keyrings/tailscale-archive-keyring.gpg
  curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${codename}.tailscale-keyring.list" \
    -o /etc/apt/sources.list.d/tailscale.list
  apt-get update -qq
fi
apt-get install -y -qq caddy tailscale nftables jq unattended-upgrades >/dev/null

# SSH: keys only and no root password. The file name sorts after cloud-init's
# 50-cloud-init.conf, which turns password auth back on, so this has to be 99.
install -d -m 0755 /etc/ssh/sshd_config.d
install -m 0644 "$here/99-edge-hardening.conf" /etc/ssh/sshd_config.d/99-edge-hardening.conf
sshd -t
systemctl reload ssh 2>/dev/null || systemctl reload sshd

# Firewall before anything listens publicly. A bad ruleset is rejected by -c
# while the console session is still open; the tailnet interface is accepted, so
# applying it cannot close the login it does not carry.
install -m 0644 "$here/nftables.conf" /etc/nftables.conf
nft -c -f /etc/nftables.conf
systemctl enable nftables
systemctl restart nftables

# One join: tagged, key expiry off (a tagged node's keys do not expire), and a
# stable hostname. The tag is what the ACL names, so a rebuild with a new
# address reaches exactly the same two ports.
if ! tailscale status --json 2>/dev/null | grep -Eq '"BackendState":[[:space:]]*"Running"'; then
  : "${TS_AUTHKEY:?set TS_AUTHKEY to a preauthorized key carrying tag:vps on the first run}"
  tailscale up --auth-key "$TS_AUTHKEY" --advertise-tags=tag:vps \
    --hostname=edge --accept-routes=false
fi

# Caddy: the two names, no admin API, no port 80. The environment file carries
# the two values the Caddyfile substitutes; caddy.service reads it through a
# drop-in because the package ships no EnvironmentFile of its own.
install -d -m 0750 /etc/caddy
install -m 0644 "$here/Caddyfile" /etc/caddy/Caddyfile
umask 027
cat >/etc/caddy/edge.env <<EOF
SMORTRESS_FQDN=$SMORTRESS_FQDN
EDGE_ACME_EMAIL=$EDGE_ACME_EMAIL
EOF
chgrp caddy /etc/caddy/edge.env
chmod 0640 /etc/caddy/edge.env
install -d -m 0755 /etc/systemd/system/caddy.service.d
cat >/etc/systemd/system/caddy.service.d/10-edge-env.conf <<'EOF'
[Service]
EnvironmentFile=/etc/caddy/edge.env
EOF
systemctl daemon-reload
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
systemctl enable caddy
systemctl restart caddy

# Certificates and the tailnet both depend on a correct clock, and a host that
# goes unpatched for a year is the failure the panel cannot show.
systemctl enable --now unattended-upgrades
timedatectl set-ntp true

say "provisioned; proving it"
exec "$here/verify.sh"
