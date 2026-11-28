# Cloudflare: DNS, the public edge and the zone state

`tofu/` in this repository is the only place the zone `sammohr.dev` is
described. It moved here from `nix-config/tofu/` (SDLC #581) so that every
object a diff can change is reviewed next to the manifests it fronts. `*.tf` is
Kanbei-critical (`docs/kanbei-critical.md`): the token decides what the zone
publishes.

## What the zone holds

SDLC #833 retired the last edge middle layer: **no Access application, no
Access policy, no tunnel and no wildcard record remains**. `tofu/dns.tf` is the
whole of the served surface:

| Record | Type | Points at | Cloud |
| --- | --- | --- | --- |
| `photos`, `opds`, `recovery` | `A` | `var.edge_ipv4`, the edge VPS (`docs/core/public-edge.md`) | grey, TTL 300 |
| apex, tags `issue` and `issuewild` | `CAA` | the pinned ACME account (`## CAA`) | n/a |

Every name is grey cloud on purpose: Cloudflare must not sit in the media path,
TLS-ALPN-01 needs the name to resolve to the box that answers it, and a proxied
record has no origin Cloudflare could reach. `agent` and `assistant` used to have
an `A` record apiece pointing at the agent UI Service's tailnet VIP (design #834);
that Service, its Caddy and both records are gone, and each application now
answers on `<app>.<tailnet>.ts.net` through a Service of its own.

The apex keeps its mail records — `MX`, the `SPF` `TXT`, the domain-verification
`TXT`s. None of them is declared here and SDLC #833 did not touch them.

`local.edge_hosts` in `tofu/cluster.tf` is the set the edge serves, and
`edge_only_hosts` the subset whose origin is the box itself rather than a tailnet
upstream (`recovery`). `tofu/dns.tf` asserts the second is a subset of the first, so
a typo publishes nothing while the config claims the name is served.

### What is served, and by whom

| Hostname | Answers from | Login |
| --- | --- | --- |
| `photos.sammohr.dev` | edge VPS, Caddy → `svc:immich` | Immich's own account |
| `opds.sammohr.dev` | edge VPS, Caddy → `svc:opds` | OPDShelf's own login |
| `recovery.sammohr.dev` | edge VPS, Caddy → the Backrest guard on loopback | the reader's own password — the guard's 10-per-10-s budget is the only other control (`docs/core/backrest.md`) |

Every name in the table answers its own origin: nothing left in the zone is
gated, proxied or tunnelled, so there is no edge policy to consult when one of
them misbehaves — go to the box (`journalctl -u edge-boot-gate.service` and
`journalctl -u caddy`) or the host.

### What is not served

- `kanbei.sammohr.dev` has **no DNS record and no origin**. Its Access
  application is deleted and the host tunnel's wildcard record that resolved it
  is retired, so the name does not resolve at all. The one piece left is the
  `webProxy.services.kanbei` ingress rule in `nix-config`, which has no
  connector to answer it; `tofu/kanbei.tf` is a note, not a resource.
- `llm`, `chat`, `nanobot`, `music` and `memory` are retired names: no record,
  no application (`## Retired hostnames`).
- `agent-hooks.sammohr.dev` (the webhook receiver) and `ntfy.sammohr.dev` (the
  notification bus) have **no record** since the cluster tunnel went. Both are
  inactive until their endpoints are redeployed as something the zone can point
  at: the receivers, the broker and its `notify` enrollment (marked inactive
  rather than deleted while it lived), their manifests and the tunnel route all
  went with the k3s tree.

A name with no record is not a default deny: Cloudflare answers NXDOMAIN, and
anyone who wants the name back has to add a record here. That is the whole of
the zone's access model now.

## Retired: Access, the tunnels, and the wildcard

This section is history, kept because operator notebooks, scripts and issues
still quote it.

Until SDLC #833 the zone had a default-deny Access application on
`*.sammohr.dev` with the owner's email allow policy, a bypass application per
public name, a `service auth` policy for `memory` and `agent`,
`allow_authenticate_via_warp` for `kanbei`, two Cloudflare tunnels (one on the
host, one in the `ingress` namespace) with a wildcard CNAME, the cluster
tunnel's CNAME set and its remotely-managed ingress, and two notification
policies. All of it is deleted, and the variables that fed it
(`cluster_hosts`, `host_tunnel_id`, `cluster_tunnel_id`, `email`) are gone from
`tofu/variables.tf` and `tofu/terraform.tfvars`.

**The `prevent_destroy` story was wrong here and is worth stating plainly.**
`prevent_destroy` is read from *configuration*, not from state, so deleting a
resource block plans a destroy — there is no `tofu state rm` first, and no
dashboard deletion before an apply. An object whose block is gone is destroyed
by the apply that removes the block. `tofu/rate-limit.tf` still carries
`prevent_destroy` on the ruleset because that resource is *kept*; that is the
only thing the setting does.

So the operator step for this retirement was one merge and one apply
(`tofu-apply.yml`). What an operator may still see is drift, not a leftover:

- Zero Trust → Access → Applications lists nothing for this zone. An entry that
  reappears means someone recreated it in the dashboard; delete it there and
  check `tofu-drift.yml`.
- Zero Trust → Networks → Tunnels lists no tunnel. The cluster tunnel's
  connector went with the cluster tree; the host tunnel was created in the
  dashboard and is deleted there.
- A host that still has a stale connector config will keep trying. The
  `~/.cloudflared` caches on operator machines are outside this repository:
  `docs/manual-steps.md#remove-the-stale-cloudflared-caches` is the step that
  removes them.

The Cloudflare SSH route went earlier (#767 T6) for the same reason: sshd
answers the tailnet and the firewall is the filter. `tests/tofu/check.bats`
asserts the absence of everything above — records, tunnels, applications,
policies, service-token credentials and the variables that gated them — so a
plan that offers to create any of them is a re-introduction, not a migration.

## Moved files

| nix-config | here | Note |
| --- | --- | --- |
| `tofu/main.tf` | `tofu/main.tf`, `tofu/dns.tf`, `tofu/rate-limit.tf` | split by object family; resource addresses unchanged |
| `tofu/access.tf` | `tofu/access.tf` | a note since SDLC #833: the file declares nothing |
| `tofu/r2.tf` | `tofu/r2.tf` | note only since SDLC #833: the restic bucket predates tofu and the browser CORS policy that was the file's one resource is retired |
| `tofu/variables.tf` | `tofu/variables.tf` | `tunnel_id` and the tunnel/cluster inputs are gone with the tunnels |
| `tofu/versions.tf` | `tofu/versions.tf` | provider and zone lookup only |
| `tofu/.terraform.lock.hcl` | `tofu/.terraform.lock.hcl` | re-resolved to 5.28.1 on bootstrap |
| `tofu/.terraform/` | not copied | provider cache, never committed |

Resource addresses keep their old names (`cloudflare_dns_record.edge`,
`cloudflare_ruleset.dav_rate_limit`, …) so the move was a state-file copy rather
than a re-import. Renaming one means `tofu state rm` plus `import` with the ID
format in `docs/manual-steps.md`.

## Provider v5

The config is v5-only (`~> 5.0`). The renames the state file carries:

| v4 | v5 |
| --- | --- |
| `cloudflare_record` | `cloudflare_dns_record` |
| `cloudflare_teams_*` | `cloudflare_zero_trust_*` |
| `cloudflare_access_application` | `cloudflare_zero_trust_access_application` (retired, #833) |
| `cloudflare_tunnel_route` | `cloudflare_zero_trust_network_hostname_route` (retired) |
| `cloudflare_record` `data` for CAA | `cloudflare_dns_record` `data = { flags, tag, value }` |

A plan that says **replace** on a record is wrong: stop and compare, because a
replacement of an edge name is a window where the name publishes nothing.

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
operator store (`secrets/cloudflare.yaml`: `platform-zone-rw-api-token` and the
`homelab-tofu-state-rw-*` pair) unless they are already exported. That file is
the single source for every Cloudflare credential; the state pair is a separate
token scoped to `homelab-tofu-state`, and the backup pair (`restic-backup-rw-*`)
is deliberately not accepted here. `AWS_DEFAULT_REGION` is set to
`auto`, because R2 has no regions.

State contents are object ids and attribute values — no token, no secret. R2
encrypts objects at rest, and there is no client-side state encryption because
there is no key to hold for it; the bucket's access is the control.

What the backend means for the workflows:

- `ci.yml` runs `tofu init -backend=false` + `tofu validate`, so PRs need no
  credential and no bucket;
- `tofu-plan-pr.yml` runs on every pull request and is the required check: it
  refuses forks, CI-touching diffs, executable HCL and JSON config under
  `tofu/`, and it runs `scripts/check-tofu-providers.py` before `tofu init` so
  only the providers in `.terraform.lock.hcl` can be fetched and no `module` can
  name a remote source. Then it plans with the read-only credentials and
  comments the result on the PR. The merge is the approval, so this is the plan
  the reviewer reads;
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

The account, apex, tailnet login and edge address come from the committed
`tofu/terraform.tfvars`.

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

No variable carries a credential, and none names a secret.

| Variable | Meaning |
| --- | --- |
| `account_id` | Cloudflare account tag |
| `domain` | apex zone |
| `tailscale_login` | the owner's tailnet login, used as a group member in the ACL |
| `tailnet` | the tailnet whose policy `tofu/tailscale.tf` owns; empty plans nothing |
| `edge_ipv4` | the edge VPS address; setting it creates the three grey `A` records, dropping it removes them (rollback) |

## The rate-limit slot is empty

`tofu/rate-limit.tf` declares the zone's ruleset with `rules = []`, and that is
the deployed state: the zone plan allows exactly one `http_ratelimit` rule (a
second fails the apply with "2 out of 1"), and the rule it used to hold spent
the slot on the reader's login endpoint — which no longer passes through
Cloudflare. The guard on the edge enforces the same 10-per-10-s-per-IP budget
itself, and the three public names are grey records outside every phase of the
ruleset. The cost of dropping the media rule that the slot displaced is a
recorded residual in `docs/core/backrest.md`, "The single rate-limit slot".

## CAA

The zone declares two `CAA` records at the apex, both naming Let's Encrypt and
nothing narrower:

```
sammohr.dev. 3600 IN CAA 0 issue "letsencrypt.org"
sammohr.dev. 3600 IN CAA 0 issuewild "letsencrypt.org"
```

They live in `tofu/dns.tf` (`cloudflare_dns_record.caa_issue` and `.caa_issuewild`)
and are unconditional: no `count`, no variable gates them. They authorize the
names Let's Encrypt actually issues for — the unproxied ones, where the order
runs on the origin and LE reads this set directly: `photos`, `opds` and
`recovery` on the public edge (`docs/core/public-edge.md`), plus `assistant` and
`agent` on smortress. `issuewild` is a separate tag because a wildcard order is
not authorized by `issue`.

**No account URI is pinned.** A CAA value may carry
`accounturi=https://acme-v02.api.letsencrypt.org/acme/acct/<id>`, but that string
is compared literally against the URI in the CSR, so it authorizes one ACME
account on one directory — a staging URI pins staging, a production URI pins
production, and the two never mix. The edge's Caddy account is not a stable
identity: a rebuild re-registers and the account it replaces is gone
(`docs/core/public-edge.md`, "Certificates"), so a pin would turn a routine
rebuild into an outage that only surfaces at renewal. Naming the CA is what
survives the rebuild: the new account orders from the same directory and the
policy already admits it.

**The proxied names are authorized by Cloudflare, not by these records.** A
proxied name answers from Cloudflare's edge, so the certificate in front of it is
Cloudflare's to order. With Universal SSL enabled, Cloudflare appends its own CAA
set (`pki.goog`, `letsencrypt.org`, `ssl.com`, `sectigo.com`, DigiCert) to any
zone that has a CAA record. Those records are invisible in the dashboard and
appear only in DNS. CAA admits issuance if *any* matching record permits it, so
the effective policy is the union of what this repository declares and what
Cloudflare manages; the managed half is what keeps Universal SSL able to renew
for `kanbei`, the wildcard and the rest. Verify the served state with:

```sh
dig +short CAA sammohr.dev
```

Expected: the two `letsencrypt.org` records **plus** the Cloudflare-added set,
values possibly carrying parameters:

```
0 issue "letsencrypt.org"
0 issuewild "letsencrypt.org"
0 issue "pki.goog; cansignhttpexchanges=yes"
0 issuewild "pki.goog; cansignhttpexchanges=yes"
0 issue "sectigo.com"
...
```

**The certificate carve-out is Advanced Certificate Manager.** Cloudflare appends
its set only while it controls the edge certificate. Turn on Advanced Certificate
Manager (or order a custom certificate, or turn Universal SSL off) and nothing is
appended: the two records above become the whole policy, which forbids the CA
Cloudflare would pick for the proxied names and stops their renewal weeks before
anyone notices. The order of operations for that move is therefore: add the CA
that will issue to these records first, then move the certificate.

`scripts/verify-caa.sh` asserts the union against reality: it reads the issuer of
the certificate `photos.sammohr.dev` serves, maps it to a CA domain (Google Trust
Services to `pki.goog`, Let's Encrypt to `letsencrypt.org`, DigiCert to
`digicert.com`, Sectigo to `sectigo.com`, ZeroSSL to `zerossl.com`) and requires
that domain in an `issue` value. It runs daily as one of the checks in
`scripts/verify-fleet.sh` (`.github/workflows/verify-fleet.yml`), so a carve-out
that stops renewal
fails there before the certificate expires. An empty set is a notice rather than
a failure: the check reports the served issuer and passes, and the two records
above are asserted statically by `tests/tofu/check.bats`.

## Retired hostnames

`llm.sammohr.dev` (the cluster served models), `chat.sammohr.dev` (replaced by
`agent.sammohr.dev`), `nanobot.sammohr.dev` (SDLC #583), `music.sammohr.dev`
and `kanbei.sammohr.dev` are gone from the zone: no DNS record, no tunnel
route, no Access application. Their runtime went with the cluster or
`nix-config`, so there is nothing left to delete in Zero Trust;
`docs/manual-steps.md#kanbei-behind-access` records what Kanbei's route was.

`memory.sammohr.dev` went the same way: the MCP wrapper was reached in-cluster,
so the name has no record either.

## The reader's gate is gone, on purpose

`recovery.sammohr.dev` (#707) used to have its own application with the email
policy and the `service auth` policy. Design #701 wants the name open so family
can use it with nothing set up in advance, and the 2026-11-20 re-affirmation
kept it password-only, so the application is deleted with the rest of them
(SDLC #833) and the name is served by the edge.

Two consequences worth knowing:

- The reader's password is the only login, and the guard in front of Backrest
  owns the 10-per-10-s-per-IP budget because no Cloudflare phase sees the
  traffic any more (`docs/core/backrest.md`).
- What makes the exposure acceptable is write denial, not a gate: the guard
  refuses every write RPC and the R2 token cannot write, so the surface is a
  read-only browser. If that denial weakens, adding an Access application back
  is the documented fallback — a reviewed change, not a dashboard edit.

## Token and agent

`CLOUDFLARE_API_TOKEN` exists in exactly two places: the `cloudflare` Actions
environment and the operator's secret store. It is never a variable in
`tofu/`, never in a manifest, and never in a workflow file. The agent holds no
Cloudflare token at all: it has no Cloudflare egress through the broker and no
service-token secret, and `tests/tofu/check.bats` asserts that no shipped tree
names one.

## Verifying

Static half — no credentials, what CI runs:

```sh
tests/tofu/check.bats
```

Expected: `tofu: 224 passed, 0 failed` with `tofu` on `PATH`; two fewer without
it, because the fmt/validate pair skips (CI runs both). The count grows with the
config.

Runtime half — the zone has no Access object to read and no tunnel to probe, so
there is no token-driven edge check any more. The live proof for what the zone
serves is the public probe, which resolves the names and checks each answers as
its own application:

```sh
scripts/verify-fleet.sh           # all three names, over valid TLS, each as its application
ssh root@smoresnet journalctl -u edge-boot-gate.service -b   # the box's own verdict on the boot
```
