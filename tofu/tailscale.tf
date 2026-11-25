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
# Credentials come from the environment and are never authored here, and they
# are not one credential everywhere (design #841). An apply holds the admin-only
# client with the `policy_file` scope, which can rewrite the whole tailnet
# (TAILSCALE_OAUTH_CLIENT_ID and TAILSCALE_OAUTH_CLIENT_SECRET, from
# secrets/tailscale.yaml locally and the `cloudflare` environment in CI). The
# pre-merge plan holds a client that reads and cannot write, because on a
# `pull_request` the workflow that runs is the PR head's; `scopes` below is
# where the plan says what it asks that client for. A provider configures even
# when `tailnet` is empty, so every tofu job in CI still needs a pair.

locals {
  # The plan's whole authority (design #841). `policy_file:read` reads,
  # validates and previews the policy, which is every Tailscale call a plan
  # makes; `devices:core:read` and `devices:posture_attributes:read` are the
  # pair the API requires beside it; `services:read` refreshes the Service
  # resources. Asking for exactly these is what keeps a plan from minting a token
  # that could save a policy, delete a device or rewrite a Service, and a client
  # granted less fails the plan at configure time.
  tailscale_plan_scopes = [
    "policy_file:read",
    "devices:core:read",
    "devices:posture_attributes:read",
    "services:read",
  ]
}

