# Cluster tunnel routes. A specific record wins over *.<domain>, so a name in
# local.cluster_hosts resolves to the cluster connector while everything else
# keeps resolving to the host tunnel in main.tf. The set defaults to the
# tunnel's own ingress keys, so DNS moves with the route rather than beside it.
resource "cloudflare_dns_record" "cluster" {
  for_each = toset(local.cluster_hosts)

  zone_id = data.cloudflare_zone.this.zone_id
  name    = "${each.value}.${var.domain}"
  type    = "CNAME"
  content = local.cluster_tunnel_cname
  proxied = true
  ttl     = 1
  comment = "cluster tunnel (k3s ingress/cloudflared)"

  lifecycle {
    precondition {
      condition     = var.cluster_tunnel_id != ""
      error_message = "cluster_hosts is non-empty but cluster_tunnel_id is empty: mint the cluster tunnel first (docs/manual-steps.md)."
    }
  }
}

# The public edge (design #725): two grey-cloud address records, one IPv4
# each, pointing at the VPS that terminates TLS for them. Grey cloud on purpose:
# Cloudflare must not sit in the media path, and TLS-ALPN-01 needs the name to
# answer directly. An explicit TTL rather than `ttl = 1`, which is the
# proxied-record value and is rejected on a record Cloudflare does not proxy.
#
# The set is empty until `edge_ipv4` is set, so this resource is declared now
# and applied at the cutover. It is applied in a second step after the cluster
# records are gone (tofu/cluster.tf, `edge_dns_hosts`): Cloudflare refuses two
# records at one name, and OpenTofu cannot order a destroy before a create.
#
# `edge_ipv4` has to stay a plan-known literal: wiring it to a resource or data
# source makes the for_each unknown at plan time and the plan fails.
resource "cloudflare_dns_record" "edge" {
  for_each = toset(local.edge_dns_hosts)

  zone_id = data.cloudflare_zone.this.zone_id
  name    = "${each.value}.${var.domain}"
  type    = "A"
  content = var.edge_ipv4
  proxied = false
  ttl     = 300
  comment = "public edge VPS (design #725)"

  lifecycle {
    precondition {
      condition     = contains(keys(local.cluster_ingress), each.value)
      error_message = "local.edge_hosts names a hostname the cluster ingress map does not know: the cutover would create a record with no origin to fall back to."
    }
  }
}

# CAA pins issuance for the zone to the ACME account Kanbei's in-VM client uses
# (docs/cloudflare.md, "CAA"). Two tags because a wildcard order is authorized
# by issuewild, not issue.
#
# Caveat that makes this a narrowing, not a lockdown: Cloudflare appends its own
# Universal SSL CAA records (pki.goog, letsencrypt.org, ssl.com, sectigo.com,
# digicert) to any zone that has a CAA record. Those are invisible in the
# dashboard and appear in `dig`, so an unpinned `letsencrypt.org` issue always
# sits beside the pinned one and any Let's Encrypt account stays authorized for
# the edge certificate. Verify with:
#   dig +short CAA sammohr.dev
resource "cloudflare_dns_record" "caa_issue" {
  # No account yet means no pin: an empty account id would encode a bogus
  # accounturi and stop Let's Encrypt issuing for the zone at all.
  count   = var.acme_account_id == "" ? 0 : 1
  zone_id = data.cloudflare_zone.this.zone_id
  name    = var.domain
  type    = "CAA"
  ttl     = 3600
  comment = "ACME account pin for the in-VM CSR client"

  data = {
    flags = 0
    tag   = "issue"
    value = "letsencrypt.org; accounturi=${local.acme_account_uri}"
  }
}

resource "cloudflare_dns_record" "caa_issuewild" {
  count   = var.acme_account_id == "" ? 0 : 1
  zone_id = data.cloudflare_zone.this.zone_id
  name    = var.domain
  type    = "CAA"
  ttl     = 3600
  comment = "ACME account pin for wildcard orders from the in-VM CSR client"

  data = {
    flags = 0
    tag   = "issuewild"
    value = "letsencrypt.org; accounturi=${local.acme_account_uri}"
  }
}
