# Cloudflare zone and tailnet policy, as code

This directory is the whole Cloudflare account's edge config: DNS records and the
tailnet policy. The Access applications and the host and cluster tunnels are
retired (SDLC #833). `docs/cloudflare.md` explains the shape; this file only
says how a change travels. SSH is deliberately absent: it is tailnet-only
(design #767), so no record, no tunnel ingress, no Access application and no
service token names it.

`tailscale.tf` is the other half of the edge from design #767 on: the tailnet
policy that admits the owner's devices to `smortress:22`, to Serve's HTTPS ports
and to Syncthing, and to nothing else. `tailscale_acl` replaces the whole policy
file, so treat a change to it as the tailnet's entire access model — and read the
`tests` block as the assertion it is, because the Tailscale API refuses to save a
policy whose tests fail. The resource is gated on `tailnet` in
`terraform.tfvars`, and its provider authenticates with
`TAILSCALE_OAUTH_CLIENT_ID` / `TAILSCALE_OAUTH_CLIENT_SECRET`: the apply's OAuth
client, with the `policy_file` scope. Both providers take their credentials from
the environment; nothing here holds one.

1. Branch, change `tofu/`, open a PR. `tofu plan` is a required check: it plans
   against the live state with read-only credentials and comments the plan on
   the PR. Read the plan, not only the diff — a renamed `for_each` key is a
   replacement.
2. Merge. `tofu-apply.yml` plans again and applies the saved plan. A plan that
   replaces or destroys anything stops instead, and waits for an owner dispatch.
3. Outside changes (dashboard edits) show up as a weekly `tofu-drift` issue.

State lives in the `homelab-tofu-state` R2 bucket (`backend.tf`), never in git.
The write credentials exist only in the `cloudflare` environment; the read-only
pair and the read-only Cloudflare token exist only in `cloudflare-plan`. The
apply's Tailscale client is `TAILSCALE_OAUTH_CLIENT_ID` /
`TAILSCALE_OAUTH_CLIENT_SECRET` in `cloudflare`. The pre-merge plan holds a
client of its own, `TAILSCALE_PLAN_OAUTH_CLIENT_*` in `cloudflare-plan`, granted
`policy_file:read`, `devices:core:read`, `devices:posture_attributes:read` and
`services:read` (design #841): `scopes` in `tailscale.tf` is what the plan asks
for, and `tofu-plan-pr.yml` probes the client until a policy write answers 403.
A provider configures even when `tailnet` is empty, so every tofu job stops until
its pair exists. `cloudflare-plan` holds only the plan pair; the weekly drift check plans with it
too.
