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
apt-get install -y -qq caddy tailscale nftables jq openssl unattended-upgrades >/dev/null

# The Caddyfile needs Caddy 2.6, whose `tls` block accepts `issuer`. Ubuntu
# 24.04 ships 2.6.2 and was validated against it; jammy's 2.4 does not parse
# the block. Fail here rather than at the first certificate order, which is a
# 443 listener that cannot be renewed.
caddy_version=$(caddy version 2>/dev/null | awk 'NR == 1 { print $1 }')
if [[ ! $caddy_version =~ ^v?2\.([0-9]+)\. ]]; then
  die "unexpected Caddy version '$caddy_version'"
fi
if ((BASH_REMATCH[1] < 6)); then
  die "Caddy $caddy_version is too old; the Caddyfile needs 2.6. Deploy Ubuntu 24.04."
fi

# SSH: keys only and no root password. sshd keeps the FIRST value it obtains and
# Ubuntu's sshd_config includes this directory first, so the drop-in has to sort
# before cloud-init's 50-cloud-init.conf, which turns password auth back on. 05
# is the same prefix docs/core/server-image.md uses for the host.
install -d -m 0755 /etc/ssh/sshd_config.d
install -m 0644 "$here/05-edge-hardening.conf" /etc/ssh/sshd_config.d/05-edge-hardening.conf
if [[ ! -s /root/.ssh/authorized_keys ]]; then
  say "warning: /root/.ssh/authorized_keys is empty; key auth becomes the only login and the console the only way to add one"
fi
# The host key is a kit item: it pins the box identity across a reinstall, so a
# client's known_hosts entry survives and the operator never has to accept a
# new fingerprint over a console session they cannot verify. Without it a fresh
# key is generated and every client's entry goes stale.
# The source copy is consumed: a recovery-kit private key must not be left
# lying on a public host.
if [[ -n ${EDGE_HOST_KEY:-} ]]; then
  [[ -r $EDGE_HOST_KEY ]] || die "EDGE_HOST_KEY is set but not readable"
  if ! ssh-keygen -y -P '' -f "$EDGE_HOST_KEY" >/dev/null 2>&1; then
    die "EDGE_HOST_KEY is passphrase-protected; the box cannot unlock it unattended"
  fi
  install -m 0600 "$EDGE_HOST_KEY" /etc/ssh/ssh_host_ed25519_key
  ssh-keygen -y -f /etc/ssh/ssh_host_ed25519_key </dev/null >/etc/ssh/ssh_host_ed25519_key.pub
  chmod 0644 /etc/ssh/ssh_host_ed25519_key.pub
  rm -f -- "$EDGE_HOST_KEY"
fi
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
(
  # A subshell: the umask must not leak into every file written afterwards.
  umask 027
  cat >/etc/caddy/edge.env <<EOF
SMORTRESS_FQDN=$SMORTRESS_FQDN
EDGE_ACME_EMAIL=$EDGE_ACME_EMAIL
EOF
)
chgrp caddy /etc/caddy/edge.env
chmod 0640 /etc/caddy/edge.env
install -d -m 0755 /etc/systemd/system/caddy.service.d
cat >/etc/systemd/system/caddy.service.d/10-edge-env.conf <<'EOF'
[Service]
EnvironmentFile=/etc/caddy/edge.env
EOF
systemctl daemon-reload
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
# The packaged unit serves a hello page on 80 until this file replaces its
# config, so an operator masking it during provisioning is normal; unmask before
# the enable, or the box's only public listener never comes back.
systemctl unmask caddy >/dev/null 2>&1 || true
systemctl enable caddy
systemctl restart caddy

# Certificates and the tailnet both depend on a correct clock, and a host that
# goes unpatched for a year is the failure the panel cannot show.
systemctl enable --now unattended-upgrades
timedatectl set-ntp true

say "provisioned; proving it"
exec "$here/verify.sh"
