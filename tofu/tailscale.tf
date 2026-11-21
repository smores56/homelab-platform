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
    # An access rule only ever accepts; anything no rule accepts is dropped, so
    # the default is deny without a rule saying so.
    acls = [
      {
        # The owner's laptops reach sshd. This is the rule the feature exists
        # for, and it is the only one that opens port 22 anywhere in the tailnet.
        action = "accept"
        src    = ["group:owner"]
        dst    = ["tag:smortress:22"]
      },
      {
        # Serve publishes the applications as HTTPS on the host itself, on the
        # three ports it can give a root path to (scripts/tailscale-serve.sh).
        action = "accept"
        src    = ["group:owner"]
        dst    = ["tag:smortress:443", "tag:smortress:8443", "tag:smortress:10000"]
      },
      {
        # The public edge (design #725). The VPS terminates public TLS and needs
        # the two dedicated Serve ports, never 443: 443 also carries the agent
        # gateway APIs and the wallpaper tree, and a port-scoped rule cannot
        # express a path. The edge is not in group:owner, so it never reaches
        # sshd on the host.
        action = "accept"
        src    = ["tag:vps"]
        dst    = ["tag:smortress:8446", "tag:smortress:8447"]
      },
      {
        # The owner reaches the edge's sshd and nothing else on it. The edge is
        # a public box, so its login is tailnet-only: the panel firewall refuses
        # 22 from the internet and this is the only rule that opens it.
        action = "accept"
        src    = ["group:owner"]
        dst    = ["tag:vps:22"]
      },
      {
        # The deploy receiver (design #798). A CI job carries tag:deploy for the
        # length of one run and may reach exactly one port: the receiver's
        # tailnet-served TCP forward on loopback. Every other port on the host
        # stays owner-only, and the deny test below keeps it that way.
        action = "accept"
        src    = ["tag:deploy"]
        dst    = ["tag:smortress:8484"]
      },
      {
        # Syncthing syncs between the laptops and the host. It is not HTTP, so
        # Serve cannot front it; the port is in the tailscale firewalld zone.
        action = "accept"
        src    = ["group:owner"]
        dst    = ["tag:smortress:22000"]
      },
    ]

    # One group, one member: the login Tailscale shows for the owner. It is not
    # the Access email: Tailscale accepts a member it does not know and admits
    # nobody, so this value has to be the tailnet's own `user@provider`.
    groups = {
      "group:owner" = [var.tailscale_login]
    }

    # tagOwners exists for the deny test below: a node carrying tag:untrusted is
    # not a member of the owner group, so it reaches nothing on smortress, and
    # the policy refuses to save if a rule ever makes it reachable.
    tagOwners = {
      "tag:untrusted" = ["group:owner"]
      # The CI deploy node. An OAuth client can only mint a key carrying a tag
      # its owner may apply, so the creator's group owns the tag; nothing else
      # in the tailnet carries it.
      "tag:deploy" = ["group:owner"]
      # The public edge. An OAuth client can only mint a key carrying a tag its
      # owner may apply, so the VPS joins with its own key and the owner group
      # owns the tag; nothing else in the tailnet may carry it.
      "tag:vps" = ["group:owner"]
      # The host's own tag. The ACL cannot name a device by hostname (the
      # validator wants an address), and a hosts alias pins the tailnet IP, so
      # the destination is a tag: it survives a reinstall that hands the node a
      # new address.
      "tag:smortress" = ["group:owner"]
    }

    # The Tailscale API evaluates these every time the policy is saved, so a rule
    # that widens access fails the plan and never reaches the tailnet. Both sides
    # list every admitted destination: a test naming only :22 would save cleanly
    # beside a new rule that opened 8443, 10000 or 22000.
    tests = [
      {
        src    = var.tailscale_login
        accept = ["tag:smortress:22", "tag:smortress:443", "tag:smortress:8443", "tag:smortress:10000", "tag:smortress:22000", "tag:vps:22"]
      },
      {
        src  = "tag:untrusted"
        deny = ["tag:smortress:22", "tag:smortress:443", "tag:smortress:8443", "tag:smortress:10000", "tag:smortress:22000", "tag:smortress:8446", "tag:smortress:8447", "tag:vps:22"]
      },
      {
        # The edge reaches the two Serve ports and nothing else: no sshd, no
        # agent gateway, no Syncthing, no deploy receiver.
        src    = "tag:vps"
        accept = ["tag:smortress:8446", "tag:smortress:8447"]
      },
      {
        src  = "tag:vps"
        deny = ["tag:smortress:22", "tag:smortress:443", "tag:smortress:8443", "tag:smortress:10000", "tag:smortress:22000", "tag:smortress:8484"]
      },
      {
        # The deploy node reaches the receiver and nothing else.
        src    = "tag:deploy"
        accept = ["tag:smortress:8484"]
      },
      {
        src  = "tag:deploy"
        deny = ["tag:smortress:22", "tag:smortress:443", "tag:smortress:8443", "tag:smortress:10000", "tag:smortress:22000", "tag:smortress:8446", "tag:smortress:8447", "tag:vps:22"]
      },
    ]
  }
}

# The host itself, tagged declaratively: a tag is the only stable name the
# policy validator accepts (a bare hostname is "invalid address", and a hosts
# alias pins the tailnet IP a reinstall would change). The data source resolves
# the device by its short hostname.
data "tailscale_device" "smortress" {
  count    = var.tailnet == "" ? 0 : 1
  hostname = "smortress"
}

resource "tailscale_device_tags" "smortress" {
  count     = var.tailnet == "" ? 0 : 1
  device_id = data.tailscale_device.smortress[0].node_id
  tags      = ["tag:smortress"]
}

# gated: a checkout with no tailnet named plans nothing here
resource "tailscale_acl" "this" {
  count = var.tailnet == "" ? 0 : 1

  # The tag must exist before a rule names it, or the policy names a tag no
  # device carries and the route closes in the same apply that opens it.
  depends_on = [tailscale_device_tags.smortress]

  # This resource is the whole policy, not a patch: the provider refuses to
  # replace a policy it did not write unless that is said out loud, and the
  # design's admitted set is the point of the apply. Rules dropped here are
  # dropped from the tailnet.
  overwrite_existing_content = true

  acl = jsonencode(local.tailnet_policy)
}
