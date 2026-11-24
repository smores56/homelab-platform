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

# The zone's CAA policy (design #842 T4) names a CA, never an ACME account. A
# value may carry `accounturi=`, but that string is compared literally against
# the account in the CSR, so it authorizes exactly one account on one directory:
# the edge's Caddy account is re-registered by a rebuild and the account it
# replaces is gone, so an account pin would turn a routine rebuild into an
# outage that first surfaces weeks later at renewal. Naming the CA alone is what
# survives a rebuild: the new account orders from the same directory and the
# same issuer, and this policy already admits it.
#
# These two records authorize the unproxied names Caddy orders for
# (`photos`/`opds`/`recovery` here, `assistant`/`agent` on smortress): grey-cloud
# records reach the origin directly, so Let's Encrypt reads this set. A wildcard
# order is not authorized by `issue`, hence the second tag.
#
# The proxied names answer from Cloudflare's edge, where the certificate is
# Cloudflare's to order. With Universal SSL the zone's answer also carries the
# CA set Cloudflare appends to any zone with a CAA record, and CAA admits
# issuance if *any* matching set permits it, so the served issuer is admitted by
# the union (docs/cloudflare.md, "CAA"). `scripts/verify-caa.sh` asserts that
# union against the certificate actually served.
resource "cloudflare_dns_record" "caa_issue" {
  zone_id = data.cloudflare_zone.this.zone_id
  name    = var.domain
  type    = "CAA"
  data = {
    flags = 0
    tag   = "issue"
    value = "letsencrypt.org"
  }
  ttl     = 3600
  comment = "unpinned CA policy for the public edge (design #842)"
}

resource "cloudflare_dns_record" "caa_issuewild" {
  zone_id = data.cloudflare_zone.this.zone_id
  name    = var.domain
  type    = "CAA"
  data = {
    flags = 0
    tag   = "issuewild"
    value = "letsencrypt.org"
  }
  ttl     = 3600
  comment = "wildcard orders need their own tag (design #842)"
}
