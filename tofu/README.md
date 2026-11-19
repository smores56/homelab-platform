# Cloudflare zone and tailnet policy, as code

This directory is the whole Cloudflare account's edge config: DNS records, the
cluster tunnel's ingress rules, Access applications and policies, and the
recovery pages project. `docs/cloudflare.md` explains the shape; this file only
says how a change travels.

`tailscale.tf` is the other half of the edge from design #767 on: the tailnet
policy that admits the owner's devices to `smortress:22`, to Serve's HTTPS ports
and to Syncthing, and to nothing else. `tailscale_acl` replaces the whole policy
file, so treat a change to it as the tailnet's entire access model — and read the
`tests` block as the assertion it is, because the Tailscale API refuses to save a
policy whose tests fail. The resource is gated on `tailnet` in
`terraform.tfvars`, and its provider authenticates with
`TAILSCALE_OAUTH_CLIENT_ID` / `TAILSCALE_OAUTH_CLIENT_SECRET`: an OAuth client
with the `policy_file` scope only, minted per `docs/manual-steps.md` section 46.
Both providers take their credentials from the environment; nothing here holds
one.

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
Tailscale OAuth client is the environment secrets
`TAILSCALE_OAUTH_CLIENT_ID` and `TAILSCALE_OAUTH_CLIENT_SECRET`, in both
environments, because the provider configures even when `tailnet` is empty: every
tofu job stops there until the pair exists. `policy_file` has no read-only scope,
so the pre-merge plan holds a client that could write; a plan never saves the
policy, and the API's own tests are what make one safe to read.
