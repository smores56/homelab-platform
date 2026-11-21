# Public hosts share one ruleset in the zone's `http_ratelimit` phase. A rule
# carries exactly one threshold, and the two populations here need two, so the
# ruleset holds one rule each rather than one shared budget.
#
# `recovery` (#707) is public with no Access gate (design #701, re-affirmed
# 2026-11-20), so the reader's own login endpoint is the only thing between the
# internet and the password. Its budget is 10 requests per 10 s per IP, and a
# client that exceeds it is blocked for the 10 s mitigation window. A human login
# is a single POST, so a mistyped password or a family member retrying stays far
# inside ten, while a scripted guesser is held at roughly one attempt per second
# per IP — under the rate the container's bcrypt work can answer, so the edge
# bounds the guessing instead of the origin's CPU absorbing it. The 10 s counting
# period and mitigation window are the only values the zone plan offers.
#
# The media hosts cannot share that budget and the reader cannot share theirs:
# an Immich timeline scroll exceeds a few hundred requests per 10 s, and 1000 is
# chosen for media. Splitting them is also what makes a password budget possible
# at all — a shared 1000/10 s allowance is not a brute-force control.
#
# `agent-hooks` is deliberately absent from both: its deliveries are
# individually authenticated and deduped, a shared per-IP budget would drop a
# legitimate burst from one provider, and the source cannot be identified before
# the request is parsed.
#
# Two rules cost two rate-limit slots, and this zone has been allowed one so far
# (a second rule failed the apply with "2 out of 1"). The login rule therefore
# needs the zone to carry two; confirm that before applying (docs/cloudflare.md).
# Resource and ruleset names are historical; renaming forces a replacement,
# which the lifecycle block forbids.
resource "cloudflare_ruleset" "dav_rate_limit" {
  zone_id = data.cloudflare_zone.this.zone_id
  name    = "dav rate limit"
  kind    = "zone"
  phase   = "http_ratelimit"

  rules = [
    {
      action      = "block"
      description = "Rate limit the public app hosts per IP"
      expression  = "(http.host eq \"music.${var.domain}\" or http.host eq \"photos.${var.domain}\" or http.host eq \"opds.${var.domain}\")"
      ratelimit = {
        characteristics     = ["ip.src", "cf.colo.id"]
        period              = 10
        requests_per_period = 1000
        mitigation_timeout  = 10
      }
    },
    {
      action      = "block"
      description = "Rate limit the Backrest login endpoint per IP"
      # The one path the Worker admits before authentication:
      # `backrest/src/index.ts` guards every RPC and lets only
      # `Authentication/Login` through, so this covers the password and nothing
      # a signed-in reader does.
      expression = "(http.host eq \"recovery.${var.domain}\" and http.request.uri.path eq \"/v1.Authentication/Login\")"
      ratelimit = {
        characteristics     = ["ip.src", "cf.colo.id"]
        period              = 10
        requests_per_period = 10
        mitigation_timeout  = 10
      }
    },
  ]

  lifecycle {
    prevent_destroy = true
  }
}
