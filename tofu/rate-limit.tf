# Public hosts share one ruleset in the zone's `http_ratelimit` phase. The zone
# plan allows exactly ONE rule (a second fails the apply with "2 out of 1"), and
# a rule carries exactly one threshold, so the slot goes to the population with
# no other control.
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
# What that slot costs: this ruleset used to hold a second rule — `music`,
# `photos` and `opds` at 1000 requests per 10 s per IP, sized for an Immich
# timeline scroll — and the slot count forced the choice. That rule was live, not
# vestigial: the three names are in `local.public_apps` (access.tf) and resolve
# through proxied CNAMEs to the cluster tunnel (dns.tf), `photos` fronting
# `immich-server` (cluster.tf), so their traffic does reach this phase. Dropping
# it removes a real edge control and leaves those hosts unpoliced at the edge;
# `docs/core/backrest.md` records the residual, its cost and the trigger for
# revisiting the choice.
#
# `agent-hooks` is deliberately absent: its deliveries are individually
# authenticated and deduped, a shared per-IP budget would drop a legitimate burst
# from one provider, and the source cannot be identified before the request is
# parsed.
#
# Resource and ruleset names are historical; renaming forces a replacement,
# which the lifecycle block forbids.
resource "cloudflare_ruleset" "dav_rate_limit" {
  zone_id = data.cloudflare_zone.this.zone_id
  name    = "dav rate limit"
  kind    = "zone"
  phase   = "http_ratelimit"

  # Empty by design: the one rule this slot held rate limited the Backrest
  # login endpoint on `recovery`, and the reader moved off Cloudflare (T2,
  # `recovery` is a grey A record at the edge now). The guard enforces the same
  # 10-per-10-s budget itself, because a host with no Cloudflare in front of it
  # gets nothing from this phase. The slot stays empty rather than going to
  # `music`/`ntfy`: giving them a budget is a change to their behaviour, not the
  # retirement of a dead control, and it belongs in its own reviewed change.
  rules = []

  lifecycle {
    prevent_destroy = true
  }
}