provider "tailscale" {
  # Set only for the pre-merge plan, which passes TF_VAR_tailscale_readonly
  # (#841 T1) and probes its client until a policy write answers 403; drift
  # follows on its own task. An apply leaves it false and takes the write
  # client's own scopes, because it writes the policy, the tags and the
  # Services. `null` is "ask for no narrowing", not "ask for nothing".
  scopes = var.tailscale_readonly ? local.tailscale_plan_scopes : null
}

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
        # Serve publishes the applications as HTTPS on the host itself, one
        # root path per port (scripts/tailscale-serve.sh): 443 Immich, 8443
        # OPDShelf, 8448 Navidrome and 10000 the Syncthing GUI. 8444 and 8445
        # are the personal and general agent UIs, separate authority domains
        # behind separate passwords, so the edge and CI stay off them (the deny
        # tests below).
        action = "accept"
        src    = ["group:owner"]
        dst    = ["tag:smortress:443", "tag:smortress:8443", "tag:smortress:8444", "tag:smortress:8445", "tag:smortress:8448", "tag:smortress:10000"]
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
        # The deploy receiver (design #798) and the names probe (#848). A CI job
        # carries tag:deploy for the length of one run and may reach the
        # receiver's tailnet-served TCP forward on loopback and, through the
        # grants below, one port on each of the six Services the probe reads.
        # Every other port on the host stays owner-only, and the deny test below
        # keeps it that way.
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

    # A Service VIP is an address the tailnet owns rather than one a device
    # holds, so it cannot be named as an `acl` destination: that form is a host's
    # port, and the VIP is no host. A grant names the service instead, and the
    # owner reaches all six Services (design #834). The CI names probe (#848)
    # holds a second grant on each of the same six, which is worth nothing unless
    # the prober is not the owner; nothing else has asked for any of them.
    #
    # One grant per application instead of one fronting all of them is the
    # narrower surface, not the wider one: each granted VIP is a Service that
    # terminates at exactly one application on one port, so the admitted set can
    # be read off this list. The Service that fronted the `sammohr.dev` aliases
    # carried everything behind one Caddy, and any route that proxy grew was
    # reachable from CI with no policy change at all; a seventh application now
    # needs a seventh grant and a line in the tests below.
    grants = [
      {
        # OPDShelf's Service, the first application off the per-port scheme. The
        # port is the same 443 and the destination is a different service, so this
        # grant widens nothing the UI's grants already admitted: a Service VIP is
        # its own address, and the owner is the only client.
        src = ["group:owner"]
        dst = ["svc:opds"]
        ip  = ["443"]
      },
      {
        # The rest of the core apps off the per-port scheme, one owner grant each
        # for the same reason as the catalogue's.
        src = ["group:owner"]
        dst = ["svc:immich"]
        ip  = ["443"]
      },
      {
        src = ["group:owner"]
        dst = ["svc:navidrome"]
        ip  = ["443"]
      },
      {
        src = ["group:owner"]
        dst = ["svc:assistant"]
        ip  = ["443"]
      },
      {
        src = ["group:owner"]
        dst = ["svc:agent"]
        ip  = ["443"]
      },
      {
        # The Syncthing GUI's, owner-only for the same reason.
        src = ["group:owner"]
        dst = ["svc:sync"]
        ip  = ["443"]
      },
      {
        # The names probe, from `.github/workflows/verify-tailnet-names.yml`: a
        # node carrying tag:deploy for the length of one run resolves the six
        # names, verifies each certificate and reads each application's status
        # class. It is the one non-owner client, so it is also the only way the
        # names are proven to work for anyone but the owner. One grant per
        # Service, because the probe reads six VIPs and a grant is one
        # source/destination pair; the deny test for tag:deploy is what keeps it
        # a probe.
        src = ["tag:deploy"]
        dst = ["svc:immich"]
        ip  = ["443"]
      },
      {
        src = ["tag:deploy"]
        dst = ["svc:navidrome"]
        ip  = ["443"]
      },
      {
        src = ["tag:deploy"]
        dst = ["svc:assistant"]
        ip  = ["443"]
      },
      {
        src = ["tag:deploy"]
        dst = ["svc:agent"]
        ip  = ["443"]
      },
      {
        src = ["tag:deploy"]
        dst = ["svc:sync"]
        ip  = ["443"]
      },
      {
        src = ["tag:deploy"]
        dst = ["svc:opds"]
        ip  = ["443"]
      },
    ]

    # The advertisement is the host's own, so it approves itself: without an
    # auto-approver every re-advertise waits for the owner to approve it by hand
    # and the VIP stays dark until someone notices.
    autoApprovers = {
      services = {
        "svc:opds"      = ["tag:smortress"]
        "svc:immich"    = ["tag:smortress"]
        "svc:navidrome" = ["tag:smortress"]
        "svc:assistant" = ["tag:smortress"]
        "svc:agent"     = ["tag:smortress"]
        "svc:sync"      = ["tag:smortress"]
      }
    }

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
        accept = ["tag:smortress:22", "tag:smortress:443", "tag:smortress:8443", "tag:smortress:8444", "tag:smortress:8445", "tag:smortress:8448", "tag:smortress:10000", "tag:smortress:22000", "tag:vps:22", "svc:opds:443", "svc:immich:443", "svc:navidrome:443", "svc:assistant:443", "svc:agent:443", "svc:sync:443"]
      },
      {
        # The owner reaches the edge login, never the edge's upstream ports and
        # never the deploy receiver: 8446/8447 belong to tag:vps and 8484 to CI.
        # A rule that widened either would fail here.
        src  = var.tailscale_login
        deny = ["tag:smortress:8446", "tag:smortress:8447", "tag:smortress:8484"]
      },
      {
        src  = "tag:untrusted"
        deny = ["tag:smortress:22", "tag:smortress:443", "tag:smortress:8443", "tag:smortress:8444", "tag:smortress:8445", "tag:smortress:8448", "tag:smortress:10000", "tag:smortress:22000", "tag:smortress:8446", "tag:smortress:8447", "tag:vps:22", "svc:opds:443", "svc:immich:443", "svc:navidrome:443", "svc:assistant:443", "svc:agent:443", "svc:sync:443"]
      },
      {
        # The edge reaches the two Serve ports and nothing else: no sshd, no
        # agent gateway, no Syncthing, no deploy receiver, no Service VIP.
        src    = "tag:vps"
        accept = ["tag:smortress:8446", "tag:smortress:8447"]
      },
      {
        src  = "tag:vps"
        deny = ["tag:smortress:22", "tag:smortress:443", "tag:smortress:8443", "tag:smortress:8444", "tag:smortress:8445", "tag:smortress:8448", "tag:smortress:10000", "tag:smortress:22000", "tag:smortress:8484", "svc:opds:443", "svc:immich:443", "svc:navidrome:443", "svc:assistant:443", "svc:agent:443", "svc:sync:443"]
      },
      {
        # The deploy node reaches the receiver and, through the grants above, one
        # port on each of the six Services the names probe reads; those seven are
        # the whole admitted set for the tag. Another destination has to be added
        # here or this list fails the policy save.
        src    = "tag:deploy"
        accept = ["tag:smortress:8484", "svc:immich:443", "svc:navidrome:443", "svc:assistant:443", "svc:agent:443", "svc:sync:443", "svc:opds:443"]
      },
      {
        # Everything else stays closed to tag:deploy. A deny test may not name a
        # destination a grant admits, so no Service destination appears here: all
        # seven are admitted to some source, six of them to this tag. The
        # remaining entries are every host port and edge login any rule admits.
        src  = "tag:deploy"
        deny = ["tag:smortress:22", "tag:smortress:443", "tag:smortress:8443", "tag:smortress:8444", "tag:smortress:8445", "tag:smortress:8448", "tag:smortress:10000", "tag:smortress:22000", "tag:smortress:8446", "tag:smortress:8447", "tag:vps:22"]
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

  # The tag and the Services must exist before a rule names them, or the policy
  # names a tag no device carries and a service the tailnet does not have, and
  # the validator refuses it: the route would close in the same apply that opens
  # it.
  depends_on = [tailscale_device_tags.smortress, tailscale_service.opds, tailscale_service.immich, tailscale_service.navidrome, tailscale_service.assistant, tailscale_service.agent, tailscale_service.sync]

  # This resource is the whole policy, not a patch: the provider refuses to
  # replace a policy it did not write unless that is said out loud, and the
  # design's admitted set is the point of the apply. Rules dropped here are
  # dropped from the tailnet.
  overwrite_existing_content = true

  acl = jsonencode(local.tailnet_policy)
}

