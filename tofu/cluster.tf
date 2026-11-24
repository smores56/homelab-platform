# The names the public edge serves (design #725). This file held the cluster
# tunnel: its ingress map, its remotely-managed config and the DNS set derived
# from them. SDLC #833 retired all three with the tunnel, so what is left is the
# desired state of the edge alone.
locals {
  # The names the A records point at the VPS. They were the cluster tunnel's
  # until the grey-cloud records replaced their CNAMEs, so nothing here names a
  # tunnel any more.
  edge_hosts     = ["photos", "opds", "recovery"]
  edge_dns_hosts = var.edge_ipv4 == "" ? [] : local.edge_hosts

  # Names whose origin is the VPS itself, not a tunnel route. The recovery
  # reader reads R2 directly and never had one.
  edge_only_hosts = ["recovery"]
}
