# Public identifiers for the zone, so an apply needs no exports. The provider
# credential is the only input that still comes from the environment; everything
# here is an identifier that docs/ prints anyway, and the tests assert this file
# carries no credential.
#
# The cluster host set normally follows `local.cluster_ingress` in
# tofu/cluster.tf, so DNS moves with the tunnel route. It is pinned here for the
# edge cutover (#725): `photos` and `opds` have to leave the cluster tunnel in a
# commit of their own, because Cloudflare refuses two records at one name and an
# apply cannot order a CNAME destroy before an A create. Delete this line once
# #709 retires their ingress rules.

account_id = "385f7d47e2e8438fbda5d6f76d760434"
domain     = "sammohr.dev"
email      = "sam@sammohr.dev"
# The same account as `email`, but the identity Tailscale itself asserts: a
# GitHub-linked login, not the IdP address. Tailscale accepts an unknown member
# in a group without error and then admits nobody, which is how the first apply
# locked the tailnet out (manual-steps section 46).
tailscale_login   = "smores56@github"
host_tunnel_id    = "583026c2-4efb-453b-8392-3ce6dfcfa0d0"
cluster_tunnel_id = "16a461e2-b28e-4535-b79d-eca2f6e9b001"

# Empty until the in-VM CSR client has registered; see docs/manual-steps.md
# step 16. The CAA records are created only once this is set.
acme_account_id = ""

cluster_hosts = ["agent", "agent-hooks", "memory", "music", "ntfy"]

# The public edge VPS (#725). Setting it creates the two grey-cloud A
# records; the previous commit already took both names off the cluster
# tunnel. Rollback: drop this value, then restore cluster_hosts.
edge_ipv4 = "192.236.188.99"

# The tailnet's name: the label before `.ts.net` MagicDNS names everything on
# it. Naming it is what creates the ACL in tofu/tailscale.tf; an empty value
# plans nothing about the tailnet.
tailnet = "stonecat-jazz"
