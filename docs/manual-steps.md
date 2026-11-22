# Manual steps

Everything here needs a human: account creation, 2FA, token issuance, and the
one-time GitHub settings that `gh api` is allowed to change but an agent must
not. Record the date and who ran it when it is done.

The commands assume the tools are on `PATH`: `sops`, `age`, `cosign`, `skopeo`,
`crane`, `jose`, `openssl`, `podman`, `restic` and `python3` from the distro or
their pinned releases, and `kustomize`, `kubeconform`, `tofu`, `vector` and `yq`
from `scripts/install-ci-tools.sh`.

## 1. Create the `smores56-homelab-agent` GitHub App

The agent's GitHub identity is an app, not a user: installation tokens are
short-lived, scoped per request by the broker, and revocable from the app's
settings page. There are no PATs for the agent anywhere.

A GitHub App cannot fork a repository, and GitHub refuses a fork of your own
private repository. The agent therefore pushes `agent/*` branches to
`homelab-platform` and opens same-repo pull requests. Same-repo PRs run
`pull_request` workflows inside the base repository, so the fork boundary is
gone; the remaining controls are that no repository-level secrets exist (only
main-gated environment secrets), and the ruleset in item 3.

1. Create the app at https://github.com/settings/apps/new:
   - Name: `homelab-agent` (that name is taken globally, so GitHub assigned the
     slug `smores56-homelab-agent`; its actor is `smores56-homelab-agent[bot]`).
   - Homepage: `https://github.com/smores56/homelab-platform`.
   - Webhook: **inactive** (the broker polls; there is no endpoint for GitHub
     to deliver to, and the tunnel admits nothing from GitHub).
   - Post installation: Setup URL blank, **Redirect on update** off.
   - Identifying and authorizing users: Callback URL blank;
     **Expire user authorization tokens** at its default (on) — it governs user
     access tokens only, which this app never issues; **Request user
     authorization (OAuth) during installation** off; **Enable Device Flow**
     off. Turning any of these on would create a second, human-impersonating
     token type the broker does not need and cannot audit.
   - Repository permissions: **Contents: read and write**, **Pull requests:
     read and write**, **Metadata: read** (mandatory); **Actions: read** for CI
     status and publish digests. Leave **Workflows** at **No access**: GitHub
     refuses a push touching `.github/workflows/**` with
     `refusing to allow a GitHub App to create or update workflow ... without
     workflows permission` (verified with the app token, 2026-11-12). A local
     probe must disable git's credential helper
     (`-c credential.helper= -c credential.https://github.com.helper=`), or it
     authenticates as the owner and the permission looks unenforced. The merge
     review is the backstop, not the gate.
   - Organization permissions, Account permissions, Enterprise permissions:
     **No access**, all of them. The app operates on two user-owned
     repositories through scoped installation tokens; anything broader is
     authority the broker would hold and never use.
   - Where can this app be installed: **Only on this account**.
2. Record the **App ID** from the app's settings page, generate a **private
   key** (downloads a `.pem`; keep it in the password manager), then install the
   app once on the `smores56` account with **all five** repositories selected:
   `homelab-apps`, `homelab-platform`, `nix-config`, `kanbei` and `sdlc` (an
   installation is per account, not per repository: one ID covers all of them,
   and the broker narrows each minted token to the repositories named on the
   logical host it is serving). Record the **installation ID** from the install
   URL (`/installations/<id>`). The app id, key and installation id reach the
   broker only as files (step 10); nothing is committed. Every repository named
   on a logical host goes into one token request, so a repository that is in
   `broker.json` but not in the installation fails the whole host with a 422:
   add it to the installation first.
3. Branch containment is the `main` ruleset, not an `agent/**` ruleset. The
   requirement for a ruleset that confines the identity to `agent/*` was dropped
   on 2026-11-21: the machine user may push any non-default branch, and what
   bounds it is that `main` requires a pull request with an approving review for
   every account except the owner, with deletion and force-push blocked.
   `nix-config` and `kanbei` are archived and out of scope; their
   `github-agent-push` / `github-agent` broker hosts are historical and go when
   the broker config next changes.
   What still has to be true, and is worth reading back from the API:
   - `main` blocks deletion and force-push, requires a pull request, and requires
     the named status checks — `tofu plan` on `homelab-platform`, `apps-schema`
     on `homelab-apps`.
   - The app holds **Workflows: No access**, so a push touching
     `.github/workflows/**` is refused by GitHub itself
     (`refusing to allow a GitHub App to create or update workflow ... without
     workflows permission`, verified 2026-11-12). That refusal is independent of
     any ruleset and must stay verified in the acceptance run.
   - Read the rulesets back rather than trusting the description:
     `gh api repos/smores56/<repo>/rulesets --jq '.[] | "\(.id) \(.name) \(.conditions.ref_name.include)"'`.
4. The mirror's `github-backup-read-pat` (step 22) is not the agent's identity;
   it stays an operator-owned fine-grained PAT.

## 2. Create the `cloudflare` environment secret

The environment exists (created by `gh api`, see `docs/runbook.md`); the secret
value can only be set by a human.

```sh
read -rsp 'Cloudflare API token: ' CLOUDFLARE_API_TOKEN
gh secret set CLOUDFLARE_API_TOKEN --env cloudflare --repo smores56/homelab-platform
unset CLOUDFLARE_API_TOKEN
```

Verify without printing the value:

```sh
gh api repos/smores56/homelab-platform/environments/cloudflare/secrets \
  --jq '.secrets[].name'
```

Expect `CLOUDFLARE_API_TOKEN`. An environment with no secret makes
`tofu-apply.yml` fail loudly; `tofu-plan-pr.yml` also fails rather than skipping,
because a silent skip would let a PR merge with no plan.

The state backend's R2 pair is a second pair of environment secrets
(`R2_STATE_ACCESS_KEY_ID`, `R2_STATE_SECRET_ACCESS_KEY`); step 14 creates the
bucket and sets both. Step 3a adds the read-only pair the pre-merge plan uses.

## 4. Create the environments and apply repo settings

Both need **Administration: write** on the repository, which the bootstrap token
lacked (HTTP 403, recorded in `docs/runbook.md`). Run as the owner with a
classic `repo`-scoped PAT or a fine-grained PAT carrying Administration and
Actions write:

1. Environments: two, with different branch policies.
   - `cloudflare` holds the write token and the write R2 pair. Policy: `main`
     only. `tofu-apply.yml` is the only reader.
   - `cloudflare-plan` holds the read-only pair from step 3a. Policy: `main` and
     `smores/*`, because the pre-merge plan runs on a PR branch.
   Neither lists `agent/*`, so a branch the bot can push reaches no environment.
   That is deliberate even for the read-only pair: reading the zone enumerates
   every DNS record, Access application and ingress rule. A PR from `agent/*`
   that touches `tofu/` therefore fails the plan check, and a human re-pushes the
   same diff onto a `smores/*` branch to plan it. The environment is declared on
   the job (GitHub accepts it nowhere else), so such a PR fails the required check
   outright rather than receiving a credential-free pass.
   Neither has required reviewers: that reviewer was the click this design
   removes, and the merge plus the required plan check are the approval now.

   ```sh
   printf '%s' '{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}' |
     gh api -X PUT /repos/smores56/homelab-platform/environments/cloudflare-plan --input -
   for p in main 'smores/*'; do
     gh api -X POST /repos/smores56/homelab-platform/environments/cloudflare-plan/deployment_branch_policies \
       -f name="$p" -f type=branch
   done
   ```
2. `docs/runbook.md` → "Repo settings": read-only default `GITHUB_TOKEN`,
   SHA-pinning required, only GitHub-owned and verified actions, fork PRs need
   owner approval, private vulnerability reporting on.

Then confirm with the `gh api` verify commands in those sections. Do this before
setting the environment secret in step 2, because a secret can only be attached
to an environment that exists.

## 5. Apply branch protection

Run the commands from `docs/runbook.md` section "Branch protection on main".
They require the same admin token; `enforce_admins` is false so the owner can
still push a bootstrap commit, while `smores56-homelab-agent[bot]` and every other
identity are bound by PR review, the required checks, and **Require review from
Code Owners** — the last one is what keeps `.github/` and `*.tf` (Kanbei-
critical) human-reviewed now that the app can technically push a workflow edit.

After applying, confirm the app cannot push to `main` (expected: `protected
branch hook declined`) and cannot force-push (expected: `Cannot force-push to a
protected branch`); the ruleset from step 1 covers every branch outside
`agent/*`. Record both outputs beside the runbook.

## 6. Create the SOPS age identity

The age private key is a credential and cannot be generated by an agent: nothing
here may hold it. One key per namespace that carries ciphertext (`flux-system`
for platform manifests, `tenant-apps` for `homelab-apps`).

```sh
age-keygen -o sops-age.agekey
age-keygen -y sops-age.agekey            # record the age1... recipient
kubectl -n flux-system create secret generic sops-age --from-file=age.agekey=sops-age.agekey
kubectl -n tenant-apps create secret generic sops-age --from-file=age.agekey=sops-age.agekey
# store the file in the password manager, then remove the local copy
rm sops-age.agekey
```

Verify (expect the `AGE-SECRET-KEY-1...` line, never paste its output into a
ticket):

```sh
kubectl -n flux-system get secret sops-age -o jsonpath='{.data.age\.agekey}' | base64 -d | head -1
kubectl -n tenant-apps get secret sops-age -o jsonpath='{.data.age\.agekey}' | base64 -d | head -1
```

The recipient goes into `.sops.yaml` when the first encrypted file lands; the
`--sops-age-secret` controller flag stays unset so each namespace decrypts only
with its own key (`docs/tenancy.md`).

## 7. Create the `homelab-apps` deploy key

The tenant GitRepository reads a private repository from `tenant-apps`.

```sh
flux create secret git homelab-apps-auth \
  --namespace=tenant-apps \
  --url=ssh://git@ssh.github.com:443/smores56/homelab-apps
```

Take the printed public key, add it to `smores56/homelab-apps` → Settings →
Deploy keys → **Allow write access: off**.

The URL is GitHub's SSH-over-443 endpoint because the cluster guest forwards only
80/443 out of the tap. An existing Secret created against `github.com` needs the
443 host key added (the identity is unchanged):

```sh
# Replace the host keys rather than appending: a file without a trailing
# newline glues the next line onto the last key and Flux then rejects it
# ("illegal base64 data").
ssh-keyscan -p 443 ssh.github.com 2>/dev/null > /tmp/kh
sudo cluster-kubectl -n tenant-apps patch secret homelab-apps-auth --type merge \
  -p "{\"data\":{\"known_hosts\":\"$(base64 -w0 /tmp/kh)\"}}"
rm -f /tmp/kh
```

Then verify:

```sh
flux -n tenant-apps get gitrepository homelab-apps -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
```

Expected: `True`.

## 8. Install External Secrets

The operator is not shipped by this repository, so installing it is a
precondition for the two ESO stages, not something they can wait for: both
`platform-secrets-eso` and `platform-observability-secrets` run unconditionally
and fail loudly on missing CRDs. Do not try to gate them with
`flux resume` — git owns those objects' spec, so a suspension set by hand
returns on the next `flux-system` reconcile.

```sh
helm repo add external-secrets https://charts.external-secrets.io
helm repo update
helm install external-secrets external-secrets/external-secrets \
  --namespace platform --create-namespace
kubectl -n platform rollout status deploy/external-secrets-webhook --timeout=120s
kubectl -n observability get externalsecret loki-gateway-token
kubectl -n broker get secret broker-credentials
```

Expected: `loki-gateway-token` is generated and owned by its ExternalSecret;
`broker-credentials` is the SOPS contract Secret from step 10. `loki-gateway-token`
is what unblocks the Loki gateway (its only reader besides the broker); Vector no
longer holds it, because both sinks write their tenant directly. A missing token
leaves the gateway unstarted (fail closed) and the broker's `loki` host dead. The agent holds no broker token, so there is no
`nanobot-broker-token` to generate. Rotate a generated token by deleting its
Secret and letting the `Password` generator mint a new one.

## 9. Digest-pin the observability images

The manifests pin version tags. Replace each tag with a digest once, from a
machine with registry access (the agent VM has none):

```sh
for ref in prom/prometheus:v3.16.0 grafana/loki:3.7.9 \
  timberio/vector:0.61.0-debian python:3.13.12-slim busybox:1.37.0 \
  ghcr.io/immich-app/immich-server:v3.0.3 \
  ghcr.io/immich-app/immich-machine-learning:v3.0.3 \
  ghcr.io/immich-app/postgres:17-vectorchord0.4.3-pgvector0.8.1 \
  deluan/navidrome:0.63.2 \
  cloudflare/cloudflared:2026.10.2 alpine/git:2.54.0; do
  printf '%s -> %s\n' "$ref" "$(crane digest "$ref")"
done
```

Then rewrite those `image:` lines under
`clusters/homelab/observability/{prometheus,loki,vector,status-exporter,loki-gateway}`,
`clusters/homelab/data/{immich,navidrome,graphiti,opdshelf}`,
`clusters/homelab/ingress` and `clusters/homelab/platform/backup`
to `repo@sha256:<digest>` (keep the tag when the registry allows
`repo:tag@sha256:...`), run `scripts/kustomize-build-all.sh` and
`tests/observability/check.sh`, and commit. The image-pin assertion in
`tests/observability/check.sh` accepts either a version tag or a `sha256:` digest,
so a half-finished sweep still fails CI rather than shipping `latest`.

`alpine/git` is the one image already pinned, because the mirror job is the only
place a tag alone would ship: `docker.io/alpine/git:2.54.0` resolves to the
manifest list `sha256:6a1fdb962814ca11508ca8d1bab94375b5b7ac4e4a9a40981c29fc32c02f095d`
(recorded 2026-11-11; verify with `crane digest docker.io/alpine/git:2.54.0`
before trusting it). No agent runtime image is published from this repository:
the tenant image and its Flux roll-out are retired (step 31), and the agent units
now ship inside the bootc image, whose pins the server-image workflow checks.

## 10. Create the broker credential Secret

The broker is platform-owned (`clusters/homelab/broker/`); this step supplies
eight files, none of which enters git. Static enrollments name five of them
(`keys` in `clusters/homelab/broker/sops-contract.yaml`); the GitHub App
enrollments add the app id, the private key and one installation id per
installation (`app_keys`). **Step 1 must be finished first.**

`notify-token` is optional: the enrollment declares `optional_secret`, so a
missing file is a 503 for that host instead of a startup abort. Create it when
the provider is chosen in step 24; until then the placeholder host answers
`dns_failure` and the rest of the broker is unaffected.

`memory-mcp-token` is optional for the same reason: its value already exists in
the graphiti Secret, and step 32 projects it into this Secret. Until it is
there, the `memory` host answers `503 credential_unavailable` and nothing else
changes.

Run this on smortress as `smores`. `cluster-kubectl` reads a root-only
kubeconfig, hence `sudo`.

```sh
NW=$(cat /run/secrets/neuralwatt-api-key)
TF=$(cat /run/secrets/tinyfish-api-key)
LOKI=$(sudo cluster-kubectl -n observability get secret loki-gateway-token \
  -o jsonpath='{.data.password}' | base64 -d)
read -rp 'App ID (digits): ' APP_ID
read -rp 'installation ID: ' INSTALL
read -rsp 'private key path: ' KEY_PATH; echo
NOTIFY=$(openssl rand -hex 32)  # optional until step 24

# No value reaches the command line or a transcript.
umask 077
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
printf '%s\n' "$NW" > "$tmp/neuralwatt-api-key"
printf '%s\n' "$TF" > "$tmp/tinyfish-api-key"
printf '%s\n' "$LOKI" > "$tmp/loki-gateway-token"
printf '%s\n' "$NOTIFY" > "$tmp/notify-token"
printf '%s\n' "$APP_ID" > "$tmp/github-app-id"
printf '%s\n' "$INSTALL" > "$tmp/github-installation-id"
install -m 0600 "$KEY_PATH" "$tmp/github-app-private-key"
unset NW TF LOKI NOTIFY APP_ID INSTALL

sudo cluster-kubectl -n broker create secret generic broker-credentials \
  --from-file="$tmp"
sudo cluster-kubectl -n broker rollout restart deployment/broker
```

The broker aborts at start if a static file is missing, and answers 503 for a
GitHub host whose token cannot be minted; it never forwards without a
credential. Verify the three credential classes:

```sh
sudo cluster-kubectl -n broker exec deploy/broker -- python -c '
import http.client
for path in ("healthz", "loki/loki/api/v1/labels", "github-platform/rate_limit"):
    c = http.client.HTTPConnection("127.0.0.1", 8080, timeout=20)
    c.putrequest("GET", "/" + path, skip_host=True)
    c.putheader("Host", "broker.broker.svc.cluster.local")
    c.endheaders()
    r = c.getresponse()
    print(path, r.status, r.read(140))
    c.close()
'
```

The explicit `Host` matters: a plain `urllib` call to `127.0.0.1` sends an
IP-literal Host, which the broker refuses with `400 ip_literal_host`.

Expected: `200`; `200` with the Loki gateway's `{"status":"success"...}`; and
`200` with the installation's rate limit. A `503` (`credential_unavailable`) on
`rate_limit` means the app id, private key or installation id is wrong: the
broker refuses rather than forwarding without a credential, so a 401 never
comes from here.

Rotation: generate a new key in the app settings, delete the Secret, repeat this
step (credentials are read once at start). `github-installation-id` is shared by
all three GitHub enrollments; their difference is the minted scope.

## 11. Rotate the Loki gateway token

The value is read from the environment at process start, so rotation is a
delete-and-roll, not a hot reload:

```sh
kubectl -n observability delete secret loki-gateway-token
# the ExternalSecret recreates it from the Password generator
kubectl -n observability rollout restart deployment/loki-gateway
```

Then repeat step 10 so the broker holds the new value, and query the `data`
tenant through the gateway to confirm (docs/observability.md, "Verification").

## 12. Create the cluster's SOPS-contract Secrets

Five cluster workloads read a credential that Cloudflare, Neuralwatt or the
operator issued, and none may exist in git. The operator creates each Secret
with `sops`; same rule as the host's `/run/secrets`: ciphertext lives in the
operator's secret store, plaintext only in the API server and the pod. The ESO
`kubernetes` provider projects four of them; OPDShelf reads its admin password
from the contract Secret directly, since it is a static value with no property
mapping.

Create the cluster tunnel (step 15), or take its token from the T7 work
(`smores56/sdlc#581`; `smores56/sdlc#580` depends on it), and write them all
encrypted with the same
age key the host secrets use:

```sh
# graphiti: Neuralwatt key for extraction and embeddings
sops -e -i neuralwatt-api-key.yaml
# ingress: the tunnel token from T7
sops -e -i cloudflare-tunnel-token.yaml
# opdshelf: OPDShelf's admin password (also the readers' Basic auth credential)
sops -e -i opdshelf-admin-password.yaml
# graphiti: the MCP wrapper's bearer token, the same value as the host secrets'
# memory-mcp-token in smores56/nix-config
sops -e -i memory-mcp-token.yaml
```

Then materialise the Secrets (SOPS contract names: `*-sops`; the broker's
`broker-credentials` is step 10 and is a plain Secret, not a `*-sops` one):

```sh
kubectl -n graphiti create secret generic neuralwatt-api-key-sops \
  --from-file=api-key=<(sops -d neuralwatt-api-key.yaml | yq -r .key | tr -d '\n')
kubectl -n ingress create secret generic cloudflare-tunnel-token-sops \
  --from-file=tunnel-token=<(sops -d cloudflare-tunnel-token.yaml | yq -r .token | tr -d '\n')
kubectl -n opdshelf create secret generic opdshelf-admin-password-sops \
  --from-file=password=<(sops -d opdshelf-admin-password.yaml | yq -r .password | tr -d '\n')
kubectl -n graphiti create secret generic memory-mcp-token-sops \
  --from-file=memory-mcp-token=<(sops -d memory-mcp-token.yaml | yq -r .token | tr -d '\n')
```

`tr -d '\n'` is load-bearing: `yq -r` ends its output with a newline and
`--from-file` stores it verbatim, which makes an `Authorization` header or a
Basic-auth password invalid. The graphiti renderer also strips line endings
defensively.

Resume the ESO stage (step 8) and confirm the projections, which is what the
Deployments actually read:

```sh
kubectl -n graphiti get secret neuralwatt-api-key -o jsonpath='{.data.api-key}' | base64 -d | wc -c
kubectl -n ingress get secret cloudflare-tunnel-token -o jsonpath='{.data.tunnel-token}' | base64 -d | wc -c
kubectl -n graphiti get secret memory-mcp-token -o jsonpath='{.data.token}' | base64 -d | wc -c
kubectl -n ingress get deploy cloudflared
```

Rotation is "rewrite the `*-sops` Secret, wait one refresh interval (1h), roll the
Deployment"; a lost key is a Neuralwatt/Cloudflare reissue, not a cluster
restore.

## 13. Cut the data apps over

Order, per-app checks and rollback are in `docs/data-migration.md`. Before the
first cutover:

