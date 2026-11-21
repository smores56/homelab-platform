# The tailnet policy (design #767, T1).
#
# sshd on smortress answers the tailnet and nothing else, so the rules that
# decide who may open port 22 are the network half of that login and belong
# beside the zone, in code. `tailscale_acl` replaces the whole policy file: this
# is the tailnet, not a patch on it, and anything no rule accepts is dropped.
#
# Everything is gated on var.tailnet. An empty value means the owner has not
# named the tailnet yet, so the resource has no instances and nothing about the
# tailnet is planned from a checkout that only manages the zone.
#
# Credentials come from the environment and are never authored here:
# TAILSCALE_OAUTH_CLIENT_ID and TAILSCALE_OAUTH_CLIENT_SECRET, the admin-only
# OAuth client with the `policy_file` scope (secrets/tailscale.yaml locally). CI
# supplies the same two values from the environment secrets of those names in
# `cloudflare` and `cloudflare-plan`, and a provider configures even when
# `tailnet` is empty, so every tofu job in CI needs them. This policy is the
# only network half: Tailnet Lock is deliberately not used, so what a joined
# node may reach is exactly what these rules accept and nothing else.
provider "tailscale" {}

locals {
  tailnet_policy = {
    # The host the rules name, resolved here rather than left to the API's
    # device-name lookup: an explicit hosts entry is what the policy validator
    # accepts in both rules and tests, and the address is the node's stable
    # tailnet IP.
    hosts = {
      smortress = "100.122.171.11"
    }

    # An access rule only ever accepts; anything no rule accepts is dropped, so
    # the default is deny without a rule saying so.
    acls = [
      {
        # The owner's laptops reach sshd. This is the rule the feature exists
        # for, and it is the only one that opens port 22 anywhere in the tailnet.
        action = "accept"
        src    = ["group:owner"]
        dst    = ["smortress:22"]
      },
      {
        # Serve publishes the applications as HTTPS on the host itself, on the
        # three ports it can give a root path to (scripts/tailscale-serve.sh).
        action = "accept"
        src    = ["group:owner"]
        dst    = ["smortress:443", "smortress:8443", "smortress:10000"]
      },
      {
        # Syncthing syncs between the laptops and the host. It is not HTTP, so
        # Serve cannot front it; the port is in the tailscale firewalld zone.
        action = "accept"
        src    = ["group:owner"]
        dst    = ["smortress:22000"]
      },
    ]

    # One group, one member: the owner identity the zone already pins. A tailnet
    # whose login is a different address fails at plan time with the API's own
    # message rather than admitting nobody silently.
    groups = {
      "group:owner" = [var.email]
    }

    # tagOwners exists for the deny test below: a node carrying tag:untrusted is
    # not a member of the owner group, so it reaches nothing on smortress, and
    # the policy refuses to save if a rule ever makes it reachable.
    tagOwners = {
      "tag:untrusted" = ["group:owner"]
    }

    # The Tailscale API evaluates these every time the policy is saved, so a rule
    # that widens access fails the plan and never reaches the tailnet.
    tests = [
      {
        src    = var.email
        accept = ["smortress:22"]
      },
      {
        src  = "tag:untrusted"
        deny = ["smortress:22", "smortress:443"]
      },
    ]
  }
}

# gated: a checkout with no tailnet named plans nothing here
resource "tailscale_acl" "this" {
  count = var.tailnet == "" ? 0 : 1

  # This resource is the whole policy, not a patch: the provider refuses to
  # replace a policy it did not write unless that is said out loud, and the
  # design's admitted set is the point of the apply. Rules dropped here are
  # dropped from the tailnet.
  overwrite_existing_content = true

  acl = jsonencode(local.tailnet_policy)
}
