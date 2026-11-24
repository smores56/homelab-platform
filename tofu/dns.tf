# The public edge (design #725): grey-cloud address records, one IPv4 each,
# pointing at the VPS that terminates TLS for them. Grey cloud on purpose:
# Cloudflare must not sit in the media path, and TLS-ALPN-01 needs the name to
# answer directly. An explicit TTL rather than `ttl = 1`, which is the
# proxied-record value and is rejected on a record Cloudflare does not proxy.
#
# The set is empty until `edge_ipv4` is set, so this resource is declared now
# and applied at the cutover (tofu/cluster.tf, `edge_dns_hosts`). The proxied
# CNAMEs these names held on the cluster tunnel are retired (SDLC #833), so no
# name is written by two records and no apply has to order a destroy first.
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
    # The names with no tunnel route behind them (`edge_only_hosts`) have to be
    # names the edge serves: a typo there publishes nothing while `edge_hosts`
    # claims the name is served. The for_each already iterates the served set,
    # so the assertion left to make is between the two sets.
    precondition {
      condition     = alltrue([for host in local.edge_only_hosts : contains(local.edge_hosts, host)])
      error_message = "local.edge_only_hosts names a hostname local.edge_hosts does not serve: the edge-only set has to be a subset of the served names."
    }
  }
}

# The agent UI's Service VIP (design #834) is an address Tailscale computes, so
# the record is one name rather than a set. A record here wins over any other
# name's, which is the point: this name answers with the VIP while the zone's
# other names are the edge's. Grey cloud and an explicit TTL for the same reason
# as the edge records: Tailscale answers, not Cloudflare, and a proxied record
# would look for an origin Cloudflare cannot reach.
#
# Gated with the Service itself, so a checkout that only manages the zone plans
# no record pointing at an address that does not exist yet.
resource "cloudflare_dns_record" "assistant" {
  count = var.tailnet == "" ? 0 : 1

  zone_id = data.cloudflare_zone.this.zone_id
  name    = "assistant.${var.domain}"
  type    = "A"
  content = tailscale_service.agent_ui[0].addrs[0]
  proxied = false
  ttl     = 300
  comment = "agent UI Service VIP (design #834)"
}

# The general UI's name (task #847) rides the same Service and VIP: Caddy routes
# by SNI, so one address answers both names and the record differs only in the
# label. The zone publishes no wildcard any more (SDLC #833), so every name the
# tailnet or the edge answers is a record of its own.
#
# PR #120's apply removed the proxied cluster CNAME this name replaced: Cloudflare
# refuses two records at one name and OpenTofu cannot order a destroy before a
# create, so the two could not share a plan. The rest of that retirement is #833's.
resource "cloudflare_dns_record" "agent" {
  count = var.tailnet == "" ? 0 : 1

  zone_id = data.cloudflare_zone.this.zone_id
  name    = "agent.${var.domain}"
  type    = "A"
  content = tailscale_service.agent_ui[0].addrs[0]
  proxied = false
  ttl     = 300
  comment = "general agent UI Service VIP (design #834, task #847)"
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
