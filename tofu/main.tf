# The zone is looked up by name: the token is scoped to this one zone, so the ID
# is not an input the operator has to transcribe.
data "cloudflare_zone" "this" {
  filter = {
    name = var.domain
  }
}

locals {
  # Let's Encrypt account URI, in the exact form the ACME client writes into a
  # CSR. CAA `accounturi` compares the string literally, so a staging directory
  # URL yields a staging pin and the two must not be mixed.
  acme_account_uri = "${trimsuffix(var.acme_directory, "/directory")}/acme/acct/${var.acme_account_id}"

  # Two tunnels, two owners (docs/cloudflare.md):
  #   host    - no connector; the nix-config cloudflared retired with the host's
  #             last route. Human-owned.
  #   cluster - cloudflared in the `ingress` namespace (T6); the apps the host no
  #             longer serves. SSH is on neither: it is tailnet-only (design
  #             #767).
  host_tunnel_cname    = "${var.host_tunnel_id}.cfargotunnel.com"
  cluster_tunnel_cname = "${var.cluster_tunnel_id}.cfargotunnel.com"
}

# One proxied wildcard CNAME fronts the host tunnel. Nothing the host serves
# resolves through it any more — SSH is tailnet-only (design #767) and the apps
# are on the cluster tunnel — so the name is what the wildcard Access application
# in access.tf denies: it is the default-deny net, not a route.
#
# Cloudflare matches one label only, so this record and that application both
# stop at `*.sammohr.dev`; `a.b.sammohr.dev` is covered by neither. The apex is
# not covered either, and nothing is served there.
resource "cloudflare_dns_record" "wildcard" {
  zone_id = data.cloudflare_zone.this.zone_id
  name    = "*.${var.domain}"
  type    = "CNAME"
  content = local.host_tunnel_cname
  proxied = true
  ttl     = 1
}