1. Install the cluster tunnel's Cloudflare objects (T7,
   `smores56/sdlc#581`): the tunnel itself (step 15), then its DNS and Access
   objects from `tofu/` by adding the hostname to `cluster_hosts` and applying.
   The host tunnel now serves nothing: its nix-config connector is retired, SSH
   is tailnet-only (design #767) and never touches the edge, the Kanbei route
   went with nix-config, and `agent`/`memory` moved to the cluster. `llm` and
   `chat` are retired by step 17. Until a hostname's cutover the wildcard record
   keeps it resolving to the host.
2. Confirm the storage contract bound:

   ```sh
   cluster-kubectl get nodes -o wide            # node name is exactly: cluster
   cluster-kubectl get pv                         # four PVs, STATUS Bound
   cluster-kubectl -n immich get pvc              # immich-data Bound
   ```

3. Create the OPDShelf admin password contract before exposing the route
   (`opdshelf-admin-password-sops`, step 12); the name is `smores56` and the
   password is also the readers' Basic auth credential.
4. The agent's write path is a file, not an API: OPDShelf's folder is the
   catalog, so `fanficfare-download` drops the EPUB where the host can move it
   into the share and `calibredb` (the host CLI, previously named after the app)
   loses its content-server tail. That change lives in `nix-config`, not here.
5. **Publish and pin the wrapper image.** In `smores56/nix-config`:
   `just publish-memory-image <git-sha>` builds the layered image, pushes it to
   `ghcr.io/smores56/nix-config/memory-mcp:<git-sha>` and prints the digest.
   Replace both `@sha256:000…` placeholders in
   `clusters/homelab/data/graphiti/{memory-mcp,memory-export-cronjob}.yaml` with
   it, and make the GHCR package public (Packages -> memory-mcp -> Change
   visibility); the cluster has no image pull secret.
6. **Move the wrapper.** Create `memory-mcp-token-sops` (step 12). Export
   **while the host stack still runs**: the graph snapshot is a `BGSAVE`
   through the live FalkorDB, so an export taken after the stop has no
   `graph.rdb` and exits non-zero. Write it into the share the cluster already
   mounts:

   ```sh
   sudo memory-export export \
     --root /var/lib/data/graphiti/db-dumps/memory/cutover \
     --state-dir /var/lib/memory \
     --graph-url redis://127.0.0.1:6379 \
     --graph-dir /var/lib/memory/falkordb \
     --graph-timeout 120
   sudo chown -R 1000:1000 /var/lib/data/graphiti/db-dumps/memory/cutover
   ```

   The restore Job runs as uid 1000, and SQLite's read-only open of a WAL
   registry still creates the `registry.sqlite-shm` sidecar next to it, so the
   pod must own the export directory; a root-owned 0755 tree fails with
   `attempt to write a readonly database`.

   Then stop the host stack
   (`sudo systemctl stop memory-export.timer; sudo systemctl stop memory-mcp
   memory-graphiti-mcp memory-llm-proxy memory-falkordb`) and scale
   `deploy/graphiti-falkordb` to 0. Install that export with the restore Job
   (*Restoring the memory registry*, directory
   `/data/db-dumps/memory/cutover`), then merge the platform branch so Flux
   creates the wrapper against the restored state. Set
   `memoryForward.enable = true` in nix-config (which also disables the host
   units declaratively, so a reboot cannot resurrect them), rebuild, and verify
   `memory status`, one write and one search. If the graph and registry still
   disagree, `memory reindex --all` until it reports nothing left.
   Keep the host state tree untouched for the observation week.
7. Leave `modules/nixos/{immich,navidrome,memory}.nix` in place until every app
   has served from the cluster for a week; then enable
   `clusterDataApps.enable` in nix-config (`docs/kanbei-split.md` in that
   repository) and, after that has run, delete the modules.

### Restoring the memory registry

There is no systemd in the cluster, so the restore is a Job. The directory
argument is the export being installed on the `graphiti-data` share: the
CronJob writes `/data/db-dumps/memory`, and the cutover export is
`/data/db-dumps/memory/cutover`. The directory must be owned by uid 1000 (the
Job's user): SQLite's read-only open of a WAL registry creates a
`registry.sqlite-shm` sidecar beside it.

```sh
# 1. Every writer and the graph stop first: the registry is single-writer.
#    On the first cutover `memory-mcp` does not exist yet; skip that line.
cluster-kubectl -n graphiti scale deploy/memory-mcp --replicas=0
cluster-kubectl -n graphiti scale deploy/graphiti-falkordb --replicas=0

# 2. Verify first, then write, from the same image the wrapper runs. Deleting
#    the job makes the command repeatable: a Job's template is immutable.
#    The pod template must carry `homelab.dev/managed-by: platform`: the
#    admission policy (platform/policies/08-data-workload-source.yaml) denies a
#    job-created pod without it, so the Job stays 0/1 with FailedCreate events.
cluster-kubectl -n graphiti delete job memory-restore --ignore-not-found
cluster-kubectl -n graphiti create job memory-restore --image=<the pinned digest> \
  --dry-run=client -o yaml \
  | yq '.spec.ttlSecondsAfterFinished = 86400 | .spec.template.metadata.labels = {"homelab.dev/managed-by": "platform", "homelab.dev/tier": "data"} | .spec.template.spec = {"securityContext": {"runAsUser": 1000, "runAsGroup": 1000, "runAsNonRoot": true, "seccompProfile": {"type": "RuntimeDefault"}, "restartPolicy": "Never", "serviceAccountName": "data-workload", "automountServiceAccountToken": false}, "containers": [{"name": "restore", "image": "<the pinned digest>", "command": ["memory-export", "restore", "/data/db-dumps/memory", "--state-dir", "/data/memory", "--graph-dir", "/data/falkordb", "--owner", "", "--no-stop"], "securityContext": {"allowPrivilegeEscalation": false, "readOnlyRootFilesystem": true, "capabilities": {"drop": ["ALL"]}}, "resources": {"limits": {"cpu": "500m", "memory": "512Mi"}}, "volumeMounts": [{"name": "data", "mountPath": "/data"}, {"name": "tmp", "mountPath": "/tmp"}]}], "volumes": [{"name": "data", "persistentVolumeClaim": {"claimName": "graphiti-data"}}, {"name": "tmp", "emptyDir": {}}]}' \
  | cluster-kubectl -n graphiti apply -f -
cluster-kubectl -n graphiti logs -f job/memory-restore

# 3. A restore writes `/data/memory/.restore-in-progress` and removes it only on
#    success; while it exists every export refuses to run. After an interrupted
#    restore, reconcile state, then delete it with the same Job shape and the
#    command `rm /data/memory/.restore-in-progress`.

# 4. Boot FalkorDB once with the AOF off so the restored dump.rdb loads. Redis
#    with `appendonly yes` starts empty when no AOF exists; renaming the old one
#    is necessary but not sufficient (see the note after this block).
cluster-kubectl -n graphiti patch deploy graphiti-falkordb --type=strategic \
  -p '{"spec":{"template":{"spec":{"containers":[{"name":"falkordb","env":[{"name":"REDIS_ARGS","value":"--appendonly no --save \"\""}]}]}}}}'
cluster-kubectl -n graphiti scale deploy/graphiti-falkordb --replicas=1
# wait until the log says "DB loaded from disk" and this count is non-zero:
cluster-kubectl -n graphiti exec deploy/graphiti-falkordb -- \
  redis-cli GRAPH.QUERY global "MATCH (n) RETURN count(n)"
cluster-kubectl -n graphiti exec deploy/graphiti-falkordb -- \
  redis-cli CONFIG SET appendonly yes
# back to the deployed args; the Recreate reloads the AOF this just wrote
cluster-kubectl -n graphiti patch deploy graphiti-falkordb --type=strategic \
  -p '{"spec":{"template":{"spec":{"containers":[{"name":"falkordb","env":[{"name":"REDIS_ARGS","value":"--appendonly yes --appendfsync everysec --save \"\""}]}]}}}}'
cluster-kubectl -n graphiti scale deploy/memory-mcp --replicas=1
```

The two `REDIS_ARGS` patches fight Flux: the data stage re-applies the
Deployment within its 10-minute interval, so run the block in one go. If the
node count stays 0, stop before `CONFIG SET` — the snapshot did not load.

Rolling back to the host is `sudo memory restore <export>` on smortress after
copying the export out of the share — not a restart of the frozen host copy,
which is missing every write since the cutover.

## 14. Move the Cloudflare OpenTofu state

The config moved from `nix-config/tofu/` to `tofu/` here (SDLC #581) with the
resource addresses unchanged, so the state file carries over rather than being
re-imported. State is never committed.

```sh
# on smortress, as the operator
cd /srv/git/github.com/smores56/homelab-platform/main
sudo cp /var/lib/cloudflare-tofu/terraform.tfstate tofu/terraform.tfstate
sudo chown "$(id -u):$(id -g)" tofu/terraform.tfstate
```

Export the variables from `docs/cloudflare.md` ("Applying"), then:

```sh
tofu -chdir=tofu init -input=false
tofu -chdir=tofu plan -no-color
```

Expected: no replacements. The diff is the wildcard application, the public
bypass applications (the four original hosts, minus any already adopted, plus
`agent-hooks` when SDLC #627 lands), the two CAA records, and an in-place update
of the four older applications from `domain` to `destinations`. Anything else —
in particular `-/+` on an Access application or the wildcard DNS record — means
the state does not match; stop before applying and compare IDs.

```sh
tofu -chdir=tofu apply -no-color
```

Then keep the state file with the rest of the operator credentials and delete
the old copy once a second plan is clean:

```sh
sudo rm -rf /var/lib/cloudflare-tofu
```

The nix-config flake apps `cloudflare-plan` / `cloudflare-apply` are removed with
this migration; do not run them after the move, because they copy the old `.tf`
files over the state.

Adopting an account whose state was lost needs imports instead: `<zone_id>/<record_id>`
for records and `accounts/<account_id>/<app_id>` for applications, listed from
`/zones/<zone>/dns_records` and `/accounts/<account>/access/apps`.

### Moving the state into R2 (SDLC #622)

The config now carries a `backend "s3" {}` block pointed at R2
(`tofu/backend.tf`), so the operator's local file has to become that bucket's
object. This is the destructive-looking step: an `init` against an empty bucket
and a local file that was forgotten would plan a create for every object that
already exists. Do it in this order and read the `state list` diff.

1. Create the bucket and its key. In the Cloudflare dashboard: R2 → **Create
   bucket** → `homelab-tofu-state` (private, default location), then R2 → **Manage
   API tokens** → **Create API token** → *Object Read & Write* on that bucket
   only. Store the pair in the `cloudflare` environment:

   ```sh
   gh secret set R2_STATE_ACCESS_KEY_ID --env cloudflare --body "<access key id>"
   gh secret set R2_STATE_SECRET_ACCESS_KEY --env cloudflare --body "<secret access key>"
   ```

   The operator needs the same pair, and it is **not** the host's restic key:
   state decides what the next apply does, so the backup credential must not be
   able to rewrite it. Both cases land in this repository's operator store
   (`docs/secrets.md`), which only the admin identity decrypts:

   ```sh
   cd /srv/git/github.com/smores56/homelab-platform/main
   sops secrets/cloudflare.yaml     # create it: cloudflare-api-token,
                                    # r2-state-access-key-id, r2-state-secret-access-key
   ```

   The zone token is duplicated in nix-config only while host units read it
   (`kanbei-access.nix`; `alerting.nix` stopped reading it when the ntfy bus
   replaced the mail sender, #649); the table in `docs/secrets.md` names what
   retires each copy. The script no longer reads nix-config at all.

2. Back up the local state and record what it holds, before touching anything:

   ```sh
   cd /srv/git/github.com/smores56/homelab-platform/main
   cp tofu/terraform.tfstate "tofu/terraform.tfstate.pre-r2-$(date +%F)"
   ./scripts/tofu-cloudflare.sh state pull > "/var/backups/tofu-state-$(date +%F).json" 2>/dev/null \
     || tofu -chdir=tofu state pull > "/var/backups/tofu-state-$(date +%F).json"
   ./scripts/tofu-cloudflare.sh state list | sort > /tmp/tofu-state-before.txt
   wc -l /tmp/tofu-state-before.txt        # record the number
   ```

   Keep both copies off the checkout: the JSON is the object graph, the `.pre-r2`
   file is what `-migrate-state` reads.

3. Migrate. `init` asks whether to copy the existing state into the new backend:

   ```sh
   ./scripts/tofu-cloudflare.sh init -migrate-state
   ```

   Answer **yes**. The script supplies the R2 pair from SOPS; `AWS_DEFAULT_REGION`
   is forced to `auto`. A `403` here means the token is not scoped to the bucket;
   an `AccessDenied` on `HeadBucket` means the bucket name in `tofu/backend.tf`
   does not exist yet.

4. Prove the state moved unchanged:

   ```sh
   ./scripts/tofu-cloudflare.sh state list | sort > /tmp/tofu-state-after.txt
   diff -u /tmp/tofu-state-before.txt /tmp/tofu-state-after.txt   # empty
   ./scripts/tofu-cloudflare.sh plan -no-color | tail -20          # no changes
   ```

   A non-empty diff or a plan that proposes a create means the migration did not
   carry the state: restore `tofu/terraform.tfstate` from step 2 and do not
   continue.

5. Remove the local copies so nothing can plan from them, then confirm CI reads
   the same state. Dispatch `tofu-apply` with `apply` left false and check that
   its plan is empty:

   ```sh
   rm tofu/terraform.tfstate tofu/terraform.tfstate.backup
   gh workflow run tofu-apply --repo smores56/homelab-platform
   gh run watch --repo smores56/homelab-platform
   ```

   The workflow's summary shows the plan. From here on, an apply is
   `workflow_dispatch` with `apply: true` after a reviewed plan-only run — never a
   push. `tofu-plan.yml` on main is the drift check.

6. Rollback, if the bucket has to be abandoned: `tofu init -migrate-state` with
   `backend.tf` reverted to the local default copies the object back into
   `tofu/terraform.tfstate`. Do that before deleting the bucket, not after.

## 15. Create the cluster tunnel

The k3s connector (`clusters/homelab/ingress/`) has no token and stays
unstarted until this exists.

1. Zero Trust → Networks → Tunnels → **Create a tunnel** → `cloudflared`, name
   `cluster`. Add **no** public hostname: DNS and Access come from `tofu/`.
2. Copy the token into the SOPS contract `cloudflare-tunnel-token-sops` in the
   `ingress` namespace (step 12). The token never enters git.
3. Record the tunnel UUID in `tofu/terraform.tfvars` (`cluster_tunnel_id`) and
   commit it: the apply reads every identifier from that file.

4. At each app's cutover, add its origin to `local.cluster_ingress` in
   `tofu/cluster.tf` and apply. DNS follows the map, so the record and the
   tunnel rule cannot drift:

```sh
tofu -chdir=tofu apply -no-color
dig +short photos.sammohr.dev
```

Expected: the CNAME points at `<cluster-uuid>.cfargotunnel.com` instead of the
host tunnel, and `kubectl -n ingress get deploy cloudflared` shows two ready
replicas. Deleting the entry from `local.cluster_ingress` flips that name back
to the host tunnel and is the rollback.

## 16. Capture the ACME account id for the CAA pin

`tofu/` pins `issue` and `issuewild` to the ACME account Kanbei's in-VM CSR
client registers with. Nothing blocks earlier applies: `acme_account_id`
defaults to empty and the two CAA records are created only once it is set, so
until this client has registered the zone simply has no CAA pin.

The responder exists only while the Kanbei VM is enabled (`kanbeiVm.enable`,
which waits on the GPU cutover): until then `kanbei-acme.service` is not defined,
`/var/lib/kanbei-acme` does not exist, and an empty `acme_account_id` is the
correct value. Re-run this step after that VM first requests a certificate.

The account URL the client prints on first registration ends in
`/acme/acct/<id>`:

```
Account URL: https://acme-v02.api.letsencrypt.org/acme/acct/<id>
```

Read it from that client's first-registration output or its persisted state;
registering the same account key again returns the same URL, so a lost log
costs a re-registration, not a new account. That trailing number goes into `acme_account_id` in `tofu/terraform.tfvars`:

```sh
tofu -chdir=tofu plan -no-color   # two CAA records to add
tofu -chdir=tofu apply -no-color
```

Then confirm what the world sees:

```sh
dig +short CAA sammohr.dev
```

Expected: the two pinned records (`issue` and `issuewild`, each with
`accounturi=https://acme-v02.api.letsencrypt.org/acme/acct/<id>`) **and** the
records Cloudflare appends for Universal SSL (`pki.goog`, `letsencrypt.org`,
`ssl.com`, `sectigo.com`). Those are added because the zone now has CAA records
and are not visible in the dashboard; `docs/cloudflare.md` explains why the pin
narrows but does not lock down issuance.

## 17. Retire `llm.sammohr.dev` and `chat.sammohr.dev`

Both applications carried `prevent_destroy`, so dropping the block cannot delete
them. Remove the state entry first, then the object:

```sh
tofu -chdir=tofu state rm cloudflare_zero_trust_access_application.llm
tofu -chdir=tofu state rm cloudflare_zero_trust_access_application.chat
```

Then in Zero Trust → Access → Applications delete the `llm` and `chat`
applications by hand, and confirm the state holds neither:

```sh
tofu -chdir=tofu state list | grep -E 'access_application\.(llm|chat)$' || echo "retired"
```

`webProxy.services` in nix-config loses both names in the change that removes
`tofu/`; until the host rebuild runs, the tunnel ingress still lists them, but
the wildcard application denies the hostnames, so the origin is unreachable:

```sh
curl -sS -o /dev/null -D - https://llm.sammohr.dev/ | head -3
```

Expected: `HTTP/2 302` with a `location:` on `*.cloudflareaccess.com`, never a
response from the host.

## 18. Prove the Access default-deny

The static half runs in CI; this is the live half, and it needs the token:

```sh
CLOUDFLARE_API_TOKEN=... tests/access/check.sh
```

Expected output is in `docs/cloudflare.md` ("Verifying"). The script asks the
API which application matches a fresh hostname (it must be the wildcard) and
then makes a real request: a `302` to the Access login is a pass, an answer from
the origin is a failure. Re-run it after any Access change; run it with
`ACCESS_PROBE_HOST=name.sammohr.dev` to check a specific hostname instead.

## 19. Publish the broker image and pin its digest

`apps/broker/` is the source and `clusters/homelab/broker/deployment.yaml` ships
a deliberate all-zero digest placeholder. From a machine with registry access:

```sh
docker build -t ghcr.io/smores56/homelab-platform/broker:<git-sha> apps/broker
docker push ghcr.io/smores56/homelab-platform/broker:<git-sha>
crane digest ghcr.io/smores56/homelab-platform/broker:<git-sha>
```

Replace the `image:` line with
`ghcr.io/smores56/homelab-platform/broker@sha256:<digest>`, delete the
`PLACEHOLDER DIGEST` comment, and run `scripts/kustomize-build-all.sh` and
`tests/policies/check.sh` before pushing. The Dockerfile's base tag
(`python:3.13-slim`) should be replaced with its digest in the same change. Normally `.github/workflows/publish-broker.yml` does all of this on a push to
`main` that touches `apps/broker/**` (or on manual dispatch): it builds, pushes
`sha-<first 12 of the commit>`, and prints both the tag and the digest in the
run summary. Use the manual commands above only when Actions is unavailable.
The image installs one pinned dependency, `cryptography==44.0.0` (RS256 JWT
signing); bump it deliberately with the image digest.

Verify: `kubectl -n broker get pods` shows two `Running` replicas on
`runsc`, and `kubectl -n broker get pod -o
jsonpath='{.items[0].spec.containers[0].image}'` prints the digest.

## 20. Route `agent.sammohr.dev` and retire `nanobot.sammohr.dev`

The two Access applications here are edge objects and survive the agent
runtime's retirement: `agent` stays, `nanobot` goes. What the retirement
changed is the origin. The cluster and the nanobot runtime that used to answer
`agent.sammohr.dev` are gone, and the agent plane on smortress is reached
through Tailscale Serve (40.4); the tunnel entry this section configures is the
historical route, kept because `tofu` state still carries it. No Cloudflare
credential goes into the agent.

**Order matters.** This change removes the `nanobot` Access application from
`tofu/access.tf`. It carried `prevent_destroy`, so the state entry is removed
before the first apply; applying first fails on the destroy.

1. Drop the retired object from state (the object still exists at the edge):

   ```sh
   tofu -chdir=tofu state rm cloudflare_zero_trust_access_application.nanobot
   ```

2. Set the cluster contract and apply. `tofu/cluster.tf` owns the tunnel's
   hostname config and refuses a `cluster_hosts` entry with no origin rule:

   ```sh
   tofu -chdir=tofu plan -no-color
   # expect: the agent CNAME, cloudflare_zero_trust_tunnel_cloudflared_config.cluster
   # with agent -> http://nanobot.tenant-apps.svc.cluster.local:80, the `agent`
   # Access application unchanged, and no `nanobot` application in the plan
   tofu -chdir=tofu apply -no-color
   dig +short agent.sammohr.dev      # CNAME <cluster-uuid>.cfargotunnel.com
   ```

   Do not add the public hostname in the Zero Trust dashboard. The
   `cloudflare_zero_trust_tunnel_cloudflared_config.cluster` resource is the
   source of truth; a dashboard edit is replaced by the next apply.

3. Mint the maki service token in Zero Trust → Access controls → Service credentials → Service tokens. The
   `service auth` policy already accepts any valid service token; store the
   `CF-Access-Client-Id`/`CF-Access-Client-Secret` pair in maki's client config,
   never in the image or this repository. The owner uses the browser identity.

4. Delete the `nanobot` application at the edge: Zero Trust → Access →
   Applications → `nanobot` → Delete. Its state entry is already gone, so a
   later apply neither recreates nor destroys it. This is the one part of the
   retirement no commit can do: until it is checked off, the application still
   exists at the edge even though nothing in this repository names it.

5. Verify the edge and the current agent plane. This section changes the Access
   application; the origin is the host's Serve route (40.10), not a pod:

   ```sh
   curl -sS -o /dev/null -D - https://agent.sammohr.dev/ | head -3     # 302 to *.cloudflareaccess.com
   curl -sS -o /dev/null -D - https://nanobot.sammohr.dev/ | head -3   # 302 to Access, never an origin
   curl -fsS -o /dev/null -w '%{http_code}\n' \
     https://smortress.<tailnet>.ts.net/apps/agent-general/v1/models
   ```

   Expect `401` on the last line: the facade answers, and a request with no key
   is refused by the facade rather than by a missing origin.

### Rotating the agent's WebUI password

The nanobot runtime held its own `config.json` and generated
`channels.websocket.tokenIssueSecret` on first start; that file, its renderer
and the pod that carried them are retired. The WebUI password is now one
ciphertext per deployment, decrypted at boot into the unit's environment file:
`secrets/server/agent-ui-personal-password.yaml` and
`agent-ui-general-password.yaml` (`docs/core/applications.md`). Rotate it the
way 40.7 rotates every agent secret:

```sh
sops secrets/server/agent-ui-personal-password.yaml   # set value: to `openssl rand -hex 32`
```

`smortress-agent-config.service` rewrites `webui.env` on the next boot, so the
rotation lands with a deploy (40.2) and invalidates every issued browser
session.

## 21. Kanbei public hostname behind Access

`tofu/kanbei.tf` creates the Access application for `kanbei.sammohr.dev`. The
hostname is published by the host tunnel's ingress in nix-config
(`webProxy.services.kanbei` -> `https://127.0.0.1:443`, the relay into the
guest), so the guest's certificate is what cloudflared verifies between the
connector and the origin. The wildcard CNAME in `tofu/main.tf` resolves the
name; no `cloudflare_dns_record` is created, and `tests/tofu/check.sh` asserts
that. A browser sees the Cloudflare edge certificate, not the guest's.

This change retires the private WARP hostname route, and that takes two applies.
OpenTofu refuses to destroy a resource whose state still carries
`prevent_destroy`, so the route's guard is dropped first and the follow-up
change deletes the resource.

1. Publish the ingress first, in nix-config: the same generation enables
   `kanbeiVm` and declares `webProxy.services.kanbei`. After the switch:

   ```sh
   curl -sS -o /dev/null -D - https://kanbei.sammohr.dev/ | head -3
   # expect: HTTP/2 302 to <team>.cloudflareaccess.com
   ```

2. Apply the application change; the plan must show no DNS record:

   ```sh
   tofu -chdir=tofu plan -no-color
   # expect: cloudflare_zero_trust_access_application.kanbei (update), nothing else
   tofu -chdir=tofu apply -no-color
   ```

3. Apply the route removal, in the commit that deletes the resource:

   ```sh
   tofu -chdir=tofu plan -no-color
   # expect: cloudflare_zero_trust_network_hostname_route.kanbei (destroy), nothing else
   tofu -chdir=tofu apply -no-color
   ```

4. Verify the name is public-but-gated and no private route survives:

   ```sh
   tofu -chdir=tofu state list | grep -E 'network_hostname_route|access_application\.kanbei$'
   dig +short kanbei.sammohr.dev      # Cloudflare edge addresses, never 172.64.128.0/20
   ```

   A token address from the Gateway initial-resolved range means a hostname
   route still exists, and WARP clients would take the retired path.

5. The application allows the owner email and **nothing else**. It deliberately
   does not attach the account-wide `service auth` policy: that decision accepts
   any valid service token in the account, so the agent's own token would open
   Kanbei. Do not attach it; an unattended client that must reach Kanbei needs
   its own Access decision plus a reviewed terraform change. `tests/tofu/check.sh`
   fails if a second policy (or a bypass) appears on the application.

## 22. Create the read-only mirror PAT and run `github-backup`

The CronJob in `clusters/homelab/platform/backup/` mirrors
`smores56/homelab-platform` and `smores56/homelab-apps` into a bundle on the
`github-backup-data` PVC. Its only credential is a fine-grained read-only PAT;
the script refuses a classic `ghp_` token at start.

1. Mint a fine-grained PAT (GitHub → Settings → Developer settings →
   Fine-grained tokens → Generate new token):

   - Resource owner: `smores56`.
   - Repository access: **Only select repositories** → `homelab-platform`,
     `homelab-apps`.
   - Permissions: **Contents: Read-only**; `Metadata: Read-only` is added
     automatically and is the only other permission. Nothing else — no
     Administration, no Pull requests, no Workflows.
   - Expiration: 90 days.

2. Store it as a SOPS contract Secret. `github-backup-read-pat.yaml` holds one
   key, `token`, and is encrypted with the operator's key:

   ```sh
   sops -e -i github-backup-read-pat.yaml
   kubectl -n platform create secret generic github-backup-read-pat-sops \
     --from-file=token=<(sops -d github-backup-read-pat.yaml | yq -r .token | tr -d '\n')
   ```

3. Resume the ESO stage (step 8) if it is not already running, then verify the
   projection without printing the value:

   ```sh
   kubectl -n platform get secret github-backup-read-pat -o jsonpath='{.data.token}' |
     base64 -d | cut -c1-12        # expect github_pat_
   ```

4. Run the job once and read its log. The log names the commit, ref count and
   bundle size; a missing bundle for an empty repository is reported as
   `commit=none` rather than a silent success.

   ```sh
   kubectl -n platform create job --from=cronjob/github-backup github-backup-manual
   kubectl -n platform logs job/github-backup-manual -f
   kubectl -n platform get pvc github-backup-data    # Bound
   ```

   Restore check: copy the bundle out of a completed job pod before its
   24-hour TTL expires and clone it offline.

   ```sh
   pod=$(kubectl -n platform get pods -l job-name=github-backup-manual -o name | head -1)
   kubectl -n platform cp "$pod:/backup/bundles/smores56/homelab-platform.bundle" .
   git clone homelab-platform.bundle /tmp/restore-check
   ```

5. Revoke the classic write PAT the old host-side mirror used. The cluster job
   never needs one: it clones over HTTPS with `x-access-token` and the
   fine-grained token. GitHub → Settings → Developer settings → Personal access
   tokens → **Tokens (classic)** → delete the token with `repo` scope. Confirm
   the list is empty (or holds only unrelated tokens) before recording the step
   as done.

6. The nightly run is `15 4 * * *` Europe/Berlin, after the host's restic walk.
   Rotation is: mint the replacement in step 1, repeat step 2, wait for the 1h
   ESO refresh (or delete the projected Secret so it is recreated), then revoke
   the old PAT.

## 23. Verify the digest job, the share and the host writer hand-off

The CronJob in `clusters/homelab/platform/digest/` writes `latest.json` and 96
snapshots to `/mnt/data/cluster-digest`; the host reads the same tree at
`/var/lib/data/cluster-digest` and age-encrypts each new document into Kanbei's
inbox. The cluster holds no age key.

1. Land the share in nix-config. The guest module must list the share, or the
   PVC stays Pending and nothing is written:

   ```nix
   # modules/nixos/cluster-vm.nix, the dataShares list (lines 25-30)
   dataShares = [
     "immich"
     "music"
     "books"
     "graphiti"
     "cluster-digest"
   ];
   ```

   Rebuild the `cluster` guest, then confirm the host directory exists with the
   owner the guest translation maps to (uid 1000):

   ```sh
   ls -ld /var/lib/data/cluster-digest
   cluster-kubectl get nodes -o wide          # node name must be `cluster`
   ```

2. Confirm the static volume and the claim bound to it:

   ```sh
   kubectl get pv cluster-digest-share        # Bound, cluster-digest-data
   kubectl -n observability get pvc cluster-digest-data   # Bound
   ```

   A Pending claim means step 1 is missing or the node name is not `cluster`;
   the PV's node affinity fails closed rather than binding elsewhere.

3. Run the job once and read its log. The builder prints one JSON summary line
   (`generated_at`, `bytes`, `events`, `pruned`) and exits 1 when either source
   failed, so a failed read is visible without opening the document:

   ```sh
   kubectl -n observability create job --from=cronjob/cluster-digest cluster-digest-manual
   kubectl -n observability logs job/cluster-digest-manual -f
   ```

4. Read the document on the host. `jq` shows the schema version, a fresh UTC
   `generated_at`, and an event count at or below 400; `wc -c` must stay at or
   below 65536. Both freshness entries carry a *measured* age, not a constant:

   ```sh
   jq -r '.schema_version, .generated_at, .source_freshness,
     (.nanobot_activity.events|length)' /var/lib/data/cluster-digest/latest.json
   wc -c /var/lib/data/cluster-digest/latest.json
   ls /var/lib/data/cluster-digest | wc -l    # latest.json + at most 96 snapshots
   ```

   - `status_exporter.age_seconds` is `generated_at` minus the exporter's
     `last_scrape_timestamp_seconds`, so it is under 90 s when the exporter is
     refreshing. `ok: false` means the exporter was unreachable or its last
     scrape failed, and the job exits 1.
   - `loki_gateway.age_seconds` is `generated_at` minus the newest stored
     data-tenant entry. `age_seconds: null` with `stale: true` means the 15 m
     window held no data-tenant line at all: the Vector write path is broken
     (or nothing logged), and the job logs `digest: stale source loki_gateway`
     on stderr while still writing the document. Do not read an empty
     `nanobot_activity` as a quiet host unless `stale` is false.

   The schedule is `*/15 * * * *` UTC, so `generated_at` should be no more than
   15 minutes old at any time. A stale `generated_at` means the CronJob is not
   running; a fresh `generated_at` with `ok: false` means a source is down.

5. Confirm the host writer's half. It watches only `latest.json` (snapshots are
   local debugging history), uses `generated_at` as a cursor so a restart does
   not duplicate a batch, and drops age ciphertext into `/var/lib/data/inbox`
   (T14). A new file in the inbox starting with `age-encryption.org/v1` is the
   successful end-to-end:

   ```sh
   ls -t /var/lib/data/inbox | head -1
   head -c 30 /var/lib/data/inbox/"$(ls -t /var/lib/data/inbox | head -1)"; echo
   ```

6. Confirm there is no way back. No Service selects the digest pod and no
   ingress policy opens it to another namespace:

   ```sh
   kubectl -n observability get svc -l app.kubernetes.io/name=cluster-digest   # empty
   kubectl -n observability get networkpolicy cluster-digest-egress \
     -o jsonpath='{.spec.policyTypes}{"\n"}{.spec.ingress}{"\n"}'             # Egress,Ingress / nothing
   ```

## 24. Provision the notification bus credentials

The `notify` logical host (SDLC #640) now names the real bus (SDLC #649):
`https://ntfy.sammohr.dev`, `POST` on a single-segment topic, body capped at
4 KiB, `Authorization: Bearer <notify-token>` injected, `allow_private: false`.
The bus is `clusters/homelab/notify/` and its shape is `docs/notify.md`; the
hostname's tunnel route is the `cluster_ingress` entry applied in step 15.

Two Secrets are created here by hand. Neither value is in git.

| Secret | Namespace | Keys | Read by |
| --- | --- | --- | --- |
| `ntfy-auth-sops` | `notify` | `users`, `tokens`, `access` | ESO projects it into `ntfy-auth`, which the Deployment reads as `NTFY_AUTH_USERS` / `_TOKENS` / `_ACCESS` |
| `broker-credentials` | `broker` | `notify-token` | the broker, injected as the bearer on `notify` |

Five tokens, one per holder, so revocation is per device:

| User | ACL | Token holder |
| --- | --- | --- |
| `sam` | admin — no ACL entry, ntfy rejects one | the web UI login; the password is the only credential a human types |
| `agent` | `agent:wo` | `notify-token` in `broker-credentials` — the agent |
| `publisher` | `alerts:wo` | `ntfy-publish@.service` on the host and `notifyrelay` in the cluster |
| `reader` | `alerts:ro`, `agent:ro` | the phone and the laptop, one token each |

`agent` is a separate user from `publisher` on purpose: the broker's
`allow_paths` is a single-segment regex, not a topic allowlist, so a publisher
token would let the agent page `alerts`. The bus enforces the boundary, not the
broker.

Generate the values without them reaching the command line or a transcript:

```sh
umask 077
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
# five tokens, 32 characters each: tk_ plus 29 from the ntfy alphabet
for u in sam agent publisher phone laptop; do
  printf 'tk_%s\n' "$(openssl rand -base64 64 | tr -dc 'A-Za-z0-9_-')" \
    | cut -c1-32 > "$tmp/tk_$u"
done
# one bcrypt hash per user; token-only users still need one, an empty hash is rejected
for u in sam agent publisher reader; do
  read -rsp "password for $u: " P; echo
  htpasswd -bnBC 10 "" "$P" | tr -d ':\n' > "$tmp/hash_$u"; unset P
done
```

Assemble the three lists and create the Secret. It must exist before the
`platform-notify` stage applies the Deployment, or the pod sits in
`CreateContainerConfigError` on the missing `ntfy-auth`:

```sh
cd "$tmp"
printf 'sam:%s:admin,agent:%s:user,publisher:%s:user,reader:%s:user\n' \
  "$(cat hash_sam)" "$(cat hash_agent)" "$(cat hash_publisher)" "$(cat hash_reader)" > users
printf 'sam:%s:web,agent:%s:broker,publisher:%s:host,reader:%s:phone,reader:%s:laptop\n' \
  "$(cat tk_sam)" "$(cat tk_agent)" "$(cat tk_publisher)" "$(cat tk_phone)" "$(cat tk_laptop)" > tokens
printf 'agent:agent:wo,publisher:alerts:wo,reader:alerts:ro,reader:agent:ro\n' > access
sudo cluster-kubectl -n notify create secret generic ntfy-auth-sops \
  --from-file=users --from-file=tokens --from-file=access
```

The Secret is created after Flux has already applied the Deployment, so the
first reconcile of `ntfy-auth` fails with `could not get secret data from
provider` and the pod sits `Pending` on `secret "ntfy-auth" not found`. The
ExternalSecret retries on `refreshInterval: 1h`; force it rather than waiting:

```sh
sudo cluster-kubectl -n notify annotate externalsecret ntfy-auth \
  force-sync="$(date +%s)" --overwrite
sudo cluster-kubectl -n notify rollout status deployment/ntfy --timeout=120s
```

`delete secret ntfy-auth` does not help at this point: `creationPolicy: Owner`
and the Secret was never created, so there is nothing to delete. That lever is
for a rotation, where the Secret exists and still holds the old value.

Then hand the `agent` token to the broker and restart it — it reads credentials
once at start:

```sh
sudo cluster-kubectl -n broker patch secret broker-credentials --type merge \
  -p "$(jq -nc --rawfile v "$tmp/tk_agent" '{stringData:{"notify-token":$v}}')"
sudo cluster-kubectl -n broker rollout restart deployment/broker
```

Verify, in this order:

```sh
# 1. ESO projected all three keys
sudo cluster-kubectl -n notify get secret ntfy-auth -o jsonpath='{.data}' | jq 'keys'
# 2. the bus is up and provisioned the users
sudo cluster-kubectl -n notify exec deploy/ntfy -- ntfy user list
# 3. a publish through the broker, from the only place the token exists
sudo cluster-kubectl -n broker exec deploy/broker -- python -c '
import http.client
c = http.client.HTTPConnection("127.0.0.1", 8080, timeout=20)
body = b"broker notify check"
c.putrequest("POST", "/notify/agent?title=broker&priority=low", skip_host=True)
c.putheader("Host", "broker.broker.svc.cluster.local")
c.putheader("Content-Type", "text/plain")
c.putheader("Content-Length", str(len(body)))
c.endheaders(); c.send(body)
r = c.getresponse(); print(r.status, r.read(200)); c.close()
'
# 4. the reader can see it
curl -s -u ":$(cat "$tmp/tk_phone")" \
  'https://ntfy.sammohr.dev/agent/json?poll=1&since=10m'
```

Step 3 expects `200` and a JSON body with an `id`; step 4 expects the same
message. Failures, by status:

| Status | Meaning |
| --- | --- |
| `502 dns_failure` | the tunnel route is not applied (step 15) or DNS has not propagated |
| `503 credential_unavailable` | `notify-token` is absent from `broker-credentials`, or the broker was not restarted |
| `401` | the token is not in `auth.db`: the Secret was edited without a `rollout restart deployment/ntfy` |
| `403` | the ACL does not cover the topic — `agent` may only write `agent` |
| `429` | the per-visitor limiter (burst 120, replenish 2s); a reconcile loop, not a person |
| `413` | the body is over the 4 KiB cap; raise `max_body_bytes` deliberately |

The body is never logged or echoed, and the bus's response is redacted like
every other host's. Rotation: replace the key in `ntfy-auth-sops`, then either
wait for the ESO refresh (1h) or delete `ntfy-auth` so it is recreated — the
Secret exists by then, so the delete is the faster lever — and restart the
Deployment. Provisioned users are immutable through the CLI, so the Secret is
the only path. `broker-credentials-contract` already lists `notify-token`, and
`tests/policies/check.sh` fails if the enrollment and that contract drift apart.

## 25. Admit the broker to agent-control

The broker's `self` logical host (SDLC #637) calls
`agent-control.tenant-apps.svc.cluster.local:8081`. The broker-side egress rule
is in this repository (`clusters/homelab/broker/egress-agent-control.yaml`), but
`tenant-apps` is default-deny, so the Service stays unreachable until the tenant
repository admits the broker namespace on that port. That rule belongs with the
agent-control manifests in `homelab-apps`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: agent-control-from-broker
  namespace: tenant-apps
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: agent-control
  policyTypes: ["Ingress"]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: broker
      ports:
        - protocol: TCP
          port: 8081
```

Verify both halves after both changes land:

```sh
sudo cluster-kubectl -n tenant-apps get networkpolicy agent-control-from-broker
sudo cluster-kubectl -n broker get networkpolicy egress-agent-control
sudo cluster-kubectl -n broker exec deploy/broker -- python -c '
import http.client
c = http.client.HTTPConnection("127.0.0.1", 8080, timeout=20)
c.putrequest("GET", "/self/self/status", skip_host=True)
c.putheader("Host", "broker.broker.svc.cluster.local")
c.endheaders(); r = c.getresponse(); print(r.status, r.read(120)); c.close()
'
```

A `502 dns_failure` means the Service name does not resolve (the agent-control
Service is missing); a timeout is the CNI dropping the packet, i.e. the
tenant-side ingress policy above is absent. No credential is involved: the
`self` host has none, and the namespace policy is the caller boundary.
## 26. Verify the `agent-control` service

The agent's cluster API capability is applied by Flux (stage
`platform-agent-control`, source `clusters/homelab/agent-control`); nothing here
creates it. This step is the post-apply proof that what runs is the reviewed
capability: ten routes, no Secrets, one pod-template write, one Actions
dispatch, and no second API client. The dispatch token is step 33; without it
the build route answers `503` and every other route is unaffected.

The image is `python@sha256:…` — the same base digest the broker's Dockerfile
pins, with no tag (a tag plus digest still counts as a tagged image, and
`tenant-images` rejects it). Bump both pins in one change.

1. Confirm the identity and both RBAC halves:

   ```sh
   kubectl -n tenant-apps get sa agent-control \
     -o jsonpath='{.automountServiceAccountToken}{"\n"}'            # true
   kubectl -n tenant-apps get role agent-control -o yaml | sed -n '/rules:/,$p'
   kubectl get clusterrole agent-control-read -o yaml | sed -n '/rules:/,$p'
   ```

   Expect `pods`, `pods/log`, `events` get/list/watch and one `deployments`
   patch scoped by `resourceNames: [nanobot]` in the Role; `pods`, `events`,
   `nodes` reads, `apps` workload reads and Flux `kustomizations` in the
   ClusterRole. No `secrets`, no `configmaps`, no create/update/delete.

2. Probe the authorisation decisions rather than reading them:

   ```sh
   sa=system:serviceaccount:tenant-apps:agent-control
   kubectl auth can-i list pods -A --as "$sa"                          # yes
   kubectl auth can-i get pods/log -n tenant-apps --as "$sa"           # yes
   kubectl auth can-i patch deployments/nanobot -n tenant-apps --as "$sa"  # yes
   kubectl auth can-i patch deployments/bench -n tenant-apps --as "$sa"    # no
   kubectl auth can-i get secrets -A --as "$sa"                        # no
   kubectl auth can-i list configmaps -A --as "$sa"                    # no
   kubectl auth can-i delete nodes --as "$sa"                          # no
   ```

3. Exercise the HTTP surface. A port-forward travels the kubelet, so it works
   regardless of the NetworkPolicy and shows up in the audit line as
   `caller=127.0.0.1`; the broker path is the only normal caller.

   ```sh
   kubectl -n tenant-apps port-forward svc/agent-control 18081:8081 &
   curl -s localhost:18081/self/status | jq '{deployment: .deployment.name, pods: (.pods|length)}'
   curl -s "localhost:18081/self/logs?tail=20" | jq '.tail'          # 20
   curl -s localhost:18081/cluster/nodes | jq '[.nodes[] | {name, ready}]'
   curl -s localhost:18081/cluster/workloads | jq '.workloads | length'
   curl -s localhost:18081/cluster/flux | jq '[.kustomizations[] | {name, ready}]'
   curl -s -o /dev/null -w '%{http_code}\n' localhost:18081/healthz          # 404
   curl -s -o /dev/null -w '%{http_code}\n' localhost:18081/api/v1/secrets   # 404
   curl -s -o /dev/null -w '%{http_code}\n' localhost:18081/self/restart     # 405
   ```

   A `502` on a route means the service's own API call failed: re-run the
   `can-i` probes in step 2, then check the API egress policy
   (`kubectl -n tenant-apps get networkpolicy agent-control-kubernetes-api-egress -o yaml`).

4. The one write. It patches a pod-template annotation and nothing else, so the
   restarted pod is a normal rollout:

   ```sh
   curl -s -X POST localhost:18081/self/restart | jq .
   kubectl -n tenant-apps rollout status deploy/nanobot --timeout=180s
   kubectl -n tenant-apps get deploy nanobot \
     -o jsonpath='{.spec.template.metadata.annotations.homelab\.dev/restart-requested-at}{"\n"}'
   ```

5. Confirm the audit trail and that nothing credential-shaped is in it:

   ```sh
   kubectl -n tenant-apps logs deploy/agent-control --tail=10
   # every request line: level=audit method=… path=… status=… caller=… duration_ms=…
   kubectl -n tenant-apps logs deploy/agent-control | grep -c 'Bearer ' || true   # no match
   ```

   The `self` logical host in `broker.json` is enrolled by its own change; until
   that lands, the port-forward above is the only way to reach the service.
## 27. Publish the webhook image, create its tokens, and register a source

The receiver in `clusters/homelab/webhook/` ships the same all-zero digest
placeholder the broker started with, and its pods stay pending until
`webhook-tokens` exists (`docs/webhook.md`). The hostname is public by
construction: there is no Access login for GitHub.

1. Publish and pin the image. `.github/workflows/publish-webhook.yml` does this
   on a push to `main` under `apps/webhook/**` (or on manual dispatch) and prints
   the digest in the run summary. By hand:

   ```sh
   docker build -t ghcr.io/smores56/homelab-platform/webhook:<git-sha> apps/webhook
   docker push ghcr.io/smores56/homelab-platform/webhook:<git-sha>
   crane digest ghcr.io/smores56/homelab-platform/webhook:<git-sha>
   ```

   Replace the `image:` line in `deployment.yaml` with
   `ghcr.io/smores56/homelab-platform/webhook@sha256:<digest>`. Pin the
   Dockerfile's base digest (`python:3.13-slim`) in the same change.

2. Create the token Secret. `admin-token` is fresh randomness; `enqueue-token`
   is the gateway's `channels.websocket.tokenIssueSecret`:

   ```sh
   kubectl -n tenant-apps exec deploy/nanobot -- \
     sh -c 'jq -r .channels.websocket.tokenIssueSecret "$HOME/.nanobot/config.json"'
   kubectl -n webhook create secret generic webhook-tokens \
     --from-literal=admin-token="$(openssl rand -hex 32)" \
     --from-literal=enqueue-token="<value printed by the previous command>"
   ```

   The gateway generates that secret on first start when `NANOBOT_WEB_TOKEN` is
   unset. If the nanobot scratch PVC is ever recreated, the value changes: read
   it again, replace `enqueue-token`, and restart the receiver. The durable fix
   is a `NANOBOT_WEB_TOKEN` from a tenant secret in `homelab-apps`.

3. Register the source. Registration needs the admin token and is reachable from
   the cluster only:

   ```sh
   kubectl -n webhook port-forward deploy/webhook 8080:8080 &
   admin=$(kubectl -n webhook get secret webhook-tokens -o jsonpath='{.data.admin-token}' | base64 -d)
   curl -sS -X POST http://127.0.0.1:8080/endpoints \
     -H "Authorization: Bearer $admin" -H 'Content-Type: application/json' \
     -d '{"name":"github-platform","secret":"<the GitHub webhook secret>"}'
   ```

   The answer carries `capability_id` and `capability_url`
   (`https://agent-hooks.sammohr.dev/hooks/<id>`), plus `hmac: true`. Configure
   the GitHub webhook with that URL, content type `application/json`, and the
   same secret. The capability id is a URL credential: do not paste it into an
   issue, a log or a commit.

4. Rotate or revoke. Re-post the same `name` (with a fresh secret if the HMAC is
   changing): the old id stops resolving in the same write and the answer carries
   the new URL. `DELETE /endpoints/<id>` with the admin token revokes a source
   without a replacement.

5. Verify.

   ```sh
   curl -sS https://agent-hooks.sammohr.dev/healthz             # {"status":"ok"}
   curl -sS -o /dev/null -w '%{http_code}\n' \
     https://agent-hooks.sammohr.dev/hooks/does-not-exist        # 404
   kubectl -n webhook logs deploy/webhook | tail -5              # route=hook status=202
   ```

   A `502 gateway unavailable` means `enqueue-token` does not match the gateway;
   a `401 invalid signature` means the source secret differs from the provider's.
   Both fail before the agent sees anything. The receiver has no rate limit of
   its own; a body over 1 MiB is refused with `413` and repeats within 6 h are
   acknowledged without a second enqueue.
## 28. Give each tree its restic Secret, then run the drill

> Pre-#660. These per-tree cluster jobs (#619) are the live scheme until
> cutover. Step 35 replaces the model with one repository per recovery group,
> written by the host and replicated with `restic copy`, and retires these
> CronJobs at cutover; keep this section and the jobs running until then.

Four trees now back themselves up from the cluster (`clusters/homelab/data/*/restic-backup.yaml`,
SDLC #619): `immich`, `navidrome`, `graphiti` and `opdshelf`, each with its own
CronJob, its own claim mounted read-only and its own repository at
`s3:https://<account>.r2.cloudflarestorage.com/restic-backup/trees/<tree>`. The
host's `restic-backups-r2.timer` keeps running and stays the owner of every tree
until that tree's drill below passes; nothing in this repository stops it.

The namespace was named `calibre` before this rename, so Flux prunes the old
namespace and deletes its `calibre-*` objects — names it previously carried —
in the same reconcile that creates the `opdshelf` ones. The PV data is
untouched because it points at the `/mnt/data/books` share, not at the
namespace. The old restic prefix `trees/calibre`, previously this tree's
repository, is orphaned in R2 (the operator may delete it); the new
`trees/opdshelf` tree starts empty, so the books backup stays on the host timer
until the new drill below passes.

1. Create one SOPS Secret per namespace. The R2 key pair is the host's existing
   one (`r2-access-key-id` / `r2-secret-access-key` in nix-config's
   `secrets/smortress.yaml`); `restic-password` is the password the host's
   repository already uses, so the operator can read both repositories with the
   same key. Encrypt the file with the operator's age key and never commit it,
   then:

   ```sh
   for ns in immich navidrome graphiti opdshelf; do
     kubectl -n "$ns" create secret generic restic-backup-sops \
       --from-file=r2-access-key-id --from-file=r2-secret-access-key \
       --from-file=restic-password
   done
   ```

   `ExternalSecret` `restic-credentials` in each namespace projects it with the
   key names the jobs read (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
   `RESTIC_PASSWORD`). The `platform-secrets-eso` stage must be resumed first
   (step 8), or the two CronJobs stay unschedulable on a missing Secret.

2. Run the preflight for each tree. It proves read access as uid 1000, creates
   the repository if it does not exist yet, then reads back a metadata check and
   100 MiB of data:

   ```sh
   for ns in immich navidrome graphiti opdshelf; do
     kubectl -n "$ns" create job --from=cronjob/restic-preflight "preflight-$(date +%s)"
   done
   kubectl -n immich get jobs -w        # then the other three namespaces
   kubectl -n immich logs job/<name>
   ```

   A job that lists unreadable paths means that tree is not yet safe as uid 1000:
   leave it on the host timer and fix the ownership on the share
   (`sudo chown -R smores:users /var/lib/data/<tree>` from the host, which is the
   uid 1000 mapping). Do not `chmod -R` a live database directory.

3. Run the first upload with the script, not with `kubectl create job`. The
   first run reads the whole tree and takes hours on `immich` and `navidrome`,
   while `create job` has no deadline flag: the Job it clones keeps the
   CronJob's `activeDeadlineSeconds`, dies `DeadlineExceeded` part-way through,
   and is deleted with its pod — so there is no log to explain it. The script
   patches the deadline onto the Job and reads it back from the API before it
   lets the upload run:

   ```sh
   scripts/restic-first-backup.sh --tree navidrome
   scripts/restic-first-backup.sh --tree immich
   kubectl -n immich get job <name> -o jsonpath='{.spec.activeDeadlineSeconds}{"\n"}'
   kubectl -n immich logs -f job/<name>
   kubectl -n immich get cronjob restic-backup -o jsonpath='{.status.lastSuccessfulTime}{"\n"}'
   ```

   Start one tree at a time: the repository lock is per tree, but a second
   upload of the same tree re-reads everything from byte 0. On smortress, where
   the admin kubeconfig is root-only, prefix the command with
   `KC='sudo cluster-kubectl'` — the script prints that hint itself when the
   client it picked cannot read the cluster. An interrupted first upload is safe
   to repeat — restic skips blobs the repository already holds — but never run
   `forget --prune` before the first snapshot exists, or the uploaded packs it
   does not reference yet are collected. Start right after a nightly run (05:00
   Europe/Berlin): `concurrencyPolicy: Forbid` covers only the Jobs the CronJob
   creates, so a nightly run that begins while a first upload is alive walks the
   same tree a second time.

   Follow the upload with `sudo scripts/restic-progress.sh` (add
   `--tree <name>` for one tree, `--once` to append a snapshot to a log). It
   streams each Job's log and renders the `--json` status record — percentage,
   bytes against restic's own total, file count and ETA — and reports a Job that
   stopped from its own state: `idle — … completed` for a finished run,
   `killed by its deadline` for a deadline kill, which takes the pod and its log
   with it.

4. Run the drill from a workstation. The exact commands are the `drill` key of
   the tree's `restic-contract` ConfigMap, and the preflight prints the same text
   on every run, so the two cannot disagree:

   ```sh
   kubectl -n immich get configmap restic-contract -o jsonpath='{.data.drill}{"\n"}'
   ```

   The drill passes when `restic snapshots --host cluster-<tree>` shows a
   snapshot from the last night and the restored file opens. Only then does that
   tree leave the host timer — a separate change in nix-config that removes one
   tree from `restic-backups-r2`'s `paths`/`backupPrepareCommand`. A tree that
   fails the drill stays host-side; the cluster job may keep running beside it,
   since the two write different repositories.

5. Re-pin the restic image when upgrading. The job pins the 0.18.1 manifest list;
   the commands are the same as step 9:

   ```sh
   crane digest docker.io/restic/restic:0.18.1
   ```

The failure signal for a tree is the Alertmanager route in step 29
(`ResticBackupStale` fires when no successful run has been recorded for 26 hours)
— check `kubectl -n <ns> get jobs` and the Job's log before assuming the share is
the problem.

## 29. Create the notify relay token and send a test alert

Cluster alerts and Flux reconcile failures go Prometheus → Alertmanager →
`notifyrelay` → ntfy topic `alerts` (`clusters/homelab/observability/`,
`clusters/homelab/flux-system/alerts/`). The relay needs one credential: the
bus's `publisher` token, which is write-only on `alerts`.

1. Take the `publisher` token from the bus's `ntfy-auth-sops` Secret (step 24)
   and store it as the relay's own Secret:

   ```sh
   kubectl -n observability create secret generic notify-relay-sops \
     --from-literal=token=<publisher token>
   ```

   Do not commit that file. `ExternalSecret` `notifyrelay-token` projects it, and
   the `platform-observability-secrets` stage must be resumed first (step 8). It
   is deliberately not the broker's `agent` token: revocation stays per source,
   so a leaked relay token cannot page the agent and a leaked agent token cannot
   page a human.

2. Confirm the whole chain before trusting it:

   ```sh
   kubectl -n observability get deploy alertmanager notifyrelay
   kubectl -n observability port-forward svc/alertmanager 9093:9093 &
   curl -s -XPOST localhost:9093/api/v2/alerts -H 'Content-Type: application/json' -d '[{
     "labels": {"alertname": "NotifyPathTest", "severity": "warning", "namespace": "observability"},
     "annotations": {"summary": "manual test of the alert path"}}]'
   kubectl -n observability logs deploy/notifyrelay --tail=20
   ```

   The relay log shows `"POST /alert HTTP/1.1" 200`; a 502 means the publish
   failed and the body names the status — `401` is a token the bus does not know
   (the Secret was replaced without restarting ntfy), `403` is an ACL miss (the
   token is not `publisher`), `413` is a body over the bus's 16 KiB limit. The
   test alert resolves after `global.resolve_timeout` (5m) and sends a second,
   resolved notification.

3. Exercise the Flux half without waiting for a real failure:

   ```sh
   kubectl -n observability port-forward svc/notifyrelay 8080:8080 &
   curl -s -XPOST localhost:8080/flux -H 'Content-Type: application/json' -d '{
     "involvedObject": {"kind": "Kustomization", "namespace": "flux-system", "name": "platform-observability"},
     "severity": "error", "reason": "ReconciliationFailed", "message": "manual test"}'
   ```

   Then confirm the real path: `kubectl -n flux-system get provider,alert` shows
   `notifyrelay` and `cluster`, and a deliberately broken Kustomization produces
   one notification within a reconcile interval.

4. Only after a real notification arrives on the phone and the laptop may a
   moved unit lose its `cloudflare-email@` hook (step 24's cutover). Host-only
   units keep it until the host lane's `ntfy-publish@` lands.

5. Rotating the token is: replace the `publisher` token in `ntfy-auth-sops`,
   restart the bus so it re-provisions `auth.db`, then replace
   `notify-relay-sops` and wait for the 1h ESO refresh (or delete
   `notifyrelay-token`). The relay reads the mounted file per delivery, so
   nothing restarts.

## 30. Cut `memory.sammohr.dev` over to the cluster tunnel

The wrapper runs in `graphiti`; its route is now platform config
(`memory = "http://memory-mcp.graphiti.svc.cluster.local:8182"` in
`tofu/cluster.tf`), and the platform admits the tunnel in
`memory-mcp-from-ingress`. This step is the gate before the host side loses its
copy; deleting `memory-forward` itself is the nix-config lane's change, only
after this passes.

1. Apply the zone: `./scripts/tofu-cloudflare.sh plan` must show exactly one new
   DNS record for `memory`, a proxied CNAME to the cluster tunnel, and the cluster
   tunnel's ingress list gaining the
   `memory.sammohr.dev -> http://memory-mcp.graphiti.svc.cluster.local:8182` rule.
   The host tunnel's own `memory` rule lives in nix-config (`web-proxy.nix`), not
   here, so it is removed in the host lane's commit — until then it is simply
   unreachable, because the DNS record now points at the other tunnel.

2. Apply the network half and confirm the flow exists:

   ```sh
   cluster-kubectl -n graphiti get networkpolicy memory-mcp-from-ingress
   cluster-kubectl -n graphiti get networkpolicy memory-mcp-nodeport-from-host   # kept
   ```

3. Probe through Access with a service token (the same token maki uses):

   ```sh
   curl -sS -o /dev/null -w '%{http_code}\n' \
     -H "CF-Access-Client-Id: $ACCESS_CLIENT_ID" \
     -H "CF-Access-Client-Secret: $ACCESS_CLIENT_SECRET" \
     https://memory.sammohr.dev/health          # expect 200
   ```

   A 403 with the Cloudflare error page means the Access application does not
   admit the token; a 502 means the tunnel has no healthy origin (check
   `cluster-kubectl -n graphiti get endpoints memory-mcp`); a 404 means the
   ingress rule was not applied.

4. Only after the 200: repoint the host clients (`maki`'s shim and the memory
   CLI) at `https://memory.sammohr.dev/mcp` and delete `memory-forward.nix` in
   nix-config. Until then both paths run, and `memory-forward` keeps loopback
   working.

5. Rollback before step 4 is removing `memory` from `local.cluster_ingress` (or
   pinning `cluster_hosts` without it) and re-adding the host tunnel route; the
   wrapper and its data are untouched by that.
## 31. Publish the nanobot image and enable its automation

Retired. Nothing in this repository builds, publishes or rolls the agent
runtime, and the workflow this section drove (`publish-nanobot.yml`) no longer
exists: `images/nanobot/` and its render tests were deleted with the runtime.
The Flux image automation it configured (`ImageRepository`, `ImagePolicy`,
`imageupdateautomation nanobot`) went with the k3s/Flux tree, and the
`nanobot-policy` ConfigMap, its admission pins and the scratch PVC went with the
cluster.

The agent plane that replaced it is the smortress Quadlet plane: the units ship
inside the bootc image (`units/quadlet/`), so an agent change is an image change
plus a maintenance-window reboot, not a published tenant image. Section 40 is
where that work happens: 40.2 deploys the image that ships the Quadlets, 40.7
creates the agent secrets, and 40.11 rotates a facade token.

## 32. Project the memory token into `broker-credentials` and probe the `memory` host

The broker's `memory` logical host (SDLC #631) calls the graphiti wrapper at
`memory-mcp.graphiti.svc.cluster.local:8182` with the same bearer token the
wrapper already enforces. That value lives in the graphiti Secret
`memory-mcp-token` (key `token`, projected from `memory-mcp-token-sops` in step
12). The broker reads credentials as files, so the value must also be a file
named `memory-mcp-token` in `broker-credentials` (step 10 created the rest).
The enrollment declares `optional_secret`: until this step runs, `memory`
answers `503 credential_unavailable` and the rest of the broker is unaffected.

Run this on smortress as `smores`. The value never reaches the command line or
a transcript: it is already base64 in the API server, and only a 0600 temporary
patch file holds it.

```sh
TOKEN_B64=$(sudo cluster-kubectl -n graphiti get secret memory-mcp-token \
  -o jsonpath='{.data.token}')
umask 077
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
printf '{"data":{"memory-mcp-token":"%s"}}\n' "$TOKEN_B64" >"$tmp/patch.json"
unset TOKEN_B64
sudo cluster-kubectl -n broker patch secret broker-credentials \
  --type merge --patch-file "$tmp/patch.json"
sudo cluster-kubectl -n broker rollout restart deployment/broker
sudo cluster-kubectl -n broker rollout status deployment/broker --timeout=120s
```

`patch --type merge` adds the one key and leaves the other files untouched; a
`create secret --from-file` of the whole directory would have replaced them.
Credentials are read once at start, hence the rollout.

Probe through the broker itself, so the injected header is what the wrapper
checks. The explicit `Host` matters: curl to `127.0.0.1` would otherwise send an
IP-literal Host, which the broker refuses with `400 ip_literal_host`.

```sh
sudo cluster-kubectl -n broker port-forward deploy/broker 18080:8080 &
sleep 2
curl -sS -o /dev/null -w '%{http_code}\n' -H 'Host: broker.broker.svc.cluster.local' \
  'http://127.0.0.1:18080/memory/health'          # expect 200
curl -sS -o /dev/null -w '%{http_code}\n' -X POST \
  -H 'Host: broker.broker.svc.cluster.local' \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"broker-probe","version":"0"}}}' \
  'http://127.0.0.1:18080/memory/mcp'             # expect 200
kill %1
```

`/memory/health` proves the two network halves (`egress-memory` in `broker`,
`memory-mcp-from-broker` in `graphiti`); `/memory/mcp` proves the credential,
because the wrapper exempts only `/health` from its bearer gate.

Expected: `200` and `200` (the second is the MCP `initialize` result). A `503`
(`credential_unavailable`) means the pod started without the file: the patch
did not land or the rollout replaced nothing. A `502` (`upstream_unreachable`)
means the wrapper Service or the NetworkPolicy pair is missing. A `401` from the
wrapper means the projected value differs from the one the wrapper reads; a
`503` with `token missing` in the wrapper's log means its own
`memory-mcp-token-sops` projection is broken (step 12).

Rotation: rewrite `memory-mcp-token-sops` (step 12), let ESO refresh the graphiti
Secret and restart the wrapper, then repeat this step so the broker holds the
new value.

## 33. Create the build dispatch token for `POST /self/build`

Retired. The endpoint existed to start `publish-nanobot.yml` through the Actions
API (`docs/flux.md`, "Dispatch contract"), and that workflow no longer exists.
`agent-control` was a cluster Deployment and went with the k3s/Flux tree, so
there is no `self` route to call and no token to mint: the build Secret, its
`/run/build/token` mount and the `503 build_unavailable` path have nothing left
to authenticate.

Reviving the route means naming a workflow that still exists and owning it in
this repository first; do not recreate the credential in anticipation of one.

## 34. Grant the app `Repository webhooks` and re-consent the installation

The `github-hooks` logical host (SDLC #628) registers outbound repository
webhooks that GitHub delivers to `https://agent-hooks.sammohr.dev/`. Its
installation token asks for `repository_hooks: write` and `metadata: read` on
`sdlc` and `homelab-apps`. The app does not hold that permission yet, and
installation permissions are not retroactive: a permission added to the app
applies to an existing installation only after the account owner accepts it. A
token request for a permission the installation never approved fails the whole
host with `422`, and hook creation is refused with
`403 Resource not accessible by integration` until the re-consent lands.

1. In the app's settings, Permissions & events -> Repository permissions ->
   **Repository webhooks: Read and write**, then Save. Change nothing else:
   the broker requests only `repository_hooks` and the mandatory `metadata`
   from these repositories, so a wider app permission is authority no host uses.
2. Re-consent the installation: https://github.com/settings/installations ->
   `smores56-homelab-agent` -> **Review permissions** -> accept the new permissions.
   The installation page lists `Repository webhooks: Read and write` afterwards;
   the broker does not restart, because the token is minted per request.
3. Probe through the broker. The explicit `Host` matters: curl to `127.0.0.1`
   would otherwise send an IP-literal Host, which the broker refuses with
   `400 ip_literal_host`. This creates a real hook; step 4 removes it.

   ```sh
   sudo cluster-kubectl -n broker port-forward deploy/broker 18080:8080 &
   sleep 2
   curl -sS -o /dev/null -w '%{http_code}\n' -X POST \
     -H 'Host: broker.broker.svc.cluster.local' \
     -H 'Content-Type: application/json' \
     --data '{"name":"web","active":true,"events":["issues"],"config":{"url":"https://agent-hooks.sammohr.dev/probe","content_type":"json"}}' \
     'http://127.0.0.1:18080/github-hooks/repos/smores56/sdlc/hooks'   # expect 201
   curl -sS -o /dev/null -w '%{http_code}\n' -X DELETE \
     -H 'Host: broker.broker.svc.cluster.local' \
     'http://127.0.0.1:18080/github-hooks/repos/smores56/sdlc/hooks/1' # expect 403
   curl -sS -o /dev/null -w '%{http_code}\n' -X POST \
     -H 'Host: broker.broker.svc.cluster.local' \
     -H 'Content-Type: application/json' \
     --data '{"config":{"url":"https://evil.example/hook"}}' \
     'http://127.0.0.1:18080/github-hooks/repos/smores56/sdlc/hooks'   # expect 403
   kill %1
   ```

   `201` is the token and the permission working. `403` on `DELETE` and on the
   foreign URL is the enrollment refusing before the credential is attached;
   the response body names `method_denied` and `body_field_denied`
   respectively. A `403 upstreamStatus: 403` instead means the installation has
   not re-consented; a `422` means the token request named a permission the
   installation lacks.
4. Delete the probe hook with the operator's own token (the broker cannot
   `DELETE` by design):

   ```sh
   gh api repos/smores56/sdlc/hooks \
     --jq '.[] | select(.config.url == "https://agent-hooks.sammohr.dev/probe") | .id'
   gh api -X DELETE repos/smores56/sdlc/hooks/<id>
   ```

Both repositories are already in the installation (step 1, item 2), so nothing
else changes. Repeating this step after a permission edit is the only work: no
secret file, no `broker-credentials` key and no restart are involved.

## 35. Prove the #660 data plane: repositories, drill, and the gate

The backup path is host systemd units plus restic; the recovery page is static
Cloudflare Pages. Every test in this repository runs a fake restic runner, so
this section is the only proof that restic actually copies and restores on the
host. Steps 1-8 are the proof and none of them is destructive; step 9 is the
first gated step.

Nothing auto-initializes a repository, and `preflight` never writes, copies or
prunes. A missing repository is reported by name, not created.

1. Pin the R2 account and re-render both artefacts. One variable feeds the host
   plan, the public manifest and every repository URL:

   ```sh
   # replace ACCOUNT with the Cloudflare account id
   $EDITOR recovery/backup.yml                  # backup_r2_repository_root
   scripts/render-recovery-groups.py
   scripts/render-recovery-groups.py --check    # must pass; CI asserts the file
   scripts/render-recovery-groups.py --host-plan > /tmp/backup.json
   ssh smortress sudo cat /etc/homelab/backup.json | diff - /tmp/backup.json
   ```

   An empty diff is the proof that the host plan and the checked-in manifest
   came from one source. A stale `recovery-groups.json` also fails
   `tests/data-plane/check.sh`.

2. Measure capacity before creating a repository. The live pool, the NVMe
   primary and the HDD secondary hold the same data at once, and the scratch
   target needs room for the newest covering snapshots:

   ```sh
   zfs list -o name,used,avail
   du -sh /var/lib/data/* | sort -h
   sudo /usr/local/sbin/homelab-clean-room-restore --capacity-bytes
   ```

   `--capacity-bytes` prints the restore requirement (newest covering snapshot
   per group, times 1.1, plus `homelab_recovery_min_free_gb` where restic
   recorded no size). A primary disk that cannot hold the retained 14/8/12 set
   for every group fails at the first prune, not at the first backup.

3. Unpack the host-secret bundle. `secrets/660-host.yaml` is the one encrypted
   source (admin recipient only). It already holds a fresh restic password and
   the service tokens; add the read-only R2 pair once Cloudflare has issued it:

   ```sh
   sops secrets/660-host.yaml       # raw 32/64-char hex pair; consumers_json as JSON
   sops -d --extract '["restic_password"]' secrets/660-host.yaml
   # copy that value into the password manager; it is the file content verbatim
   ```

   Every value is the exact file content: the password and tokens verbatim, the
   R2 pair as raw hex, `consumers_json` as JSON text. The unpacker refuses base64
   where raw content is required, an equal token pair, or a `consumers_json` that
   is not JSON, so a mistaken paste fails here instead of at service start.

   Unpack it into the directory the install play reads, then wipe the plaintext:

   ```sh
   sops -d secrets/660-host.yaml > /dev/shm/host-secrets.yaml
   sudo scripts/unpack-host-secrets.py --bundle /dev/shm/host-secrets.yaml \
     --dest /run/operator-secrets
   shred -u /dev/shm/host-secrets.yaml
   ```

   Prove the pair reaches the bucket without creating anything:

   ```sh
   sudo sh -c '. /run/operator-secrets/restic/r2.env && exec restic \
     --repo "s3:https://<account>.r2.cloudflarestorage.com/homelab-restic/notes" \
     --password-file /run/operator-secrets/restic/data-plane.password snapshots'
   # expect: "repository ... does not exist" — never an authentication error
   ```

   Store the same password and read-only pair in `secrets/recovery.yaml` (SOPS,
   admin identity) for the page blob.

   The data-plane units read their own files from subdirectories of the same
   root, so the unpacking above is the install step. The Ansible secrets play
   that used to copy them into place is retired with `ansible/`.

   The policy is `host_secret_files` in `recovery/inventory.yml`: one entry per
   file, relative to the secret root, with `unit` and `mount` for a file a unit
   mounts. The unpacker writes every file `0600` root inside `0700`
   directories, so there is no second writer of that file and a drift is
   corrected on the next unpack. Rotate the bundle, unpack again, and restart
   only the unit whose file changed; a stopped or recovery-fenced unit stays
   stopped.

   A host unit also cannot pull an image. Every `podman run` uses `--pull=never`
   and its own `--root`, so put a digest-pinned OCI archive on the host and load
   it into each per-service store; a unit fails closed while the image is
   absent. The broker reads `deploy/data-plane/config/source-catalog.json`. Only
   the dedicated `events` and `intents` datasets are handed to the container
   uid; `/srv/books` stays host-owned, so a general-source write needs an owner
   match before cutover.

4. Create the repositories. There is nothing to create per group: the per-group
   `<repository_root>/<group id>` model, `data_plane backup-init` and the
   `/opt/data-plane/lib` tree it ran from are retired with the Ansible data
   plane. A repository is one of the three destinations (`ssd`, `hdd`, `r2`) and
   `smortress-restic-init` creates all three once, refusing an unmounted or
   non-empty local mountpoint and never re-initialising an existing one. Section
   38 item 4 is the command and its expected output; a second run prints
   "already initialised" for each backend and changes nothing.

5. Run one real cadence. The driver runs every unit for one backend, in order,
   taking one recursive ZFS snapshot per unit and tagging it `verified` only
   after restic exits 0; forget, prune and the weekly `check --read-data-subset`
   follow in the same pass:

   ```sh
   sudo /usr/libexec/smortress-restic-backup ssd
   sudo /usr/libexec/smortress-restic-backup hdd
   sudo /usr/libexec/smortress-restic-backup r2
   for b in ssd hdd; do
     sudo env RESTIC_PASSWORD_FILE=/run/smortress/secrets/restic-password.yaml \
       restic -r "/var/lib/restic/$b/restic" snapshots --host smortress \
       --tag unit:notes --tag verified
   done
   ```

   The run fails on an unmounted dataset (`readiness`), on a repository that is
   not its mountpoint (`repo-not-mounted`), on a missing `.zfs/snapshot`, and on
   a copy that does not land; it never backs up the previous tree. A second
   concurrent run fails on the per-job lock after `RESTIC_LOCK_WAIT`. Every
   attempt is recorded under `/var/lib/homelab/restic`, so a SIGKILL shows up as
   a stale `running` record rather than a silent gap.

6. Prove structure, then payload, then freshness. `smortress-restic-verify` is
   the freshness join: it fails closed unless the recorded attempt is a success,
   its snapshot is the newest for that unit's `host,paths`, it carries
   `unit:<unit>`, `host:smortress` and `verified`, and it is inside the backend's
   maximum age.

   ```sh
   sudo /usr/libexec/smortress-restic-verify; echo "verify exit $?"

   # Structure and payload, bounded: a bare `restic check` reads metadata only.
   sudo env RESTIC_PASSWORD_FILE=/run/smortress/secrets/restic-password.yaml \
     restic -r /var/lib/restic/hdd/restic check --read-data-subset=1/30
   ```

   Neither command modifies a repository. The verifier names the failing
   `<backend>/<unit>` and the reason (`repo-not-mounted`, `exit-<n>`,
   `not-configured`, an expired `running` record, a snapshot mismatch), so one
   run shows every gap; `tests/core/restic-plane.sh` proves the same join with
   stubs.

7. Restore a unit to a dedicated scratch mount. The Ansible recovery play that
   fenced every writer and restored nvme→hdd→r2 is retired with `ansible/`; the
   current procedure is `docs/core/restic-plane.md`, "Restore by hand":

   ```sh
   export RESTIC_PASSWORD_FILE=/run/smortress/secrets/restic-password.yaml
   sudo /usr/libexec/smortress-restic-restore-drill r2 books --list
   sudo /usr/libexec/smortress-restic-restore-drill r2 books \
     --target /var/lib/restic/hdd/drill/books
   ```

   The drill passes when the printed tree matches the unit's paths and a
   restored file opens. It only accepts a `verified` snapshot and refuses a
   non-empty target, so it is never the live restore: restoring over a dataset
   means stopping that unit's writers first, restoring, and starting them only
   after the tree has been opened. `scripts/retirement-gate.sh` runs the same
   helper over every unit and destination and prints the evidence table.

8. Drill the browser page against the rendered manifest, then deploy it. The
   blob must be built against the manifest the site ships:

   ```sh
   cd apps/recovery-page
   deno task blob --manifest ../../deploy/data-plane/config/recovery-groups.json \
     --secrets ../../secrets/recovery.yaml
   deno task blob --check-only \
     --manifest ../../deploy/data-plane/config/recovery-groups.json
   deno task test && deno task build
   CLOUDFLARE_API_TOKEN=... CLOUDFLARE_ACCOUNT_ID=... \
     npx wrangler pages deploy dist --project-name <pages-project>
   ```

   Unlock the deployed page with the printed recovery password, open every
   group, restore a sample tree and open the files. The legacy page and the
   legacy repositories stay live until this passes.

9. The cluster apply this step used to end with is retired with `ansible/`: the
   host runs Quadlets, not a cluster, and the values below reach the host units
   as files through the bundle in item 3. The key names are the contract; the
   values are generated once and never committed:

   - `event-service`: `append-token`, `read-token`, `consumers.json`
   - `write-broker`: `identity`, `operator-key`
   - `confirmation-surface`: `token`, `key`
   - one `token` per relay source (brave, finance, tuta, immich)

   The append and read tokens must differ; the service refuses equal tokens,
   and a relay never receives either. `consumers.json` is a JSON object of
   consumer name to secret, not a token.

   The host units use the same values under
   `/etc/homelab/secrets/<service>/` (item 3) and mount them read-only at the
   paths their environment names; `homelab-collector-relay` is retired, because
   the host runs no collector.

10. Before any destructive step, re-prove access. The Ansible rescue play is
    retired with `ansible/`: access is the console (physical) plus the host's
    own `sshd`, which is independent of ZFS and every data-plane unit. Open both
    immediately before a destructive command.

    **Waived for T6 (#709):** smortress is physically reachable on demand and
    physical access to a powered-on host is an accepted risk. See
    `docs/migration-gates.md`, "Access-path decision"; the retirement steps stop
    data-plane writers only, never `sshd`.

11. Order the gates. Inventory → `protect_old` (needs `gate_ready` from step 6)
    → pilot → scratch stack → shadow backfill → `cutover` (recorded human
    confirmation) → `retire_old` (irreversible, confirmation). The 970 is never
    formatted before `retire_old`; the 5 TB HDD is never formatted, and new
    repositories are namespaced beside the old ones.

    Freeze the superseded HDD/R2 repositories after the gate and the drill
    pass: stop writing and pruning them, record the date in the recovery kit,
    and delete them only after 90 days through the reviewed retention process.
    Until the 970 is converted, rollback is `bootctl set-default` plus a
    verified old-generation restore to scratch — see `docs/migration-gates.md`.

## 36. Core migration T0: freeze, rescue, verify, publish the kit

Feature #701, task #703. The gate, its dispositions and the evidence it expects
live in `docs/core/t0-gate.md`; the kit contract is
`docs/core/recovery-kit.md`. Nothing in T1–T6 may repartition or wipe a disk
until every step below is done and its evidence is posted on #703. This section
supersedes section 35 and `docs/migration-gates.md` for the new core. Run the
commands from the `~/repos/github.com/smores56/homelab-platform` checkout on
`smortress`.

1. Freeze the legacy graph. Flux stops reconciling git, repairing Helm drift and
   pushing image-automation commits; the applications and the nightly backups
   keep running. `--apply` records the previous state before patching and fails
   on any object it cannot verify.

   ```sh
   sudo scripts/core/freeze-legacy.sh --check
   sudo scripts/core/freeze-legacy.sh --apply
   ```

   Abort path: `sudo scripts/core/freeze-legacy.sh --resume` restores exactly
   the state recorded by the last `--apply`.

2. Rescue what no backup holds. The Syncthing identity and the vault version
   history live outside `restic's` source path, so the 980 cannot be wiped
   before these are copied (or the owner declares them disposable in #703).

   ```sh
   sudo systemctl stop syncthing.service 2>/dev/null || true
   sudo tar -C /var/lib -c syncthing syncthing-versions \
     | zstd -T0 -o /var/backup/t0-syncthing-state.tar.zst
   sudo sha256sum /var/backup/t0-syncthing-state.tar.zst
   sudo systemctl start syncthing.service 2>/dev/null || true
   ```

   `/var/backup` is the HDD, which survives the migration; copy the archive into
   the kit or to another disk before the HDD itself is converted in T3.

3. Refresh both legacy repositories. The unit's `ExecStart` is backup, then
   `forget --prune` with the configured 14/8/12 policy, then `check`: starting
   it prunes by policy. Wait for each to finish before starting the next; the
   verifier refuses to run while one is active.

   ```sh
   sudo systemctl start restic-backups-local.service
   sudo systemctl start restic-backups-r2.service
   journalctl -u restic-backups-local.service -u restic-backups-r2.service -n 40
   ```

4. Prove they restore. The verifier opens both repositories with the units' own
   password file and R2 credentials, checks every retained tree is present,
   reads a sample of packs, restores the small trees plus the live Immich dump,
   and requires `pg_restore --list` to parse that dump.

   ```sh
   sudo scripts/core/verify-legacy-backups.sh --keep
   ```

   `pg_restore` is not on the host's PATH; the script reports the exact
   `pg_restore --list <file>` line if it
   cannot find one, and that counts as a failure, not a pass.

5. Measure the root-only trees and the secrets (names only), then replace the
   unmeasured rows in the gate document with the output.

   ```sh
   sudo scripts/core/legacy-audit.sh --out /var/tmp/t0-audit.md
   ```

6. Publish the kit. In the Bitwarden item **homelab core recovery** record the
   legacy Restic password and URIs, the legacy R2 access key pair, the HDD and
   970 LUKS passphrases, the current 980 root passphrase and the smortress SSH
   host private key; add the SOPS age identity and the YubiKey restore bundle if
   they are not already there. Write the paper copy and run the drill in
   `docs/core/recovery-kit.md` — a kit item that has not opened a repository is
   not in the kit. T2–T4 add their own items as they create the keys.

7. Record the gate. Paste into #703: the `--apply` output, the two verifier
   tables, the audit report, the rescue archive checksum and the drill date.
   The owner re-reads the disposable list in the gate document and confirms it
   there.

## 37. Core server image (T2): sign, install, verify, roll back

This section creates the T2 signing key, publishes the derived image, installs
smortress through the uCore auto-rebase path, and proves the failure boundaries.
Run it once per image-generation change and once per scratch install.

No kit secret is staged for the install. `ignition/smortress.bu` carries neither
a LUKS key nor a passphrase, `scripts/render-ignition.sh` decrypts nothing but
the account hash, first-boot Ignition binds root to Clevis alone and creates `p5`
unformatted, and `smortress-data-init.service` generates the data key on the
host. Both offline recovery passphrases exist only after step 8.1: a host that
skips it has no way in without Tang and the TPM.

### Preflight: every precondition, with the command that proves it

The install wipes the target. `coreos-installer install` rewrites the partition
table and the first boot formats `p4` with `wipe_volume: true`, so whatever the
980 held is gone at that boot. Each item below is a precondition plus the command
that proves it; a line that does not print what it says it must stops the
install instead of being worked around.

P1, P3 and P5 run on the operator machine in the checkout; P2, P4 and P6 run on
the Fedora CoreOS live media with the target attached. Step 2 writes
`derived-image`, step 3 writes `disk` and `tang-thumbprint` and generates both
passphrases, so the preflight runs twice: once before step 1, and again after
step 3 — the second run is the one that gates step 5.

1. **Tang advertises the key root is bound to, and the pinned thumbprint is that
   key.** The effective URL is `ignition/operator/tang-url` when that file
   exists, otherwise the template default.

   ```sh
   tang_url=$(cat ignition/operator/tang-url 2>/dev/null \
     || printf '%s\n' http://10.0.0.193:7654)
   curl -sS -m5 -o /tmp/tang-adv.json "$tang_url/adv"
   served=$(jose fmt -j /tmp/tang-adv.json -g payload -y -o - \
     | jose jwk thp -i - -a S256 \
     | head -n1)
   printf 'served: %s\npinned: %s\n' "$served" \
     "$(cat ignition/operator/tang-thumbprint)"
   rm -f /tmp/tang-adv.json
   ```

   Expected: `curl` exits 0 and writes a JSON advertisement, and the two
   thumbprint lines are identical 43-character base64url strings. An empty
   `tang-thumbprint` file is not a pass: the renderer refuses it in step 4.

2. **The target's TPM2 is present and healthy.** The Clevis half of threshold 2
   is bound at first boot and needs this TPM then; a TPM that answers here and
   fails later lands on the console path under Failure paths.

   ```sh
   ls -l /dev/tpmrm0
   cat /sys/class/tpm/tpm0/tpm_version_major
   sudo systemd-cryptenroll --tpm2-device=list
   ```

   Expected: `/dev/tpmrm0` exists, the version major prints `2`, and the list
   prints one `/dev/tpmrm0` row with a vendor string. When the live media has no
   `systemd-cryptenroll`, the two `/dev` and sysfs lines are the check.

3. **The offline kit is in hand with its named items.** The Bitwarden item
   **homelab core recovery** and its printed copy carry the new 980 root LUKS
   passphrase, the new 980 data LUKS passphrase, the cosign private key and its
   password, the SOPS admin age identity and the smortress SSH host private key
   (`docs/core/recovery-kit.md`). Only the age identity is provable from a shell:

   ```sh
   export SOPS_AGE_KEY_FILE=/path/to/admin-keys.txt   # the admin age identity
   sops --decrypt --extract '["hash"]' secrets/server/smores-password-hash.yaml \
     | cut -c1-3
   ```

   Expected: `$6$`. The password manager and the paper copy are a manual check:
   the item exists, it is writable, and its printed rows are legible.

4. **The target disk is the 980 and nothing else.** Size alone does not separate
   it from the 970 — both are 1 TB class disks — so the model does.

   ```sh
   disk=$(cat ignition/operator/disk)
   printf '%s\n' "$disk"
   lsblk -dno MODEL,SIZE,TRAN "$disk"
   lsblk -bno SIZE "$disk"
   lsblk -rno MOUNTPOINTS "$disk" | grep -c .
   ```

   Expected: a `/dev/disk/by-id/nvme-...` path, a MODEL that contains `980`,
   `931.5G`, `nvme`, `1000204886016` bytes, and `0` — nothing on the running
   host is mounted from the disk that is about to be wiped. The 970 and the 5 TB
   HDD are not install targets.

5. **The image to install is a digest the committed public key signed.**

   ```sh
   cat ignition/operator/derived-image
   grep -qE '@sha256:[0-9a-f]{64}$' ignition/operator/derived-image \
     && echo digest-pinned
   cosign verify --key image/cosign.pub "$(cat ignition/operator/derived-image)" \
     >/dev/null && echo signature-verified
   ```

   Expected: `ghcr.io/smores56/homelab-platform/server@sha256:<64 hex>`, then
   `digest-pinned` and `signature-verified`. This item needs registry access.

6. **Console and network are in place for the first boots.** From the live media,
   on the install network:

   ```sh
   ip -o link show | awk '$2 != "lo:" {print $2, $9}'
   ip -4 route get 10.0.0.193
   curl -sS -m5 -o /dev/null -w '%{http_code}\n' http://10.0.0.193:7654/adv
   ```

   Expected: the wired interface is `UP` with a DHCP address, the route to Tang
   leaves through it, and the status is `200` — the same path dracut takes with
   `ip=dhcp rd.neednet=1`. The monitor and keyboard on the target are a manual
   check: the autorebase units write to the console (`StandardOutput=journal+console`)
   and the console is the only way to enter a LUKS passphrase.

### Install steps

1. Create the cosign signing key. The private key and password go into the
   Bitwarden item **homelab core recovery**; only the public key is committed.

   ```sh
   install -d -m 0700 "$HOME/.config/smortress"
   export COSIGN_PASSWORD="$(openssl rand -base64 32)"
   cosign generate-key-pair \
     --output-key-prefix "$HOME/.config/smortress/cosign"
   install -m 0644 "$HOME/.config/smortress/cosign.pub" image/cosign.pub
   gh api -X PUT "repos/smores56/homelab-platform/environments/server-image" \
     --input - <<<'{}' >/dev/null
   gh secret set COSIGN_PRIVATE_KEY --env server-image \
     <"$HOME/.config/smortress/cosign.key"
   printf '%s' "$COSIGN_PASSWORD" | gh secret set COSIGN_PASSWORD --env server-image
   ```

   Verification:

   ```sh
   test -s "$HOME/.config/smortress/cosign.key" && echo private-key-present
   git ls-files --error-unmatch image/cosign.pub >/dev/null && echo pubkey-committed
   gh secret list --env server-image
   ```

   Expected: `private-key-present`, `pubkey-committed`, and two rows,
   `COSIGN_PASSWORD` and `COSIGN_PRIVATE_KEY`. Record `COSIGN_PASSWORD` and attach
   `cosign.key` to the Bitwarden item. If the key is rotated, re-sign every digest
   that is still deployed before replacing `image/cosign.pub`.

2. Publish the image and pin its digest. The base is not pinned: it tracks the
   uCore `stable-nvidia` stream tag, and the publish workflow resolves that tag's
   digest at build time, records it in the image's
   `org.opencontainers.image.base.digest` label and prints it in the run summary.
   `refresh-pins.sh` only tells you what the tag resolves to right now; it writes
   nothing.

   ```sh
   scripts/refresh-pins.sh        # informational: <tag>@<digest>, no file changes
   gh workflow run publish-server-image.yml
   gh run list --workflow publish-server-image.yml --limit 1
   gh run watch "$(gh run list --workflow publish-server-image.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
   read -r digest   # paste the sha256:... value from the run summary
   printf '%s\n' "ghcr.io/smores56/homelab-platform/server@${digest}" \
     >ignition/operator/derived-image
   ```

   The derived image stays digest-pinned even though the base does not: the run
   summary's digest is the one signed and verified, and `bootc` consumes only
   that. What the moving base gives up is reproducibility of the base layer; the
   counterweights are `scripts/check-server-image.sh`, the cosign signature and
   `bootc rollback`.

   `render-ignition.sh` refuses anything that is not
   `<registry>/<repo>@sha256:<64 hex>`.

   Verification:

   ```sh
   gh run list --workflow publish-server-image.yml --limit 1 \
     --json conclusion --jq '.[0].conclusion'   # success
   grep -qE '@sha256:[0-9a-f]{64}$' ignition/operator/derived-image \
     && echo digest-pinned
   ```

   Expected: `success` and `digest-pinned`. The run summary also carries the
   `ghcr.io/ublue-os/ucore@sha256:...` base the build resolved, and the image
   label repeats it. The renderer in step 4 also refuses a derived image that is
   the base itself (it names the uCore repository), so an unpublished image stops
   there.

3. Stage the operator values. None of these files is committed
   (`ignition/operator/` is gitignored), and the two recovery passphrases are not
   staged for the renderer at all: no secret enters Ignition or the installer
   media (design #701), so they go straight into the recovery kit.

   ```sh
   install -d -m 0700 ignition/operator
   install -m 0644 "$HOME/.ssh/id_ed25519.pub" ignition/operator/ssh_authorized_keys
   install -d -m 0700 /tmp/smortress-kit
   ( umask 077
     openssl rand -base64 48 \
       >/tmp/smortress-kit/root-recovery-passphrase
     openssl rand -base64 48 \
       >/tmp/smortress-kit/data-recovery-passphrase
   )
   curl -sf "$(cat ignition/operator/tang-url 2>/dev/null \
     || printf '%s\n' http://10.0.0.193:7654)/adv" >/tmp/tang-adv.json
   jose fmt -j /tmp/tang-adv.json -g payload -y -o - \
     | jose jwk thp -i - -a S256 \
     | head -n1 >ignition/operator/tang-thumbprint
   chmod 0600 ignition/operator/tang-thumbprint
   rm -f /tmp/tang-adv.json
   lsblk -o NAME,SIZE,MODEL,SERIAL
   read -r disk     # the /dev/disk/by-id path of the 931.5G 980
   printf '%s\n' "$disk" >ignition/operator/disk
   ```

   Move both passphrase files, and the account password, into the Bitwarden item
   and onto paper with the rest of the kit, then take them off this machine:

   ```sh
   shred -u /tmp/smortress-kit/root-recovery-passphrase \
     /tmp/smortress-kit/data-recovery-passphrase
   rmdir /tmp/smortress-kit
   ```

   They are needed after the install, in step 8.1, not before it. The disk path
   must be the 931.5G 980's `/dev/disk/by-id` name; the 970 and the 5 TB HDD are
   not install targets.

   Verification:

   ```sh
   ls -l ignition/operator/
   git status --porcelain -- ignition/operator   # empty: the directory is gitignored
   test ! -e /tmp/smortress-kit/root-recovery-passphrase \
     && test ! -e /tmp/smortress-kit/data-recovery-passphrase \
     && echo passphrases-off-this-machine
   ```

   Expected: `ssh_authorized_keys` at `0644`, `tang-thumbprint` at `0600`, `disk`
   and `derived-image` present, no `git status` output, and
   `passphrases-off-this-machine` — which is only true once both values are in the
   kit. Then re-run preflight P4 and P5 against the files this step wrote.

3.1 Check the `smores` account password ciphertext. It is not an operator file:
   the hash ships as ciphertext, because bootc never reconciles `/var` and a
   reinstall must not need anything the installer carried.
   `scripts/render-ignition.sh` reads it for the install and
   `smortress-password.service` re-applies it at every boot.

   ```sh
   git ls-files secrets/server/smores-password-hash.yaml
   ```

   A checkout already carries the ciphertext, so this is a check unless the
   password changes; the mint steps live in "Changing the smores account
   password" below.

   Verification: the command prints the path, and
   `head -1 secrets/server/smores-password-hash.yaml` prints `hash: ENC[`.

4. Render and validate Ignition. No kit secret is in the result: root is bound
   to Clevis only and the data partition is left unformatted. It still carries
   the account password hash, so keep it mode 0600 and remove it after install.

   ```sh
   export SOPS_AGE_KEY_FILE=/path/to/admin-keys.txt   # the admin age identity
   scripts/render-ignition.sh --check
   scripts/render-ignition.sh
   stat -c '%a %n' ignition/smortress.ign
   ```

   The first command must print `render-ignition: butane accepted`; the second
   prints the exact `coreos-installer install` command to run. Both decrypt
   `secrets/server/smores-password-hash.yaml`, so sops has to find the admin
   identity (`SOPS_AGE_KEY_FILE`, `SOPS_AGE_KEY_CMD` or the default
   `~/.config/sops/age/keys.txt`) and be on `PATH` (`SOPS_BIN` overrides the
   name). Without an identity, `--check` warns and validates the template with a
   fixture hash; the install render refuses.

   Verification — the rendered config carries one Clevis-only LUKS device and no
   key file:

   ```sh
   jq -r '.storage.luks | map(.name) | join(",")' ignition/smortress.ign
   jq -r '.storage.luks | map(has("keyFile")) | join(",")' ignition/smortress.ign
   jq -r '.storage.luks | map(.clevis.threshold) | join(",")' ignition/smortress.ign
   stat -c '%a %n' ignition/smortress.ign
   ```

   Expected: `root`, `false`, `2`, and `600 ignition/smortress.ign`. A `true`, a
   second device name or a threshold other than `2` means a secret or a weaker
   binding entered the config: stop and fix the template, do not install.

5. Write the live media, then install from it. The live media must be Fedora
   CoreOS `live` from the same release as the uCore base tag, and the installer is
   what refuses an Ignition spec it cannot write.

   ```sh
   iso=$(ls "$HOME"/Downloads/fedora-coreos-*-live.x86_64.iso | tail -n1)
   expected=$(grep -oE '\b[0-9a-f]{64}\b' "${iso}.sha256" | head -n1)
   test "$expected" = "$(sha256sum "$iso" | cut -d' ' -f1)" && echo iso-matches-published-sha256
   lsblk -dno MODEL,SIZE,TRAN /dev/disk/by-id/usb-*
   read -r media    # the /dev/disk/by-id/usb- path of the stick, never the 980
   case "$media" in /dev/disk/by-id/usb-*) ;; *) echo "not a usb by-id path" >&2; exit 1 ;; esac
   sudo dd if="$iso" of="$media" bs=4M status=progress oflag=direct
   sudo head -c "$(stat -c %s "$iso")" "$media" | sha256sum
   sha256sum "$iso"
   ```

   Expected: `iso-matches-published-sha256`, a MODEL and size that are the USB
   stick, and two identical sha256 lines — the read-back hash is the write
   verification, because `dd` writes a prefix of a block device and returns 0
   whether or not the bytes landed. The release match is one comparison:

   ```sh
   # UCORE_IMAGE interpolates UCORE_TAG, so it is read by sourcing the file.
   (. image/pins.env && podman run --rm "$UCORE_IMAGE" \
     cat /etc/os-release | grep ^VERSION_ID)
   # on the live media:
   grep ^VERSION_ID /etc/os-release
   ```

   Expected: the same `VERSION_ID` on both sides.

   Carry the checkout and the rendered file on a stick labelled `INSTALL`, and
   from the live media compare the copy against the render:

   ```sh
   sudo mkdir -p /mnt/install
   sudo mount -L INSTALL /mnt/install
   cd /mnt/install/homelab-platform
   sha256sum ignition/smortress.ign   # must equal the operator machine's value
   test -s ignition/smortress.ign && echo config-on-media
   ```

   Expected: one hash equal to `sha256sum ignition/smortress.ign` on the operator
   machine, and `config-on-media`. Serving the config instead is equivalent, and
   the hash pin is what makes it equivalent:

   ```sh
   # on the operator machine, on the install network
   python3 -m http.server 8000 --bind 10.0.0.2      # the operator machine's address
   openssl dgst -sha512 -binary ignition/smortress.ign | base64 -w0
   ```

   ```sh
   # on the live media
   read -r pin    # paste the sha512- base64 value from the operator machine
   sudo coreos-installer install "$(cat ignition/operator/disk)" \
     --ignition-url http://10.0.0.2:8000/ignition/smortress.ign \
     --ignition-hash "sha512-$pin" \
     --append-karg ip=dhcp --append-karg rd.neednet=1
   ```

   Run the install from the live media, with the media copy of the checkout:

   ```sh
   sudo coreos-installer install "$(cat ignition/operator/disk)" \
     --ignition-file ignition/smortress.ign \
     --append-karg ip=dhcp --append-karg rd.neednet=1
   sudo systemctl reboot
   ```

   Remove the installation media. Two automatic reboots follow: the unsigned
   rebase and the signed rebase. Keep the network up.

   Verification, after the installer exits 0:

   ```sh
   disk=$(cat ignition/operator/disk)
   lsblk -o NAME,SIZE,PARTLABEL "$disk"
   sudo blkid /dev/disk/by-partlabel/luks-root 2>/dev/null; echo "blkid exit $?"
   ```

   Expected: `p1` `BIOS-BOOT`, `p2` `EFI-SYSTEM`, `p3` `boot` and `p4` (the FCOS
   root the installer wrote), and `blkid exit 2` — there is no `luks-root`
   partition label yet and no `p5`, because both are first-boot Ignition's work.
   Step 8 proves they appeared; an install that stops here is not a failed
   install, it is an incomplete first boot.

6. Prove the transition, then hand over to bootc.

   ```sh
   sudo rpm-ostree status
   sudo journalctl -u ucore-unsigned-autorebase.service \
     -u ucore-signed-autorebase.service --no-pager
   sudo bootc status
   sudo bootc switch --enforce-container-sigpolicy "$(cat ignition/operator/derived-image)"
   sudo bootc upgrade
   sudo bootc rollback
   ```

   `rpm-ostree status` must show the derived digest and the signed reference
   before `bootc switch`. `bootc rollback` reverts the OS deployment only; it
   does not undo `/var`, ZFS changes or database migrations.

   Verification — both autorebase stages ran, in order, and neither unit can run
   again:

   ```sh
   ls /etc/ucore-autorebase
   systemctl is-enabled ucore-unsigned-autorebase.service \
     ucore-signed-autorebase.service || true
   digest=$(grep -oE 'sha256:[0-9a-f]{64}' ignition/operator/derived-image)
   sudo rpm-ostree status | grep -qF "$digest" && echo booted-derived-digest
   ```

   Expected: `signed` and `unverified` (the two markers), `disabled` twice — the
   units disable themselves in their last `ExecStart`, so `systemctl is-enabled`
   exits non-zero and prints `disabled` — and `booted-derived-digest`. A missing
   `unverified` marker means the first stage never ran and the second stage was
   never eligible; see Failure paths.

7. Verify the signature policy from a separate machine. The host enforces it
   through bootc; this command proves the committed public key matches the
   signed digest.

   ```sh
   cosign verify \
     --key image/cosign.pub "$(cat ignition/operator/derived-image)"
   ```

   Verification: the command exits 0 and prints
   `The following checks were performed on each of these signatures:` followed by
   `The cosign claims were validated`. A non-zero exit means the digest is not
   signed by `image/cosign.pub` — do not switch to it.

8. Prove the two encrypted volumes exist as designed. Ignition bound root to
   Clevis only, and the first boot of the derived image formatted p5 from a key
   that never left the host.

   ```sh
   sudo clevis luks list -d /dev/disk/by-partlabel/root
   sudo cryptsetup luksDump /dev/disk/by-partlabel/root \
     | grep -cE '^[[:space:]]*[0-9]+: luks2'
   sudo cryptsetup status data
   sudo cryptsetup luksDump /dev/disk/by-partlabel/luks-data \
     | grep -cE '^[[:space:]]*[0-9]+: luks2'
   stat -c '%a %U %n' /etc/luks/data
   grep -n '^data[[:space:]]' /etc/crypttab
   sudo journalctl -u smortress-data-init.service --no-pager \
     | grep -c 'init-data-luks: formatted'
   systemctl is-active smortress-data-init.service smortress-zpool.service
   sudo zpool get -H -o value health smortress
   zfs get -H -o value mounted smortress/raw/photos
   findmnt -rn -o SOURCE,TARGET smortress/raw/photos
   ```

   Expected, line by line: the Clevis list is one line starting `<slot>: sss`
   with `"t":2` and both `tang` and `tpm2` pins; `1` keyslots on root (the Clevis
   binding, and no Ignition key slot); `cryptsetup status data` is active, is
   LUKS2 and names `/dev/disk/by-partlabel/luks-data`;
   `1` keyslot on data (the host's key file); `400 root /etc/luks/data`;
   `/etc/crypttab` carries
   `data /dev/disk/by-partlabel/luks-data /etc/luks/data luks,discard,nofail`;
   `1` — `init-data-luks` formatted the device exactly once, with
   `init-data-luks: formatted /dev/disk/by-partlabel/luks-data with /etc/luks/data`
   in the unit's history; `active` twice; `ONLINE`; `yes`; and
   `smortress/raw/photos /var/srv/photos`.

   Counts of `0`, a missing mapper, a `/etc/luks/data` that is not `400 root`, or
   a pool that is not `ONLINE` are failures, not warnings: the device was
   formatted and opened by `smortress-data-init.service` before the pool, and its
   journal is `sudo journalctl -u smortress-data-init.service -b`.

8.1 Add the offline recovery passphrases. This is the only step that gives the
   host a way in when Tang is unreachable and the TPM is gone; skipping it
   leaves smortress with **no offline recovery**, so a dead TPM, a dead Tang Pi
   and a reinstall from the kit become the only way back to the data.

   Root has no passphrase slot to authenticate the new one with, so the Clevis
   slot's key is recovered from the running host and destroyed immediately:

   ```sh
   slot=$(sudo clevis luks list -d /dev/disk/by-partlabel/root | awk -F: 'NR==1 {print $1}')
   test -n "$slot"
   sudo sh -c "clevis luks pass -d /dev/disk/by-partlabel/root -s $slot >/run/root-clevis.key && chmod 0400 /run/root-clevis.key"
   sudo test -s /run/root-clevis.key
   sudo cryptsetup luksAddKey --key-file /run/root-clevis.key /dev/disk/by-partlabel/root
   sudo shred -u /run/root-clevis.key
   sudo cryptsetup luksAddKey --key-file /etc/luks/data /dev/disk/by-partlabel/luks-data
   ```

   Each `luksAddKey` prompts for the new passphrase twice: paste the
   `root-recovery-passphrase` from the kit at the first, the
   `data-recovery-passphrase` at the second (step 3). `clevis luks pass` needs
   both Tang and the TPM, so run this while the host is still on the network it
   was installed on and its TPM is healthy.

   Verification, one test-open per volume plus the keyslot counts:

   ```sh
   sudo cryptsetup open --test-passphrase /dev/disk/by-partlabel/root
   sudo cryptsetup open --test-passphrase /dev/disk/by-partlabel/luks-data
   sudo cryptsetup luksDump /dev/disk/by-partlabel/root \
     | grep -cE '^[[:space:]]*[0-9]+: luks2'
   sudo cryptsetup luksDump /dev/disk/by-partlabel/luks-data \
     | grep -cE '^[[:space:]]*[0-9]+: luks2'
   ```

   Each `open --test-passphrase` prompts once and exits 0 with no output when the
   passphrase opens the slot; a wrong one prints
   `No key available with this passphrase.` and exits non-zero. Both counts must
   now print `2`: root is Clevis plus passphrase, data is key file plus passphrase.

   Then prove console recovery. Power off, unplug the wired NIC so Tang is
   unreachable and the sss threshold cannot be met, and boot:

   ```sh
   sudo systemctl poweroff
   ```

   At the console, systemd asks for the root passphrase (`Please enter passphrase
   for disk ...`). Enter the root recovery passphrase from the kit. The system
   must boot and the data LUKS must open from `/etc/luks/data` without a second
   prompt; confirm from the console session:

   ```sh
   sudo cryptsetup status data
   sudo zpool get -H -o value health smortress
   ```

   Expected: `active` and `ONLINE`, with no prompt for the data device. This is a
   console check: no SSH session proves the passphrase reached the boot prompt,
   and the NIC has to be unplugged before the boot — dracut binds Clevis before
   root is mounted, so what matters is the state at that moment. The same prompt
   appears when the TPM is the missing half instead of Tang.

8.2 Confirm the data key file stayed off `/boot`. `smortress-data-init.service`
   generates `/etc/luks/data` on the encrypted root; Dracut must not copy it
   into the unencrypted initramfs.

   ```sh
   sudo lsinitrd /boot/ostree/*/initramfs-*.img | grep -E '/etc/luks|/etc/crypttab' || true
   ```

   Verification: `/etc/luks/data` may not appear, and no data `/etc/crypttab`
   entry may appear; the root entry is Dracut's own and is expected. If
   `/etc/luks/data` does, move the key to `/var/lib/homelab/luks-data`, point the
   data crypttab entry at it with `noauto`, open it after root with
   `sudo systemctl start systemd-cryptsetup@data.service` from a unit ordered
   before `smortress-zpool.service`, and recheck. Repeat the check after every
   kernel update.

9. Stage the age identity and prove the decrypt unit. The file at
   `/var/lib/homelab/age/keys.txt` must be the unwrapped `AGE-SECRET-KEY-...`
   identity, not the passphrase-wrapped kit container.

   ```sh
   sudo install -d -m 0700 -o root -g root /var/lib/homelab/age
   # write the kit's age identity to a local temporary file first, then:
   sudo install -m 0600 -o root -g root /path/to/kit-age-identity \
     /var/lib/homelab/age/keys.txt
   sudo systemctl restart sops-decrypt.service
   sudo cat /run/smortress/secrets/canary.yaml
   ```

   Verification: the last command must print `canary: sops-decrypt-ok`, and
   `stat -c '%a %U' /var/lib/homelab/age/keys.txt` must print `600 root`. Remove
   the temporary identity file. Then restart the Quadlets; they must start only
   after the unit succeeds.

10. Configure and open the HDD.

    ```sh
    ls -l /dev/disk/by-id/ata-*
    read -r hdd
    printf '%s\n' "$hdd" >/tmp/hdd-device
    sudo install -m 0644 -o root -g root /tmp/hdd-device /etc/smortress/hdd-device
    openssl rand -base64 48 \
      | sudo install -m 0600 -o root -g root /dev/stdin \
        /var/lib/homelab/keys/hdd.key
    sudo cryptsetup luksAddKey "$(cat /etc/smortress/hdd-device)" \
      /var/lib/homelab/keys/hdd.key
    sudo systemctl start smortress-cryptsetup-hdd.service
    ls -l /dev/mapper/luks-hdd
    ```

    The `luksAddKey` prompt accepts the existing HDD passphrase from the kit.
    Verification: `ls -l /dev/mapper/luks-hdd` names a `dm-` device,
    `stat -c '%a %U' /var/lib/homelab/keys/hdd.key` prints `600 root`, and
    `systemctl is-active smortress-cryptsetup-hdd.service` prints `active`. Remove
    the HDD and reboot once: boot must complete, the unit must log the absence,
    and T3's freshness alert must be the only failure.

11. Prove the network boundary.

    ```sh
    sudo tailscale up --ssh --hostname smortress
    sudo firewall-cmd --zone=bootstrap --list-all   # must show no interfaces
    ```

    The enrollment unit needs the decrypted auth key, so a host enrolled by hand
    before the age identity exists has to close the window explicitly:

    ```sh
    sudo touch /var/lib/homelab/tailscale-enrolled
    sudo /usr/libexec/access-lockdown
    sudo firewall-cmd --get-active-zones
    sudo firewall-cmd --zone=tailscale --list-all
    sudo ss -ltnp
    ```

    Verification: `tailscale0` must be the only interface in the `tailscale` zone;
    the default zone is `drop`, and the wired interface must no longer appear in a
    zone of its own. From a LAN host that is not on Tailscale, `ssh
    smores@<lan-ip>` and every application port must fail. From a Tailscale peer
    they work.

12. Prove per-group readiness isolates failures.

    ```sh
    sudo systemctl status zfs-ready@photos.service
    sudo zfs unmount smortress/raw/photos
    sudo systemctl restart zfs-ready@photos.service
    sudo zfs mount smortress/raw/photos
    sudo systemctl restart zfs-ready@photos.service
    ```

    Verification: the middle restart must fail with `zfs-ready: nothing is mounted
    at /srv/photos`; the last must succeed. A consumer of `photos` must be down
    between the two, while `zfs-ready@books` and unrelated backups stay up.

13. Update the kit and run the drill. Record the cosign key/password, the root
    and data recovery passphrases, the HDD passphrase and the age identity in
    the Bitwarden item and on the paper copy; run the drill in
    `docs/core/recovery-kit.md` with only kit material. A row without the drill
    is not a kit item. Verification: the drill's restore is the check, and the
    row's date is recorded in that document.

14. Repeat steps 5–12 on the scratch disk before the production wipe. Record
    the `bootc rollback` output and the two reboot-stage journals in #705.

15. Move an installed host to a newer build. The deployment reference is a
    digest, so `bootc upgrade` re-checks that exact digest and never moves on
    its own; switch explicitly, then upgrade as usual:

    ```sh
    sudo bootc switch --enforce-container-sigpolicy \
      "ghcr.io/smores56/homelab-platform/server@sha256:<digest from the run summary>"
    sudo systemctl reboot
    ```

    A host may follow CI's moving `:latest` tag instead. Only `main` runs move
    that tag, and only after the signature verified, so every later update is
    one command:

    ```sh
    sudo bootc switch --enforce-container-sigpolicy \
      ghcr.io/smores56/homelab-platform/server:latest
    sudo systemctl reboot
    sudo bootc upgrade   # from then on
    ```

    Signature policy still applies to the tag. What it gives up is the deploy
    receiver's descendancy check, so a tag moved backwards would deploy an older
    build; the receiver stays the authoritative path. `bootc rollback` is not
    sticky here: it boots the previous deployment and leaves the reference
    alone, so the next `bootc upgrade` re-stages the build you just left — after
    a rollback, switch back to the digest you trust. Confirm the booted
    deployment with `rpm-ostree status`; `bootc rollback` undoes the OS
    deployment only, not `/var`, ZFS changes or database migrations.

### Failure paths

Every failed verification above means the same thing: stop and read the state,
do not continue to the next step and do not improvise a workaround. What each
one means and the next command to run:

- **P1 fails (Tang unreachable, or the thumbprint differs).** `curl` timing out
  means dracut will not reach Tang either, and a different thumbprint means the
  pinned value is not the key this Tang serves. Do not install: fix the network
  or the Tang deployment, re-derive the thumbprint with step 3, re-run P1. A host
  installed anyway formats root with a Clevis binding it can never open and has
  no passphrase slot — that is a reinstall, not a repair.
- **P2 fails (no TPM, or `tpm_version_major` is 1).** Threshold 2 can never be
  met on this board. The install still boots, but the only way in is the console
  prompt step 8.1 creates: before it, nothing unlocks root when Tang or the TPM is
  unavailable. Abort and fix the board (TPM disabled in firmware, cleared
  ownership), then re-run the install.
- **P4 fails (wrong disk).** The install wipes whatever `/dev/disk/by-id` path
  `ignition/operator/disk` names. Rewrite the file with the 980's path, re-run
  P4, and re-render in step 4 — the rendered config pins the disk.
- **P5 fails (unsigned digest).** Stop before step 5. `cosign verify` exiting
  non-zero means the digest is not signed by `image/cosign.pub`; re-publish
  (`gh run list --workflow publish-server-image.yml --limit 1`) or restore the
  signing key from the kit before pinning a new digest.
- **Step 4 shows `keyFile` or a second LUKS device.** A secret entered the
  config. Nothing is installed yet: fix `ignition/smortress.bu`, re-run
  `tests/core/ignition-boundary.sh` and re-render.
- **Step 5 verification shows no `p4`, or `blkid` exits 0 on `luks-root`.** The
  installer did not write the layout. Re-run `coreos-installer install` from the
  live media; if it fails again, the media or the target disk is the problem and
  the disk needs a `wipefs -a` from the live media before another attempt.
- **Step 6 has no `/etc/ucore-autorebase/unverified` marker.** The unsigned
  rebase never ran, so the signed stage was never eligible — usually no network
  at first boot. The unit disables itself only in its last `ExecStart`, so it is
  still enabled:

  ```sh
  sudo journalctl -b -u ucore-unsigned-autorebase.service --no-pager
  sudo systemctl restart ucore-unsigned-autorebase.service
  ```

  A missing `signed` marker with `unverified` present is the same failure one
  stage later:

  ```sh
  sudo journalctl -b -u ucore-signed-autorebase.service --no-pager
  sudo systemctl restart ucore-signed-autorebase.service
  ```

  Both restart commands end in `systemctl reboot`; the marker is what keeps a
  completed stage from running twice.
- **Step 6 boots the wrong reference.** `rpm-ostree status` without the derived
  digest means the rebase never completed, and a reboot on its own boots whatever
  deployment is default: the missing-marker path above is the fix. Once both
  markers exist, the way forward is
  `sudo bootc switch --enforce-container-sigpolicy "$(cat ignition/operator/derived-image)"`.
- **The boot stops at the root passphrase prompt and accepts nothing.** Root has
  no passphrase slot and no Clevis binding that can be satisfied, so nothing on
  the host can open the volume: reinstall from the media, it is not a repair. Do
  not wipe before reading the header from the live media, in case Tang and the
  TPM are healthy and the binding is the problem:

  ```sh
  sudo cryptsetup luksDump /dev/disk/by-partlabel/root | sed -n '/^Keyslots:/,/^Tokens:/p'
  sudo clevis luks list -d /dev/disk/by-partlabel/root
  ```
- **Step 8 shows more than one keyslot on root.** A slot Ignition was supposed to
  delete survived. Continue only if a Clevis slot is listed, and record the extra
  slot in #705, because step 8.1's counts then come out higher than `2`:

  ```sh
  sudo cryptsetup luksDump /dev/disk/by-partlabel/root | sed -n '/^Keyslots:/,/^Tokens:/p'
  ```
- **Step 8 shows the Clevis binding but no data mapper, or `/etc/luks/data`
  missing.** The data oneshot failed and the pool unit failed with it. The unit is
  idempotent, so restarting it is the fix path:

  ```sh
  sudo journalctl -b -u smortress-data-init.service --no-pager
  sudo systemctl restart smortress-data-init.service
  sudo systemctl restart smortress-zpool.service
  sudo cryptsetup status data
  sudo zpool get -H -o value health smortress
  ```

  A missing `/dev/disk/by-partlabel/luks-data` is the installer, not the unit:
  reinstall.
- **Step 8.1's `clevis luks pass` fails.** It needs Tang *and* the TPM at the
  same time; either one failing means the Clevis keyslot cannot be recovered, and
  without it no passphrase can be added. Check both:

  ```sh
  curl -sS -m5 -o /dev/null -w '%{http_code}\n' http://10.0.0.193:7654/adv
  sudo systemd-cryptenroll --tpm2-device=list
  ```

  If either fails, the host has **no offline recovery** and the only paths in are
  a working Tang+TPM at boot or a reinstall. Clevis failure at boot means console
  recovery is the only path — and it exists only if step 8.1 completed. Without a
  passphrase slot there is no console prompt, so what was written to the new pool
  since the install is gone — T3 has not initialised a repository yet. Reinstall
  from the media; the T0 kit still holds the legacy data, not this pool.
- **A wrong passphrase at `open --test-passphrase`.** `No key available with this
  passphrase.` means the value in the kit is not the one in the slot — usually a
  copy error or the wrong kit row. Re-copy from the kit, retry; if it still fails,
  add the value again while Tang and the TPM are healthy.

  ```sh
  slot=$(sudo clevis luks list -d /dev/disk/by-partlabel/root | awk -F: 'NR==1 {print $1}')
  sudo sh -c "clevis luks pass -d /dev/disk/by-partlabel/root -s $slot >/run/root-clevis.key && chmod 0400 /run/root-clevis.key"
  sudo cryptsetup luksAddKey --key-file /run/root-clevis.key /dev/disk/by-partlabel/root
  sudo shred -u /run/root-clevis.key
  sudo cryptsetup luksAddKey --key-file /etc/luks/data /dev/disk/by-partlabel/luks-data
  ```
- **Step 8.1 skipped, or abandoned partway.** Do not proceed quietly: the host
  has no offline recovery and T2's evidence is incomplete. Record the hole with
  the observed keyslot counts and close it in the next window while Tang and the
  TPM are both healthy — the window closes when either dies:

  ```sh
  sudo cryptsetup luksDump /dev/disk/by-partlabel/root | sed -n '/^Keyslots:/,/^Tokens:/p'
  sudo cryptsetup luksDump /dev/disk/by-partlabel/luks-data | sed -n '/^Keyslots:/,/^Tokens:/p'
  gh issue comment 705 --repo smores56/homelab-platform \
    --body 'known-open: smortress root and data LUKS have Clevis/keyfile slots only; no offline recovery passphrase. Close in section 37 step 8.1.'
  ```
- **Step 8.2 shows `/etc/luks/data` in the initramfs.** The key is on the
  unencrypted `/boot`, which is the at-rest bypass that step exists to catch. Apply
  the remediation in that step before anything else, then recheck — and keep the
  old initramfs until the new one passes.

### Rollback

What is undoable and what is not, by stage. The 970 rollback disk is not touched
by any of this and stays the way back to the current production host.

- **Nothing written yet (preflight or step 4 failed).** Nothing to roll back. The
  rendered config is a file: `rm ignition/smortress.ign`.
- **Install written, first boot not completed.** Boot the live media again and
  re-run step 5 with the previous signed digest in
  `ignition/operator/derived-image`. The disk is wiped a second time; whatever the
  980 held is gone either way.
- **Both autorebase stages done, step 8.1 not done.** The OS deployment is
  revertible, the disk is not: a rollback boots an older deployment against the
  new `/var` and the new pool, and it cannot bring back the disk that was wiped.

  ```sh
  sudo bootc rollback
  sudo systemctl reboot
  sudo rpm-ostree status
  ```

  `bootc rollback` leaves the reference alone, so the next `bootc upgrade`
  re-stages the build you just left. After a rollback, switch explicitly to the
  digest you intend to stay on — it must still be signed by `image/cosign.pub`:

  ```sh
  sudo bootc switch --enforce-container-sigpolicy \
    "ghcr.io/smores56/homelab-platform/server@sha256:<digest of the build to return to>"
  sudo systemctl reboot
  ```

- **After step 8.1, before T3 has a backup.** Roll back the OS as above; the LUKS
  headers keep both passphrases, so the data stays openable with the kit. There is
  no data rollback: nothing has backed up `p5` yet.

Unrecoverable, in every case:

- Everything the 980 held before the install. `wipe_volume: true` destroys the old
  root LUKS container, so the T0 kit's "980 root LUKS passphrase (current
  install)" row opens nothing after that boot.
- `/etc/luks/data` if it is lost before step 8.1. The data container has no other
  key, so the pool on `p5` cannot be opened again, and a passphrase added later
  does not help.
- ZFS dataset content written after the install until T3 initialises the
  repositories. `bootc rollback` does not touch `/var` or the pool.
- Anything shredded in step 3. Once the passphrase files are gone, the kit is the
  only copy.

Before reinstalling over a host that still boots, export the pool so the next
install does not meet a half-imported one:

```sh
sudo zpool export smortress
```

### Changing the smores account password

The hash is one ciphertext file, `secrets/server/smores-password-hash.yaml`,
encrypted to the host and admin identities by `.sops.yaml`'s `secrets/server/`
rule. Nothing reads that file on the host: `sops-decrypt.service` writes the bare
hash into `/run/smortress/secrets/` at boot (`value` in `secrets.manifest`), and
`smortress-password.service` re-applies it through `chpasswd -e`. The password itself
lives in the recovery kit only.

1. Mint the new ciphertext. The password never reaches a command line: it is read
   from the terminal and hashed through stdin.

   ```sh
   ( umask 077
     read -rsp 'smores account password: ' password; echo
     printf 'hash: %s\n' \
       "$(printf '%s\n' "$password" | openssl passwd -6 -stdin)" \
       >secrets/server/smores-password-hash.yaml
     unset password
   )
   sops --encrypt --in-place secrets/server/smores-password-hash.yaml
   head -1 secrets/server/smores-password-hash.yaml   # must be `hash: ENC[`
   ```

   `sops --encrypt --in-place` takes both recipients from the creation rule for
   that path, so no `--age` list is needed and the host identity can still
   decrypt after the change. Commit the ciphertext; the password goes into the
   recovery kit.

2. Deploy and reboot. The unit reconciles at boot, so the new hash takes effect on
   the next boot of a deployment that carries it:

   ```sh
   sudo bootc switch --enforce-container-sigpolicy \
     "ghcr.io/smores56/homelab-platform/server@sha256:<digest from the run summary>"
   sudo systemctl reboot
   ```

3. Prove it at the console, never over the SSH session the old password protects.
   Log in on the physical or hypervisor console with the new password, then read
   the unit and the field it wrote:

   ```sh
   sudo journalctl -b -u smortress-password.service --no-pager
   sudo getent shadow smores | cut -d: -f2 | cut -c1-3   # must print $6$
   ```

   The journal must contain
   `re-applied the smores password field from ciphertext`. A failed unit leaves
   the previous password in place, which is recoverable over SSH; fix the
   ciphertext (usually a missing `value` in the manifest line, or a value that is
   not sha512crypt) and reboot again.

## 38. Restic plane (T3): R2 token, Healthchecks, first init, first drill

This section brings the three repositories up. It assumes section 37 finished:
the derived image boots, the age identity is staged at
`/var/lib/homelab/age/keys.txt`, and `secrets/server/restic-password.yaml`
decrypts. The 5 TB HDD is already wiped and formatted (`LABEL=restic-hdd`);
nothing in this section repartitions or reformats it. The 970 carries
`LABEL=restic-ssd` once it has been fitted and formatted (SDLC #796): on a host
where that has not happened yet, the `ssd` steps below fail and the HDD and R2
repositories are brought up alone.

1. Confirm both mounts by UUID. A missing HDD is expected to be survivable. A
   missing 970 is a failure of this step only once #796 has fitted it; before
   that, an empty `blkid -L restic-ssd` is the expected result and the backend
   stays red until the disk exists.

   ```sh
   sudo blkid -L restic-ssd
   sudo blkid -L restic-hdd
   sudo systemctl start var-lib-restic-ssd.mount var-lib-restic-hdd.mount
   findmnt -no SOURCE,TARGET,FSTYPE /var/lib/restic/ssd
   findmnt -no SOURCE,TARGET,FSTYPE /var/lib/restic/hdd
   sudo systemctl list-timers 'smortress-restic-*'
   ```

   The first must report a `by-label/restic-ssd` source and the second
   `973b7492-bb88-43c7-bac3-772384e45220`. Four timers must be listed: SSD and
   HDD hourly, R2 daily at midnight, and the verifier at `:40`.

2. Confirm the R2 write credentials. The bucket `homelab-restic` and the path
   `/smortress` already exist, and `secrets/server/r2-credentials.yaml` is
   committed ciphertext with exactly two keys, `r2_access_key_id` and
   `r2_secret_access_key` — the Object Read & Write pair for the backup jobs.
   (The read-only pair is T4's.) The file is already listed in
   `image/rootfs/etc/smortress/secrets.manifest` as `root root 0400`; there is
   nothing to add unless the pair is rotated.

   To rotate, create a new Object Read & Write token scoped to `homelab-restic`
   and edit the ciphertext in place; sops applies the `secrets/server/*.yaml`
   creation rule from `.sops.yaml` (the machine identity, the admin identity and
   the three YubiKeys), so the host can still decrypt it:

   ```sh
   sops secrets/server/r2-credentials.yaml
   ```

   Replace both values and save. The host reads the ciphertext from
   `/var/lib/smortress/secrets`, so the rotation lands there and is re-decrypted
   without an image or a reboot:

   ```sh
   sudo install -m 0600 -o root -g root secrets/server/r2-credentials.yaml \
     /var/lib/smortress/secrets/r2-credentials.yaml
   sudo systemctl restart sops-decrypt.service
   sudo systemctl restart smortress-restic-backup@ssd.service   # and the other three
   ```

   A container that mounts the decrypted file keeps the old one until it
   restarts, and `/run` is tmpfs, so the next boot re-decrypts the new file. Do
   not create a second credentials file, and do not touch the legacy migration
   bucket.

3. Create the Healthchecks.io check and commit its ping URL. In the
   Healthchecks.io dashboard create one check named `smortress restic
   freshness`, period **1 hour**, grace **30 minutes**, and attach the Pushover
   integration. Copy its ping URL (`https://hc-ping.com/<uuid>`), then:

   ```sh
   ( umask 077
     printf 'restic-ping-url: %s\n' 'https://hc-ping.com/<uuid>' >/tmp/hc.yaml
     sops --encrypt --input-type yaml --output-type yaml \
       --filename-override secrets/server/healthchecks.yaml /tmp/hc.yaml \
       >secrets/server/healthchecks.yaml
     rm -f /tmp/hc.yaml
   )
   ```

   Add this line to `image/rootfs/etc/smortress/secrets.manifest`:

   ```text
   healthchecks.yaml       root  root  0400
   ```

   A *new* secret also needs its host copy, because the seed copies only the set
   the image was built with:

   ```sh
   sudo install -m 0600 -o root -g root secrets/server/healthchecks.yaml \
     /var/lib/smortress/secrets/healthchecks.yaml
   sudo systemctl restart sops-decrypt.service
   ```

   The URL is a capability: never commit it plaintext, and treat a leaked URL as
   a rotated check.

4. Prove decryption, then initialise. `restic-init` never re-initialises an
   existing repository and refuses to create one under an unmounted mountpoint.

   ```sh
   sudo systemctl restart sops-decrypt.service
   sudo cat /run/smortress/secrets/restic-password.yaml   # the password only
   sudo test -s /run/smortress/secrets/r2-credentials.yaml && echo r2-ok
   sudo test -s /run/smortress/secrets/healthchecks.yaml && echo hc-ok
   sudo /usr/libexec/smortress-restic-init
   ```

   Expected: `ssd: created /var/lib/restic/ssd/restic`,
   `hdd: created /var/lib/restic/hdd/restic`, `r2: created
   s3:https://.../homelab-restic/smortress`. A second run must print "already
   initialised" for each and change nothing.

5. First backup per destination, then freshness. The first upload of a
   destination is sized for reading everything once (9 h per attempt for R2, one
   attempt) and needs no override; an interrupted first run records its failure
   and the next scheduled run resumes from the objects restic already uploaded.

   ```sh
   sudo /usr/libexec/smortress-restic-backup ssd
   sudo /usr/libexec/smortress-restic-backup hdd
   sudo /usr/libexec/smortress-restic-backup r2
   sudo /usr/libexec/smortress-restic-verify
   ```

   A `/etc/systemd/system/smortress-restic-backup@.service.d/` drop-in on an
   older host that raised `RESTIC_DEADLINE_LOCAL` / `RESTIC_DEADLINE_R2` must be
   removed: it overrode judgement that is now baked into the script, and its
   local bound (39600 s) outlived `max_age_local` (8400 s) while its R2 bound
   times `attempts` outlived `TimeoutStartSec`, so systemd killed a long run and
   left `result=running` with a stale staging snapshot behind.

   ```sh
   sudo rm -rf /etc/systemd/system/smortress-restic-backup@.service.d
   sudo systemctl daemon-reload
   ```

   Each snapshot must carry `group:<name>`, `host:smortress` and `verified`:

   ```sh
   for b in ssd hdd; do
     sudo env RESTIC_PASSWORD_FILE=/run/smortress/secrets/restic-password.yaml \
       restic -r "/var/lib/restic/$b/restic" snapshots --json \
       | jq -r '.[] | "\(.id) \(.tags | join(",")) \(.paths | join(","))"'
   done
   ```

   `restic-check` without reading data proves nothing about restorability, so
   continue to step 6 before calling this done.

6. First restore drill, one group from each destination. The helper selects
   only `verified` snapshots and refuses a non-empty target.

   ```sh
   sudo /usr/libexec/smortress-restic-restore-drill ssd photos --list
   sudo /usr/libexec/smortress-restic-restore-drill ssd photos
   sudo /usr/libexec/smortress-restic-restore-drill hdd books
   sudo /usr/libexec/smortress-restic-restore-drill r2 notes
   ```

   Open a file from each restored tree under
   `<target>/<mountpoint>/.zfs/snapshot/<backend>/`, check its contents and
   ownership against the live path, then remove the target. A drill is only
   evidence once a restored file was opened and matched.

7. Prove the failure boundaries. These must not stop unrelated backups or turn
   a missing disk into a failed boot.

   ```sh
   sudo umount /var/lib/restic/hdd
   sudo env RESTIC_ATTEMPTS=1 /usr/libexec/smortress-restic-backup hdd
   jq -r '.last_attempt | "\(.result) \(.reason)"' \
     /var/lib/homelab/restic/state/hdd-photos.json
   sudo /usr/libexec/smortress-restic-verify; echo "verify exit $?"
   sudo systemctl start var-lib-restic-hdd.mount
   ```

   The job must print `failure repo-not-mounted`, the verifier must exit
   non-zero, and the SSD jobs must still succeed. To prove readiness isolation,
   `sudo zfs unmount smortress/raw/books` and restart `zfs-ready@raw-books.service`; only the
   `books` jobs may fail.

8. Record the new kit rows in `docs/core/recovery-kit.md`: the three repository
   URIs (including the R2 bucket and path), the shared Restic password, the R2
   write token, and the Healthchecks check name. Run the kit drill from a
   machine that is not smortress with only those items.

## 39. Hosted Backrest (T4): seed the gate repository, deploy, and run the matrix

Runs from a laptop with `podman`, `restic`, `jq` and network access. smortress
stays off for the whole matrix: only R2 and Cloudflare are involved. The gate
repository is a separate path (`/gate` under the new bucket), so a failed run
cannot touch production snapshots.

### 39.1 Seed a disposable repository

The 100 GiB payloads are sparse zeros on purpose. Restic stores almost nothing,
but `restic dump` still delivers 100 GiB to the client, which is what the
four-hour stream measures. A 5 GiB incompressible file covers random-data
throughput. Real disk use is about 6 GB; the scan and upload are the cost.

Use the Object Read & Write pair from section 38 for the seeding; the read-only
pair comes next.

```sh
export GATE=/var/tmp/backrest-gate
export RESTIC_REPOSITORY="s3:https://385f7d47e2e8438fbda5d6f76d760434.r2.cloudflarestorage.com/homelab-restic/gate"
export AWS_DEFAULT_REGION=auto
export AWS_ACCESS_KEY_ID=$(mise x -- sops -d --extract '["r2_access_key_id"]' secrets/server/r2-credentials.yaml)
export AWS_SECRET_ACCESS_KEY=$(mise x -- sops -d --extract '["r2_secret_access_key"]' secrets/server/r2-credentials.yaml)
read -rsp 'gate restic password: ' RESTIC_PASSWORD && export RESTIC_PASSWORD

restic init
mkdir -p "$GATE/tree"
for i in $(seq -w 0 99); do truncate -s 1G "$GATE/tree/part-$i.bin"; done
truncate -s 100G "$GATE/big.bin"
head -c 5G /dev/urandom >"$GATE/random.bin"
head -c 1M /dev/urandom >"$GATE/small.bin"
mkdir -p "$GATE/small-tree"
head -c 256K /dev/urandom >"$GATE/small-tree/a.bin"
head -c 128K /dev/urandom >"$GATE/small-tree/b.bin"
printf 'gate small tree\n' >"$GATE/small-tree/readme.txt"
restic backup --host backrest-gate --tag verified "$GATE"
export REPO_GUID=$(restic cat config --json | jq -r .id)
export BIG_SHA256=$(sha256sum "$GATE/big.bin" | cut -d' ' -f1)
printf 'guid=%s\nbig=%s\n' "$REPO_GUID" "$BIG_SHA256"
```

The matrix's *small* payloads are `/var/tmp/backrest-gate/small.bin` and
`/var/tmp/backrest-gate/small-tree`; the four-hour streams use `big.bin` and
`tree`. Never point the small checks at the big payloads: the harness caps them
at 64 MiB on purpose.

### 39.2 Read-only R2 token

Dashboard → R2 → Manage API tokens → Create, **Object Read only**, scoped to
`homelab-restic`. This is Backrest's only credential. Keep it in Bitwarden.

```sh
read -rsp 'read-only access key id: ' R2_READ_ACCESS_KEY_ID && export R2_READ_ACCESS_KEY_ID
read -rsp 'read-only secret: ' R2_READ_SECRET_ACCESS_KEY && export R2_READ_SECRET_ACCESS_KEY
```

### 39.3 Access service token (optional for the reader)

The reader has no Access application (39.4), so nothing needs a service token to
reach it and `gate.sh` sends the pair only when it is exported. The token from
the `memory`/`agent` work still exists for those two: the `service auth` policy
is account-wide, so a leak reaches both; rotate it in the same place. It does
**not** reach ssh: there is no `ssh` application at the edge, because the route
is tailnet-only (section 41).

### 39.4 Remove the reader's Access gate

`tofu/access.tf` no longer declares a `backrest` application: the name is in
`local.public_apps` so Access passes it to the Worker and Backrest's password is
the only login. The application carried `prevent_destroy`, so drop its state
entry **first** — dropping the block alone fails the apply:

```sh
tofu -chdir=tofu state rm cloudflare_zero_trust_access_application.backrest
```

Then apply. A merge of the change runs `tofu-apply` (it triggers on `tofu/**`
changes to `main`); a manual dispatch is `gh workflow run tofu-apply.yml`. The
same change replaces the media rule in `tofu/rate-limit.tf` with the login rule
(10 requests per 10 s per IP on `/v1.Authentication/Login`), because the zone
allows exactly one `http_ratelimit` rule and a second fails the apply with
"2 out of 1". The plan therefore rewrites one rule in place; the media hosts lose
their edge rate limit, a residual recorded in `docs/core/backrest.md`.

Verify from a network that is not the tailnet, with no Cloudflare session:

```sh
curl -sS -o /dev/null -D - https://recovery.sammohr.dev/ | head -3
# no `location: https://<team>.cloudflareaccess.com` and no 401/403 from
# Access: the response is the reader's own page or its login form
```

Then the login limit, which answers `429`/`403` rather than the login form after
the burst:

```sh
for _ in $(seq 12); do
  curl -sS -o /dev/null -w '%{http_code}\n' -X POST \
    -H 'Content-Type: application/json' --data '{"username":"probe","password":"probe"}' \
    https://recovery.sammohr.dev/v1.Authentication/Login
done
```

### 39.5 Worker secrets and the first deploy

Run from the repository root. `put_secret` reads stdin, so no secret ever
appears in argv.

```sh
put_secret() { (cd backrest && mise x node@22 -- npx wrangler secret put "$1"); }

(cd backrest && mise x node@22 -- npm ci)
systemctl --user start podman.socket   # wrangler drives rootless podman through this socket

printf '%s' "$RESTIC_PASSWORD" | put_secret RESTIC_PASSWORD
printf '%s' "$R2_READ_ACCESS_KEY_ID" | put_secret R2_ACCESS_KEY_ID
printf '%s' "$R2_READ_SECRET_ACCESS_KEY" | put_secret R2_SECRET_ACCESS_KEY

# The operator's password stays in Bitwarden and on paper; only its bcrypt hash
# reaches Cloudflare.
read -rsp 'backrest operator password: ' pw
operator_bcrypt=$(printf '%s' "$pw" | backrest/scripts/hash-password.sh)
unset pw
printf '%s' "$operator_bcrypt" | put_secret BACKREST_OPERATOR_BCRYPT

# A service account the Worker uses to index snapshots. It is not a human login.
bootstrap=$(openssl rand -base64 32)
bootstrap_bcrypt=$(printf '%s' "$bootstrap" | backrest/scripts/hash-password.sh)
printf '%s' "$bootstrap" | put_secret BACKREST_BOOTSTRAP_PASSWORD
printf '%s' "$bootstrap_bcrypt" | put_secret BACKREST_BOOTSTRAP_BCRYPT
unset bootstrap bootstrap_bcrypt

BACKREST_REPO_ID=r2 \
BACKREST_REPO_URI="$RESTIC_REPOSITORY" \
BACKREST_REPO_GUID="$REPO_GUID" \
  mise x node@22 -- backrest/scripts/deploy.sh
```

`deploy.sh` pins the image by the digest the Cloudflare registry reports, because
wrangler cannot read podman's push digest and Cloudflare rejects the mismatch. It
also carries a small podman shim for wrangler's Docker-only flags, so no manual
`DOCKER_HOST` juggling is needed. The first request after a deploy is the cold
start: the image renders the config, the Worker waits for port 9898, reindexes
the snapshot set, and only then proxies. Watch it with `(cd backrest && mise x node@22 -- npx wrangler
tail)`; a restic download attempt would appear there and is a gate failure.

### 39.6 Run the matrix

```sh
export BACKREST_URL=https://recovery.sammohr.dev
export BACKREST_BOOTSTRAP_USER=bootstrap
read -rsp 'bootstrap password: ' BACKREST_BOOTSTRAP_PASSWORD && export BACKREST_BOOTSTRAP_PASSWORD
export BACKREST_REPO_ID=r2
read -rsp 'Access client id: ' CF_ACCESS_CLIENT_ID && export CF_ACCESS_CLIENT_ID
read -rsp 'Access client secret: ' CF_ACCESS_CLIENT_SECRET && export CF_ACCESS_CLIENT_SECRET
export RESTIC_REPOSITORY RESTIC_PASSWORD
export BACKREST_GATE_SMALL_FILE=$GATE/small.bin
export BACKREST_GATE_SMALL_DIR=$GATE/small-tree

backrest/scripts/gate.sh matrix
backrest/scripts/gate.sh stream "$GATE/big.bin" sha "$BIG_SHA256"
backrest/scripts/gate.sh stream "$GATE/tree" tar
BACKREST_CANCEL_AFTER=30 backrest/scripts/gate.sh cancel "$GATE/big.bin"
```

`matrix` proves the config shape, the credential redaction, verified-only
listing, the small streams, every restic write denial and every proxy write
refusal. The two `stream` runs are the four-hour budget; the `sha` run must
print the seeded hash, and the `tar` run must parse the whole stream.

Interruption is the one check that needs the platform: start the 100 GiB stream,
find the application with `(cd backrest && mise x node@22 -- npx wrangler
containers list)`, list its live instances with `containers instances <APP_ID>`,
open a shell on one with `containers ssh <INSTANCE_ID>`, and run
`kill 1`. `ssh` takes an instance id, not the application id the list prints;
the app id is only the argument to `instances`. The client must see a truncated,
failed download — never a silent success — and the next request must start
cleanly.

### 39.7 Record the verdict

Paste the output, byte counts and failure text on issue #707. On a pass,
redeploy with the production repository URI and GUID from section 38, run
`gate.sh matrix` once more, and delete the `/gate` path afterwards. On a
failure, use 39.8; it is preauthorized.

### 39.8 VPS fallback (preauthorized)

Same image, same environment contract, same Access and R2 policy. Only the
hosting changes: a tunnel instead of the Worker route, and persistent
`/data` and `/cache` volumes.

```sh
# On the laptop: build and publish the same image the Worker uses.
podman build -t ghcr.io/smores56/backrest:vps backrest/container
gh auth token | podman login ghcr.io -u smores56 --password-stdin
podman push ghcr.io/smores56/backrest:vps
```

```sh
# On the VPS, as root.
install -d -m 0700 /etc/backrest
$EDITOR /etc/backrest/env
#   BACKREST_INSTANCE=backrest-recovery
#   BACKREST_REPO_ID=r2
#   BACKREST_REPO_URI=<production URI>
#   BACKREST_REPO_GUID=<GUID>
#   RESTIC_PASSWORD=<restic password>
#   R2_ACCESS_KEY_ID=<read-only key>
#   R2_SECRET_ACCESS_KEY=<read-only secret>
#   BACKREST_OPERATOR_USER=operator
#   BACKREST_OPERATOR_BCRYPT=<base64 bcrypt>
#   BACKREST_BOOTSTRAP_USER=bootstrap
#   BACKREST_BOOTSTRAP_BCRYPT=<base64 bcrypt>
chmod 600 /etc/backrest/env

cat >/etc/systemd/system/backrest.service <<'EOF'
[Unit]
Description=Backrest recovery reader
After=network-online.target
Wants=network-online.target

[Service]
Restart=always
EnvironmentFile=/etc/backrest/env
ExecStart=/usr/bin/podman run --rm --name backrest \
  -p 127.0.0.1:9898:9898 \
  -v backrest-data:/data -v backrest-cache:/cache \
  --env-file /etc/backrest/env \
  ghcr.io/smores56/backrest:vps /backrest

[Install]
WantedBy=multi-user.target
EOF

podman volume create backrest-data
podman volume create backrest-cache
systemctl daemon-reload
systemctl enable --now backrest.service
curl -fsS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9898/   # any status means listening
```

Point the hostname at the VPS with a dedicated cloudflared tunnel
(`cloudflared tunnel run --token <token>`, token in Bitwarden) and a reviewed
tofu diff that moves `recovery.sammohr.dev` from the Worker route to the tunnel.
The Access application does not change. Then run 39.6 again against the same
hostname — the matrix is the acceptance criterion, not the platform.

## 40. Applications (T5) and agent deployments (T6): publish images, expose them, prove restores

These steps make Immich, OPDShelf and Syncthing run from the derived image and
prove that each one restores on scratch storage. Subsections 40.7 to 40.13 cover
the agent deployments from SDLC #711 and their browser UIs from #775: their seven
secrets, the pinned model file, the two gateway routes on 443, the two UI ports and
the facade wire. Background and invariants are in
`docs/core/applications.md`; the recovery groups are in
`docs/core/restic-plane.md`. Prerequisites: the derived image from section 37 is
booted, the age identity is staged root-only under `/var` (section 37), and the
tailnet has MagicDNS and HTTPS certificates enabled.

### 40.1 Publish and sign the application images

The host's default-reject policy accepts an application image only when it is
signed by the smortress cosign key and pushed under
`ghcr.io/smores56/homelab-platform`, so the images have to be mirrored before the
Quadlets can start. The workflow does the copy, the signature and the
verification; it needs the `server-image` environment's signing key.

```sh
gh workflow run publish-app-images.yml --repo smores56/homelab-platform
gh run watch --repo smores56/homelab-platform
```

A green run prints every mirrored reference. Any digest mismatch or a missing
`.sig` lookaside tag fails the run instead of leaving a half-mirrored set.

```sh
skopeo inspect --no-tags --format '{{.Digest}}' \
  docker://ghcr.io/smores56/homelab-platform/immich-server@sha256:c716dc20f957aafd89fa9d284a2ec63e25c9e2d8d8e87c6197d540a3dce237db
```

That must print the same digest back, and so must the same command with no
credential at all — which is how the host pulls it. GHCR packages are private by
default: for each of the six packages, open
`https://github.com/users/smores56/packages/container/<name>/settings`, choose
Change visibility → Public, and confirm the unauthenticated inspect above still
answers. The mirror script fails its own run when a package is not anonymously
readable, because a private package is a failed pull on the first boot after the
deploy, not a deploy-time error. On the host the policy is what enforces the
rest:

```sh
sudo podman pull ghcr.io/smores56/homelab-platform/immich-server@sha256:c716dc20f957aafd89fa9d284a2ec63e25c9e2d8d8e87c6197d540a3dce237db
```

A signature that does not verify fails that pull before the image reaches local
storage. The mirror signs the index digest and every platform manifest of it,
because containers/image verifies the manifest it copies: a pull of an index by
digest selects one platform, and an index-only signature is rejected with
`A signature was required, but no signature exists`. The run ends with a
policy-checked pull of every image to prove exactly that.

#### The pre-baked web UI image

Hermes' browser UI is the one application image this repository builds rather
than mirrors. Upstream's entrypoint installs the Python dependencies from PyPI at
container start, which a sealed deployment can never do, so
`images/agent-webui/Containerfile` moves that install to build time: uv is
baked in, the finished virtual environment ships inside the image under
`/apptoo`, and the entrypoint's first-start install finds its marker and does
nothing with its network access removed.

```sh
gh workflow run publish-agent-webui.yml --repo smores56/homelab-platform
gh run watch --repo smores56/homelab-platform
```

The run builds, signs, verifies and policy-pulls the image, and prints the pin
row in its step summary:

```
agent-webui|built:images/agent-webui/Containerfile|sha256:...
```

Copy that row into the `app_images` table of `scripts/app-images.sh` and merge
it. The Quadlets take their reference from that table, so the digest the host
pulls is the digest the run signed; a typo is a rejected pull at boot instead of
a merge error. A rebuild produces a new digest and therefore a new row: the
image that runs is always one that was signed and proved, never a tag that moved
under a running host.

### 40.2 Deploy the image that ships the Quadlets

The running deployment tracks a pinned derived digest, so `bootc upgrade` has
nothing to move to: it re-reads the same reference and boots the same OS. Point
it at the digest the `publish-server-image` run for this change printed.

```sh
read -r digest   # the sha256:... value from that run's summary
sudo bootc status
sudo bootc switch --enforce-container-sigpolicy \
  "ghcr.io/smores56/homelab-platform/server@${digest}"
sudo systemctl reboot
```

After the reboot the pool unit creates the new `syncthing` group and the Quadlet
generator picks up the six containers and the bridge network. A container whose
network file is missing from the image is dropped by the generator with
`requested Quadlet unit opdshelf.network was not found` and leaves no unit to
start, so read the generator's own errors before chasing the containers:

```sh
journalctl -b | grep -i quadlet-generator
```

```sh
sudo zfs list -o name,mountpoint smortress
systemctl list-units --all 'immich-*' 'opdshelf*' 'syncthing*'
sudo podman ps --format '{{.Names}}	{{.Status}}'
```

`immich-server`, `immich-postgres`, `immich-valkey`,
`immich-machine-learning`, `opdshelf` and `syncthing` should all be `Up`. A unit
that failed to start names its reason: `systemctl status <unit>` then
`journalctl -u <unit> -n 50 --no-pager`.

```sh
systemctl status smortress-app-secrets.service zfs-ready@syncthing.service
```

Podman secrets exist only if `smortress-app-secrets.service` succeeded; a
container that declares one fails to create, not to authenticate, when it did
not.

The new `syncthing` recovery group has no Restic status until its first backup
runs, and the `r2` destination is only due at 00:00 UTC, so
`smortress-restic-verify` fails on `r2/syncthing: no status state` until then.
Start that backup once the applications are up:

```sh
sudo systemctl start smortress-restic-backup@r2.service
sudo systemctl start smortress-restic-verify.service
```

A unit that fails with `statfs <path>: no such file or directory` mounts a
directory the image creates through tmpfiles; if `journalctl -b | grep tmpfiles`
shows `Failed to resolve user`, the entry names a login the image does not
create. The state directories outside the recovery groups are
`/var/lib/immich/ml-cache` and `/var/lib/syncthing-versions`, both owned by the
numeric uid the containers run as.

### 40.3 Inspect or rotate an application secret

Both application secrets are single-value SOPS files. Viewing one needs the age
identity, which only the operator has: the machine identity this host staged at
`/var/lib/homelab/age/keys.txt`, root-only. It is linked at root's default sops
path, and the sudoers drop-in strips inherited `SOPS_AGE_*` variables, so plain
`sudo sops` is the whole command — there is nothing to set.

```sh
sudo sops --decrypt --extract '["password"]' \
  /var/lib/smortress/secrets/immich-db-password.yaml
```

Rotating a value that a container reads is one step; rotating a password the
database already stores is two. Postgres sets the `immich` role's password once,
at `initdb`, so changing only the secret makes the server fail authentication.
Change the role first, on the running cluster:

```sh
sudo podman exec -i immich-postgres psql -U immich -d immich \
  -c "ALTER USER immich WITH PASSWORD '$(sudo sops --decrypt --extract '["password"]' /var/lib/smortress/secrets/immich-db-password.yaml)'"
```

Then edit the ciphertext, publish a new image, reboot, and recreate the
containers so they pick up the new Podman secret:

```sh
sops secrets/server/immich-db-password.yaml
git commit -am 'chore(core): rotate the Immich database password'
git push
sudo bootc upgrade && sudo systemctl reboot
```

`sudo systemctl restart immich-postgres.service immich-server.service
opdshelf.service` recreates those containers in place, which is enough after a
`systemctl restart smortress-app-secrets.service`. The OPDShelf password has no
such second copy: rotating the ciphertext is the whole change.

### 40.4 Declare the Serve routes

`scripts/tailscale-serve.sh` is the producer of every route on this host. The
image installs it as `/usr/libexec/tailscale-serve`, and
`smortress-tailscale-serve.service` runs it at every boot. There is no
hand-run declaration to remember: a reinstall or a re-enrolment that left Serve
empty is repaired by starting the unit, never by retyping a `tailscale serve`
command into a shell.

Serve needs HTTPS certificates for the tailnet, which is an admin-console toggle,
not a host setting. Once it is on:

```sh
sudo systemctl start smortress-tailscale-serve.service
tailscale serve status
```

The status output must show eight routes — seven HTTPS proxies and the
wallpapers path: 443 to `http://127.0.0.1:2283` (Immich), 8443 to
`http://127.0.0.1:8083` (OPDShelf), 10000 to `http://127.0.0.1:8384` (Syncthing
GUI), 8444 and 8445 to the two agent web UIs, 8446 to `http://127.0.0.1:2283`
and 8447 to `http://127.0.0.1:8083` for the public edge (`§50.6`), and
`/wallpapers/` on 443 to the directory `/srv/wallpapers`. The wallpaper route is the only one with no application
behind it: Serve publishes the wallpaper dataset as static files, and the path
shows a `Path` target where the others show a `Proxy`. Nothing here is Funnel.

The wallpaper route fails in a client rather than on this host, so prove it from
a tailnet device — the timer on the laptops fetches exactly this URL and carries
no credential:

```sh
curl -fsS https://smortress.<tailnet>.ts.net/wallpapers/ | head
```

A `200` with the file links means the route is up; an empty listing means the
dataset is not mounted under it, which is what
`systemctl status zfs-ready@raw-wallpapers.service` answers.

Syncthing refuses a proxied Host header: the GUI is bound to localhost, so it
rejects anything whose `Host` is not localhost with `403`, which is every request
the Serve proxy forwards (`https://smortress.<tailnet>.ts.net:10000`). Turn the
check off through its own API, with the key from the config it writes on the
`syncthing` dataset:

```sh
key=$(sudo sed -n 's:.*<apikey>\(.*\)</apikey>.*:\1:p' /var/lib/syncthing/config/config.xml)
sudo curl -fsS -X PATCH -H "X-API-Key: $key" -H 'Content-Type: application/json' \
  -d '{"insecureSkipHostcheck": true}' http://127.0.0.1:8384/rest/config/gui
curl -fsS -o /dev/null -w '%{http_code}\n' \
  https://smortress.<tailnet>.ts.net:10000/rest/noauth/health
```

The last command answers `200` only after that patch, and the patch persists in
`config.xml`; a restored config needs it again if the snapshot predates it. The
GUI has no password of its own, so the tailnet-only Serve route is the whole
access control on it.

### 40.5 Verify the applications and the closed LAN

From a tailnet device (laptop or phone):

```sh
curl -fsS -o /dev/null -w '%{http_code}\n' https://smortress.<tailnet>.ts.net/api/server/ping
curl -fsS -o /dev/null -w '%{http_code}\n' https://smortress.<tailnet>.ts.net:8443/healthz
curl -fsS -o /dev/null -w '%{http_code}\n' https://smortress.<tailnet>.ts.net:10000/rest/noauth/health
```

All three must answer 200. On the phone: no exit node, global DNS override off,
ordinary internet and LAN traffic working while Immich and OPDShelf load.

From a machine on the LAN that is **not** on the tailnet:

```sh
curl --max-time 3 http://10.0.0.125:22000
ssh -o ConnectTimeout=3 smores@10.0.0.125
```

Both must time out. A connection there means the default firewalld zone is no
longer `drop` or a Quadlet published an address it should not have.

### 40.6 Prove the restores on scratch storage

Sign in to smortress over Tailscale and stop the applications **and the dump
timer**. A drill that runs beside the live cluster proves nothing about a cold
restore, and the 21:00 timer would otherwise start Postgres on the live dataset
in the middle of one.

```sh
sudo systemctl stop smortress-immich-dump.timer
sudo systemctl stop immich-server.service immich-machine-learning.service immich-postgres.service \
  immich-valkey.service opdshelf.service syncthing.service
```

`smortress-restic-restore-drill` writes the unit's paths under
`<target>/<mountpoint>/.zfs/snapshot/<backend>`, because those are the paths the
snapshot recorded. Set the variables the rest of this section uses; `path` prints
the restored tree of one dataset.

```sh
drill=/var/lib/restic/ssd/drill
path() { printf '%s%s/.zfs/snapshot/ssd' "$drill" "$1"; }
for unit in files photos books music wallpapers git apps repo-archive; do
  sudo /usr/libexec/smortress-restic-restore-drill ssd "$unit" --target "$drill/$unit"
done
sudo chown -R 1000:1000 "$drill"
sudo chcon -R -t container_file_t "$drill"
```

Every application runs as uid 1000 and each group root is owned by that uid (the
pool unit sets it at dataset creation). A restored tree is root-owned and
unlabelled, because the restore runs as root and Restic does not carry
`security.selinux`: the `chown` and `chcon` above are what make it a tree the
application can write and Podman may mount. A real restore needs the same two
steps before the application starts.

**Immich, logical restore.** This is the path the cutover uses and the one that
survives a version change.

```sh
sudo install -d -o 1000 -g 1000 -m 0700 /var/lib/restic/ssd/drill-pg
sudo podman network create drillnet 2>/dev/null || true
sudo podman run --rm -d --name drill-pg --network drillnet --network-alias drill-pg \
  --user 1000:1000 -e PGDATA=/data -e POSTGRES_USER=immich -e POSTGRES_DB=immich \
  -e POSTGRES_PASSWORD_FILE=/run/secrets/pw \
  --secret immich-db-password,type=mount,target=/run/secrets/pw \
  -v /var/lib/restic/ssd/drill-pg:/data:z \
  ghcr.io/smores56/homelab-platform/immich-postgres@sha256:79b95b795f0911e95ffa4d092a2162c4d81a984d5629bc8f786afe0bc0657671
sudo podman cp "$(path /var/lib/immich/dumps)/immich.dump" drill-pg:/tmp/immich.dump
sudo podman exec drill-pg pg_isready -U immich -d immich
sudo podman exec drill-pg pg_restore -U immich -d immich --no-owner --clean --if-exists \
  /tmp/immich.dump
sudo podman exec drill-pg psql -U immich -d immich -c 'select count(*) from asset;'
```

The count must be non-zero and match what the phone shows. Then start a throwaway
server against the restored library:

```sh
sudo podman run --rm -d --name drill-immich --network drillnet \
  -p 127.0.0.1:12283:2283 --user 1000:1000 \
  -e DB_HOSTNAME=drill-pg -e DB_PORT=5432 -e DB_USERNAME=immich -e DB_DATABASE_NAME=immich \
  -e DB_PASSWORD_FILE=/run/secrets/pw -e IMMICH_MEDIA_LOCATION=/data/library \
  -e IMMICH_MACHINE_LEARNING_URL=http://127.0.0.1:3003 \
  --secret immich-db-password,type=mount,target=/run/secrets/pw \
  -v "$(path /var/srv/photos):/data/library:z" \
  ghcr.io/smores56/homelab-platform/immich-server@sha256:c716dc20f957aafd89fa9d284a2ec63e25c9e2d8d8e87c6197d540a3dce237db
curl -fsS http://127.0.0.1:12283/api/server/ping
```

`{"res":"pong"}` plus a non-zero asset count is the proof that the dump, the
library and the version agree. A restored library is not proven by a running
server: open one asset through the restore and compare it.

**Immich, physical restore.** Restore the cluster files instead of the dump. The
`state/immich-postgres` dataset root is `PGDATA`, so the live host and the drill
both use `PGDATA=/data` with no subdirectory:

```sh
sudo podman rm -f drill-immich drill-pg
sudo rm -rf /var/lib/restic/ssd/drill-pg
sudo install -d -o 1000 -g 1000 -m 0700 /var/lib/restic/ssd/drill-pg
sudo cp -a "$(path /var/lib/immich/postgres)/." /var/lib/restic/ssd/drill-pg/
sudo chown -R 1000:1000 /var/lib/restic/ssd/drill-pg
sudo podman run --rm -d --name drill-pg --network drillnet --network-alias drill-pg \
  --user 1000:1000 -e PGDATA=/data \
  -v /var/lib/restic/ssd/drill-pg:/data:z \
  ghcr.io/smores56/homelab-platform/immich-postgres@sha256:79b95b795f0911e95ffa4d092a2162c4d81a984d5629bc8f786afe0bc0657671
sudo podman exec drill-pg psql -U immich -d immich -c 'select count(*) from asset;'
```

That cluster carries the password that was current when the snapshot was taken.
After a real physical restore, set it from the decrypted secret before starting
the server, or rotate the ciphertext — otherwise the server cannot authenticate:

```sh
sudo podman exec -i drill-pg psql -U immich -d immich \
  -c "ALTER USER immich WITH PASSWORD '$(sudo sops --decrypt --extract '["password"]' /var/lib/smortress/secrets/immich-db-password.yaml)'"
```

**OPDShelf.** Nothing stateful to rebuild; prove the tree serves.

```sh
sudo podman run --rm -d --name drill-opds -p 127.0.0.1:18083:8083 \
  --user 1000:1000 -e PORT=8083 -e BOOKS_DIR=/books -e DATA_DIR=/books/.opdshelf \
  -e WATCH=false \
  --secret opdshelf-admin-password,type=env,target=ADMIN_PASSWORD \
  -v "$(path /var/srv/books):/books:z" \
  ghcr.io/smores56/homelab-platform/opdshelf@sha256:b82f94f72b41686fd9169a2269d65550f411a97dfa341a330df88b0bfab0af35
curl -fsS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18083/healthz
curl -fsS -u "smores56:$OPDS_PASSWORD" http://127.0.0.1:18083/ | head -5
sudo podman rm -f drill-opds
```

The catalog answers only with the admin password, which is the behaviour being
proven; read it into `OPDS_PASSWORD` from the decrypted secret rather than
typing it into a shell history.

**Syncthing.** Restore the identity and the folder, and let nothing sync until a
primary is designated.

```sh
sudo podman run --rm -d --name drill-syncthing --network host \
  -e HOME=/var/syncthing -e STHOMEDIR=/var/syncthing/config \
  -e STGUIADDRESS=127.0.0.1:18384 \
  -v "$(path /var/lib/syncthing/config):/var/syncthing/config:z" \
  -v "$(path /var/srv/files):/srv/files:z" \
  ghcr.io/smores56/homelab-platform/syncthing@sha256:2b71da7c0d0a91a6ae5285ad079226fecc0a365d08b27720e1f7037b018f7546
curl -fsS http://127.0.0.1:18384/rest/noauth/health
```

The GUI on `127.0.0.1:18384` must list the restored folder. Pause every folder
there before a peer is allowed to connect; only then is the restored tree the
primary. The drill config keeps the restored `<listenAddress>`, so stop the drill
before the real service starts.

```sh
sudo podman rm -f drill-syncthing drill-pg
sudo podman network rm drillnet
sudo rm -rf "$drill" /var/lib/restic/ssd/drill-pg
sudo systemctl start immich-postgres.service immich-valkey.service immich-machine-learning.service \
  immich-server.service opdshelf.service syncthing.service
sudo systemctl start smortress-immich-dump.timer
```

The T6 cutover reuses these drills: it restores the same units from each of the
three destinations before the legacy stack is retired.

### 40.7 Create the seven agent secrets

The agent deployments need seven single-value SOPS files. Three are `api_key:`
keys: two self-issued gateway keys and the hosted provider key, which is the only
credential on this host that is not ours. Two are `token:` values, one per source
facade. Two are `password:` values, the browser UI's login gate, one per
deployment -- separate on purpose, because the two UIs are separate authority
domains and a password leaked from one must not open the other. `sops` finds the
age recipients in `.sops.yaml`, so every command below runs from the repository
root.

Replace the seeded provider key first. The ciphertext committed with this change
holds a random value: with it the proxy answers `401` from the provider, which is
the loud failure it is supposed to be, and nothing else breaks.

```sh
sops secrets/server/agent-hosted-key.yaml      # set api_key: to the provider key
sops secrets/server/agent-local-api-key.yaml   # optional: rotate, openssl rand -hex 32
sops secrets/server/agent-general-api-key.yaml # optional: rotate the same way
sops secrets/server/agent-facade-personal-token.yaml  # optional: rotate, openssl rand -hex 32
sops secrets/server/agent-facade-general-token.yaml   # optional: rotate the same way
sops secrets/server/agent-ui-personal-password.yaml   # optional: rotate, openssl rand -hex 32
sops secrets/server/agent-ui-general-password.yaml    # optional: rotate the same way
```

A facade token and a UI password are not replaced by hand: the committed
ciphertexts already hold fresh random values, so those four secrets need no edit
at all unless you are rotating them (40.11 for the tokens; a UI password is
rewritten into `webui.env` at every boot, so rotating it is the same sops-and-
deploy cycle followed by a restart of the one UI).

```sh
git commit -am 'chore(core): set the agent provider key'
```

Each file must stay a single scalar, because `image/rootfs/etc/smortress/secrets.manifest`
declares it `value`: a second key or an empty value fails `sops-decrypt.service` at
boot rather than publishing half a secret. The seven manifest rows are exactly

```text
agent-local-api-key.yaml      root  root  0400  value
agent-general-api-key.yaml    root  root  0400  value
agent-hosted-key.yaml         root  root  0400  value
agent-facade-personal-token.yaml root root 0400 value
agent-facade-general-token.yaml  root root 0400 value
agent-ui-personal-password.yaml  root root 0400 value
agent-ui-general-password.yaml   root root 0400 value
```

After the image is deployed (40.2), the decrypted copies are root-only and each
container's own copy is 0400 for uid 1000:

```sh
sudo ls -l /run/smortress/secrets/agent-*.yaml
sudo stat -c '%u:%g %a %n' /var/lib/agent/local/.env /var/lib/agent/general/.env \
  /var/lib/agent/local/webui.env /var/lib/agent/general/webui.env
```

`smortress-agent-config.service` rewrites `.env` at every boot from the ciphertext,
so a rotated gateway key lands with the next reboot -- the container reads
`API_SERVER_KEY` from it, and the runtime has no `_FILE` variant to mount instead.

### 40.8 Fetch the pinned model into the model dataset

The model is not in any backup: 16.5 GiB of a blob that a checksum re-derives. It
is fetched once into `state/agent-model`, which the pool unit must have created and
mounted first.

The weight file is `AtomicChat/Inkling-2-Mini-GGUF`, a GGUF conversion of
Thinking Machines' `thinkingmachines/Inkling-2-Mini` (26.4B MoE, 3.4B active, 1M
context, Apache-2.0). `AD-Q4_K` is the quant the unit pins: the base repository's
own table puts it at KLD 0.0080 / top-1 96.3% against BF16. The *Uncensored*
variant in the neighbouring repository is deliberately not used: it costs fidelity
(0.0115 / 95.6% at the same quant) and buys nothing for a typed-tool agent, while
the personal profile reads attacker-influenced mail and calendar text. The
`mmproj` vision projector is not fetched either -- the deployment is text-only
until something asks for images.

```sh
sudo zfs get -H -o value mounted smortress/state/agent-model
sudo chown 1000:1000 /var/lib/agent/model
sudo curl -fL --retry 3 --continue-at - -o /var/lib/agent/model/Inkling-2-Mini-AD-Q4_K.gguf.part \
  'https://huggingface.co/AtomicChat/Inkling-2-Mini-GGUF/resolve/main/Inkling-2-Mini-AD-Q4_K.gguf?download=true'
```

Verify before it is used. The size and the checksum are the pin; a partial or
re-encoded download fails here, not inside llama.cpp:

```sh
echo '2bfc233e10925297cc79dffce5d9be4f2a2b43e499ea6a1bf03b9242867dce9e  /var/lib/agent/model/Inkling-2-Mini-AD-Q4_K.gguf.part' \
  | sudo sha256sum -c -
sudo stat -c '%s' /var/lib/agent/model/Inkling-2-Mini-AD-Q4_K.gguf.part   # 16525559776
sudo mv /var/lib/agent/model/Inkling-2-Mini-AD-Q4_K.gguf.part \
        /var/lib/agent/model/Inkling-2-Mini-AD-Q4_K.gguf
sudo chown 1000:1000 /var/lib/agent/model/Inkling-2-Mini-AD-Q4_K.gguf
```

The name matters: `units/quadlet/agent-model.container` starts the server with
`-m /models/Inkling-2-Mini-AD-Q4_K.gguf`. A different file name needs that unit
changed as well, which is an image change. The previous model
(`Qwen2.5-7B-Instruct-Q4_K_M.gguf`) is dead weight once the new one loads; it lives
in no backup unit, so removing it is just disk:

```sh
sudo rm -f /var/lib/agent/model/Qwen2.5-7B-Instruct-Q4_K_M.gguf
```

The server's flags are one decision and are measured, not guessed: `-c 196608
--parallel 3` gives three 65,536-token slots (the config's `context_length` is
one slot), `-ub 128` keeps the prompt graph small enough to allocate, and
`-fa on -ctk q8_0 -ctv q8_0` halve the KV cache while flash attention keeps the
attention graph flat. 20,834 MiB resident of 24,576 at 57 tok/s generation is what
that buys; a fourth slot, the default micro-batch, or an fp16 cache each push the
load back over the card.

### 40.9 Validate the units and check the three listeners

`systemd-analyze verify` parses the two hand-written units and needs no root, so it
runs from the checkout before the deploy:

```sh
systemd-analyze verify units/systemd/smortress-nvidia-cdi.service \
  units/systemd/smortress-agent-config.service
```

After the reboot, the generator's own dry run is what shows a Quadlet the image did
not install, or one that names a network file that is not there: the generator
drops the container and says so, and the unit is simply absent.

```sh
sudo /usr/lib/systemd/system-generators/podman-system-generator -dryrun -v 2>&1 \
  | grep -E 'agent-(model|local|general|proxy|facade-personal|facade-general)\.(service|network)'
sudo podman quadlet list | grep agent
systemctl cat agent-proxy.service agent-facade-personal.service | head -40
```

A changed `[Network]` option does not apply by rebooting alone:
`podman network create --ignore` leaves an existing network's stored config
untouched, and the generated `ExecStart` will happily show the new flag while
the network keeps the old one. `NetworkDeleteOnStop=true` on the agent networks
makes the next boot rebuild them; on a running host the manual form is

```sh
sudo systemctl stop agent-webui-personal agent-local agent-facade-personal agent-model
sudo systemctl stop agent-local-network.service
sudo podman network rm systemd-agent-local
sudo systemctl start agent-local-network.service
sudo systemctl start agent-model.service agent-facade-personal.service agent-local.service agent-webui-personal.service
```

`systemctl cat` is the ground truth: it prints the unit the generator produced, so a
`Network=` that resolved to nothing, a `Secret=` that no Podman secret satisfies, or
a `Volume=` whose host path is missing (`statfs /var/lib/agent/general/memory: no
such file or directory`) is visible before anything is started.

Start them in dependency order and read the one thing each step produces:

```sh
sudo systemctl start zfs-ready@state-agent-model.service zfs-ready@state-agent-local.service \
  zfs-ready@state-agent-general.service
sudo systemctl start smortress-nvidia-cdi.service
sudo nvidia-ctk cdi list                                     # one device, nvidia.com/gpu=all
sudo systemctl start smortress-agent-config.service
sudo ls -l /var/lib/agent/local/config.yaml /var/lib/agent/general/config.yaml
sudo stat -c '%u:%g %a %n' /var/lib/agent/local/memory /var/lib/agent/general/memory
sudo systemctl start agent-proxy.service agent-model.service agent-general.service agent-local.service
sudo systemctl start agent-facade-personal.service agent-facade-general.service
sudo podman ps --filter name=agent --format '{{.Names}}	{{.Status}}'
```

Six containers answer `Up`: the proxy, the model server, the two gateways and the
two facades. The two memory directories must be `1000:1000 0750` before the facades
start -- the seed unit creates them, and a facade that lets podman create its own
bind source gets a root-owned directory inside a 0750 dataset and fails its first
memory write.

The model server must be *on* the GPU, and that is a separate fact from the
container being up: it can load the model and listen on 8080 while CUDA reported
no device. `nvidia-smi` must list `llama-server` with the model resident; with no
entry, look for `ggml_cuda_init: failed to initialize CUDA` in the unit's log and
for a `denied { map } ... nvidia_container_t ... container_file_t` audit line,
which means `smortress-selinux-nvidia-map.service` did not load its rule.

```sh
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv
```

A template change does not reach a deployment that is already seeded:
`smortress-agent-config.service` copies `config.yaml` in once and never rewrites
it, because the runtime and the operator own that copy. To take the current
template -- the `delegation` block, for example -- discard the copy and re-run the
seeder; an edit made in place would survive every boot instead.

```sh
sudo rm /var/lib/agent/local/config.yaml
sudo systemctl restart smortress-agent-config.service agent-local.service
sudo grep -A6 '^delegation:' /var/lib/agent/local/config.yaml
```

The same for the general side with `/var/lib/agent/general/config.yaml` and
`agent-general.service`.

The proxy and the two gateways answer on loopback. The proxy check is also the only
proof the provider key works: `200` on `/v1/models` means the key was accepted by the
provider, `401` means the ciphertext still holds the seeded random value (40.7).

```sh
curl -fsS http://127.0.0.1:18003/healthz
curl -fsS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18003/v1/models
curl -fsS -H 'Accept: application/json' http://127.0.0.1:18003/v1/models | head -c 400
```

The model ids the account offers come back from that last call. The general config
pins `qwen-3.8-27b`; an id the account does not offer fails the first turn at the
provider, and the fix is that line in `/var/lib/agent/general/config.yaml`, not a
change to the proxy.

The gateways need their own key. It is one value in each `.env`, and the same value
authenticates `/v1/models` and `/v1/chat/completions`:

```sh
key=$(sudo sed -n 's/^API_SERVER_KEY=//p' /var/lib/agent/local/.env)
curl -fsS -H "Authorization: Bearer $key" http://127.0.0.1:18001/v1/models
curl -fsS -H "Authorization: Bearer $key" -H 'Content-Type: application/json' \
  -d '{"model":"hermes-agent","messages":[{"role":"user","content":"ping"}]}' \
  http://127.0.0.1:18001/v1/chat/completions
gkey=$(sudo sed -n 's/^API_SERVER_KEY=//p' /var/lib/agent/general/.env)
curl -fsS -H "Authorization: Bearer $gkey" -H 'Content-Type: application/json' \
  -d '{"model":"hermes-agent","messages":[{"role":"user","content":"ping"}]}' \
  http://127.0.0.1:18002/v1/chat/completions
```

The gateways run the runtime's own supervisor, so its uid remap is the thing to
read: the unit passes `HERMES_UID=1000`/`HERMES_GID=1000` because the image rejects
an arbitrary `--user`, and the boot log must show the remap and files owned by 1000.

```sh
sudo podman logs smortress-agent-local 2>&1 | grep -E 'stage2|Changing hermes'
sudo stat -c '%u:%g %a %n' /var/lib/agent/local /var/lib/agent/local/config.yaml
```

A `Permission denied` under `/opt/data` means the remap did not run: check that
`HERMES_UID`/`HERMES_GID` are still in the unit and that the dataset is 0750
`1000:1000`. Do not fix it by widening the dataset mode -- the next container in
the same network would read it.

The personal side must have no egress, and that is checked from inside its own
namespace, not from the host. The network has no default route, so a name may
still resolve through the bridge resolver while no connection can leave the
subnet; the route and the failed connection are the proof, not the lookup:

```sh
sudo podman exec smortress-agent-model cat /proc/net/route
sudo podman exec smortress-agent-local python3 -c \
  'import socket; socket.create_connection(("1.1.1.1", 443), 3)' ; echo "exit=$?"
sudo podman exec smortress-agent-local python3 -c \
  'import socket; print(socket.create_connection(("smortress-agent-model", 8080), 3))'
```

`/proc/net/route` rather than `ip route`: neither agent image ships iproute2.
It shows the subnet route and no `00000000` default entry; the second command
fails with `Network is unreachable`; the third must connect, because the model
call above still succeeding is what makes the failure meaningful.

### 40.10 Check the two Serve routes

`scripts/tailscale-serve.sh` declares `/apps/agent-local` and `/apps/agent-general`
on 443 as core paths and 8444/8445 as core ports for the two web UIs, before the
tenant plan is applied, and the stale-route pruning skips both paths. After the
deploy:

```sh
sudo systemctl start smortress-tailscale-serve.service
tailscale serve status
```

The status must show `https://smortress.<tailnet>.ts.net:443` handlers `/`,
`/wallpapers/`, `/apps/agent-local`, `/apps/agent-general`, and one `/apps/<name>`
per tenant app, plus root handlers on `:8444` and `:8445` for the two web UIs. The
UIs are ports rather than paths because a web UI emits absolute asset and link
URLs: behind a path prefix the browser would ask the tailnet root, which is Immich. There is no handler for `127.0.0.1:18003` and there must never be
one: the general gateway reaches the proxy by container name, and a tailnet path to
the proxy would let any device spend the provider key. From a tailnet device:

```sh
read -r key   # paste the personal gateway key: sudo sed -n 's/^API_SERVER_KEY=//p' /var/lib/agent/local/.env
curl -fsS -H "Authorization: Bearer $key" \
  https://smortress.<tailnet>.ts.net/apps/agent-local/v1/models
curl -fsS -o /dev/null -w '%{http_code}\n' \
  https://smortress.<tailnet>.ts.net/apps/agent-general/v1/models
```

The first answers the gateway's model list; the second answers `401` without its own
key, which is the correct answer for a request that carries no credential.

### 40.11 Rotate a facade token

A facade token lives in three places that have to move together: the ciphertext in
git, the Podman secret the facade mounts, and the gateway's seeded `config.yaml`.
The first two follow the image (`sops-decrypt.service` re-decrypts and
`smortress-app-secrets.service` re-creates the secret on every boot), but the third
does not: `smortress-agent-config.service` seeds the config with `cp -n`, so a
deployed `config.yaml` holds the token it was seeded with and nothing rewrites it.
Rotating therefore ends with deleting that file so the unit seeds it again.

Rotate the ciphertext, then deploy it, then re-seed. Do not delete the config
before the new ciphertext is running: the reseed would copy the *old* token back.

```sh
sops secrets/server/agent-facade-personal-token.yaml   # set token: to `openssl rand -hex 32`
git commit -am 'chore(core): rotate the personal facade token'
git push
```

Publish the image, then deploy it (40.2):

```sh
sudo bootc upgrade && sudo systemctl reboot
```

After that boot the decrypted file and the Podman secret already carry the new
value; the gateway still has the old one. Delete the seeded config and let the seed
unit rebuild it, then restart the two containers that read the token:

```sh
sudo rm /var/lib/agent/local/config.yaml
sudo systemctl restart smortress-agent-config.service
sudo stat -c '%u:%g %a %n' /var/lib/agent/local/config.yaml   # 1000:1000 0600
sudo systemctl restart agent-facade-personal.service agent-local.service
```

A reboot does the same thing in one step (`sudo rm /var/lib/agent/local/config.yaml`
then `sudo systemctl reboot`): the seed unit is ordered
`Before=agent-local.service`, so the gateway starts against a config that already
carries the new token. The general deployment is the same commands with
`general` in place of `local` and `agent-facade-general-token.yaml` in place of the
personal ciphertext. Verify with 40.12 -- a gateway whose config still holds the old
token gets `401` from its facade, and the facade's log is where that shows up.

### 40.12 Verify the facade wire from the gateway

Three things have to be true and each has its own command: the facade answers an MCP
client inside the deployment's network, it answers only with the token, and the
gateway has registered its tools.

The client is the gateway container itself -- it is on `agent-local.network` and its
image carries `python3` -- and the token arrives on stdin, never in an argument:

```sh
sudo podman exec -i smortress-agent-local python3 -c '
import json, sys, urllib.request
token = sys.stdin.readline().strip()
def call(method, ident, params=None):
    request = urllib.request.Request(
        "http://smortress-agent-facade-personal:18004/mcp",
        data=json.dumps({"jsonrpc": "2.0", "id": ident, "method": method,
                         "params": params or {}}).encode(),
        headers={"Content-Type": "application/json", "X-Deployment-Token": token})
    with urllib.request.urlopen(request, timeout=10) as answer:
        return json.load(answer)
print(call("initialize", 1)["result"]["serverInfo"])
print([tool["name"] for tool in call("tools/list", 2)["result"]["tools"]])
' < <(sudo cat /run/smortress/secrets/agent-facade-personal-token.yaml)
```

The first line is the server info: `agent-facade-personal`. The second is the tool
list, and it is exactly `sources.describe`,
`sources.read`, `sources.search`, `memory.read`, `memory.write`, `memory.search` and
`memory.rebuild` -- no `repos`, no `books`, because the personal deployment has no
adapter for them. The general deployment answers the same way at
`http://smortress-agent-facade-general:18005/mcp` from `smortress-agent-general`,
with `repos` and `books` and no personal source.

A request with no token is `401` before any tool could run. This prints `401`:

```sh
sudo podman exec smortress-agent-local python3 -c '
import urllib.error, urllib.request
request = urllib.request.Request("http://smortress-agent-facade-personal:18004/mcp",
                                 data=b"{}", headers={"Content-Type": "application/json"})
try:
    urllib.request.urlopen(request, timeout=10)
except urllib.error.HTTPError as error:
    print(error.code)
'
```

The gateway's own view of the facade is the runtime's client, and its MCP subcommand
is the direct way to ask it. It exits non-zero and prints the reason when the server
is unreachable or refuses the token, so it is also the fastest diagnosis of a
rotation that did not reach the config:

```sh
sudo podman exec -e HERMES_HOME=/opt/data smortress-agent-local hermes mcp test personal
```

The tool names the runtime registers are prefixed with the server name from
`mcp_servers`, with dots turned into underscores: `mcp__personal__sources_describe`
through `mcp__personal__memory_rebuild`, and `mcp__general__*` on the other side. A
gateway that sees no `personal` server at all is a config problem, and the two things
to read are whether the placeholder is gone and what the facade logged:

```sh
sudo grep -c '__FACADE_TOKEN__' /var/lib/agent/local/config.yaml   # 0 after seeding
sudo podman logs smortress-agent-facade-personal 2>&1 | tail
```

The facade logs the method, the path and the status of every request it answers -- a
`401` where the gateway's `initialize` should be is the old token in
`config.yaml`, and 40.11 is the fix. The log carries no header and no token, so it is
safe to paste into a bug report.

### 40.13 Verify the two browser UIs

Both UIs run the image this repository builds (40.1). The first thing to check is
therefore that starting them installs nothing: upstream's entrypoint fetches uv
from astral.sh, builds the venv and installs from PyPI, and the bake exists so that
none of it happens.

```sh
sudo systemctl start agent-webui-personal.service agent-webui-general.service
sudo journalctl -u agent-webui-personal.service -n 60 --no-pager \
  | grep -E 'already installed|Existing virtual environment|skipping|listening'
```

Expect all of `uv already installed`, `Existing virtual environment found —
reusing`, `Dependencies already installed — skipping`, `hindsight-client already
installed` and `listening on http://0.0.0.0:8787`. A `Downloading uv` or a failing
`uv pip install` means the image that started is not the baked one, and on the
sealed personal side it would also have failed outright.

Both publish on loopback only, behind their own password gates:

```sh
for port in 18006 18007; do
  curl -sS -o /dev/null -w "$port / -> %{http_code} %{redirect_url}\n" http://127.0.0.1:$port/
  curl -sS -o /dev/null -w "$port /login -> %{http_code} /health -> " http://127.0.0.1:$port/login
  curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:$port/health
done
```

Each `/` answers `302` toward `/login?next=/`, each `/login` answers `200`, and
`/health` answers `200` without a session. A `200` on `/` means no password
reached the process: read `sudo sed -n 's/^HERMES_WEBUI_PASSWORD=.*/HERMES_WEBUI_PASSWORD=<set>/p'
/var/lib/agent/local/webui.env` -- the file must exist, be `1000:1000 0400`, and
carry both lines.

The personal UI has no route off the host, and that is a property of its network
rather than of the UI:

```sh
sudo podman exec smortress-agent-webui-personal python3 -c \
  'import socket; socket.create_connection(("1.1.1.1", 443), 3)'; echo "exit=$?"
sudo podman exec smortress-agent-webui-personal cat /proc/net/route
```

The first must exit non-zero and the second must show no default route. The general
UI runs on the egress network, so the same probe there succeeds; that difference is
the split, not a defect.

Each UI must be a client of its own deployment's gateway. Ask one question in each
and read the gateway's log:

```sh
sudo podman logs --since 2m smortress-agent-local 2>&1 | grep -c 'POST /v1'
sudo podman logs --since 2m smortress-agent-general 2>&1 | grep -c 'POST /v1'
```

The deployment whose UI answered is the deployment whose count moves. A personal
question that moves the general gateway's count is the crossing this split exists to
prevent, and the UI's `HERMES_WEBUI_GATEWAY_BASE_URL` is the thing to read.

From a tailnet device, open the two UIs and sign in with each deployment's own
password -- they are separate on purpose:

```sh
sops -d secrets/server/agent-ui-personal-password.yaml
sops -d secrets/server/agent-ui-general-password.yaml
```

* `https://smortress.<tailnet>.ts.net:8444/` is the personal UI: it answers from the
  pinned local model, and its model picker is the runtime's, not a hosted one.
* `https://smortress.<tailnet>.ts.net:8445/` is the general UI: it answers from the
  hosted provider, through `agent-proxy`.

The first-run wizard is disabled (`HERMES_WEBUI_SKIP_ONBOARDING=1`): in gateway mode
the UI has no agent source mounted, so the wizard reports `Missing imports:
run_agent` and offers a setup path this deployment does not use. Agent features that
need that source (model auto-detection, personality routing, CLI session import) are
absent in both UIs; the facades are the tool surface.

Rotating a UI password is the same sops-and-deploy cycle as 40.11, without its
reseed step: `smortress-agent-config.service` rewrites `webui.env` at every boot, so
the new value is in place after the boot that ships the new ciphertext, and

```sh
sudo systemctl restart agent-webui-personal.service
```

is enough once the image is running. Deleting `webui.env` is never part of the
procedure: it is rewritten, not seeded once.

### 40.14 Claim the SimpleFIN access URL and run the collector once

The finance collector needs one credential this repository cannot invent: the
access URL SimpleFIN issues for your account. It is a secret, so it arrives as
ciphertext and never as an environment variable or an argument.

The ciphertext ships seeded with a random value, which is a loud failure rather
than a silent one: the first request cannot authenticate and the collector
publishes nothing. Claim a real one and replace it.

1. Ask SimpleFIN for a setup token (their dashboard does this), then claim it. The
   claim is single-use and returns the access URL:

   ```sh
   read -r setup_token   # paste the setup token
   python3 - <<'PY'
   import base64, sys
   print(base64.b64decode(sys.stdin.read().strip()).decode())
   PY
   ```

   That prints the claim URL; `curl -X POST <claim-url>` answers with the access
   URL. It embeds the account's username and password, so do not paste it into a
   shell that logs.

2. Write it into the ciphertext and deploy it:

   ```sh
   sops secrets/server/simplefin-access-url.yaml   # set access_url: to the claimed URL
   git commit -am 'chore(core): claim the SimpleFIN access URL'
   git push && sudo bootc upgrade && sudo systemctl reboot
   ```

3. After the boot, prove the secret is where the unit expects it and run the
   collector once by hand before the timer does:

   ```sh
   sudo stat -c '%u:%g %a %n' /run/smortress/secrets/simplefin-access-url.yaml
   sudo systemctl start smortress-agent-collect-finance.service
   sudo journalctl -u smortress-agent-collect-finance.service -n 20 --no-pager
   sudo podman secret inspect simplefin-access-url
   ```

   The unit prints one JSON report; the run is good when `published` names a
   generation and `objects` counts the transactions. A refusal exits 3 and
   publishes nothing, and its message names the endpoint by host and path -- never
   the credential.

4. Read the generation back, and confirm the deployment can see it without any
   network of its own:

   ```sh
   sudo ls -ld /var/lib/agent/local/replica/finance/published/*/
   sudo find /var/lib/agent/local/replica/finance -maxdepth 2 -user 1000 -printf '%u:%g %p\n'
   ```

   Every published generation must be owned by uid 1000. A `.staging` directory
   left behind means a run was interrupted mid-enumeration; it is safe to remove,
   because nothing publishes from there.

5. Turn the timer on and check it is scheduled:

   ```sh
   sudo systemctl list-timers smortress-agent-collect-finance.timer
   ```

6. Map the accounts, then read the journal. The third stage of the unit renders
   the newest published generation as an hledger journal, and it needs one thing
   from you: which hledger account each SimpleFIN account is. The file is seeded
   as `{}` at the first boot and is never overwritten, so this edit is one-time
   per account. Every entry the file does not name renders as
   `assets:unknown:<id>`, which is how you find the ids:

   ```sh
   sudo grep -ho '"object_id": "finance::account::[^"]*"' \
     /var/lib/agent/local/replica/finance/published/*/manifest.json | sort -u
   sudo vi /var/lib/agent/local/index/hledger/accounts.json
   ```

   Write `{"<account id>": "assets:bank:checking"}` for each account, then rerun
   the service so the projection picks the mapping up. A mapping that is not a
   JSON object of string to string, or a name that is empty or starts with `-`,
   `!` or `;`, is refused with exit 3 and the journal is left as it was:

   ```sh
   sudo systemctl start smortress-agent-collect-finance.service
   sudo journalctl -u smortress-agent-collect-finance.service -n 20 --no-pager
   sudo less /var/lib/agent/local/index/hledger/finance.journal
   ```

   The journal follows the provider's sign: an amount appears exactly as
   SimpleFIN sent it, and the counter-account `expenses:unknown` carries its
   negation. An unchanged journal is not rewritten, so the mtime only moves when
   the generation's own bytes changed.

The collector writes into `state/agent-local`, so the raw replica is in the
personal recovery group and a Restic restore returns the transactions with the
deployment (`docs/core/restic-plane.md`). The journal is derived and rebuilt by
the next run, so a restore that skips it costs one run; `accounts.json` is the
one file under `state/agent-local/index` an operator wrote, and it restores with
the dataset.

### 40.15 Sign in to TutaBridge and store its password

Tuta serves no IMAP, so the mail side of the personal deployment needs a bridge:
`agent-tmail` talks to Tuta's API in process, decrypts in process and presents the
mailbox as local IMAP. It needs one thing this repository cannot invent: a Tuta
session, created interactively with the account password and a TOTP code.
Everything after that resumes that session unattended.

The bridge also generates its own local IMAP password, which is what the mail
collector authenticates with; the Tuta password is never stored here.

1. Start the bridge and sign in once. `init` asks for the address, the password
   and the code from the authenticator; nothing is echoed to the journal:

   ```sh
   sudo systemctl start agent-tmail.service
   sudo podman exec -it smortress-agent-tmail init
   ```

   `agent-tmail.service` is the Quadlet-generated unit name -- the file is
   `agent-tmail.container`, not the container name. The session lands in
   `/var/lib/agent/local/quarantine/tmail`, alongside the GPG key that unseals it
   and the TLS certificate a client verifies.

2. Prove the bridge is signed in, not merely running:

   ```sh
   sudo systemctl is-active agent-tmail.service
   sudo podman healthcheck run smortress-agent-tmail
   sudo podman exec smortress-agent-tmail tutabridge health
   ```

   `is-active` alone proves nothing: the container stays `active` while it waits
   for `init`, after a rejected session, and when Tuta refuses this client version.
   The health commands are the only ones that tell those states apart.

3. Read the bridge password it generated and put it where the deployment expects
   it. This is a secret: it goes into ciphertext, never into a unit file or a
   shell argument that a log would keep.

   ```sh
   sudo podman exec smortress-agent-tmail password
   sops secrets/server/tmail-bridge-password.yaml   # set tmail_bridge_password:
   git switch -c smores/tmail-bridge-password
   git add secrets/server/tmail-bridge-password.yaml
   git commit -m 'chore(agent): set the TutaBridge password'
   git push -u origin HEAD
   ```

   Merge that PR the usual way, wait for the `publish-server-image` run to finish,
   then upgrade:

   ```sh
   sudo bootc upgrade && sudo systemctl reboot
   ```

   The upgrade is what puts the new ciphertext on the host; running it before the
   publish run completes reinstalls the previous image and leaves the seeded random
   value in place. That seed is a loud failure once a collector tries to use it,
   but it is indistinguishable from "the operator has not claimed it yet", so do
   not skip the ordering.

4. Prove the collector. `smortress-agent-mail-stream.service` is long-running,
   not a timer: it publishes an initial generation, then holds one IDLE
   connection per folder. Start it and follow its journal:

   ```sh
   sudo systemctl start smortress-agent-mail-stream.service
   sudo journalctl -u smortress-agent-mail-stream.service -f
   ```

   Each published pass prints one JSON line. The first is the initial full pass;
   its `details.folders` must contain `INBOX` with a non-zero count, and `objects`
   must be at least the sum of the folder counts. The generation itself is the
   newest directory under the replica:

   ```sh
   sudo ls -1 /var/lib/agent/local/replica/mail/published | tail -n 1
   sudo journalctl -u smortress-agent-mail-stream.service -n 1 --no-pager
   ```

   Send a message to yourself from another account and watch the journal again: a
   second JSON line appears within a minute. That is the `INBOX` IDLE connection
   pushing `EXISTS`, followed by the publisher's 30-second quiet window. The
   second line's `generation_id` sorts after the first, and `objects` has grown by
   one; `deleted` stays `0` unless a message was expunged.

   A line reporting `uidvalidity changed` or `folders disappeared` is a refusal,
   not a collector bug: the service has exited, and the mailbox needs the restore
   rule below or a fresh sign-in before it can publish again.

#### Restoring the bridge's volume

The volume holds the session, the per-folder UID counters, the GPG key and the
password. The IMAP server always reports `UIDVALIDITY 1`, so a restore that
returns the replica but not the volume -- or an older copy of the volume -- gives
every message a new UID without changing the epoch. A collector reading that would
see "every message vanished, every message is new", which is a mass tombstone.

The volume and the replica both live in `state/agent-local`, so one Restic
snapshot holds them together: restore
`/var/lib/agent/local/quarantine/tmail` and `/var/lib/agent/local/replica/mail`
from the same snapshot, or neither. The snapshot is taken from a running
container, so treat one taken mid-write (the bridge's store is SQLCipher) as not a
valid restore point.

If the volume is genuinely lost, move the replica aside as well and let the
bridge resync from Tuta: the old generations stay as the history they are, and the
new ones start from a consistent epoch.

### 40.16 Sign in to the Tuta calendar exporter and run the dumper

Tuta serves no CalDAV, so the calendar's provider half is our own client:
`apps/tuta_calendar/`, shipped in `images/tuta-calendar/` and published by
`.github/workflows/publish-tuta-calendar.yml`. It needs one thing this
repository cannot invent -- a Tuta session, created interactively with the
account password and, on most accounts, a TOTP code -- and everything after that
resumes it unattended.

`smortress-agent-collect-calendar.service` runs the pair every two hours: the
exporter rewrites the entity directory, then the collector publishes it as a
generation. The image is pinned in `scripts/app-images.sh`; the session skips the
timed run until it exists, so the only step that cannot be automated is the
sign-in below.

1. The volumes already exist: `smortress-agent-config.service` creates
   `/var/lib/agent/local/quarantine/tuta-calendar` (0700, the sealed session) and
   `/var/lib/agent/local/quarantine/calendar` (0750, the dump) on the personal
   side of the agent dataset, next to the mail bridge's. Nothing to do unless a
   restore left them root-owned, in which case booting again re-applies the owner.

2. Sign in once. `init` asks for the address, the password and -- only if the
   account answers with a challenge -- one code from the authenticator. Nothing
   is echoed, no secret is accepted on the command line, and the password is
   never written: the session that lands on the volume is sealed with a
   passphrase-less GPG key the run generates there.

   ```sh
   image=$(bash -c 'source scripts/app-images.sh; app_image_ref tuta-calendar')
   sudo podman run --rm -it \
     -v /var/lib/agent/local/quarantine/tuta-calendar:/data:z \
     "$image" init --store /data
   ```

   It prints one line, `session for <address> sealed at /data/session.gpg`, and
   nothing else. Prove that what it wrote is a sealed session rather than a
   token in a file:

   ```sh
   sudo find /var/lib/agent/local/quarantine/tuta-calendar -maxdepth 1 \
     -printf '%u:%g %m %p\n'
   sudo grep -c accessToken /var/lib/agent/local/quarantine/tuta-calendar/session.gpg
   ```

   The seal must be `1000:1000 600`, the keyring directory `700`, and the grep
   must find nothing (a `grep: …: binary file matches` here means the seal is
   not encrypted; stop and treat the store as compromised). A refusal instead of
   a session -- `the session seal … could not be opened`, `the account's second
   factor is U2F or WebAuthn only`, `the verifier for this password was not
   accepted` -- is the run refusing to store something it could not prove, and
   re-running `init` is the whole remedy.

3. Dump the calendar into the directory the collector reads:

   ```sh
   sudo podman run --rm \
     -v /var/lib/agent/local/quarantine/tuta-calendar:/data:z \
     -v /var/lib/agent/local/quarantine/calendar:/out:z \
     "$image" dump --store /data --out /out
   ```

   It prints one JSON line -- `{"command": "dump", "objects": N, "removed": 0,
   "out": "/out"}` -- and exits `0`, or exits `3` with the reason on stderr and
   writes nothing. `objects` is the number of events; `removed` counts files left
   over from a previous run that this one did not rewrite, which is how an event
   deleted in the web UI stops being present.

4. Run the collector over it. The replica root is the same one the finance
   collector uses, on the same volume:

   ```sh
   cd /srv/git/github.com/smores56/homelab-platform/main
   sudo PYTHONPATH=libs python3 -m data_plane.collectors.raw \
     --root /var/lib/agent/local/replica/calendar calendar \
     --entities /var/lib/agent/local/quarantine/calendar
   ```

   The report's `objects` must equal the dump's count and `deleted` must be `0`:
   this source has no tombstone, so a missing event is carried forward as
   absent-unknown instead. Confirm one generation was published per run and that
   it is owned by uid 1000:

   ```sh
   sudo ls -1 /var/lib/agent/local/replica/calendar/published | wc -l
   sudo find /var/lib/agent/local/replica/calendar/published -maxdepth 1 \
     -user 1000 -printf '%u:%g %p\n'
   ```

   A second run must add exactly one generation, and only if something changed
   in `published`: a staging directory left behind means a run was interrupted
   mid-enumeration and is safe to remove, because nothing publishes from there.

5. Spot-check three events against the Tuta web calendar -- the point is the
   three shapes that map differently, not the count:

   ```sh
   # a plain timed event: an ISO instant on both ends
   sudo grep -l '"rrule": null' /var/lib/agent/local/quarantine/calendar/*.json | head -n 1
   # an all-day event: date-only values, which is what makes the ICS VALUE=DATE
   sudo grep -lE '"start": "[0-9]{4}-[0-9]{2}-[0-9]{2}"' \
     /var/lib/agent/local/quarantine/calendar/*.json | head -n 1
   # a series: an RRULE built from the repeat rule, and the raw rule beside it
   sudo grep -l '"rrule": "FREQ=' /var/lib/agent/local/quarantine/calendar/*.json | head -n 1
   ```

   Open each of those three files (`sudo cat`) and compare `summary`, `start`,
   `end` and, for the series, `rrule` and `recurrence` against the event in the
   web UI. An all-day event whose `start` carries a time is a bug in the
   midnight-UTC test, not in the collector: the collector writes `VALUE=DATE`
   exactly when the value is ten characters long.

6. Run it through the unit, then leave the timer to it:

   ```sh
   sudo systemctl start smortress-agent-collect-calendar.service
   sudo journalctl -u smortress-agent-collect-calendar.service -n 30 --no-pager
   sudo systemctl list-timers smortress-agent-collect-calendar.timer
   ```

   The collector stage prints one JSON line; `objects` must equal the dump's
   count and `deleted` must be `0`. The pass is *skipped*, not failed, while the
   seal is missing (`ConditionPathExists=`), so a start that leaves nothing in the
   journal means step 2 has not run. A red unit is a refusal: the journal names
   the reason and the replica is untouched.

7. Expect the version floor. Tuta raises the minimum client version it accepts,
   and everything else about this account stops working at once. Every refusal
   names the endpoint and never the token:

   - `HTTP 474 InvalidSoftwareVersionError` -- `CLIENT_VERSION` in
     `apps/tuta_calendar/api.py` is below the server's minimum. Read the current
     version from `https://app.tuta.com/index.js` (`versionNumber`), raise the
     constant, and run `publish-tuta-calendar` via `workflow_dispatch`; the new
     digest is what step 1 then names.
   - `HTTP 412` -- the model version moved. Raise `SYS_MODEL_VERSION` or
     `TUTANOTA_MODEL_VERSION` in the same file, rebuild the same way, and expect
     the field numbers in `apps/tuta_calendar/dump.py` to be the next thing to
     move.
   - `HTTP 401` or `403` -- the stored session was revoked or expired. Run step 2
     again; the replica is untouched.

   A dump that exits `3` publishes nothing, so a missed version bump shows up as
   an unchanged generation count rather than as a calendar that quietly emptied.

### 40.17 Export the Brave sync seed and run the browsing collector

The browsing collector's provider half is a real Brave running in the agent
dataset: one headless profile, joined to this account's Sync chain, whose
`History` the collector copies whenever it changes. Brave has no CLI to join a
chain and the join UI needs a human to type a 25-word code, so the membership is a
**seed**: the OSCrypt blob the desktop's own join wrote, planted into the profile's
`Preferences` before the browser starts. Everything after that resumes it
unattended.

The seed is the chain's key. Anything holding it can read and write the synced
history, so it lives in one ciphertext, reaches one unit as a Podman secret at uid
1000 mode 0400, and lands in a `0600` `Preferences` document. Nothing logs it.

1. Upgrade to an image that carries the browser. The publish run for
   `images/brave/Containerfile` already happened; its digest is pinned in
   `scripts/app-images.sh` and in `units/quadlet/agent-brave.container`, and both
   move together when the image is rebuilt:

   ```sh
   git log --oneline -1 -- scripts/app-images.sh
   sudo bootc upgrade && sudo systemctl reboot
   ```

   A pin that moves without the Quadlet names a digest the host never pulls, and
   the container fails before it starts; a Quadlet that moves without the row
   fails the check that every application image is in the table.

2. Export the seed from a desktop profile already in the chain, with Brave
   **closed**. Brave stores base64 of the raw blob (`v10` + IV + ciphertext) and
   the contract here is the `v10<base64>` form, so the export drops the `v10` the
   decoded blob starts with and the literal prefix restores it:

   ```sh
   prefs="$HOME/.config/BraveSoftware/Brave-Browser/Default/Preferences"
   seed="v10$(jq -r '.brave_sync_v2.seed' "$prefs" | base64 -d | tail -c +4 | base64 -w0)"
   printf '%s\n' "${#seed}"        # a real seed is hundreds of characters, never 0
   ```

   A profile that has never joined has no `brave_sync_v2.seed` and `jq` prints
   `null`: join Sync in that profile first, wait for the chain to deliver, then
   close it and export again. The blob is portable because both sides run with
   `--password-store=basic`, whose fixed "peanuts" key is what decrypts it; a seed
   from a keyring-backed profile would not decrypt and is not worth exporting.

3. Encrypt it and put it where the boot image reads it. `sops` takes the
   recipients from the creation rule for that path, so no `--age` list is needed:

   ```sh
   ( umask 077
     printf 'brave_sync_seed: %s\n' "$seed" >/tmp/brave-sync-seed.yaml
     sops --encrypt --input-type yaml --output-type yaml \
       --filename-override secrets/server/brave-sync-seed.yaml \
       /tmp/brave-sync-seed.yaml >secrets/server/brave-sync-seed.yaml
     rm -f /tmp/brave-sync-seed.yaml
     unset seed
   )
   head -1 secrets/server/brave-sync-seed.yaml   # must be `brave_sync_seed: ENC[`
   ```

   Commit that, merge, wait for the `publish-server-image` run to finish, then
   upgrade. The upgrade is what puts the new ciphertext on the host:

   ```sh
   sudo bootc upgrade && sudo systemctl reboot
   ```

4. Prove the seed planted. `smortress-agent-brave-seed.service` runs before the
   browser at every boot and is idempotent, so it replants a rotated seed and
   leaves the profile's other keys alone. Its journal names no value:

   ```sh
   sudo journalctl -u smortress-agent-brave-seed.service -n 5 --no-pager
   sudo stat -c '%u:%g %a %n' \
     /var/lib/agent/local/quarantine/brave-profile/Default/Preferences
   sudo jq -r '.brave_sync_v2.seed | (test("^v10"), length > 0)' \
     /var/lib/agent/local/quarantine/brave-profile/Default/Preferences
   sudo jq -r '.sync' \
     /var/lib/agent/local/quarantine/brave-profile/Default/Preferences
   ```

   The journal line is `{"event": "seed", "planted": true, …}` on the first boot
   and `{"event": "seed", "planted": false, "unchanged": true, …}` after it. The
   file is `1000:1000 600`. The first `jq` prints `false` then `true`: `false`
   because the stored form is base64 (it starts `djEw…`, not `v10`), `true`
   because it is not empty. The second prints `requested`, `keep_everything_synced`
   and `has_setup_completed`, all `true` -- a profile with the seed but without
   those three registers on the chain and downloads nothing.

   A `{"event": "refused", …}` line instead means the seeder wrote nothing: the
   secret still carries the shipped placeholder, the value is not a `v10` blob, or
   `sops-decrypt` did not produce the file. Fix it with step 3 and reboot, not with
   a restart of the unit.

   Prove the value never reached a journal, without printing it:

   ```sh
   seed=$(sops -d secrets/server/brave-sync-seed.yaml | awk '{print $2}')
   sudo journalctl -u smortress-agent-brave-seed.service \
     -u smortress-agent-collect-brave.service --since '-1 day' | grep -cF "$seed"
   unset seed
   ```

   It must print `0`.

5. Prove the browser runs and that the proxy is what it talks to:

   ```sh
   sudo systemctl is-active agent-brave.service
   sudo podman logs --tail 40 smortress-agent-brave
   sudo journalctl -u agent-egress-proxy.service --since '-30 min' --no-pager | tail -40
   sudo journalctl -u agent-egress-dns.service --since '-30 min' --no-pager | tail -20
   ```

   `agent-brave.service` is the Quadlet-generated name for
   `agent-brave.container`, not the container name. `is-active` alone proves
   little: the browser stays up with a seed it cannot decrypt. The proxy's journal
   is the evidence that matters -- it names `sync-v2.brave.com:443` among the
   CONNECT requests it tunnelled and nothing else, because
   `image/rootfs/etc/smortress/agent/egress-policy.json` grants the `brave` label
   exactly that hostname. The resolver's journal shows the same shape from the
   other side: answers for that name, `refused` for every other name Chromium
   tries (`accounts.google.com`, `clients2.google.com` and the component updater
   among them).

   A `sync-v2.brave.com` CONNECT that is refused, or no CONNECT at all, is the
   failure to read carefully: refused means the policy and the image disagree
   (rebuild both), and none means the browser never started its sync engine (a
   seed that did not plant, or `sync.requested` missing -- see step 4).

6. Prove a visit reaches the replica. With the profile joined, a visit made
   anywhere in the chain arrives here as a change to `History`:

   ```sh
   sudo journalctl -u smortress-agent-collect-brave.service -f
   ```

   Browse to a site on a phone in the same chain, wait for the chain to deliver it
   (a minute or two), and watch two JSON lines appear: the snapshot's
   (`{"event": "snapshot", "out": "/quarantine/History", "urls": N, …}`) and the
   collector's report (`{"source_id": "brave.history", "objects": …, "deleted": 0,
   "published": "…"}`). Then read the visit out of the generation it published:

   ```sh
   gen=$(sudo ls -1 /var/lib/agent/local/replica/brave/published | tail -n 1)
   sudo jq -r '.rows[] | "\(.[1]) \(.[2])"' \
     "/var/lib/agent/local/replica/brave/published/$gen/objects/brave%3A%3Atable%3A%3Aurls"
   ```

   The URL you visited is in that list, with its title. `deleted` is always `0`:
   retention expiry, a deletion in the browser and a recreated profile all look
   the same from here, so a table that stops appearing is carried forward with an
   absence reason instead of being tombstoned (`docs/raw-replicas.md`, "Brave").

   No pass at all means the watcher saw nothing: `smortress-agent-collect-brave.path`
   watches `Default/History` and its sidecars, and the six-hourly timer
   (`…-brave.timer`, `Persistent=true`) is the reconcile. A red unit is a refusal
   -- a database that failed `integrity_check`, a replica that could not be written
   -- and the journal names the reason.

7. Rotate or remove the seed.

   **Rotate** (a new chain, or a seed you believe leaked): replace the value with
   step 3, merge, wait for `publish-server-image`, `sudo bootc upgrade`, and
   reboot. The seeder replants at every boot, so the new blob is in `Preferences`
   before the browser reads it. Note what a rotation costs: a different seed is a
   different chain, so the profile starts a fresh `History` and the previous
   generations stay in the replica as the history they are.

   **Remove this host from the chain**, which is the real revocation: on a desktop
   in Brave's Sync settings, remove the `smortress` device. The seed on this host
   keeps working for a cached profile and stops delivering anything new.

   **Remove the seed from this host**: stop the browser, delete the profile, and
   replace the ciphertext value with a random 32-byte hex placeholder so the
   seeder refuses it (a value that is not a `v10` blob is refused, which is why the
   shipped placeholder is that shape):

   ```sh
   sudo systemctl stop agent-brave.service
   sudo rm -rf /var/lib/agent/local/quarantine/brave-profile
   ( umask 077
     printf 'brave_sync_seed: %s\n' "$(openssl rand -hex 32)" >/tmp/brave-sync-seed.yaml
     sops --encrypt --input-type yaml --output-type yaml \
       --filename-override secrets/server/brave-sync-seed.yaml \
       /tmp/brave-sync-seed.yaml >secrets/server/brave-sync-seed.yaml
     rm -f /tmp/brave-sync-seed.yaml
   )
   ```

   `smortress-agent-config.service` recreates the profile directory (0700) at the
   next boot, so the browser starts unseeded rather than not at all: it runs, it
   collects nothing, and the seeder's refusal is the journal line that says why.

## 41. Delete the Cloudflare SSH route (design #767, T6)

SSH is tailnet-only, so the Cloudflare route is deleted and not replaced. The
repository no longer carries any of it: `smortress-cloudflared.service`, the
`CLOUDFLARED_*` pins and build steps, `secrets/server/cloudflared-tunnel.yaml`
and its manifest line, `tofu/ssh_tunnel.tf`, and the `ssh` Access application,
its `service_auth_ssh` policy and the dedicated service token. This section is
the operator's removal, and it runs last — only once the tailnet route is proven
in sections 42, 43 and 45.

`tofu/` owned the edge objects, so the apply is what deletes them:
`cloudflare_dns_record.ssh` (the specific `ssh.sammohr.dev` CNAME),
`cloudflare_zero_trust_tunnel_cloudflared_config.ssh` (the tunnel's ingress),
`cloudflare_zero_trust_access_application.ssh`,
`cloudflare_zero_trust_access_policy.service_auth_ssh` and
`cloudflare_zero_trust_access_service_token.ssh`. Their `prevent_destroy`
lifecycle blocks were deleted with the resources, so this is a plain destroy: no
`tofu state rm` first, and a plan that offers to keep them is a stale checkout.

1. Plan against the real state and read it:

   ```sh
   ./scripts/tofu-cloudflare.sh plan -no-color
   # expect: 5 to destroy, 0 to add, 0 to change — the ssh record, the ssh tunnel
   # config, the ssh application, the ssh token policy, the ssh service token.
   # A replace or a destroy anywhere else means the state and the config
   # disagree: stop and compare instead of applying.
   ```

2. Apply it as an owner dispatch. `tofu-apply.yml` refuses a destructive plan
   unattended, which is why the merge alone changes nothing:

   ```sh
   gh workflow run tofu-apply.yml
   ```

   The token is revoked at the edge by the same apply, so the laptops' pair is
   dead from then on.

3. Delete the tunnel object by hand. It was created in the dashboard (Zero
   Trust → Networks → Tunnels → `smortress-ssh`) and this repository never owned
   it: `ssh_tunnel_id` only named its UUID, which the DNS record and the ingress
   pointed at, so there is no state entry for the tunnel itself and nothing can
   delete it for you. With the ingress gone it has no rules and no connector;
   remove it in Zero Trust → Networks → Tunnels. Its connector token goes with
   it; the host's ciphertext leaves with the next deployment (section 37 step
   15), and until then it decrypts into `/run` for a unit that no longer exists.

4. Prove the route is gone:

   ```sh
   ./scripts/tofu-cloudflare.sh state list | grep ssh || echo "no ssh objects in state"
   # expect: no ssh objects in state
   ```

   In Zero Trust → Access → Applications the list must hold `wildcard
   default-deny`, `memory`, `agent`, `backrest`, `kanbei` and the public set, and
   no `ssh`. From a device **not** on the tailnet, a request to
   `ssh.sammohr.dev` now hits the wildcard deny or the host tunnel's catch-all
   and never an sshd.

From #767's T1 on, the tailnet is the only route in; what this section removes
was the rollback.

## 42. Tailnet-only sshd on smortress

`image/rootfs/etc/ssh/sshd_config.d/05-tailnet-ssh.conf` is the only sshd
drop-in. It carries no `ListenAddress`, so sshd listens on every local address,
and it points `AuthorizedKeysFile` at `/etc/ssh/authorized_keys.d/smores`, the one
`ssh-ed25519` line shipped in the image. The network half of the login is
firewalld: the default zone is `drop`, only `tailscale0` sits in the `tailscale`
zone, and that zone accepts `ssh` plus Syncthing's 22000/tcp+udp (design #767).

Nothing binds the tailnet address: it is per node and unknown at build time, so
the interface is the gate. The loopback `Match` block at the end of the drop-in
stays for a different reason. uCore ships `90-enable-localhost-passwords.conf`,
which sets `PasswordAuthentication yes` for `Match Address 127.0.0.1,::1` so
Cockpit's web login can use the core password. sshd parses its configuration
twice; the second pass re-reads only the matching `Match` blocks and keeps the
first value it obtains, so the *earlier file* wins. Our file sorts at `05-` for
that reason; a drop-in sorting after `90-` is silently ignored.

**The order of these steps is a lockout guard.** The key and the drop-in ship in
the same image, so the reboot in step 1 cannot strand you for want of a key line —
but the *route* has to exist first. A laptop reaches port 22 through the tailnet
(section 45), and only through it: the Cloudflare tunnel that used to be the
rollback is deleted (section 41). Firewalld admits `ssh` on `tailscale0` alone, so
a LAN address never gets in, and a host whose tailnet policy does not admit the
laptop is reachable only from the console.

1. Deploy the image (section 37 step 15) and reboot. The deployment reference is
   a digest, so `bootc upgrade` re-checks the build already running and moves
   nothing: switch to the digest the publish produced, or take `bootc upgrade`
   instead on a host following `:latest`.

   ```sh
   sudo bootc switch --enforce-container-sigpolicy \
     "ghcr.io/smores56/homelab-platform/server@sha256:<digest from the run summary>"
   sudo systemctl reboot
   # on a host following :latest, from then on:
   #   sudo bootc upgrade && sudo systemctl reboot
   ```

2. Prove the listener. One wildcard socket per family, no address-specific one:
   sshd has no `ListenAddress` on purpose, and a line naming one address would be
   wrong the moment the node's tailnet address changed.

   ```sh
   sudo ss -ltnp '( sport = :22 )'
   # expect: one wildcard IPv4 socket and one wildcard IPv6 socket, both from
   # sshd; a 127.0.0.1 row would mean a ListenAddress came back
   grep -rn ListenAddress /etc/ssh/sshd_config /etc/ssh/sshd_config.d/
   # expect: no output — the shipped drop-in sets none
   ```

3. Prove the firewall, not the listener, is the gate:

   ```sh
   sudo firewall-cmd --get-default-zone               # expect: drop
   sudo firewall-cmd --zone=tailscale --list-all       # expect: ssh, 22000/tcp+udp, interface tailscale0
   sudo firewall-cmd --zone=drop --list-all            # expect: no services and no ports
   ```

   From a machine that is **not** on the tailnet, `nc -vz smortress 22` must hang
   and then time out. A `Connection refused` there means sshd is not listening at
   all, so step 2 failed rather than the firewall working.

4. Prove the password decision survived uCore's file. Both greps are
   case-insensitive on purpose: OpenSSH 10 prints CamelCase directive names, so a
   lowercase pattern matches nothing and "no output" then reads as success.

   ```sh
   sudo sshd -T -C addr=127.0.0.1,user=smores | \
     grep -iE '^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin|allowusers|authorizedkeysfile|pubkeyauthoptions|permituserrc|maxauthtries|logingracetime|allowtcpforwarding|allowstreamlocalforwarding|allowagentforwarding) '
   sudo sshd -T -C addr=100.64.0.1,user=smores | grep -iE '^passwordauthentication '
   ```

   Compare the output against this table line by line. A line that is missing is a
   failure, not a quiet pass:

   | directive | expected |
   | --- | --- |
   | `PasswordAuthentication` | `no`, in both queries |
   | `KbdInteractiveAuthentication` | `no` |
   | `PermitRootLogin` | `no` |
   | `AllowUsers` | `smores` |
   | `AuthorizedKeysFile` | `/etc/ssh/authorized_keys.d/smores` |
   | `PubkeyAuthOptions` | `none` — a per-key option in `authorized_keys` decides, never the daemon |
   | `PermitUserRC` | `no` |
   | `MaxAuthTries` | `10` |
   | `LoginGraceTime` | `60` |
   | `AllowTcpForwarding` | `no` |
   | `AllowStreamLocalForwarding` | `no` |
   | `AllowAgentForwarding` | `yes` |

   `PasswordAuthentication yes` in the loopback query means the drop-in is sorting
   after `90-` or was not shipped; check `ls /etc/ssh/sshd_config.d/` on the host
   before going further.

   `AllowAgentForwarding no` is the failure that costs the most, because it is
   silent until section 44: sshd creates `~/.ssh/agent` and exports
   `SSH_AUTH_SOCK` only for a session that forwarded an agent, so without this
   line the sudo tap degrades to the password on every escalation.
   `AllowStreamLocalForwarding no` does not cover it — agent forwarding is its
   own directive.

5. Prove the key file. Root-owned, world-readable, labelled `etc_t`: sshd opens it
   as root, so nothing about ownership or SELinux has to be fixed by hand — which
   is the whole reason this path replaced `/var/lib/homelab/.ssh`:

   ```sh
   ls -lZ /etc/ssh/authorized_keys.d/smores
   # expect: -rw-r--r--. 1 root root ... system_u:object_r:etc_t:s0
   ssh-keygen -lf /etc/ssh/authorized_keys.d/smores
   # expect: one 256-bit ED25519 line
   ```

6. Prove the doors, from a laptop on the tailnet with the key in place:

   ```sh
   ssh smortress true          # expect: success, with no password prompt
   ```

   `Permission denied (publickey)` means the laptop is not offering the shipped
   key. A timeout means the tailnet policy (section 45) or the firewall is
   refusing the address; `tailscale ping smortress` says which.

## 43. Retire Tailscale SSH on smortress

`smortress-tailscale-up.service` no longer passes `--ssh`, and
`smortress-tailscale-ssh-off.service` runs `tailscale set --ssh=false` on every
boot. The second unit exists because tailscaled persists the preference in its
state file: removing the flag fixes only the first enrollment, and a preference
restored with the state — or a hand-run `tailscale up --ssh` — turns it back
on. Nothing changes in firewalld: sshd listens on every address now (section 42),
so this preference is what stops tailscaled from intercepting port 22 on the
tailnet, and the `tailscale` zone already accepts `ssh` for OpenSSH.

1. Do nothing here before section 42 is done and the tailnet route works
   (section 45). This section removes Tailscale SSH from the picture, and a host
   with no other route is reachable only from the console.

2. Deploy the image (section 37 step 15) and reboot. The deployment reference is
   a digest, so `bootc upgrade` re-checks the build already running and moves
   nothing: switch to the digest the publish produced, or take `bootc upgrade`
   instead on a host following `:latest`.

   ```sh
   sudo bootc switch --enforce-container-sigpolicy \
     "ghcr.io/smores56/homelab-platform/server@sha256:<digest from the run summary>"
   sudo systemctl reboot
   # on a host following :latest, from then on:
   #   sudo bootc upgrade && sudo systemctl reboot
   ```

3. Prove the preference and the unit:

   ```sh
   sudo systemctl status smortress-tailscale-ssh-off.service
   tailscale debug prefs | jq -r .RunSSH    # expect: false
   ```

   `true` here means the unit did not run: check that
   `/var/lib/tailscale/tailscaled.state` exists and that the unit is enabled
   (`systemctl is-enabled smortress-tailscale-ssh-off.service`).

4. Prove port 22 is OpenSSH and not tailscaled, from a tailnet device such as a
   laptop:

   ```sh
   ssh -v -o BatchMode=yes -o ConnectTimeout=5 smortress true 2>&1 |
     grep -m1 -i 'remote software version'
   # expect: remote software version OpenSSH_... — Tailscale SSH would answer
   # with its own banner, and a tailnet identity instead of a key
   tailscale status | grep smortress        # expect: still up, so Serve is unaffected
   ```

5. Clearing it by hand is the same one-liner, and the next boot repeats it:

   ```sh
   sudo tailscale set --ssh=false
   ```

## 44. sudo on smortress: a touch on a forwarded agent, password fallback

sudo on smortress answers one tap. `ssh -A smortress` forwards the client's
agent, and the agent holds a **touch-required** `sk-ssh-ed25519` resident
credential, so `/etc/pam.d/sudo` asks the key in the laptop for a signature and
the tap happens there. The account password sits directly behind it as the
fallback, so an absent, unplugged or unmapped key costs typing rather than
access. The token is convenience by construction, not a gate: an agent running
as `smores` does not hold the account password, and that is the whole of what
the split buys (design #767, T8).

What the image carries, and nothing else:

- `image/rootfs/etc/pam.d/sudo` — `pam_faillock` preauth, `libpam_rssh.so`
  against `/etc/ssh/sudo_authorized_keys` with `cue`, `pam_unix` as the
  fallback, then `authfail` and `authsucc`;
- `image/rootfs/etc/ssh/sudo_authorized_keys` — the sudo credentials' public
  halves, root `0600`, separate from the login key file;
- `image/Containerfile` — the `sudo-build` stage that builds `pam_rssh` at the
  tag and commit pinned in `image/pins.env`; no distribution package is layered
  and no local SELinux policy ships;
- `image/rootfs/etc/sudoers.d/10-human-gate` — `timestamp_timeout=30`,
  `timestamp_type=tty`, `log_subcmds`, and `Defaults env_keep +=
  "SSH_AUTH_SOCK"`; without the last one sudo drops the forwarded socket path
  before the PAM stack runs, `pam_rssh` logs "SSH agent socket address not
  configured", and every escalation falls back to the password.

There is no host-local secret any more. The retired TOTP stack needed a
root-owned usersfile under `/var/lib/homelab/sudo`, written by
`scripts/enroll-yubikey-totp.sh` over a fifo held by a console root shell; that
script, the fifo procedure and the usersfile are gone, and nothing in this stack
has to be enrolled before sudo works. The directory and its usersfile under
`/var/lib/homelab/sudo` are dead weight on an upgraded host and can be deleted.

### One credential per YubiKey, and it is the sudo one

The login key is not a token credential. `/etc/ssh/authorized_keys.d/smores`
ships one plain `ssh-ed25519` key from dotfiles' sops (`SMORTRESS_SSH_KEY`), so
`ssh smortress` is touch-free with no resident credential at all, and the image
check refuses an `sk-` handle in that file. The only thing on a YubiKey is the
**sudo** credential: minted with the default touch option and resident, its
public half committed to `/etc/ssh/sudo_authorized_keys`.

That is why the two files cannot satisfy each other: the login key is a
different key type in a different file, and `libpam_rssh` reads only the sudo
one. A key carrying no sudo credential still logs in and cannot sudo, so the
spare must be enrolled too.

1. Mint the sudo credential on each key, one key attached at a time. The private
   half never leaves the token: the `-f` file is a handle, and nothing is
   written to the laptop's disk that matters. The comment is what makes the
   public line identifiable in step 2.

   ```sh
   ssh-keygen -t ed25519-sk -O resident -C "smores-sudo-key1" \
     -f ~/.ssh/id_smortress_sudo_1
   # touch the key when it blinks
   ```

   One file per key, because each resident credential is its own handle and
   `ssh-keygen` refuses to overwrite an existing `-f` path: the second key needs
   `id_smortress_sudo_2`, the spare `_3`. The suffix matches the `-C`
   (`smores-sudo-key1`, `-key2`, `-key3`), which is what makes the committed
   public line identifiable later, and every client's loader adds each
   `~/.ssh/id_smortress_sudo*` file, so a handle minted here needs no renaming —
   only one fetched back with `-K` does, below. Write the serial that `ykman
   info` prints next to the physical label: that is the only record that makes
   "which key is this" answerable once three of them are in a drawer.

   `-O resident` is what lets the credential live on the key rather than in the
   handle file, so a replacement laptop fetches it back rather than minting a
   second one:

   ```sh
   cd ~/.ssh && ssh-keygen -K
   ```

   `-K` does not load the agent, and it does not know this procedure's names: it
   writes each resident credential it finds as an `id_ed25519_sk*` handle with its
   `.pub` beside it, and nothing on the client reads that shape. Rename every
   downloaded handle **and its `.pub`** to `~/.ssh/id_smortress_sudo_<n>` before
   adding it, using the number that matches the credential's `-C` label (`_1` is
   `smores-sudo-key1`):

   ```sh
   cd ~/.ssh
   ls id_ed25519_sk*                    # one handle plus .pub per key
   mv id_ed25519_sk     id_smortress_sudo_1
   mv id_ed25519_sk.pub id_smortress_sudo_1.pub
   ssh-add ~/.ssh/id_smortress_sudo_*   # what actually loads the agent
   ```

   The names are load-bearing twice. dotfiles' `scripts/add-sudo-credential.sh`
   — and the reboot step in its README — adds every `~/.ssh/id_smortress_sudo*`
   handle and nothing else, so a handle left under a `-K` name is never loaded:
   after the next reboot the agent is empty, `libpam_rssh` finds no key, and the
   tap degrades to the password silently. The suffix is also what ties the
   committed public line in step 2 to the physical key. Skip `ssh-add` and sudo
   has nothing to ask for a signature. Do **not** add `-O no-touch-required`:
   that option is the whole difference between the two credentials.

2. Commit the public halves, one `sk-ssh-ed25519` line per key, and
   nothing else. The file is empty in the repository until the first enrollment,
   and an empty file is a `PAM_AUTH_ERR` — the password is the way in until the
   lines land.

   ```sh
   cat ~/.ssh/id_smortress_sudo_*.pub >>    image/rootfs/etc/ssh/sudo_authorized_keys
   scripts/check-server-image.sh     # refuses anything but sk lines, no no-touch-required
   ```

   This is the only edit in this procedure that is a commit: the credentials'
   public halves are declarative, so a spare key is admitted by `bootc upgrade`
   and revoked by deleting its line.

3. Deploy the image (section 37 step 15) and reboot. The deployment reference is
   a digest, so `bootc upgrade` re-checks the build already running and moves
   nothing: switch to the digest the publish produced, or take `bootc upgrade`
   instead on a host following `:latest`.

   ```sh
   sudo bootc switch --enforce-container-sigpolicy \
     "ghcr.io/smores56/homelab-platform/server@sha256:<digest from the run summary>"
   sudo systemctl reboot
   # on a host following :latest, from then on:
   #   sudo bootc upgrade && sudo systemctl reboot
   ```

   `sudo_authorized_keys` is image content under `/etc`, so it arrives with the
   deployment; nothing loads, labels or enables it. The one way it does *not*
   arrive is a hand edit: bootc's `/etc` merge keeps a locally modified file, so
   a host can boot an upgraded image and still read the older set of lines.
   Compare the deployment's copy and re-apply it when the two differ:

   ```sh
   sudo diff /usr/etc/ssh/sudo_authorized_keys /etc/ssh/sudo_authorized_keys
   ```

4. Prove the tap, then prove the fallback. `sudo -k` clears the per-TTY ticket
   the previous attempt left behind, and `-A` is what forwards the agent:

   ```sh
   ssh -A -t smortress 'sudo -k; sudo true'
   # expect: "Please touch the device.", one tap, no password
   ssh -t smortress 'sudo -k; sudo true'
   # expect: no tap, the account password, success
   ssh -A -t smortress 'sudo -k; sudo true'   # with the key unplugged
   # expect: no tap, the account password, success
   ```

   The second and third commands are the fallback, and it is a property of the
   return codes rather than of arithmetic kept by hand: `pam_rssh` returns
   `PAM_AUTHINFO_UNAVAIL` with no `SSH_AUTH_SOCK`, `PAM_CRED_INSUFFICIENT` for a
   key file that is missing or unreadable, and `PAM_AUTH_ERR` for a dead socket,
   a key the agent does not hold, a refused touch, or an *empty* key file (which
   parses to no entries, so no key matches), and never `PAM_IGNORE`, so every
   non-success is ignored onto `pam_unix`.

   None of those three proves the credential is touch-required: the public half
   records no touch policy, and `pam_rssh` never reads the user-presence bit, so
   no file says whether the credential needs a tap. Covering the sensor is the
   only proof, with the key plugged in and the agent holding the handle:

   ```sh
   ssh -A -t smortress 'sudo -k; sudo true'   # cover the sensor; do not touch
   # expect: no signature, the account password, success
   ```

   A touch-required credential cannot answer without the tap, so the failure is
   logged and ignored onto `pam_unix`; one minted with `-O no-touch-required`
   signs anyway and the command succeeds silently, which is the failure this
   drill exists to catch.

   `default=ignore` is what swallows all of them by design, so a stack mistake
   here never fails loudly: it degrades to the password. The evidence is in the
   module's syslog output, logged under `sudo`'s own name (the module never sets
   its ident) and only at warn and above, which is why a config error is visible
   only here:

   The message names which of the three shapes you hit, and each one is a
   different repair, so read it before touching the stack:

   | log line | meaning |
   |---|---|
   | `SSH agent socket address not configured` | no `SSH_AUTH_SOCK` in sudo's environment: the session forwarded no agent (`ssh -A` with no agent running does this), or `env_keep` is missing |
   | `Broken pipe (os error 32)` | the variable is set and the socket is dead: a multiplexed session, or an agent that exited |
   | `Failed to authenticate key N: SSH-Agent reports failure` then `None of these keys passed authentication` | the socket is live and the token is absent, or the touch was refused; one `cue` per credential tried |
   | `None of these keys passed authentication` with **no** per-key lines | the socket is live and the agent holds no credentials: a client whose agent started empty after a reboot, or one where `ssh-add` never ran |

   A working tap logs nothing here, because the module reports success below its
   default warn level.

   ```sh
   sudo journalctl -t sudo -g 'SSH agent|authorized_keys|keys passed' -n 20 --no-pager
   # expect: no output after a working tap — success is logged at info, below the
   # module's default warn level; anything printed here explains the password
   # prompt
   ```

   The login key and the sudo credential are not interchangeable. The login key
   is not in `sudo_authorized_keys`, and the sudo credential is not an
   `ssh-ed25519` line in `authorized_keys.d/smores`, which is what the
   separation of the two files buys:

   ```sh
   ssh -A -t smortress 'sudo -k; sudo true'      # agent forwarded, sudo credential loaded
   # expect: the touch credential signs
   ssh -o IdentitiesOnly=yes -i ~/.ssh/id_smortress_sudo_1 smortress true
   # expect: refused, no matching key in authorized_keys.d/smores
   ```

   `IdentitiesOnly=yes` is not decoration: without it the agent also offers the
   login credential, sshd accepts that one, and the "expect refused" line passes
   with the sudo credential never consulted.

5. Prove the 30-minute per-TTY ticket and the tally. A second sudo in the same
   TTY inside the window is silent; a new ssh session is a new TTY and prompts
   again. A tap clears the faillock tally, and five refusals lock the account for
   300 seconds — the password included, because `pam_faillock preauth` is the
   first row on every path:

   ```sh
   ssh -A -t smortress 'sudo -k; sudo true; sudo true'   # one tap, one prompt
   ssh -A -t smortress 'sudo -k; sudo true'              # new tty, prompts again
   for _ in 1 2 3 4 5; do ssh -t smortress 'sudo -k; sudo -S true < /dev/null'; done
   ssh -A -t smortress 'sudo -k; sudo true'
   # expect: every factor refused for 300 seconds. `preauth` is `required`, not
   # `die`, so dispatch continues and the cue or the password prompt may still
   # appear -- the refusal lands at the end, on the aggregate impression. The
   # point is that a correct tap and the correct password both fail while the
   # tally stands, and then a tap works again after --reset.
   ```

   Read the tally from a root shell opened before the lockout, or wait it out:

   ```sh
   faillock --user smores
   faillock --user smores --reset
   ```

   The physical console is **not** a way around the tally. Fedora's `login`
   pulls in `system-auth`, the same file that carries `pam_faillock preauth`, and
   the tally is per user in `/var/run/faillock` rather than per service, so a
   console login is refused too until it ages out. It ages out slower there than
   it does for sudo: stock `login` runs `deny=3 unlock_time=600`, so the console
   may be the last way back. What the console gives you is the same break-glass
   as ssh — the account password, in sudo's own stack — not a bypass.

6. Run the AVC drill after every image change that touches this stack, and log
   the socket path it prints.

   On this base **sudo runs unconfined**: `/usr/bin/sudo` carries `sudo_exec_t`,
   but the process stays `unconfined_t` (`ps -eo label,comm | grep sudo`), there
   is no `sudo_t` type to write a rule for (`semodule -i` rejects it), and an
   unconfined domain already holds every permission the forwarded socket needs.
   So no local policy ships, and the earlier `smortress_sudo_rssh` module is
   gone: it could not have loaded, and it failed at every boot.

   ```sh
   ssh -A -t smortress 'echo "$SSH_AUTH_SOCK"; ls -ld ~/.ssh/agent'
   ssh -A -t smortress 'sudo -k; sudo true'      # tap
   sudo ausearch -m avc -c sudo                  # from a root shell, right after
   ```

   An empty `ausearch` after a working tap means nothing is denied. A live
   `denied { connectto }` for `ssh_home_t` means a future base confines sudo: the
   denial's `scontext` names the domain to write the rule for — it will not be
   `sudo_t` unless the exec transition returns — and the rule is one CIL line
   shipped under `image/rootfs/`, plus a loader unit, because the policy store in
   `/etc` and `/var` is not reconciled by bootc.

7. Rotation and revocation are edits to the public half, not to a host secret.
   A lost key is removed by deleting its line from
   `image/rootfs/etc/ssh/sudo_authorized_keys` and deploying; sudo then falls back
   to the password for that key's owner, and the other keys keep working. Re-mint
   a credential with step 1, which leaves the old one on the token until it is
   deleted there (`ykman fido credentials list`, then `delete`).

8. Residuals the design accepts:

- the forwarded socket is owned by `smores` and usable by any process running as
  `smores` on the server, and by root. A same-uid process can hold a signature
  request open and wait for the blink; `ForwardAgent` scoped to `Host smortress`
  and destination-constrained keys reduce that surface without closing it;
- an agent sharing your TTY inherits the sudoers ticket for up to 30 minutes.
  `log_subcmds` records what ran:

  ```sh
  sudo journalctl -g 'COMMAND=' -n 20 --no-pager
  ```

- a wrong local policy fails closed — sudo prompts for the password — but logs
  an AVC on every escalation, which is what step 6 exists to catch;
- `pam_rssh` has no upstream SIGINT handling, and the `sudo-build` stage compiles
  it unpatched: Ctrl-C during a touch wait leaves the signature request pending
  on the client until it times out, rather than withdrawing it. It affects the
  client's agent, not the server;
- the work Mac's OpenSSH holds no `sk` handle without a FIDO provider, so its
  shells export `SSH_SK_PROVIDER=/usr/lib/ssh-keychain.dylib` and the bootstrap
  adds every `~/.ssh/id_smortress_sudo*` handle to the agent. Until that has run
  once after a reboot the Mac takes the password, which is the fallback working
  as designed rather than a fault.

## 45. Tailnet policy and enrollment key (design #767, T1)

`tofu/tailscale.tf` owns the tailnet policy: one `tailscale_acl` resource, gated on
`var.tailnet`, that admits `group:owner` to `smortress` on 22, on Serve's
443/8443/10000 and on Syncthing's 22000, and admits nothing else. Tailscale
accepts only what a rule accepts, so the default is deny without a rule saying
so.

`smortress` is named by its tag, `tag:smortress`. The provider does both halves —
`data.tailscale_device` resolves the node by hostname, `tailscale_device_tags`
gives it the tag — and the ACL resource depends on the tag resource, so an apply
can never name a tag no device carries. Device tagging needs the CI client's
`devices:core` scope; a `policy_file`-only client can rewrite the policy but not
the tag.

The group member is `var.tailscale_login`, the tailnet's own `user@provider`
(here `smores56@github`), **not** the Access `var.email`: Tailscale accepts a
group member it does not know without error and then admits nobody, which is
exactly how the first apply cut every laptop out of the tailnet. The same login
appears in the policy's `tests`, which the API evaluates on every save: a rule
that widens access fails the plan instead of reaching the tailnet. The provider
reads its OAuth client from `TAILSCALE_OAUTH_CLIENT_ID` and
`TAILSCALE_OAUTH_CLIENT_SECRET`, and no credential is committed.

The policy is the only network half: Tailnet Lock is deliberately **not** used.
The owner disabled it rather than maintain a signing-key set, so nothing decides
which nodes may join beyond the account the auth key belongs to. What still holds
is the ACL below (only `group:owner` reaches the listed ports), key-only sshd with
one ed25519 key from dotfiles' sops, and firewalld's default `drop`. The residual
is explicit: anyone who can enroll a device into the owner's Tailscale account
reaches smortress:22 and needs the key, and only the key. Turning on **device
approval** in the admin console is the TKA-free control against that, and it is
compatible with everything here.

Nothing here is planned while `tailnet` is empty. The provider does refuse to
configure without credentials even then, so the zone's plan and apply need the
OAuth client exported too (step 3) — do that before the merge that names the
tailnet.

1. Mint the host's enrollment key. Admin console → Settings → Keys → **Generate
   auth key**, with **Reusable** off (the node enrolls once). If device approval
   is on, tick **Pre-approved** too. Encrypt it to
   the host identity, the only identity that reads image ciphertext:

   ```sh
   ( umask 077
     printf 'authkey: %s\n' 'tskey-auth-...' >/tmp/tailscale.yaml
     sops --encrypt --input-type yaml --output-type yaml \
       --filename-override secrets/server/tailscale.yaml \
       /tmp/tailscale.yaml >secrets/server/tailscale.yaml
     rm -f /tmp/tailscale.yaml
   )
   ```

   `smortress-tailscale-up.service` reads `authkey:` out of the decrypted file and
   skips enrollment when the ciphertext is absent, so this file and its manifest
   line (`tailscale.yaml`, which this task adds) have to land together, and the
   ciphertext lands before the image that lists it: `scripts/sops-decrypt.sh` fails
   closed on a manifest entry without its ciphertext.

2. Mint the OAuth client that may write the policy. Admin console → Settings →
   OAuth clients → **New client**, scope **policy_file** and nothing else.
   Encrypt it to the admin identity only: it can rewrite the whole tailnet, so no
   host and no cluster identity may read it.

   ```sh
   ( umask 077
     printf 'client_id: %s\nclient_secret: %s\n' '<id>' '<secret>' >/tmp/tailscale-oauth.yaml
     sops --encrypt --input-type yaml --output-type yaml \
       --filename-override secrets/tailscale.yaml \
       /tmp/tailscale-oauth.yaml >secrets/tailscale.yaml
     rm -f /tmp/tailscale-oauth.yaml
   )
   ```

   This admin-only file is one of the two places the client lives. The other is
   the two GitHub environments below, and both hold the same client: rotate one
   without the other and a plan or an apply fails at provider configuration.

3. Wire the client into CI. The two environment secrets are named after the
   variables the provider reads, so nothing else has to map them:
   `TAILSCALE_OAUTH_CLIENT_ID` and `TAILSCALE_OAUTH_CLIENT_SECRET`, in **both**
   the `cloudflare` environment (apply) and the `cloudflare-plan` environment
   (pre-merge plan and drift), holding the same client as
   `secrets/tailscale.yaml`. Terraform configures a provider whenever a resource
   of that provider is in the configuration, `count = 0` included, so the apply
   job fails at provider configuration — before it reads a resource, and with
   `tailnet` still empty — until those two secrets exist.

   ```sh
   gh secret set TAILSCALE_OAUTH_CLIENT_ID --env cloudflare --repo smores56/homelab-platform
   gh secret set TAILSCALE_OAUTH_CLIENT_SECRET --env cloudflare --repo smores56/homelab-platform
   gh secret set TAILSCALE_OAUTH_CLIENT_ID --env cloudflare-plan --repo smores56/homelab-platform
   gh secret set TAILSCALE_OAUTH_CLIENT_SECRET --env cloudflare-plan --repo smores56/homelab-platform
   ```

   `scripts/check-pr-secret-boundary.sh` allowlists exactly those two names in
   `tofu-plan-pr.yml`: `policy_file` has no read-only scope, so what keeps the
   pre-merge plan safe is that it plans and never saves a policy.

4. Name the tailnet in `tofu/terraform.tfvars` (`tailnet = "..."`, the label before
   `.ts.net`).

5. Apply. The merge that sets `tailnet` runs `tofu-apply.yml`, which plans first
   and stops on anything destructive. A local plan exports the same two values and
   the R2 state pair:

   ```sh
   export TAILSCALE_OAUTH_CLIENT_ID=$(sops -d --extract '["client_id"]' secrets/tailscale.yaml)
   export TAILSCALE_OAUTH_CLIENT_SECRET=$(sops -d --extract '["client_secret"]' secrets/tailscale.yaml)
   tofu -chdir=tofu plan          # expect: tailscale_acl.this will be created
   ```

6. Prove the policy, from a laptop:

   ```sh
   tailscale status                          # expect: smortress listed
   ssh smortress true                        # expect: success (section 42)
   curl -sS --max-time 5 http://smortress:80/ && echo open || echo closed
   # expect: closed — the policy admits 22, 443, 8443, 10000 and 22000 only
   ```

   From a device that is not in `group:owner` — a phone on another account, or a
   node carrying `tag:untrusted` — port 22 on smortress must not answer. `tailscale
   ping smortress` still succeeds there: the policy drops the port, not the node.

   The policy names the host by tag (`tag:smortress`), not by address: a bare
   hostname is rejected by the validator ("invalid address") and a `hosts` alias
   pins the tailnet IP that a reinstall changes. `tofu/tailscale.tf` owns both
   halves — `data.tailscale_device` resolves the node by hostname and
   `tailscale_device_tags` gives it the tag — and the ACL resource depends on the
   tag resource, so a policy that names a tag no device carries cannot be applied
   in the same run that creates the tag.

   Two consequences worth knowing. The node itself is now outside
   `group:owner`, so it is not a source in any rule: traffic *from* smortress to
   another tailnet node is dropped (Syncthing still syncs because the laptops
   dial in). And a re-enrolment that uses an auth key without the tag strips it;
   mint the key with `--advertise-tags=tag:smortress`, or run the next apply to
   put it back. Tagging devices needs the CI client's `devices:core` scope
   (manual-steps section 46 step 2); a `policy_file`-only client can rewrite the
   policy but not the tag.

## 47. Agent shell jobs (T5 of #702): runner uids, prepull, and the two probes

`smortress-agent-job-provision.service` creates each shell runner's subuid range,
the general runner's ACL on `/var/srv/git`, and the uid-keyed egress table. The
pinned job image must be prepulled once per runner; `--pull=never` makes a job on
a host that skipped this fail closed rather than reach a registry.

```sh
sudo systemctl status --no-pager smortress-agent-job-provision.service
getent passwd agent-shell-personal agent-shell-general
grep -E '^agent-shell-(personal|general):' /etc/subuid /etc/subgid
sudo nft list table inet smortress_agent_jobs
getfacl -p /var/srv/git | grep agent-shell-general
sudo /usr/libexec/agent-job-provision --check
```

The check exits 0 only when both ranges are the exact expected lines and the
egress ruleset parses. Pre-pull the pinned image as each runner:

```sh
image=$(cat /etc/smortress/agent/job-image)
for runner in agent-shell-personal agent-shell-general; do
  state=${runner#agent-shell-}
  runtime=/run/smortress/agent-job/$runner
  sudo install -d -o "$runner" -g "$runner" -m 0700 "$runtime"
  sudo -u "$runner" env -i HOME="/var/lib/agent-shell/$state" \
    XDG_RUNTIME_DIR="$runtime" PATH=/usr/bin:/bin podman pull "$image"
done
```

Prove the split with one job per class. The personal job has no host mount and no
route out; the general job sees only the general tree, with general egress.

```sh
sudo /usr/libexec/agent-job-personal \
  'id; test ! -e /var/srv/git && echo "no general tree"; test -e /run/podman/podman.sock && echo "socket" || echo "no podman socket"'
sudo /usr/libexec/agent-job-general 'id; ls -la /work | head'
```

Both egress refusals must be denials, not timeouts into a successful fetch:

```sh
sudo /usr/libexec/agent-job-personal \
  'python3 -c "import urllib.request; urllib.request.urlopen(\"https://example.com\", timeout=3)" || echo blocked'
sudo /usr/libexec/agent-job-general \
  'python3 -c "import urllib.request; urllib.request.urlopen(\"http://169.254.169.254/latest/meta-data/\", timeout=3)" || echo blocked'
```

An output that exceeds 1 MiB is truncated and reported; a job that runs past 300
seconds has its whole transient cgroup killed and any leftover container removed.
Shell jobs are unsupervised YOLO by design: there is no command approval here.
The only approval contract is the write broker's `libs/data_plane/approval.py`.

## 48. Create the machine-user account and its scoped token

> **Current model (2026-11-22):** both machine credentials are for the Hermes
> general agent only; an interactive session you launch uses your own login and
> nothing is injected. Read `docs/agent-identity.md` first. The dev token is the
> classic `repo` PAT under `smores56-agent` (steps below, which still apply); the
> `sdlc` registry uses a fine-grained PAT **owned by `smores56`**, scoped to
> `smores56/sdlc` with Issues read/write and Metadata read and no Contents. Both
> are delivered per job by the shell dispatcher (T5) from ciphertext, never from a
> home directory. The
> `smores56-homelab-agent` App and its per-host enrollments are retired: the
> registration, its key and the broker's `github-*` enrollments are gone, so step
> 1 item 1 and step 34 are history, not instructions. "Cannot merge" is enforced
> by the `main` ruleset's required approving review, not by the token.

SDLC #710, part of #702. The general shell agents act on GitHub as a dedicated
machine account, never as `smores56` and never through the `dotfiles` work PAT.
The ceiling is a Write collaborator role: it can push branches, open pull
requests, and edit issues, and it cannot change rulesets, Environments, secrets,
collaborators, or repository settings. The token is a classic PAT because a
fine-grained PAT cannot act on another user's repositories as a collaborator
([fine-grained limitations](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens#fine-grained-personal-access-tokens-limitations));
a classic token's reach is exactly the machine user's own permissions, so the
collaborator roles are the control.

This is the shell's identity, not the broker's. The broker keeps
`smores56-homelab-agent`: installation tokens minted per request and scoped per
logical host (`docs/broker.md`), never placed in a shell job. GitHub recommends
an App for long-lived integrations; the migration is recorded in 48.8, and the
PAT is the approved T0 identity until the T5 dispatcher exists.

### 48.1 Create the account

Do this in a browser, not from an agent. Use an address that is not the one on
`smores56` and is not a `+` alias of it; verify it.

1. Sign up at <https://github.com/signup> with username `smores56-agent`,
   display name `smores56 agent`, and bio `Machine account for automation.
   Owner: smores56.` The Terms of Service permit one free machine account in
   addition to the personal account, provided it is used only for automation
   ([ToS §3](https://docs.github.com/en/site-policy/github-terms/github-terms-of-service#3-account-requirements)).
2. Settings -> Password and authentication -> enable TOTP 2FA; store the
   recovery codes. A passkey in the password manager is an account login
   factor only and grants no repository authority.
3. No SSH key, OAuth app, security key, or organisation. The PAT is the only
   credential a job ever receives.
4. Settings -> Emails shows the address verified.

Recorded 2026-11-21: login `smores56-agent`, id `359421157`, type `User`,
created `2026-11-21T05:25:30Z`; 2FA on, recovery codes and passkey in the
password manager; no SSH key, OAuth app, or organisation.

### 48.2 Create the classic PAT

As `smores56-agent`, <https://github.com/settings/tokens/new>:

- Note `homelab general shell`
- Expiration: 90 days, or non-expiring by explicit owner decision. The token
  created here is non-expiring (2026-11-21), an accepted deviation: the only
  kill switch becomes manual revocation.
- Scope: `repo` only. Do not add `workflow`, `admin:*`, `delete_repo`,
  `write:packages`, `gist`, `read:org`, or `notifications`. Without `workflow`
  the token cannot create or update `.github/workflows/**`, which is a control,
  not an omission.

Copy it once; the durable copy is the password-manager item
`GitHub smores56-agent PAT`. For the probes below, keep a local 0600 copy
outside every repository:

```sh
install -d -m 700 ~/.config/smores56-agent
read -rsp 'machine PAT: ' T; printf '%s' "$T" > ~/.config/smores56-agent/token; unset T
chmod 600 ~/.config/smores56-agent/token
```

Verify without printing the value:

```sh
GH_TOKEN=$(cat ~/.config/smores56-agent/token) gh api user --jq .login
# expect: smores56-agent
GH_TOKEN=$(cat ~/.config/smores56-agent/token) gh api -i user |
  grep -i '^x-oauth-scopes:'
# expect: x-oauth-scopes: repo
```

No `github-authentication-token-expiration` header means non-expiring.

### 48.3 Make it a Write collaborator on every personal repository

GitHub refuses a collaborator change on an archived repository
(`Repository was archived so is read-only.`), and archived repositories are
read-only anyway. The sweep therefore covers every active repository and
records the archived refusals rather than hiding them.

A transient owner classic PAT is needed because the owner's fine-grained token
has no Administration permission. Create it as `smores56` with scope `repo` and
a 7-day expiry, then store it 0600:

```sh
read -rsp 'owner classic PAT: ' T; printf '%s' "$T" > ~/.config/smores56-agent/owner-token; unset T
chmod 600 ~/.config/smores56-agent/owner-token
```

Add the machine user as `push` (Write) on every repository. The loop prints one
line per repository and tolerates the archived refusals:

```sh
OWNER=$(cat ~/.config/smores56-agent/owner-token)
while read -r r; do
  out=$(GH_TOKEN="$OWNER" gh api -X PUT \
    "repos/smores56/$r/collaborators/smores56-agent" -f permission=push 2>&1) || {
      printf 'skip %s: %s\n' "$r" "$(printf '%s' "$out" | tr '\n' ' ')"; continue; }
  printf 'invited %s\n' "$r"
done < <(gh repo list smores56 --limit 400 --json name --jq '.[].name')
```

Invitations are accepted by the machine user, not the owner:

```sh
MACHINE=$(cat ~/.config/smores56-agent/token)
GH_TOKEN="$MACHINE" gh api user/repository_invitations --paginate \
  --jq '.[] | [.id, .repository.full_name] | @tsv' |
while IFS=$'\t' read -r id repo; do
  GH_TOKEN="$MACHINE" gh api -X PATCH "user/repository_invitations/$id" >/dev/null &&
    printf 'accepted %s\n' "$repo"
done
GH_TOKEN="$MACHINE" gh api user/repository_invitations --jq 'length'
# expect: 0
```

Verify the role and that the repository permission is Write, never Admin or
Maintain:

```sh
while read -r r; do
  role=$(GH_TOKEN="$OWNER" gh api \
    "repos/smores56/$r/collaborators/smores56-agent/permission" --jq .role_name)
  perms=$(GH_TOKEN="$MACHINE" gh api "repos/smores56/$r" \
    --jq '[.permissions.admin,.permissions.maintain,.permissions.push] | @tsv')
  printf '%-24s %-6s %s\n' "$r" "$role" "$perms"
done < <(gh repo list smores56 --limit 400 --json name,isArchived \
  --jq '.[] | select(.isArchived|not) | .name')
```

Expected 2026-11-21: 20 active repositories at `role_name=write` with
`admin=false`, `maintain=false`, `push=true`; `sdlc` is one of them and is the
only active private repository. The 60 archived repositories returned
`Repository was archived so is read-only.` and were skipped. Archived
repositories are not writable; if a private archived history must be readable
by the machine user, unarchive it, add the collaborator, and re-archive.

### 48.4 Place every workflow secret in a main-only Environment

Two rules bound the token's ability to run its own branch's workflows:

1. There are no repository-level secrets. The machine user can list the names
   (not the values) as a Write collaborator; the list must be empty:

   ```sh
   GH_TOKEN=$(cat ~/.config/smores56-agent/token) gh api \
     repos/smores56/homelab-platform/actions/secrets --jq '.total_count'
   # expect: 0
   ```

2. Every workflow secret lives in an Environment, and the two environments that
   hold the write/signing credentials allow `main` only. `cloudflare-plan` is
   the one deliberate exception: it holds the read-only plan pair and allows
   `main` and `smores/*`, because the pre-merge plan runs on an owner-pushed
   branch. It never allows `agent/*`.

   `cloudflare` must already list `main`. On 2026-11-21 `cloudflare-plan` listed
   zero branch policies and `server-image` had `deployment_branch_policy: null`,
   so both were corrected:

   ```sh
   OWNER=$(cat ~/.config/smores56-agent/owner-token)

   GH_TOKEN="$OWNER" gh api -X PUT \
     repos/smores56/homelab-platform/environments/server-image --input - <<'JSON'
   {"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}
   JSON
   GH_TOKEN="$OWNER" gh api -X POST \
     repos/smores56/homelab-platform/environments/server-image/deployment-branch-policies \
     -f name=main -f type=branch

   for p in main 'smores/*'; do
     GH_TOKEN="$OWNER" gh api -X POST \
       repos/smores56/homelab-platform/environments/cloudflare-plan/deployment-branch-policies \
       -f name="$p" -f type=branch
   done
   ```

   Verify all three:

   ```sh
   for e in cloudflare cloudflare-plan server-image; do
     printf '%-16s ' "$e"
     GH_TOKEN="$OWNER" gh api \
       "repos/smores56/homelab-platform/environments/$e/deployment-branch-policies" \
       --jq '[.branch_policies[].name] | join(",")'
   done
   # expect:
   # cloudflare       main
   # cloudflare-plan  main,smores/*
   # server-image     main
   ```

GitHub evaluates the environment policy before the job starts. A branch outside
the list gets the job rejected with `Branch "<ref>" is not allowed to deploy to
<environment> due to environment protection rules.` and no step runs, so no
secret is injected. The runtime proof is in 48.5.

A `pull_request` run is not evaluated as the head branch. GitHub sees
`refs/pull/<n>/merge`, so the `smores/*` policy does not match it and
`tofu-plan-pr.yml` is refused for every PR, including this repository's own
`smores/*` branches (observed run `44872568178` on PR #94: `Branch
"refs/pull/94/merge" is not allowed to deploy to cloudflare-plan`). The
policy list is still the intended one, but the pre-merge plan does not execute
until either `refs/pull/*/merge` is allowed (which also admits agent and fork
PRs to the read-only plan) or the plan moves to a `push` on `smores/*` (a
workflow change, not part of this step). The required check therefore fails by
construction today; the owner's `--admin` merge is what lands a PR.

### 48.5 Prove the ceiling

Git's credential helper is the trap. `~/.config/git/config` contains
`credential.https://github.com.helper = !gh auth git-credential`, so a plain
`git push` in a repository cloned from GitHub authenticates as the owner even
when the URL carries `x-access-token`. Every control then looks unenforced,
because the owner is the ruleset bypass. Run the probes with every helper
disabled and a dedicated askpass:

```sh
TOKEN_FILE="$HOME/.config/smores56-agent/token"
cat > /tmp/askpass-machine.sh <<EOF
#!/bin/sh
cat "$TOKEN_FILE"
EOF
chmod 700 /tmp/askpass-machine.sh
mkdir -p /tmp/empty-home

gitm() {
  env -i PATH=/usr/bin:/bin HOME=/tmp/empty-home GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null GIT_ASKPASS=/tmp/askpass-machine.sh \
    GIT_TERMINAL_PROMPT=0 git -c credential.helper= \
    -c user.name='smores56 agent' \
    -c user.email='smores56-agent@users.noreply.github.com' "$@"
}
```

Clone and test `homelab-platform` (repeat for `nix-config` and `kanbei`; both
have the same `main` ruleset):

```sh
gitm clone --depth 1 https://x-access-token@github.com/smores56/homelab-platform.git
cd homelab-platform
git commit --allow-empty -m 't0 authority probe'
gitm push origin HEAD:refs/heads/agent/t0-probe        # succeeds
gitm push origin HEAD:main                            # rejected
gitm push --force origin HEAD:main                    # rejected
gitm push origin :main                                # rejected
```

Observed 2026-11-21 on all three repositories:

```text
! [remote rejected] HEAD -> main (push declined due to repository rule violations)
error: failed to push some refs to 'https://github.com/smores56/homelab-platform.git'
```

The force push returns the same message. The deletion returns
`! [remote rejected] main (refusing to delete the current branch:
refs/heads/main)`, and `refs/heads/main` remains.

A workflow-file push is refused by the token's scope before any ruleset:

```sh
mkdir -p .github/workflows
printf 'name: t0-probe\non: workflow_dispatch\njobs: {}\n' > .github/workflows/t0-probe.yml
git add .github/workflows/t0-probe.yml && git commit -m 't0 workflow probe'
gitm push origin HEAD:refs/heads/agent/t0-wf-probe
# expect:
# ! [remote rejected] ... (refusing to allow a Personal Access Token to create
# or update workflow '.github/workflows/t0-probe.yml' without 'workflow' scope)
```

Open a PR from the probe branch and try to merge it as the machine user:

```sh
MACHINE=$(cat ~/.config/smores56-agent/token)
GH_TOKEN="$MACHINE" gh pr create --repo smores56/homelab-platform \
  --head agent/t0-probe --base main --title 'T0 authority probe' --body 'probe'
GH_TOKEN="$MACHINE" gh pr merge <n> --merge
# expect: Pull request smores56/homelab-platform#<n> is not mergeable:
#         the base branch policy prohibits the merge.
GH_TOKEN="$MACHINE" gh pr merge <n> --merge --admin
# expect: GraphQL: Repository rule violations found
#         At least 1 approving review is required by reviewers with write access.
#         Required status check "tofu plan" is failing.
```

Close the PR and delete the probe branch afterwards:

```sh
GH_TOKEN="$MACHINE" gh pr close <n> --repo smores56/homelab-platform --delete-branch
GH_TOKEN="$MACHINE" gh api -X DELETE \
  repos/smores56/homelab-platform/git/refs/heads/agent/t0-probe
```

Environment dispatch on the machine user's branch is refused for all three
environments. The job has zero steps, so the secret is never read:

```sh
GH_TOKEN="$MACHINE" gh workflow run publish-app-images.yml \
  --repo smores56/homelab-platform --ref agent/t0-probe
GH_TOKEN="$MACHINE" gh workflow run tofu-apply.yml \
  --repo smores56/homelab-platform --ref agent/t0-probe -f plan_only=true
```

Open a PR from the same branch to exercise `cloudflare-plan`. Observed
2026-11-21, with the exact annotations:

| Environment | Ref | Annotation |
| --- | --- | --- |
| `server-image` | `agent/t0-probe-machine` | `Branch "agent/t0-probe-machine" is not allowed to deploy to server-image due to environment protection rules.` |
| `cloudflare` | `agent/t0-probe-machine` | `Branch "agent/t0-probe-machine" is not allowed to deploy to cloudflare due to environment protection rules.` |
| `cloudflare-plan` | `refs/pull/93/merge` | `Branch "refs/pull/93/merge" is not allowed to deploy to cloudflare-plan due to environment protection rules.` |

The recorded probe branch was `agent/t0-probe-machine`; the commands above
use `agent/t0-probe`.

Recorded runs: `actions/runs/44872248868` (server-image),
`actions/runs/44872273360` (cloudflare), `actions/runs/44872279543`
(cloudflare-plan). Each also carries `The deployment was rejected or didn't
satisfy other protection rules.` and no job steps.

Administration endpoints return `404` or `403`, never a mutation:

```sh
GH_TOKEN="$MACHINE" gh api repos/smores56/homelab-platform/branches/main/protection
# {"message":"Not Found",...,"status":"404"}
GH_TOKEN="$MACHINE" gh api -X PATCH repos/smores56/homelab-platform \
  -f description="$(GH_TOKEN="$OWNER" gh api repos/smores56/homelab-platform --jq .description)"
# {"message":"Not Found",...,"status":"404"}
GH_TOKEN="$MACHINE" gh api -X PUT \
  repos/smores56/homelab-platform/collaborators/t0-nonexistent-probe \
  -f permission=push
# {"message":"Not Found",...,"status":"404"}
```

`gh api .../actions/secrets` returns names only (`{"secrets":[],"total_count":0}`)
and `.../environments` is readable; neither exposes a value or a write. The
`admin=false` read-back in 48.3 is the same ceiling.

### 48.6 SDLC approval is not yet bound to the owner

`sdlc approve` adds `status:approved` and a comment with a design hash, but it
does not compare the comment author to `smores56` (`sdlc_issues.py:569-593` in
`dotfiles`). A Write collaborator can therefore post the same label and comment.
Do not run `sdlc approve` as the machine user on a real feature; the claim that
"an SDLC approval recorded by the machine user is not accepted" is false until
that CLI change lands. The approval check lives outside this repository.

### 48.7 Rotate and revoke

- Machine PAT: revoke it at <https://github.com/settings/tokens> as
  `smores56-agent`, create a replacement with scope `repo` only, update the
  password manager, and replace the T5 dispatcher's copy. The broker is
  untouched.
- Owner transient PAT: revoke it immediately after 48.5 and remove the file:

  ```sh
  rm -f ~/.config/smores56-agent/owner-token
  ```

- Remove the local machine-token file when the T5 dispatcher owns the secret:

  ```sh
  rm -f ~/.config/smores56-agent/token
  ```

- The passkey, password, and recovery codes are account login factors. They
  never enter a job, a manifest, or this repository.

### 48.8 Residual and next step

Accepted on 2026-11-21:

- The PAT is non-expiring by owner decision; manual revocation is the only kill
  switch.
- `sdlc` is a private repository on the free plan where GitHub refuses rulesets
  and branch protection (`Upgrade to GitHub Pro or make this repository public`,
  HTTP 403). The machine user has Write there, so it can push `main`; this was
  not executed. `sdlc` needs protections before the Write ceiling is real.
  `homelab-apps` is no longer in this list: its `main` ruleset stopped being a
  gap on 2026-11-21, and both the direct-push refusal and an app-only
  auto-merge were measured on 2026-11-22 (`docs/core/apps-tenant.md`,
  `scripts/agent-tenant-pr-probe.sh`).
- The `main` rulesets cover only `~DEFAULT_BRANCH`. Non-main branches have no
  force-push or deletion rule, and the app-gating ruleset described in section
  1 item 3 is absent on `homelab-platform`, `nix-config`, and `kanbei`.
- The 60 archived repositories are excluded; a private archived history is not
  readable by the machine user.
- `cloudflare-plan`'s `main`/`smores/*` policy does not match a
  `pull_request` run's `refs/pull/<n>/merge`; the plan check is refused for
  every PR (recorded run `44872568178`). Fixing it is a separate decision:
  allow `refs/pull/*/merge` (read-only plan for every PR, including agent and
  fork PRs) or trigger the plan on `smores/*` pushes.
- The `sdlc` approval author check in 48.6 is missing.

The standard-practice replacement is a GitHub App installation token minted by
the trusted T5 dispatcher for each general job (1 hour, narrowed to one
repository and `contents`/`pull_requests`/`issues`), with the App private key in
the dispatcher and never in the job. That is a design delta to #702/#715, not
part of this walkthrough; this section records the approved T0 identity and the
controls that bound it.

## 49. Deploy receiver (#798, T7): notify credentials, the three secrets, the boot counter, and the operator commands

The receiver is the only thing that changes a deployment on `smortress`. A merge
to `homelab-platform` `main` or to `homelab-apps` `main` reaches the host as one
signed request, and the host re-derives everything else itself
(`docs/core/server-image.md`, "The deploy path"). Nothing but these credentials,
one Healthchecks check and one `bootupctl update` is a human decision: the
workflows, the units, the state tree, the secrets' manifest lines and the
snapshot gate are all in the tree.

The image ships the receiver, the drain, the verifier, the platform and apps
steps, the boot gate and the operator CLI; it starts the listener, the queue
path, the boot gate and the two timers at boot. The `deploy-notify` Environment
is what the two notify jobs read, so the order below is: Environment, tailnet
client, Healthchecks check, ciphertexts, boot counter, then the commands an
operator uses when something needs a hand.

### 49.1 Create the `deploy-notify` Environment in both repositories

Both repositories have a `notify` job that runs `environment: deploy-notify` with
`permissions: {}` and no checkout; the Environment is main-only so a pull request
or a branch run cannot read the webhook key even if it edits the workflow.

The webhook key is not minted here: it is the value the repository already
encrypts at `secrets/server/webhook-secret.yaml`, and both Environments and the
host have to agree on it byte for byte. Read it from there (49.4 replaces it if
that ciphertext still holds the random value the commit shipped) and record it in
the password manager.

```sh
OWNER=$(cat ~/.config/smores56-agent/owner-token)
WEBHOOK=$(sops decrypt --extract '["webhook-secret"]' secrets/server/webhook-secret.yaml)

for repo in homelab-platform homelab-apps; do
  GH_TOKEN="$OWNER" gh api -X PUT "repos/smores56/$repo/environments/deploy-notify" \
    --input - <<'JSON'
{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}
JSON
  GH_TOKEN="$OWNER" gh api -X POST \
    "repos/smores56/$repo/environments/deploy-notify/deployment-branch-policies" \
    -f name=main -f type=branch
done
```

The three secrets are the same names in both repositories because both jobs run
the same script: the OAuth client from 49.2 in two secrets, and the one webhook
key the host also holds (`webhook-secret.yaml`, 49.4).

```sh
for repo in homelab-platform homelab-apps; do
  printf '%s' '<oauth client id>' | GH_TOKEN="$OWNER" \
    gh secret set TS_OAUTH_CLIENT_ID --env deploy-notify --repo "smores56/$repo"
  printf '%s' '<oauth client secret>' | GH_TOKEN="$OWNER" \
    gh secret set TS_OAUTH_CLIENT_SECRET --env deploy-notify --repo "smores56/$repo"
  printf '%s' "$WEBHOOK" | GH_TOKEN="$OWNER" \
    gh secret set DEPLOY_WEBHOOK_SECRET --env deploy-notify --repo "smores56/$repo"
done

for repo in homelab-platform homelab-apps; do
  printf '%-16s ' "$repo"
  GH_TOKEN="$OWNER" gh api "repos/smores56/$repo/environments/deploy-notify/secrets" \
    --jq '[.secrets[].name] | sort | join(",")'
done
# expect:
# homelab-platform DEPLOY_WEBHOOK_SECRET,TS_OAUTH_CLIENT_ID,TS_OAUTH_CLIENT_SECRET
# homelab-apps     DEPLOY_WEBHOOK_SECRET,TS_OAUTH_CLIENT_ID,TS_OAUTH_CLIENT_SECRET
```

There are still no repository-level secrets (48.4).

**Accepted residual.** The client below carries `devices` write as well as
`auth_keys`, and the two cannot be separated: `auth_keys` mints the ephemeral
preauthorized key, and applying `tag:deploy` to the node it created is a device
write. The impact is that a compromised notify job — or anything that reads the
two secrets on a runner — can re-tag or delete the `smortress` device itself, not
merely its own ephemeral node: the host then leaves the tailnet until the admin
client from section 45 re-tags it, and while it is retagged the ACL that admits
`tag:deploy` on port 8484 admits a node the attacker controls. What bounds it is
scope, not the scope of that write: the client is `auth_keys`-only plus this one
write, the ACL admits the tag on one port, and nothing else in the tailnet is
readable with it. The alternative — a static auth key in the Environment — trades
this write for a key that never expires, which is worse.

### 49.2 Create the tailnet client that carries `tag:deploy`

The notify job joins the tailnet as an ephemeral node tagged `tag:deploy`, and
the ACL admits that tag on `tag:smortress:8484` and on nothing else. The tag's
owner is `group:owner`; a client that mints any other tag is refused, and the
`policy_file` admin client from section 45 is not used here.

1. Admin console → Settings → OAuth clients → **New client**. Scopes: `auth_keys`
   write and `devices` write, nothing else — `auth_keys` is what mints the
   ephemeral pre-authorized key, `devices` is what lets the tag be applied to it.
   Tags: `tag:deploy`.
2. Put the client id and secret in both repositories' `deploy-notify`
   Environment (49.1). One client, two Environments: rotating it is a change in
   both, and a job that can reach the tailnet must never also hold the cosign key
   (which lives in `server-image`, a different Environment).
3. Prove the tag carries the right reach after the next deploy: the notify job's
   log shows the node joining, the POST answers `202`, and the node disappears
   from `tailscale status` when the job ends.

### 49.3 Create the `deploy` Healthchecks check

One check, five-minute period, is the receiver's only notification path: every
failure, hold and rollback pings `/fail`, every successful apply and every healthy
boot gate pings success, and Pushover's own integration is what reaches the
phone.

1. Healthchecks → **Add Check**: name `deploy`, period **5 minutes**, grace time
   **5 minutes**, no schedule, integration **Pushover**. Simple `ping/<uuid>` URL.
2. Record the URL; it goes into `secrets/server/deploy-ping-url.yaml` (49.4), not
   into a workflow and not into this repository's plaintext.
3. Confirm the dead-man is what keeps it green: the beat is
   `smortress-deploy-heartbeat.timer` every five minutes, and it pings `/fail`
   when the listener does not answer `/healthz` or a queue entry is older than
   30 minutes. A stopped listener therefore pages, which is the point.

### 49.4 Seed the three deploy ciphertexts, and rotate the key inside one deploy

`secrets/server/{webhook-secret,webhook-secret-next,deploy-ping-url}.yaml` and
their three manifest lines ship with the image; the values behind them are the
operator's. `webhook-secret` is what both notify jobs sign with today,
`webhook-secret-next` is the rotation slot, and `deploy-ping-url` is 49.3's URL.
All three are `value` in the manifest, so `sops-decrypt` writes the bare scalar:
the listener compares the raw key, and the heartbeat hands the bare URL to curl.

Confirm what the committed ciphertext holds before you trust a deploy to it:

```sh
sops decrypt --extract '["webhook-secret"]' secrets/server/webhook-secret.yaml
# expect: a 64-character hex value you hold, and the two DEPLOY_WEBHOOK_SECRET
#         secrets (49.1) are exactly it. A value nobody holds is a key no notify
#         job can sign with, and the listener then refuses every event.

sops decrypt --extract '["deploy-ping-url"]' secrets/server/deploy-ping-url.yaml
# expect: the https://hc-ping.com/<uuid> URL from 49.3
```

Replace one that does not match, or seed a rotation slot that has no meaning yet:

```sh
( umask 077
  printf 'deploy-ping-url: %s\n' 'https://hc-ping.com/<uuid>' >/tmp/deploy-ping-url.yaml
  sops --encrypt --input-type yaml --output-type yaml \
    --filename-override secrets/server/deploy-ping-url.yaml \
    /tmp/deploy-ping-url.yaml >secrets/server/deploy-ping-url.yaml
  rm -f /tmp/deploy-ping-url.yaml
)
```

`webhook-secret-next` is the same command with that key name and a fresh
`openssl rand -hex 32`. It holds a random value nobody knows, which is correct:
the listener accepts either file, and a slot nobody holds changes no behaviour.

Rotating the webhook key takes two platform deploys, and there is no window in
which the old key is refused:

1. Write the new key into `webhook-secret-next.yaml`, commit, and let the image
   publish and the receiver deploy it. From that boot the listener accepts either
   key.
2. Change `DEPLOY_WEBHOOK_SECRET` in both `deploy-notify` Environments to the new
   key (49.1). The next notify signs with it and is accepted.
3. Move the new key into `webhook-secret.yaml` and put a fresh random value in
   `webhook-secret-next.yaml`; commit and deploy. The old key is now gone from
   the image.
4. Prove it: `curl` one request, or wait for the next merge, and read
   `journal.jsonl` for `queue-enqueued` (49.6); a body signed with the retired
   key is a `deploy-rejected` with reason `bad-signature`.

The listener refuses to start when `webhook-secret.yaml` is empty or missing, so
a failed decrypt is a unit that answers nothing rather than one that accepts
unsigned requests. `sudo systemctl status smortress-deploy-listener` is where
that shows up, and the heartbeat pages for it.

### 49.5 The boot counter is not installable on this host

`bootc` has no boot counting and the post-boot gate only runs if userspace
starts, so the image ships
`/usr/lib/bootupd/grub2-static/configs.d/10-smortress-count.cfg` in the hope
that `bootupd` would copy it into `/boot/grub2/grub.cfg`. On smortress it does
not, and this is the measured result, not an assumption:

```sh
sudo bootupctl status
# Component BIOS: At latest version
# Component EFI:  At latest version
# No components are adoptable.
sudo bootupctl update
# No update available for any component.
sudo grep -c 'boot_counter' /boot/grub2/grub.cfg
# expect: 0
```

`bootupctl update` only regenerates `grub.cfg` when it installs a bootloader
component, and there is no `--force`; every component is already current, so the
static snippet is never copied. **The host therefore has no pre-userspace
rollback today.** Do not claim one, and do not enable `kernel.panic`: a panic
that reboots without a counter loops the same image forever. The image ships no
`kernel.panic` sysctl for that reason. `RuntimeWatchdogSec=1min` stays armed as a
liveness measure, with the same caveat: a PID 1 that hangs every boot would
reboot into the same image until an operator intervenes.

What does exist is the userspace gate: a deployment that boots but fails its
**host** health check is denylisted and `bootc rollback --apply` reverts it. The
tenant's apps are not part of that check — a broken app is an apps revision, and
`smortress-apps-health.timer` reports it every five minutes without rolling
anything back — so a red gate here always means the platform itself. The gate
journals `boot-counting-absent` on every boot where `grub.cfg` does not read the
counter, so the gap is visible without reading this page.

```sh
journalctl -u smortress-boot-gate.service --no-pager -n 20
# expect: "healthy after N attempt(s)" when a deployment was owed
# expect: boot-counting-absent when it was not installed
```

Revisit this step if the mechanism changes: a bootc install that runs bootupd
after the snippet exists, a systemd-boot host, or a packaged greenboot that
regenerates the bootloader. Until then, a host that will not boot is recovered
from the console, and the recovery point is the pre-reboot snapshot the deploy
gate took.

### 49.6 The operator view: `status`, `/healthz`, and the journal

`/usr/libexec/smortress-deploy` is the whole operator surface. It is not on
root's `PATH` (`/usr/libexec` is not, by design), so every command below names
the installed path. `status` is read-only and takes no lock, so it answers on
a host whose drain is wedged.

```sh
sudo /usr/libexec/smortress-deploy status | jq .
# {"schema":1,
#  "repos":{"homelab-platform":{"commit":"…","indexDigest":"sha256:…","manifestDigest":"sha256:…"},
#           "homelab-apps":{"commit":"…"}},
#  "apps":{"unitsHash":"…","secretsHash":"…",
#          "apps":{"<name>":{"unit":"<sha256 of the installed unit>","secrets":"<sha256 of the names and values>"}}},
#  "updated":"…",
#  "held":null,
#  "pending":null,
#  "denylist":{"commits":{},"digests":{}}}

sudo curl -sS http://127.0.0.1:8484/healthz
# expect: {"status":"ok","rejected":{}}
# "rejected" is the listener's in-memory tally of what it refused, by reason
# (bad-signature, stale-timestamp, replayed-nonce, listener-busy, ...). Those
# refusals are not journaled -- a journal line is an fsync, and the port takes
# them from anyone on the tailnet -- so this is where a stream of them shows.
```

`state.json` records what is running. `pending.json` exists only between a staged
platform deploy and the boot gate that judges it, `held.json` only while a
snapshot gate is waiting for an operator. The append-only record is
`/var/lib/homelab/deploy/journal.jsonl` (rotated to `journal.1.jsonl` at 5 MiB),
one JSON object per line:

```sh
sudo tail -n 20 /var/lib/homelab/deploy/journal.jsonl | jq -c .
# the events worth knowing:
#   queue-enqueued, deploy-rejected, already-deployed      the listener's answers
#   verified, verify-rejected, verify-infra-failure       the host's own verdict
#   deploy-held, gate-released, gate-released-by-operator, gate-green
#   stage-digest-mismatch, boot-gate-green, boot-gate-failed, rolled-back-by-bootloader
#   apps-start, apps-pulled, apps-rejected, apps-applied, apps-quota-applied,
#   apps-reverted, apps-failed, apps-serve-failed,
#   apps-unhealthy (a started app was not active, or was restarted),
#   apps-name-refused (a name the schema forbids reached a unit sink),
#   apps-work-kept (a work tree the sweep would not remove)
#   apps-health-failed (a plan app is not serving: the reason, the app, the unit;
#   from the five-minute smortress-apps-health.timer, which rolls nothing back and
#   pings nothing -- this journal line is the tenant's only signal)
#   denylist-added, denylist-cleared, bootstrap-recorded, state-reconciled,
#   booted-unrecorded, poll-denylisted, notify-sent, notify-failed
sudo journalctl -u smortress-deploy-listener.service -u smortress-deploy.service \
  -u smortress-boot-gate.service -u smortress-apps-health.service --no-pager -n 50
```

### 49.7 A held deploy: what it looks like, and `release --force`

A platform deploy whose snapshot gate cannot make one restore unit fresh — no
usable local repository, or the 3600 s budget spent — holds instead of rebooting.
Nothing is staged, nothing reboots, the check is red, and the hold is the only
state:

```sh
sudo /usr/libexec/smortress-deploy status | jq '.held'
# {"schema":1,"digest":"sha256:…","commit":"…","digests":{…},
#  "missingUnits":["books"],"reason":"no-usable-repository","heldAt":"…","released":false}
```

Fix the repository (the restic plane's own sections), or decide the reboot is
worth it without that unit. The second is the break-glass path and takes the
flag on purpose:

```sh
sudo /usr/libexec/smortress-deploy release --force
# smortress-deploy: released sha256:… for smores; the next drain of <commit> stages it
```

It records the operator, the digest and the missing units, changes no image and
reboots nothing: the next request for that commit — the daily 03:00 window
re-enqueues it while it is still the tip, or a manual dispatch does it sooner —
reaches the gate, sees the release, stages and reboots. A release covers one
digest only.

### 49.8 A denylisted commit or digest: `unblock`

A failed gate, a rollback and a rejected apps definition all denylist what they
refused, and a denial is final: the listener refuses the commit, and the hourly
poll pages and stops enqueuing it. That is deliberate, so the way out is a hand
that removes exactly one entry:

```sh
sudo /usr/libexec/smortress-deploy status | jq '.denylist'
# {"commits":{"<40-hex>":{"reason":"apps:definition-rejected","at":"…"}},
#  "digests":{"sha256:…":{"reason":"boot-gate:apps-not-mounted","at":"…"}}}

sudo /usr/libexec/smortress-deploy unblock digest sha256:…
# smortress-deploy: cleared the denylisted digest sha256:… for smores
sudo /usr/libexec/smortress-deploy unblock commit <40-hex>
```

The way on is the same act in reverse. The drain retries a failed apps apply
every 300 s, and an app that starts and then exits fails every attempt, so a
revision that cannot stay up would be attempted forever:

```sh
sudo /usr/libexec/smortress-deploy block commit <40-hex>
# smortress-deploy: denylisted the commit <40-hex> for smores
```

The next attempt is refused by the verifier, the drain pops the entry, and the
poll stops offering the tip until `unblock` removes exactly that entry. It takes
the same two tables and value shapes as `unblock`, refuses a non-root caller and
a value that is already listed, and journals `denylist-added` with the operator.

Set the value only after the cause is gone — a fixed definition is a *new* commit
and needs no unblock; a denied digest is usually a failed health gate, so read
`journal.jsonl` for its `boot-gate-failed` reason first. `unblock` refuses a
non-root caller, a mistyped table (`commit`/`digest` only) and a value that is not
on the list, and journals `denylist-cleared` with the operator.

### 49.9 A restored or rebuilt host: `bootstrap`

`state.json` lives outside every recovery group because it is rebuildable, and
the one thing that cannot be inferred is the commit the host is running: no
recorded ancestor means no descendancy check, and every deploy is refused with
`bootstrap-required` rather than guessed. After a restore, and only then:

```sh
sudo bootc status --json | jq -r '.status.booted.image.imageDigest'
sudo /usr/libexec/smortress-deploy bootstrap homelab-platform <40-hex>
# smortress-deploy: recorded homelab-platform at <sha> for smores; the next deploy must be a descendant of it
sudo /usr/libexec/smortress-deploy bootstrap homelab-apps <40-hex>
```

Take the commit from the image's own `org.opencontainers.image.revision` label
when the booted digest is no longer in the registry. `bootstrap` refuses to
overwrite an existing record, refuses a repository the receiver does not deploy,
and journals `bootstrap-recorded`. It is not a way to make a hand-run
`bootc switch` look deployed (see `docs/core/server-image.md`, "What a hand-run
switch still gives up").

### 49.10 A record that disagrees with the boot: `reconcile`

The boot gate compares the image this host booted with the digest `state.json`
records, and when they differ it journals `booted-unrecorded` and pages —
deliberately leaving the record alone, because the host is healthy and a
hand-run `bootc switch` is the operator's choice. Repairing it is an operator
act, and the digest is read from the host rather than retyped:

```sh
sudo bootc status --booted --json | jq -r '.status.booted.image.imageDigest'
sudo /usr/libexec/smortress-deploy reconcile --commit <40-hex>
# smortress-deploy: recorded <40-hex> at sha256:… for smores
```

The commit is the one the operator asserts: a digest-pinned boot carries no
commit in `bootc status`, and the revision label lives only in the registry
config. `reconcile` reads the booted digest, refuses a non-root caller, refuses
a record that already matches, drops the stale digest form rather than keeping
two, leaves other repositories' records alone, and journals `state-reconciled`
with the previous commit and the operator. It is not `bootstrap` (which refuses
an existing record) and not a way to make a hand-run switch look deployed.

### 40.18 Run the agent runtime drill

Three rows of the T6 cutover matrix behind #716 cannot be answered by a tree:
the live mount namespaces, the root-only secrets, and a cold restore of an agent
dataset from a real destination. `scripts/agent-runtime-drill.sh` runs them as
root from a checkout and prints one PASS/FAIL line per observation.

It prints secret names and file modes, never a value; it writes only under the
restic data disk's `drill/` (`/var/lib/restic/ssd/drill`, or
`SMORTRESS_AGENT_DRILL_ROOT`), never on the root filesystem; and it stops nothing, so
the fencing below is yours. Rehearse the whole plan first — `--dry-run` prints
every command and executes none, and it is the only mode that runs unprivileged:

```sh
scripts/agent-runtime-drill.sh --dry-run mounts
scripts/agent-runtime-drill.sh --dry-run credentials
scripts/agent-runtime-drill.sh --dry-run restore agent-local --backend all
```

Anything else without `sudo` exits 1 and names the privilege it needs.

**Fencing, before any restore.** A restore into a dataset a live process is
writing into proves nothing, and the drill cannot stop that process. Stop every
writer of both agent datasets, including the one-shot collectors and their
timers, and give the running browser collector time to finish:

```sh
sudo systemctl stop smortress-agent-collect-finance.timer \
  smortress-agent-collect-calendar.timer smortress-agent-collect-brave.path \
  smortress-agent-collect-brave.timer
sudo systemctl stop smortress-agent-mail-stream.service agent-tmail.service \
  agent-brave.service syncthing.service
sudo systemctl stop agent-webui-personal.service agent-webui-general.service \
  agent-facade-personal.service agent-facade-general.service \
  agent-local.service agent-general.service agent-proxy.service
sudo systemctl is-active agent-local.service agent-general.service  # inactive
```

**Hostile mount probe (#716 row 5).**

```sh
sudo scripts/agent-runtime-drill.sh mounts
```

Five PASS lines, one per path, each carrying the error the namespace answered as
uid 0 and as uid 1000:

```
PASS smortress-agent-general /var/srv/repo-archive
     uid 0: absent: no such path in this namespace; uid 1000: absent: no such path in this namespace
```

A `FAIL` line is the finding, not a nuisance: `present and listable` means the
mount exists in the namespace and the boundary is only a permission, and
`present but not listable` means it exists at all. Either one means a Quadlet
gained a `Volume=` it must not have; `tests/core/agent-recovery.sh` names the
class of mistake (`agent-mount-cross`). `SKIP <container> is not running` means
the probe had nothing to exec into — start the gateway and rerun.

**Credential blast radius (#716 row 6).**

```sh
sudo scripts/agent-runtime-drill.sh credentials
```

The good shape, all of it `PASS`:

```
PASS restic-password is staged root-only
     root-only 400
PASS smortress-agent-general cannot read restic-password
     uid 0: absent: no such path in this namespace; uid 1000: absent: no such path in this namespace
...
PASS no agent unit names a plane secret
     19 unit definitions
```

`readable` on any line is the finding: a container that can read
`/run/smortress/secrets/restic-password.yaml`, `/run/smortress/secrets/r2-credentials.yaml`
or `/var/lib/homelab/age/keys.txt` can destroy every recovery point, including
the ones it cannot reach over the network. `present but not readable` still
fails, because a mount source that should not be there is one permission
mistake from readable. The oneshot collectors (`smortress-agent-collect-*`,
`smortress-agent-mail-stream`, `smortress-agent-brave-snapshot|seed`) exit between
runs, so their containers print `SKIP` and the closing `no agent unit names a
plane secret` line carries their half: it reads every
`units/quadlet/agent-*.container` and `units/systemd/smortress-agent-*.service`
for those three paths. A `FAIL … is staged root-only` line means the host copy is
wrong (not root-owned, or not 0400) and the probes proved nothing.

**Cold restore of an agent dataset (#716 row 1).** One subcommand per group and
destination; `--backend all` walks `ssd`, `hdd` and `r2` with one target each.

```sh
sudo scripts/agent-runtime-drill.sh restore agent-local --backend ssd
sudo scripts/agent-runtime-drill.sh restore agent-general --backend ssd
sudo scripts/agent-runtime-drill.sh restore agent-local --backend all
sudo scripts/agent-runtime-drill.sh restore agent-general --backend all
```

It calls `/usr/libexec/smortress-restic-restore-drill` (the verified snapshot
only), which lands the tree at
`<target>/var/lib/agent/<side>/.zfs/snapshot/<backend>`, then checks it:

- gateway state: `.env` (with an `API_SERVER_KEY=` line, printed as a name and
  never a value), `webui.env` (`HERMES_WEBUI_PASSWORD=`), `config.yaml`;
- `webui/`, `webui/state` non-empty (the chats) and `webui/workspace`;
- facade memory: `memory/local` on the personal side, `memory/external` on the
  general one, with at least one record;
- collector data, personal side only: `quarantine/` non-empty and at least one
  `replica/<source>/published/<gen>/manifest.json`; the general tree must carry
  no generation at all;
- ownership: no uid outside `0`/`1000` came out of the archive, then the
  documented `chown -R 1000:1000`, then uid 1000 can write `memory`, `webui` and
  (personal) `quarantine`, `replica`, `index`;
- the FTS index rebuilt from the restored records as uid 1000, reporting how many
  records it indexed (`1 of 1 records indexed`); a missing index is not a lost
  record — `apps/agent_facade/memory.py` rebuilds it — but a zero count with
  records on disk is a finding;
- a second restore into the same target, which the helper refuses with
  `refusing to mix a drill into old data`.

The good shape ends `0 failed`; the run prints `<n> passed, <n> failed, <n>
skipped`. A `FAIL … restores` line carries the helper's own reason (no verified
snapshot, no room on the target filesystem, repository not configured) and the
remaining checks for that backend are skipped: a drill is only evidence once the
contents were checked. A `FAIL …: restore target <dir> inside the live dataset
<key>` line means `--target` names a path under a mounted dataset, which is the
one thing a drill must never write into; pick a target on a data disk
(`/var/lib/restic/hdd/drill` or `/var/lib/restic/ssd/drill`), never under
`/var/tmp`.
`SKIP restored hledger projection is present` is expected before the finance
collector's first run, because that journal is derived.

The restored tree is throwaway and stays behind: compare a known file, then

```sh
sudo rm -rf /var/lib/restic/ssd/drill/ssd-agent-*
```

Start the writers again in the order section 40.9 gives, then section 40.9's
listener checks:

```sh
sudo systemctl start agent-model.service agent-facade-personal.service \
  agent-local.service agent-general.service agent-proxy.service \
  agent-webui-personal.service agent-webui-general.service \
  agent-facade-general.service
sudo systemctl start agent-tmail.service smortress-agent-mail-stream.service \
  syncthing.service
sudo systemctl start smortress-agent-collect-finance.timer \
  smortress-agent-collect-calendar.timer smortress-agent-collect-brave.path \
  smortress-agent-collect-brave.timer
```

The static half of these rows needs no host. `tests/core/agent-recovery.sh` is
run by CI and asserts what the tree can prove (per-unit datasets, retention and
readiness on every destination, the mount table, the target rules);
`tests/core/agent-drill.sh` asserts this drill itself and runs in the same
checkout: it parses and refuses non-root, `--help` lists the three subcommands,
`--dry-run` executes no `podman` or `restic` command under a recording `PATH`
shim, and every probe script is a constant with the path passed as a positional
argument.

## 50. Public edge VPS (#725, T1): key, panel firewall, bootstrap, cutover

The edge is a RackNerd 4 GB KVM VPS in New York with one IPv4 and no IPv6. It
runs Caddy for `photos.sammohr.dev` and `opds.sammohr.dev`, joins the tailnet as
`tag:vps`, and proxies to Serve ports 8446 and 8447. `docs/core/public-edge.md`
is the shape and the failure modes; this section is the operator order. Nothing
here can be done by repo code: keys, the panel, and the console need a human.

> The cutover (`§50.8`) changes which Immich is authoritative. It waits for
> #709's retirement gate and for the origin-parity comparison, not for the box
> to exist.

### 50.1 Apply the tailnet policy first

A key can only carry a tag its owner may apply, and the tag has to exist in
`tagOwners` before that. Apply the policy that carries `tag:vps`, the
`tag:vps -> tag:smortress:8446,8447` rule and its deny tests:

```sh
cd /srv/git/github.com/smores56/homelab-platform/main
tofu -chdir=tofu apply -no-color
```

Evidence: the apply output, and the policy tests refusing any widening.

### 50.2 Mint a preauthorized `tag:vps` key

In the Tailscale admin console: **Settings → Keys → Generate auth key**, tag
`tag:vps`, preauthorized, 1-day expiry, reusable off. Do not store it anywhere;
it is used once, in `§50.4`, and the node's key expiry is off because it is
tagged. A reinstall has to mint a new one, which is why the admin login and its
2FA recovery codes are recovery-kit rows (`docs/core/recovery-kit.md`).

### 50.3 Panel firewall (not planned)

Decision 2026-11-22: the ctrl network firewall stays off. The host nftables
ruleset (`provision/edge/nftables.conf`, applied by the bootstrap) is the only
layer; the accepted residual is that a host firewall which fails at boot leaves
the kernel default-allow, and a compromised host can expose any port it likes.

If that changes, the rule set is `tcp/443`, `udp/41641` and ICMP (all types, not
just echo — PMTU needs destination-unreachable), added **before** enabling it,
or certificate issuance fails. Console/VNC bypasses the panel.

### 50.4 Deploy and join from the console

Deploy the **Ubuntu 24.04** template in New York (jammy's Caddy 2.4 cannot
parse the TLS options in `provision/edge/Caddyfile`), name the VPS `smoresnet` in
the panel, note the IPv4 in `docs/core/public-edge.md`, and from the HTML5
console install Tailscale from its signed repository, as `bootstrap.sh` does —
not `curl | sh`:

```sh
. /etc/os-release
install -d -m 0755 /usr/share/keyrings
curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/$VERSION_CODENAME.noarmor.gpg" \
  -o /usr/share/keyrings/tailscale-archive-keyring.gpg
curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/$VERSION_CODENAME.tailscale-keyring.list" \
  -o /etc/apt/sources.list.d/tailscale.list
apt-get update -qq && apt-get install -y tailscale
tailscale up --auth-key 'tskey-auth-…' --advertise-tags=tag:vps \
  --hostname=smoresnet --accept-routes=false
tailscale status
```

Port 22 is closed at the panel, so this console session is the only way in
until the tailnet link is up. A root key has to be authorized before `§50.5`
closes password auth: the template installs the key from the order form into
`/root/.ssh/authorized_keys`. If the order carried none, add one now from this
console — after the bootstrap, key auth is the only way to log in.

### 50.5 Copy the bootstrap over the tailnet and run it

From a laptop on the tailnet:

```sh
cd /srv/git/github.com/smores56/homelab-platform/main
git fetch origin && git checkout origin/main
tar -C provision -cf - edge | ssh root@smoresnet 'tar -C /root -xf -'
ssh root@smoresnet
```

Then on the box:

```sh
SMORTRESS_FQDN=smortress.stonecat-jazz.ts.net \
EDGE_ACME_EMAIL=… \
EDGE_HOST_KEY=/root/edge-host-key \
  /root/edge/bootstrap.sh
```

The join is skipped because `§50.4` already did it. `EDGE_HOST_KEY` is the key
from the recovery kit; copy it next to the tree first (`scp`), and omit the
variable to let the box generate a fresh one. `verify.sh` runs at the end; every
line must read `ok`.

### 50.6 Declare the Serve routes on smortress

They ship with the image that carries #725, so deploy it first, then:

```sh
sudo firewall-cmd --reload
sudo systemctl restart smortress-tailscale-serve.service
tailscale serve status
```

Expected: the previous routes unchanged, plus 8446 → `http://127.0.0.1:2283`
and 8447 → `http://127.0.0.1:8083`. Confirm the pair from the edge:

```sh
ssh root@smoresnet EXPECT_UPSTREAM=1 /root/edge/verify.sh
```

That run must be green before `§50.8`; the plain bootstrap run skips the
upstream checks because it predates this step.

### 50.7 Prove it before touching the zone

The names still resolve to the cloud edge here, so the public probe cannot run
and no certificate can exist. What can be proven is the pair:

```sh
ssh root@smoresnet EXPECT_UPSTREAM=1 /root/edge/verify.sh
```

Every line must read `ok`: the firewall shape, both Serve ports answering, the
upstream certificate verifying, and this box being unable to reach smortress on
443 (the ACL deny list's runtime proof).

### 50.8 The cutover (after #709's gate)

Prove the host copy is the authoritative library first; a difference here means
the cutover would serve a different Immich:

```sh
CLUSTER_URL=https://photos.sammohr.dev CLUSTER_API_KEY=... \
HOST_URL=https://smortress.stonecat-jazz.ts.net HOST_API_KEY=... \
  scripts/compare-photos-origin.sh
```

Both counts must match, and the usage within `EDGE_USAGE_DELTA` if you allow
one. Then record 30 days of `photos` + `opds` transfer from Cloudflare's analytics;
if it is a meaningful fraction of 10 TB, stop and size the plan instead. Also
enable the panel firewall now, with `tcp/443`, `udp/41641` and ICMP echo
(`§50.3`), or certificate issuance fails with the rest of the world.

Cloudflare refuses two records at one name and OpenTofu cannot order a destroy
before a create, so the cutover is two commits, each applied by CI
(`tofu-apply`), with no local credentials:

```sh
cd /srv/git/github.com/smores56/homelab-platform/main
git fetch origin && git checkout origin/main
$EDITOR tofu/terraform.tfvars   # cluster_hosts = [<every host but photos and opds>]
git commit -qm 'chore(tofu): take photos and opds off the cluster tunnel'
git push
```

Wait for `tofu-apply` to finish, then:

```sh
$EDITOR tofu/terraform.tfvars   # edge_ipv4 = "<vps-ipv4>"
git commit -qm 'feat(tofu): point the edge names at the VPS'
git push
```

Expected in that second plan: two grey-cloud `A` records with `ttl = 300`, and
nothing else. Between the two applies the names fall through to the wildcard
(the host tunnel behind the Access deny), which is the only window either order
has. Then, once Caddy has ordered:

```sh
scripts/verify-public-edge.sh   # all ten green, certificates included
```

That probe checks each name answers *as its application*: Immich's own HTML
shell for any path, OPDShelf's 401 challenge for any path. It cannot be a status
code alone — Immich answers 200 and OPDShelf 401 for paths that do not exist.

Rollback is the same two commits in reverse: drop `edge_ipv4` (the `A` records
go, names fall to the deny), then restore `cluster_hosts` (the CNAMEs return).

### 50.9 The rebuild drill, timed

Destroy nothing on the first attempt: reinstall the template from the panel on
the real box, then repeat `§50.2`–`§50.7` (the reinstall destroyed the node
identity, so the key is new too). The kit rows (`§5`,
`docs/core/recovery-kit.md`) must already hold the ctrl login with its 2FA
recovery codes, the edge SSH host key and Caddy's data directory. Record the
elapsed time and the panel bandwidth graph in the issue; if the rebuild is not
minutes, T2 does not move Backrest here.
