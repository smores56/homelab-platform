# Public identifiers for the zone, so an apply needs no exports. The provider
# credential is the only input that still comes from the environment; everything
# here is an identifier that docs/ prints anyway, and the tests assert this file
# carries no credential.

account_id = "385f7d47e2e8438fbda5d6f76d760434"
domain     = "sammohr.dev"
# The identity Tailscale itself asserts: a GitHub-linked login, not an identity
# provider's address. Tailscale accepts an unknown member in a group without
# error and then admits nobody, which is how the first apply locked the tailnet
# out (docs/core/server-image.md, "Access: the tailnet policy, sshd, and sudo").
tailscale_login = "smores56@github"

# The public edge VPS (#725). Setting it creates the grey-cloud A records, which
# are the only records the edge names have (SDLC #833 retired the cluster
# tunnel's CNAMEs). Rollback: drop this value.
edge_ipv4 = "192.236.188.99"

# The tailnet's name: the label before `.ts.net` MagicDNS names everything on
# it. Naming it is what creates the ACL in tofu/tailscale.tf; an empty value
# plans nothing about the tailnet.
tailnet = "stonecat-jazz"
