# Public identifiers for the zone, so an apply needs no exports. The provider
# credential is the only input that still comes from the environment; everything
# here is an identifier that docs/ prints anyway, and the tests assert this file
# carries no credential.
#
# The cluster host set is not here on purpose: it follows `local.cluster_ingress`
# in tofu/cluster.tf, so DNS moves with the tunnel route.

account_id        = "385f7d47e2e8438fbda5d6f76d760434"
domain            = "sammohr.dev"
email             = "sam@sammohr.dev"
host_tunnel_id    = "583026c2-4efb-453b-8392-3ce6dfcfa0d0"
cluster_tunnel_id = "16a461e2-b28e-4535-b79d-eca2f6e9b001"

# Created in the dashboard (remotely managed); paste its UUID, then merge: the
# ssh DNS record and its ingress are written by the same apply.
ssh_tunnel_id = "bc44b9af-3d18-496b-8ef2-f6e6f73f5fad"

# Empty until the in-VM CSR client has registered; see docs/manual-steps.md
# step 16. The CAA records are created only once this is set.
acme_account_id = ""

# The tailnet's name: the label before `.ts.net` MagicDNS names everything on
# it. Naming it is what creates the ACL in tofu/tailscale.tf; an empty value
# plans nothing about the tailnet.
tailnet = "stonecat-jazz"
