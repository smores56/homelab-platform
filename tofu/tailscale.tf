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
        # OPDShelf and 8448 Navidrome. 8444 and 8445 are the personal and general
        # agent UIs, separate authority domains behind separate passwords, so the
        # edge and CI stay off them (the deny tests below). The Syncthing GUI is
        # not here: since #897 T2 it is reachable only as `svc:sync`, so no host
        # port on 10000 exists to grant.
        action = "accept"
        src    = ["group:owner"]
        dst    = ["tag:smortress:443", "tag:smortress:8443", "tag:smortress:8444", "tag:smortress:8445", "tag:smortress:8448"]
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
        # keeps it that way. The edge's receiver is the same shape and has its
        # own rule below (design #939, T11).
        action = "accept"
        src    = ["tag:deploy"]
        dst    = ["tag:smortress:8484"]
      },
      {
        # The edge's deploy receiver (design #939, T11). This is the whole of the
        # widening: the lowest-trust identity in the tailnet -- an ephemeral CI
        # node -- gains reach on the public box, on one port and no other, where
        # before it could reach none of the edge. The HMAC secret is the second
        # factor: without it the receiver answers 401 and queues nothing, so this
        # rule is admission to a port and not authentication to a deploy. The
        # deny tests below pin every other port on the edge to the owner, and
        # tag:deploy's own deny keeps the edge login shut.
        action = "accept"
        src    = ["tag:deploy"]
        dst    = ["tag:vps:8484"]
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
    # owner reaches all eight Services (design #834, plus the reader's own path
    # back below). The CI names probe (#848) holds a second grant on each of the
    # six it reads, which is worth nothing unless the prober is not the owner; the
    # public edge (#725, #953) holds the only grant on the three it proxies.
    #
    # One grant per application instead of one fronting all of them is the
    # narrower surface, not the wider one: each granted VIP is a Service that
    # terminates at exactly one application on one port, so the admitted set can
    # be read off this list. The Service that fronted the `sammohr.dev` aliases
    # carried everything behind one Caddy, and any route that proxy grew was
    # reachable from CI with no policy change at all; another application now
    # needs another grant and a line in the tests below.
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
        # The zellij web terminal's, owner-only for the same reason: the tailnet
        # is the first gate and the login token the second (#954).
        src = ["group:owner"]
        dst = ["svc:terminal"]
        ip  = ["443"]
      },
      {
        # The recovery reader's owner grant. #953 narrowed this Service to the
        # edge alone, which left the reader reachable from exactly one place and
        # debuggable from none: a tailnet-only name that does not even resolve is
        # not a credential boundary the owner can use. The boundary that matters
        # is unchanged -- the reader still answers only its own login form, it is
        # still not granted to the probe or any tagged host, and the write denial
        # at the Backrest and R2 layers is still the control (docs/core/backrest.md,
        # "The read-only boundary").
        src = ["group:owner"]
        dst = ["svc:recovery"]
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
      {
        # The public edge (design #725) gets a grant apiece, on the same 443 the
        # owner reads: the VPS resolves the two names the applications own and
        # proxies to them, and each Service terminates at one application, so the
        # rule is narrower than any host port could be. This is the edge's only path
        # into the host -- a Service destination cannot be an `acl` destination, so
        # no host-port rule names it -- and never 443 on the host's own name, which
        # also carries the agent gateway APIs and the wallpaper tree, where a
        # port-scoped rule cannot express a path.
        src = ["tag:vps"]
        dst = ["svc:immich"]
        ip  = ["443"]
      },
      {
        src = ["tag:vps"]
        dst = ["svc:opds"]
        ip  = ["443"]
      },
      {
        # The recovery reader (SDLC #953). It runs on this host now, so
        # `recovery.sammohr.dev` is the edge proxying to a Service instead of
        # reaching a process on the VPS, and the corpus-read credential never
        # leaves the tailnet. A Service and not a host port, still: the host's 443
        # carries the agent gateway APIs and the wallpaper tree, and a
        # port-scoped rule cannot say "this path only". The owner's grant above is
        # the other half of its reachable set: two sources, owner and edge, and no
        # third -- in particular no probe grant, because a login form is not a
        # status class.
        src = ["tag:vps"]
        dst = ["svc:recovery"]
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
        "svc:terminal"  = ["tag:smortress"]
        "svc:recovery"  = ["tag:smortress"]
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
    # beside a new rule that opened 8443 or 22000.
    tests = [
      {
        src    = var.tailscale_login
        accept = ["tag:smortress:22", "tag:smortress:443", "tag:smortress:8443", "tag:smortress:8444", "tag:smortress:8445", "tag:smortress:8448", "tag:smortress:22000", "tag:vps:22", "svc:opds:443", "svc:immich:443", "svc:navidrome:443", "svc:assistant:443", "svc:agent:443", "svc:sync:443", "svc:terminal:443"]
      },
      {
        # The owner reaches the edge login, never either deploy receiver: the two
        # 8484s belong to tag:deploy. A rule that widened it would fail here.
        src  = var.tailscale_login
        deny = ["tag:smortress:8484", "tag:vps:8484"]
      },
      {
        src  = "tag:untrusted"
        deny = ["tag:smortress:22", "tag:smortress:443", "tag:smortress:8443", "tag:smortress:8444", "tag:smortress:8445", "tag:smortress:8448", "tag:smortress:22000", "tag:vps:22", "tag:vps:8484", "svc:opds:443", "svc:immich:443", "svc:navidrome:443", "svc:assistant:443", "svc:agent:443", "svc:sync:443", "svc:terminal:443", "svc:recovery:443"]
      },
      {
        # The edge reaches no host port at all. Its three destinations are Service
        # names from the grants above, and a Service destination cannot be named in
        # `acl` or in a test, so this deny of every other host port and edge login is
        # the whole guard: a rule that gave the tag a port would fail here. The
        # edge's own 8484 belongs to tag:deploy for the same reason as the
        # server's, so it is named here too.
        src  = "tag:vps"
        deny = ["tag:smortress:22", "tag:smortress:443", "tag:smortress:8443", "tag:smortress:8444", "tag:smortress:8445", "tag:smortress:8448", "tag:smortress:22000", "tag:smortress:8484", "tag:vps:8484", "svc:navidrome:443", "svc:assistant:443", "svc:agent:443", "svc:sync:443", "svc:terminal:443"]
      },
      {
        # The deploy node reaches both receivers -- the server's and, since T11,
        # the edge's -- and, through the grants above, one port on each of the six
        # Services the names probe reads; those eight are the whole admitted set for
        # the tag. Another destination has to be added here or this list fails the
        # policy save.
        src    = "tag:deploy"
        accept = ["tag:smortress:8484", "tag:vps:8484", "svc:immich:443", "svc:navidrome:443", "svc:assistant:443", "svc:agent:443", "svc:sync:443", "svc:opds:443"]
      },
      {
        # Everything else stays closed to tag:deploy. A deny test may not name a
        # destination a grant admits, so neither Service destination nor the two
        # 8484s appear here: the first eight are admitted to some source, six of
        # them to this tag, and both receivers to this tag alone. The remaining
        # entries are every host port and edge login any rule admits -- the edge's
        # login included, which is what keeps the one port T11 opened from being
        # the first of several.
        src  = "tag:deploy"
        deny = ["tag:smortress:22", "tag:smortress:443", "tag:smortress:8443", "tag:smortress:8444", "tag:smortress:8445", "tag:smortress:8448", "tag:smortress:22000", "tag:vps:22"]
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
  depends_on = [tailscale_device_tags.smortress, tailscale_service.opds, tailscale_service.immich, tailscale_service.navidrome, tailscale_service.assistant, tailscale_service.agent, tailscale_service.sync, tailscale_service.terminal]

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

# The personal workspace on 127.0.0.1:18008. The `sammohr.dev` alias Caddy used to
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

# The Syncthing GUI's own Service, the same shape as the rest: Serve forwards the
# client's Host unchanged and the GUI's check is on (design #897, T2), so the route
# reaches a loopback proxy that rewrites Host to the one address the GUI trusts.
# This name is the GUI's only way in; the old host route on 10000 is retired.
resource "tailscale_service" "sync" {
  count = var.tailnet == "" ? 0 : 1

  name  = "svc:sync"
  ports = ["tcp:443"]
}

# The zellij web terminal, the same shape and the same reason: zellij binds
# 127.0.0.1:8082 (units/systemd/smortress-zellij-web.service) and Serve terminates
# TLS for the Service name, so `https://terminal.<tailnet>.ts.net/` is the URL the
# terminal owns. Owner-only, and never probed: `tag:deploy` gets no grant.
resource "tailscale_service" "terminal" {
  count = var.tailnet == "" ? 0 : 1

  name  = "svc:terminal"
  ports = ["tcp:443"]
}

# The recovery reader's own Service (SDLC #953). The reader answers on
# 127.0.0.1:9898 behind its read-only guard
# (units/systemd/smortress-backrest.service), Serve terminates TLS for the
# Service name, and the public edge proxies `recovery.sammohr.dev` to it over the
# tailnet instead of to a process on the VPS. That is what keeps the corpus-read
# credential off the public box. Granted to `tag:vps` alone: the owner reads the
# public name like everyone else, and the reader's password is the only login.
resource "tailscale_service" "recovery" {
  count = var.tailnet == "" ? 0 : 1

  name  = "svc:recovery"
  ports = ["tcp:443"]
}
