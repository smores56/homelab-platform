# The cluster tunnel's remotely-managed ingress (SDLC #583).
#
# `cloudflared` in the `ingress` namespace runs with a tunnel token, so its
# hostname rules live in Cloudflare rather than in a local config file. This
# resource is that configuration, so a dashboard edit is replaced by the next
# apply (docs/manual-steps.md step 20 has the operator order).
#
# `local.cluster_ingress` is the single mapping from a subdomain to the
# in-cluster origin. It has to move in lockstep with `var.cluster_hosts`: DNS
# sends the name to this tunnel, and without an ingress rule it would land on
# the catch-all. The precondition below refuses that partial cutover.
locals {
  cluster_ingress = {
    # `memory` is the wrapper's Service in the cluster (SDLC #617). The host's
    # `memory-forward` socat hop and its own route stay until this one answers
    # 200 through Access; nothing here removes either.
    agent       = "http://nanobot.tenant-apps.svc.cluster.local:80"
    agent-hooks = "http://webhook.webhook.svc.cluster.local:8080"
    memory      = "http://memory-mcp.graphiti.svc.cluster.local:8182"
    music       = "http://navidrome.navidrome.svc.cluster.local:4533"
    # The notification bus (SDLC #649). Its own namespace, so the route names
    # the Service rather than a tenant app.
    ntfy   = "http://ntfy.notify.svc.cluster.local:8080"
    opds   = "http://opdshelf.opdshelf.svc.cluster.local:8083"
    photos = "http://immich-server.immich.svc.cluster.local:2283"
  }

  # The two names the public edge serves (design #725). They stay on the cluster
  # tunnel until `edge_ipv4` is set. The plan then holds a destroy and a create
  # at the same name, which OpenTofu cannot order against each other and
  # Cloudflare refuses to hold at once, so the cutover is applied in two steps
  # (docs/core/public-edge.md, "DNS and the cutover"): the cluster records first
  # with -target, the A records after. The comments here describe the desired
  # state, not a race-free apply.
  edge_hosts     = ["photos", "opds", "recovery"]
  edge_dns_hosts = var.edge_ipv4 == "" ? [] : local.edge_hosts

  # Names whose origin is the VPS itself, not a tunnel route. The recovery
  # reader reads R2 directly and never had one, so there is no cluster record
  # for it to fall back to and the DNS precondition has to admit that.
  edge_only_hosts = ["recovery"]

  # The DNS set follows the ingress map unless explicitly pinned, so a cutover
  # is one edit here and the two cannot disagree. The edge names leave it only
  # when their own record exists, which keeps the tunnel as the fallback while
  # the cutover has not happened.
  cluster_hosts = setsubtract(
    var.cluster_hosts == null ? sort(keys(local.cluster_ingress)) : var.cluster_hosts,
    local.edge_dns_hosts,
  )

  # Ordered rules; the catch-all is appended last and must stay last.
  cluster_ingress_rules = [
    for host in sort(keys(local.cluster_ingress)) : {
      hostname = "${host}.${var.domain}"
      service  = local.cluster_ingress[host]
    }
  ]
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "cluster" {
  # No tunnel yet means no config to manage: an empty `cluster_tunnel_id`
  # otherwise reaches the API as an invalid UUID. The count keeps a
  # credential-free plan working before the tunnel exists.
  count = var.cluster_tunnel_id == "" ? 0 : 1

  account_id = var.account_id
  tunnel_id  = var.cluster_tunnel_id

  config = {
    # The catch-all keeps the same object shape (`hostname = null`) so the list
    # is one type; cloudflared requires it to be the last rule.
    ingress = concat(local.cluster_ingress_rules, [{ hostname = null, service = "http_status:404" }])
  }

  lifecycle {
    precondition {
      condition     = alltrue([for host in local.cluster_hosts : contains(keys(local.cluster_ingress), host)])
      error_message = "cluster_hosts names a hostname with no cluster_ingress rule: add it in tofu/cluster.tf before moving the DNS record."
    }
  }
}