# OPDShelf's own Service: the first application off the per-port scheme. A Service
# gives the application a name of its own instead of a second port on the host's,
# and Tailscale terminates TLS there and issues the certificate for that name, so
# `https://opds.<tailnet>.ts.net/` is a URL the catalogue owns. This is also the
# experiment that proves Tailscale issues a certificate for a Service FQDN; the
# host's 8443 route (scripts/tailscale-serve.sh) stays as the rollback until it
# has. Owner-only: the ACL grants nothing but `group:owner` to it.
resource "tailscale_service" "opds" {
  count = var.tailnet == "" ? 0 : 1

  name  = "svc:opds"
  ports = ["tcp:443"]
}

# The rest of the core apps off the per-port scheme, the same shape and the same
# reason as OPDShelf's: a Service gives the application a name of its own instead
# of a second port on the host's, and Tailscale terminates TLS there and issues
# the certificate for that name, so `https://immich.<tailnet>.ts.net/` and its
# three siblings are URLs the applications own. The host routes in
# scripts/tailscale-serve.sh (443, 8448, 8444, 8445) stay as the rollback, so this
# is additive. Owner-only, like the catalogue's.
resource "tailscale_service" "immich" {
  count = var.tailnet == "" ? 0 : 1

  name  = "svc:immich"
  ports = ["tcp:443"]
}

resource "tailscale_service" "navidrome" {
  count = var.tailnet == "" ? 0 : 1

  name  = "svc:navidrome"
  ports = ["tcp:443"]
}

# The personal web UI on 127.0.0.1:18006. The `sammohr.dev` alias Caddy used to
# answer for it is gone with that terminator; this Service is the name it owns.
resource "tailscale_service" "assistant" {
  count = var.tailnet == "" ? 0 : 1

  name  = "svc:assistant"
  ports = ["tcp:443"]
}

resource "tailscale_service" "agent" {
  count = var.tailnet == "" ? 0 : 1

  name  = "svc:agent"
  ports = ["tcp:443"]
}

# The Syncthing GUI's own Service, the same shape as the rest now that its host
# check is off (docs/manual-steps.md): Serve forwards the client's Host unchanged,
# and with the check on the GUI answers 403 to the name. The host's 10000 route
# stays as the rollback.
resource "tailscale_service" "sync" {
  count = var.tailnet == "" ? 0 : 1

  name  = "svc:sync"
  ports = ["tcp:443"]
}
