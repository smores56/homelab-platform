# Cloudflare: DNS, tunnels and Access

`tofu/` in this repository is the only place the zone `sammohr.dev` is
described. It moved here from `nix-config/tofu/` (SDLC #581) so that every
object a diff can change is reviewed next to the manifests it fronts. `*.tf` is
Kanbei-critical (`docs/kanbei-critical.md`): the token can repoint a route.

## Ownership: two tunnels, one zone

| Tunnel | Runs where | Serves | Owner |
| --- | --- | --- | --- |
| Host tunnel | no connector: nix-config's `cloudflared` is retired, and the tunnel is locally managed and slated for retirement (#615) | nothing | human |
| Cluster tunnel | `cloudflared` in the `ingress` namespace (`clusters/homelab/ingress/`) | the apps the host no longer serves (`immich`, `music`, `opdshelf`, `memory`, `agent`, `notify`, `webhook`) | this repository |

SSH is not on either tunnel. It is tailnet-only (design #767): sshd answers the
tailnet and the firewall is the filter, so there is no connector, no `ssh` DNS
record and no `ssh` Access application to own (`docs/manual-steps.md#retire-the-cloudflare-ssh-route`,
`docs/manual-steps.md#the-tailnet-policy-sshd-and-sudo`).

`tofu/` owns DNS, Access, notifications and the ingress of the **cluster**
tunnel; it creates no connector. The cluster tunnel's DNS comes from
`var.cluster_hosts` and `var.cluster_tunnel_id` in `tofu/dns.tf`, and its
ingress from the `cluster` resource in `tofu/cluster.tf`. The host tunnel keeps
the wildcard record in `tofu/main.tf`; it is the default-deny net now, since the
names that used to resolve through it moved to the cluster or the tailnet.

`kanbei.sammohr.dev` is a **public hostname behind Access** (SDLC #586):
`tofu/kanbei.tf` creates the application and the wildcard record resolves the
name. Its origin was the nix-config `webProxy.services.kanbei` rule into the
guest relay, and that rule retired with nix-config. The name has no origin until
a connector publishes it again; the Access application still answers first, so
it is denied rather than exposed.

A private WARP hostname route and its Gateway L4 rewrite were retired on
2026-11-13. A private hostname needs Gateway to hand the client an
initial-resolved IP and rewrite the connection into the tunnel, which never
happened for either owner device; a public hostname needs no client component.
`tests/tofu/check.sh` asserts there is no private hostname route and no record
of its own.

The Cloudflare SSH route was deleted in #767's T6 and `tests/tofu/check.sh`
asserts its absence: no `ssh` DNS record, no tunnel ingress, no `ssh` Access
application, no dedicated service token and no `ssh_tunnel_id` variable. A plan
that offers to create any of them is a re-introduction, not a migration.

## Moved files

| nix-config | here | Note |
| --- | --- | --- |
| `tofu/main.tf` | `tofu/main.tf`, `tofu/dns.tf`, `tofu/access.tf`, `tofu/notifications.tf`, `tofu/rate-limit.tf` | split by object family; resource addresses unchanged |
| `tofu/pages.tf` | `tofu/pages.tf` | verbatim |
| `tofu/r2.tf` | `tofu/r2.tf` | verbatim |
| `tofu/variables.tf` | `tofu/variables.tf` | `tunnel_id` renamed `host_tunnel_id`, new cluster/ACME inputs |
| `tofu/versions.tf` | `tofu/versions.tf` | provider and zone lookup only |
| `tofu/.terraform.lock.hcl` | `tofu/.terraform.lock.hcl` | re-resolved to 5.28.1 on bootstrap |
| `tofu/.terraform/` | not copied | provider cache, never committed |

Resource addresses keep their old names (`cloudflare_dns_record.wildcard`,
`cloudflare_zero_trust_access_application.memory`, …) so the move is a state-file
copy rather than a re-import. Renaming one means `tofu state rm` plus `import`
with the ID format in `docs/manual-steps.md`.

## Provider v5

The config is v5-only (`~> 5.0`). What the naming means:

| v4 | v5 |
| --- | --- |
| `cloudflare_record` | `cloudflare_dns_record` |
| `cloudflare_access_application` | `cloudflare_zero_trust_access_application` |
| `cloudflare_access_policy` | `cloudflare_zero_trust_access_policy` |
| `self_hosted_domains` | `destinations` (a set of `{type, uri}`; `domain` still reads but `destinations` is what new blocks use) |
| `cloudflare_teams_*` | `cloudflare_zero_trust_*` |
| `cloudflare_tunnel_route` | `cloudflare_zero_trust_network_hostname_route` |
| `cloudflare_record` `data` for CAA | `cloudflare_dns_record` `data = { flags, tag, value }` |

The four older applications were written with `domain`; they now use
`destinations`, which the provider derives from the same API field. The first
plan after the move may show an in-place update for `domain`/`destinations` and
nothing else. A plan that says **replace** is wrong for this migration: stop and
compare, because the resources carry `prevent_destroy` and a replacement means
the state does not match the config.

## State

State is **remote** and never committed: `tofu/backend.tf` points the S3 backend
at this account's R2 endpoint, in the private `homelab-tofu-state` bucket under
`cloudflare/terraform.tfstate` (SDLC #622). Before that move it was an
operator-local file, so a lost checkout lost the only mapping between the config
and the live objects — the bucket is what makes CI and the operator plan against
the same state.

Two credentials reach it, both from the environment and neither in git:

| Variable | What it is | Where CI gets it |
| --- | --- | --- |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | the R2 key pair, scoped to `homelab-tofu-state` | `cloudflare` environment secrets `R2_STATE_ACCESS_KEY_ID` / `R2_STATE_SECRET_ACCESS_KEY` |
| `CLOUDFLARE_API_TOKEN` | the zone token | `cloudflare` environment secret |

Locally, `scripts/tofu-cloudflare.sh` decrypts both from this repository's
operator store (`secrets/cloudflare.yaml`: `cloudflare-api-token`,
`r2-state-access-key-id`, `r2-state-secret-access-key`) unless they are already
exported. The state pair is a separate token scoped to `homelab-tofu-state`;
the host's restic pair (`r2-access-key-id` / `r2-secret-access-key`, in
nix-config) is deliberately not accepted here. `AWS_DEFAULT_REGION` is set to
`auto`, because R2 has no regions.

State contents are object ids and attribute values — no token, no secret. R2
encrypts objects at rest, and there is no client-side state encryption because
there is no key to hold for it; the bucket's access is the control.

What the backend means for the workflows:

- `ci.yml` runs `tofu init -backend=false` + `tofu validate`, so PRs need no
  credential and no bucket;
- `tofu-plan-pr.yml` runs on every pull request and is the required check: it
  refuses forks, CI-touching diffs and executable HCL, then plans with the
  read-only credentials and comments the result on the PR. The merge is the
  approval, so this is the plan the reviewer reads;
- `tofu-apply.yml` runs on a merge to `main` (and on an owner dispatch). It inits
  against R2, runs `plan -detailed-exitcode -out=tfplan`, publishes the plan and
  applies that saved plan — never an auto-approve flag, and never from a plan that
  replaces or destroys a resource; those fail the run and wait for a dispatch;
- `tofu-drift.yml` is a weekly read-only plan for changes that came from outside
  the repository, and reports them through one `tofu-drift` issue.

Two environments carry the split. `cloudflare` holds the write token and the
write R2 pair and allows `main` only; `cloudflare-plan` holds the read-only pair
and allows `main` and `smores/*`, because the pre-merge plan runs on a PR
branch. A branch therefore cannot reach the write token even if its workflow
declares `environment: cloudflare`: the policy refuses it before any secret is
injected. `docs/manual-steps.md#environments-and-their-branch-policies` provisions both.

The state lives in R2 (`tofu/backend.tf`), and the operator secrets are staged with `docs/manual-steps.md#environments-and-their-branch-policies`:
back up the file, `init -migrate-state`, compare `tofu state list` before and
after, then delete the local copy. Do not run `init` with an empty or partial
state against this config: the first plan would propose creating every object
that already exists.

## Applying

```sh
# On smortress, from a homelab-platform checkout, as the operator.
./scripts/tofu-cloudflare.sh init -input=false
./scripts/tofu-cloudflare.sh plan -no-color
./scripts/tofu-cloudflare.sh apply -no-color
```

The account, apex, alert address and both tunnel ids come from the committed
`tofu/terraform.tfvars`; `acme_account_id` there stays empty until step 16. The
cluster host set is not a variable either — it follows `local.cluster_ingress`
in `tofu/cluster.tf`.

Two credentials are environment inputs, and the script is the one place that
fetches them: SOPS decrypts the operator store in this repository
checkout (override the path with `CLOUDFLARE_SECRETS_FILE`) for the zone token
and the R2 state pair, and preset variables skip SOPS entirely.

The R2 state is authoritative, and the script refuses to run while
`/var/lib/cloudflare-tofu` exists: a second state directory there plans a
whole-zone create that Cloudflare rejects object by object. Remove it, or set
`CLOUDFLARE_IGNORE_LEGACY_TOFU_DIR=1` if you know it is empty. A stale
`tofu/terraform.tfstate` in a checkout is equally dangerous for the opposite
reason — after the migration it is an orphan copy, so delete it rather than
letting a later `init` offer to copy it back.

No variable carries a tunnel secret, and none is a credential.

| Variable | Meaning |
| --- | --- |
| `account_id` | Cloudflare account tag |
| `domain` | apex zone |
| `email` | the only Access principal admitted, and the alert recipient |
| `host_tunnel_id` | UUID of the nix-config host tunnel |
| `cluster_tunnel_id` | UUID of the k3s tunnel; empty until it exists |
| `cluster_hosts` | subdomains routed to the cluster tunnel; unset by default, derived from `local.cluster_ingress` in `tofu/cluster.tf`. Pin it only to roll a single name back to the host tunnel |
| `acme_account_id` | numeric Let's Encrypt account pinned in CAA |
| `acme_directory` | ACME directory of that account (staging pins staging) |

## Access: default deny

`cloudflare_zero_trust_access_application.wildcard` covers `*.sammohr.dev` with
one allow policy (the owner's email). That is the default: a hostname under the
zone with no application of its own is reachable only by the owner's identity.

- **One label only.** Cloudflare wildcards stop at one label, so neither the
  wildcard record nor the wildcard application covers `a.b.sammohr.dev`, and
  the apex is not covered either. Nothing is served at either.
- **Specific wins.** A more specific application overrides the wildcard for its
  hostname; that is how the public and protected applications below co-exist
  with the deny default.
- **Bypass is unlogged.** Cloudflare evaluates bypass before allow and does not
  log bypassed requests, so a bypass application *is* the public surface. The
  set is `local.public_apps` in `tofu/access.tf` and nothing else:

  | Hostname | Why public |
  | --- | --- |
  | `photos.sammohr.dev` | mobile clients cannot complete an Access login; no edge rate limit since the slot moved to the reader |
  | `music.sammohr.dev` | same, for the Navidrome clients; same slot loss |
  | `opds.sammohr.dev` | OPDS readers and the web reader; the app's own login is the gate. Its per-IP edge budget went with the `http_ratelimit` slot (`docs/core/backrest.md`, "The single rate-limit slot") |
  | `agent-hooks.sammohr.dev` | GitHub delivers webhooks with no browser and no service token; the capability URL is the credential and the receiver verifies the source's HMAC (`docs/webhook.md`). Not rate limited |
  | `ntfy.sammohr.dev` | the notification bus (SDLC #649); the Android app cannot complete an Access login, and a service token cannot ride alongside the ntfy bearer the broker injects. ntfy's own auth is the gate — `deny-all` default, no signup, and its per-visitor request limiter |
  | `recovery.sammohr.dev` | the hosted Backrest reader (#707). Design #701 opens it so family can use it with nothing set up in advance, so the reader's own password is the only login and the login endpoint is rate limited at 10 requests per 10 s per IP (`tofu/rate-limit.tf`). What makes this exposure acceptable is not a gate but write denial: the Worker refuses every write RPC and the R2 token cannot write, so the surface is a read-only browser (`docs/core/backrest.md`). Re-adding an Access application here is the documented fallback if that denial weakens |

  `photos.sammohr.dev` and `opds.sammohr.dev` leave the zone's data path at
  #725's cutover: their records become grey-cloud `A`s to the edge VPS, which
  means Access no longer evaluates for them and these two rows become inert.
  They stay until then, and they are the rollback (`docs/core/public-edge.md`).

  The set carries no `prevent_destroy`, deliberately. Removing a name deletes
  its bypass application and the name falls back to the wildcard deny on the
  next request; adding one is a reviewed widening. The wildcard and the
  protected applications do carry `prevent_destroy`, so removing one of those
  needs `tofu state rm` first (same pattern as the retired hostnames below).

- **Protected applications** keep the email allow policy and add a
  `non_identity` decision where an unattended client connects. One decision
  exists: `service auth`, which accepts `any_valid_service_token` in the account.
  `memory` (the MCP wrapper's device) and `agent` (a blessed device's proxy)
  attach it. The reader at `recovery.sammohr.dev` is **not** one of them: it has
  no application at all (#707 design delta) and reaches the origin through the
  public bypass above. There is no `ssh` application either: sshd is
  tailnet-only (design #767), so no edge object names it.
  `kanbei` keeps the email policy alone and
  adds `allow_authenticate_via_warp`, so a device that already runs the
  Cloudflare One client skips the login; a device without it gets the ordinary
  Access redirect. `nanobot` is retired (SDLC #583): the agent app is served on
  `agent`, and the old application is gone rather than left email-only.
  The API rejects `allow_authenticate_via_warp` until the account has a
  Cloudflare One Client authentication session duration (Zero Trust → Access →
  Settings); it is an account-wide prerequisite, not something this repository
  can declare.
- The `service auth` policy is account-wide: any service token minted in that
  account is accepted by `memory` and `agent`. Scoping one per
  application means replacing that include with a token-id or token-tag include
  in `tofu/access.tf`. The dedicated `ssh` token and its `service_auth_ssh`
  policy are deleted with the SSH route (#767 T6); the remaining tokens are
  minted in Zero Trust → Access controls → Service credentials and their
  expiring-token notification is the rotation reminder.

## CAA

Two records at the apex pin issuance to the ACME account the in-VM CSR client
uses:

```
sammohr.dev. 3600 IN CAA 0 issue     "letsencrypt.org; accounturi=https://acme-v02.api.letsencrypt.org/acme/acct/<id>"
sammohr.dev. 3600 IN CAA 0 issuewild "letsencrypt.org; accounturi=https://acme-v02.api.letsencrypt.org/acme/acct/<id>"
```

`accounturi` is compared literally against the URI in the CSR, so the account
id and the directory must both be the production pair. `issuewild` is a separate
tag because a wildcard order is not authorized by `issue`.

**Caveat — this is a narrowing, not a lockdown.** With Universal SSL enabled,
Cloudflare appends its own CAA records (`pki.goog`, `letsencrypt.org`,
`ssl.com`, `sectigo.com`, DigiCert) to any zone that has a CAA record. They are
invisible in the dashboard and appear only in DNS. Because CAA authorizes
issuance if *any* matching record permits it, the unpinned `letsencrypt.org`
record keeps any Let's Encrypt account able to issue for the edge certificate;
the pin binds the account Kanbei's own order uses, and the Cloudflare-managed
records keep Universal SSL working. Verify with:

```sh
dig +short CAA sammohr.dev
```

Expected: the two pinned records above **plus** the Cloudflare-added set, e.g.

```
0 issue "letsencrypt.org; accounturi=https://acme-v02.api.letsencrypt.org/acme/acct/<id>"
0 issuewild "letsencrypt.org; accounturi=https://acme-v02.api.letsencrypt.org/acme/acct/<id>"
0 issue "pki.goog; cansignhttpexchanges=yes"
0 issuewild "pki.goog; cansignhttpexchanges=yes"
0 issue "letsencrypt.org"
0 issuewild "letsencrypt.org"
...
```

A `dig` that shows only the pinned pair means Universal SSL is off (or the zone
uses Advanced certificates), which is also acceptable but then the pin is the
whole policy.

## Retired hostnames

`llm.sammohr.dev` is retired (the cluster served models) and `chat.sammohr.dev`
was replaced by `agent.sammohr.dev`. `nanobot.sammohr.dev` is retired with the
agent cutover (SDLC #583): it falls under the wildcard CNAME, and the wildcard
Access application denies it once its own application is gone. The runtime that
used to answer it is gone as well, so that application is the only edge object
left to delete; its existence is an operator step, not a repository change.

All three applications carried `prevent_destroy`, so they cannot be deleted by
dropping the block: the state entry goes first, then the object is deleted in
Zero Trust.

```sh
tofu -chdir=tofu state rm cloudflare_zero_trust_access_application.llm
tofu -chdir=tofu state rm cloudflare_zero_trust_access_application.chat
tofu -chdir=tofu state rm cloudflare_zero_trust_access_application.nanobot
```

`docs/manual-steps.md#kanbei-behind-access` has the surrounding steps (dashboard
deletion, the nix-config ingress removal and the agent cutover).

## The reader's gate is gone, on purpose

`recovery.sammohr.dev` (#707) used to have its own application with the email
policy and the `service auth` policy. Design #701 wants the name open so family
can use it with nothing set up in advance, and the 2026-11-20 re-affirmation kept
it password-only, so the application is removed and the name is in
`local.public_apps`. It carried `prevent_destroy`, so its state entry goes first:

```sh
tofu -chdir=tofu state rm cloudflare_zero_trust_access_application.backrest
```

Two consequences worth knowing before the apply:

- The wildcard would otherwise deny the name, so removing the application
  **without** the public-set entry leaves it owner-only rather than open. The two
  halves of this change ship together, and `tests/tofu/check.sh` asserts both.
- The zone plan allows exactly one `http_ratelimit` rule (a second fails the
  apply with "2 out of 1"), so `tofu/rate-limit.tf` spends its only slot on the
  reader's login endpoint at 10 requests per 10 s and deletes the media rule
  (`photos`/`music`/`opds`, 1000 per 10 s) rather than merging two populations
  onto a threshold that fits neither. That deletion is a residual, not a
  cleanup: those names are proxied and the rule was live. The cost, and the
  trigger for revisiting the choice, are in `docs/core/backrest.md`
  ("The single rate-limit slot").

## Token and agent

`CLOUDFLARE_API_TOKEN` exists in exactly two places: the `cloudflare` Actions
environment and the operator's secret store. It is never a variable in
`tofu/`, never in a manifest, and never in a workflow file. The agent holds no
Cloudflare token at all: it has no Cloudflare egress through the broker and no
service-token secret, and `tests/tofu/check.sh` asserts that no cluster manifest
names one.

## Verifying

Static half — no credentials, what CI runs:

```sh
tests/tofu/check.sh
```

Expected: `tofu: 200 passed, 0 failed` with `tofu` on `PATH`; 198 without it, because the fmt/validate pair skips (CI runs both). The count grows with the config.

Runtime half — needs a token that can read Access:

```sh
CLOUDFLARE_API_TOKEN=... tests/access/check.sh
```

Expected on a healthy zone:

```
probe probe-1762866000.sammohr.dev against sammohr.dev

ok   Access matches probe-1762866000.sammohr.dev to application "wildcard default-deny"
ok   the matching application is the wildcard, not an override
     HTTP 302
ok   the edge redirects to the Access login instead of the origin

access: 3 passed, 0 failed
```

`HTTP 302` with a `location:` on `*.cloudflareaccess.com` is the pass; `401` or
`403` is also a denial and passes. A `200`, `404` or any tunnel error (`502`,
`530`, `1033`) is a failure: the origin answered, so Access was not applied to
that name. Without `CLOUDFLARE_API_TOKEN` the script prints a skip notice and
exits 0.
