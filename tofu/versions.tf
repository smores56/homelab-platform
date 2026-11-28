# Cloudflare zone, Access, tunnel routes and DNS for sammohr.dev, plus the
# tailnet policy that admits SSH to smortress (tofu/tailscale.tf, design #767).
#
# Moved here from nix-config's `tofu/` (SDLC #581). The resource addresses are
# the ones the operator's state already holds, so the move is a state-directory
# copy, not a re-import; renaming an address would need `tofu state rm` plus
# `import`.
#
# Provider v5 names only:
#   cloudflare_dns_record                    (was cloudflare_record)
#   cloudflare_zero_trust_access_application (was cloudflare_access_application)
#   cloudflare_zero_trust_access_policy      (was cloudflare_access_policy)
#   destinations                             (was self_hosted_domains; supersedes `domain`)
#
# State is operator-owned and never in git: an apply runs from a checkout with
# its own state directory. No secret is an input: CLOUDFLARE_API_TOKEN comes
# from the environment (`cloudflare` Actions environment or a sops-decrypted
# file), and no variable carries a token. The Tailscale provider reads its OAuth
# client from TAILSCALE_OAUTH_CLIENT_ID / TAILSCALE_OAUTH_CLIENT_SECRET the same
# way, so both providers are configured from the environment and neither has a
# credential in the repository.

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
    # The tailnet policy (tofu/tailscale.tf). The 0.29 line is the framework
    # provider that validates the policy against the API at plan time, tests
    # included, so a widening rule fails before it is applied.
    tailscale = {
      source  = "tailscale/tailscale"
      version = "~> 0.29.0"
    }
  }
}

provider "cloudflare" {}

# `tailscale` is configured in tofu/tailscale.tf, next to the resource it serves.
