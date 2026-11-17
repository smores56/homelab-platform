# The SSH tunnel: a connector dedicated to `ssh.sammohr.dev`.
#
# The host tunnel's connector lived in nix-config and is gone. That tunnel is
# locally managed, so no API can write its ingress (docs/cloudflare.md); a
# dashboard-created tunnel is remotely managed, which is what puts its rules in
# this file and leaves the connector holding only a token
# (`units/systemd/smortress-cloudflared.service`).
#
# DNS is a specific record, so it wins over the wildcard in main.tf for this
# one name and every other name stays where it is. Both objects are gated on a
# non-empty id: a checkout that has not minted the tunnel yet still plans.
locals {
  ssh_tunnel_cname = "${var.ssh_tunnel_id}.cfargotunnel.com"
}

resource "cloudflare_dns_record" "ssh" {
  count = var.ssh_tunnel_id == "" ? 0 : 1

  zone_id = data.cloudflare_zone.this.zone_id
  name    = "ssh.${var.domain}"
  type    = "CNAME"
  content = local.ssh_tunnel_cname
  proxied = true
  ttl     = 1
  comment = "ssh tunnel (cloudflared on smortress)"
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "ssh" {
  count = var.ssh_tunnel_id == "" ? 0 : 1

  account_id = var.account_id
  tunnel_id  = var.ssh_tunnel_id

  config = {
    ingress = [
      {
        hostname = "ssh.${var.domain}"
        service  = "ssh://localhost:22"
      },
      {
        # The same object shape as the ssh rule so the list is one type;
        # cloudflared requires the catch-all to be the last rule.
        hostname = null
        service  = "http_status:404"
      },
    ]
  }
}
