#!/usr/bin/env bash
# Static checks for the Cloudflare OpenTofu config (SDLC #581).
#
# No credentials, no API calls, no state: it reads `tofu/*.tf` as text and
# asserts the reviewed shape of the zone. Runtime behaviour (a hostname with no
# application really being blocked) is tests/access/check.sh, which needs a
# token.
#
#   tests/tofu/check.sh
# shellcheck disable=SC2016  # patterns match HCL text: ${...} is literal, not a shell expansion
set -uo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root" || exit 1

pass=0
fail=0
ok() {
  pass=$((pass + 1))
  printf 'ok   %s\n' "$1"
}
bad() {
  fail=$((fail + 1))
  printf 'FAIL %s\n' "$1"
  [[ -n ${2:-} ]] && printf '     %s\n' "${2//$'\n'/$'\n'     }"
  return 0
}

# has <description> <pattern> : pattern must appear in the whole config.
has() {
  if grep -Eq -- "$2" "$work/code.tf"; then ok "$1"; else bad "$1" "no match for /$2/ in tofu/*.tf"; fi
}
hasnt() {
  if grep -Eq -- "$2" "$work/code.tf"; then bad "$1" "matched /$2/ in tofu/*.tf"; else ok "$1"; fi
}
eq() {
  if [[ $1 == "$2" ]]; then ok "$3"; else bad "$3" "got '$1' want '$2'"; fi
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Marker comment lines are file boundaries; a match is reported with its file.
for f in tofu/*.tf; do
  printf '# %s\n' "$f"
  cat "$f"
done >"$work/all.tf"

# Comment lines are dropped for the assertions: a comment naming a retired
# resource or a deprecated argument must not read as one being present.
grep -Ev '^[[:space:]]*#' "$work/all.tf" >"$work/code.tf"

# extract <type.name> : prints the resource block with that address.
extract() {
  awk -v want="$1" '
    /^resource "/ {
      n = split($0, parts, "\"")
      inblock = (n >= 4 && parts[2] "." parts[4] == want)
    }
    inblock { print }
    inblock && /^}/ { inblock = 0 }
  ' "$work/code.tf"
}

# absent <type.name> <description> : the resource address must not be declared.
# The address is a dotted pair only in `extract`'s awk split, never in the text,
# so a regex over `tofu/*.tf` would pass whether the block is there or not.
absent() {
  if [[ -z $(extract "$1") ]]; then ok "$2"; else bad "$2" "$1 is still declared"; fi
}

command -v grep >/dev/null 2>&1 || {
  echo "missing grep" >&2
  exit 1
}

echo "== toolchain"
if command -v tofu >/dev/null 2>&1; then
  if tofu fmt -check -recursive tofu; then ok "tofu fmt -check"; else bad "tofu fmt -check" "run: tofu fmt -recursive tofu"; fi
  if (cd tofu && tofu init -backend=false -input=false >/dev/null && tofu validate >"$work/validate.log" 2>&1); then
    ok "tofu init -backend=false + validate"
  else
    bad "tofu init -backend=false + validate" "$(tail -5 "$work/validate.log")"
  fi
else
  printf 'skip tofu fmt/validate (tofu not on PATH; CI runs both)\n'
fi

echo "== default-deny"
wildcard_count=$(grep -Ec '^[[:space:]]*uri[[:space:]]*=[[:space:]]*"\*\.' "$work/code.tf")
eq "$wildcard_count" "1" "exactly one Access destination is a wildcard"

wildcard_app=$(extract cloudflare_zero_trust_access_application.wildcard)
if [[ -n $wildcard_app ]]; then ok "the wildcard destination belongs to cloudflare_zero_trust_access_application.wildcard"; else bad "wildcard Access application exists"; fi
if grep -qF 'uri  = "*.${var.domain}"' <<<"$wildcard_app"; then ok "wildcard application covers *.<zone>"; else bad "wildcard application covers *.<zone>"; fi
if grep -q 'cloudflare_zero_trust_access_policy.email.id' <<<"$wildcard_app"; then ok "wildcard application allows the owner email"; else bad "wildcard application allows the owner email"; fi
if grep -q 'cloudflare_zero_trust_access_policy.bypass.id' <<<"$wildcard_app"; then bad "wildcard application has no bypass policy"; else ok "wildcard application has no bypass policy"; fi
if grep -q 'cloudflare_zero_trust_access_policy.service_auth.id' <<<"$wildcard_app"; then bad "wildcard application grants no service-token access"; else ok "wildcard application grants no service-token access"; fi

if grep -q 'decision   = "bypass"' "$work/code.tf"; then ok "a bypass policy exists"; else bad "a bypass policy exists"; fi
bypass_uses=$(grep -c 'cloudflare_zero_trust_access_policy.bypass.id' "$work/code.tf")
eq "$bypass_uses" "1" "the bypass policy is attached to exactly one resource (the public set)"

public_app=$(extract cloudflare_zero_trust_access_application.public)
if grep -q 'for_each = local.public_apps' <<<"$public_app"; then ok "public applications iterate local.public_apps"; else bad "public applications iterate local.public_apps"; fi
for host in photos music opds ntfy; do
  if grep -qE "^[[:space:]]*\"${host}\",$" "$work/code.tf"; then ok "public application: $host"; else bad "public application: $host"; fi
done

echo "== protected applications"
for app in memory agent backrest; do
  block=$(extract "cloudflare_zero_trust_access_application.${app}")
  if [[ -z $block ]]; then
    bad "application ${app} exists"
    continue
  fi
  ok "application ${app} exists"
  if grep -q 'cloudflare_zero_trust_access_policy.email.id' <<<"$block"; then ok "${app} allows the owner email"; else bad "${app} allows the owner email"; fi
done
for app in memory agent backrest; do
  if grep -q 'cloudflare_zero_trust_access_policy.service_auth.id' <<<"$(extract "cloudflare_zero_trust_access_application.${app}")"; then
    ok "${app} accepts any valid service token"
  else
    bad "${app} accepts any valid service token"
  fi
done

# No Cloudflare SSH route (design #767 T6). SSH is tailnet-only, so the edge
# objects that carried it are gone and must stay gone: an `ssh` application, a
# dedicated token, its scoped policy, or an `ssh.<zone>` destination anywhere in
# the config would put the route back.
absent cloudflare_zero_trust_access_application.ssh "no ssh Access application is declared"
absent cloudflare_zero_trust_access_service_token.ssh "no dedicated ssh service token is declared"
absent cloudflare_zero_trust_access_policy.service_auth_ssh "no ssh service-token policy is declared"
hasnt "no ssh destination is routed" 'uri[[:space:]]*=[[:space:]]*"ssh\.\$\{var\.domain\}"'
if grep -qE '^[[:space:]]*(client_secret|client_id)[[:space:]]*=' "$work/code.tf"; then
  bad "no service-token credential is authored in the config"
else
  ok "no service-token credential is authored in the config"
fi

# The hosted Backrest reader (#707) owns recovery.sammohr.dev; the static letter
# and its Pages domain are retired.
backrest_app=$(extract cloudflare_zero_trust_access_application.backrest)
if grep -qF 'uri  = "recovery.${var.domain}"' <<<"$backrest_app"; then
  ok "backrest serves recovery.<zone>"
else
  bad "backrest serves recovery.<zone>"
fi
if grep -qE '^resource "cloudflare_(pages_domain|dns_record)" "recovery"' tofu/pages.tf; then
  bad "the Pages domain and DNS record are retired"
else
  ok "the Pages domain and DNS record are retired"
fi
if grep -q '^[[:space:]]*"backrest",$' <<<"$(extract cloudflare_zero_trust_access_application.public)"; then
  bad "backrest must not be a public bypass hostname"
else
  ok "backrest is not a public bypass hostname"
fi

# nanobot.sammohr.dev is retired in favour of agent.sammohr.dev (SDLC #583).
if [[ -n $(extract cloudflare_zero_trust_access_application.nanobot) ]]; then
  bad "no nanobot application remains"
else
  ok "no nanobot application remains"
fi

# Kanbei is a public hostname behind Access (SDLC #586). The private WARP route
# is retired: it never got a client past the edge certificate, and a public
# hostname needs no client component.
echo "== kanbei access application"
if [[ -n $(extract cloudflare_zero_trust_network_hostname_route.kanbei) ]]; then
  bad "the private kanbei hostname route is gone"
else
  ok "the private kanbei hostname route is gone"
fi
kanbei_app=$(extract cloudflare_zero_trust_access_application.kanbei)
if [[ -z $kanbei_app ]]; then
  bad "kanbei Access application exists"
else
  ok "kanbei Access application exists"
  if grep -qF 'uri  = "kanbei.${var.domain}"' <<<"$kanbei_app"; then ok "kanbei publishes kanbei.<zone>"; else bad "kanbei publishes kanbei.<zone>"; fi
  if grep -qF 'type = "public"' <<<"$kanbei_app"; then ok "kanbei destination is public"; else bad "kanbei destination is public"; fi
  if grep -q 'cloudflare_zero_trust_access_policy.email.id' <<<"$kanbei_app"; then ok "kanbei allows the owner email"; else bad "kanbei allows the owner email"; fi
  # The account service-auth decision accepts any valid token in the account
  # (the agent's included), so the app must attach exactly the owner policy.
  eq "$(grep -c 'cloudflare_zero_trust_access_policy\.' <<<"$kanbei_app")" "1" \
    "kanbei attaches exactly one Access policy"
  if grep -q 'cloudflare_zero_trust_access_policy.service_auth.id' <<<"$kanbei_app"; then
    bad "kanbei has no service-token policy"
  else
    ok "kanbei has no service-token policy"
  fi
  if grep -q 'cloudflare_zero_trust_access_policy.bypass.id' <<<"$kanbei_app"; then bad "kanbei has no bypass policy"; else ok "kanbei has no bypass policy"; fi
  if grep -qF 'prevent_destroy = true' <<<"$kanbei_app"; then ok "kanbei application is protected from destroy"; else bad "kanbei application is protected from destroy"; fi
  if grep -qF 'allow_authenticate_via_warp = true' <<<"$kanbei_app"; then ok "kanbei lets a WARP client skip the login"; else bad "kanbei lets a WARP client skip the login"; fi
fi
hasnt "kanbei has no public DNS record" '^[[:space:]]*name[[:space:]]*=[[:space:]]*"kanbei\.'
hasnt "kanbei has no tunnel ingress rule" 'kanbei[[:space:]]*=[[:space:]]*"http'
if [[ -n $(extract cloudflare_dns_record.kanbei) ]]; then
  bad "kanbei has no cloudflare_dns_record"
else
  ok "kanbei has no cloudflare_dns_record"
fi

# The operator-facing half of the same contract: the state-rm order for a
# prevent_destroy object and the service-token mint step.
if grep -qF 'state rm cloudflare_zero_trust_access_application.nanobot' docs/manual-steps.md; then
  ok "manual steps remove the nanobot state entry first"
else
  bad "manual steps remove the nanobot state entry first"
fi
if grep -qF 'kanbei.sammohr.dev' docs/manual-steps.md && grep -qiF 'service auth' docs/manual-steps.md; then
  ok "manual steps cover the Kanbei route and service token"
else
  bad "manual steps cover the Kanbei route and service token"
fi

echo "== retired hostnames"
hasnt "no llm application" 'cloudflare_zero_trust_access_application" "llm"'
hasnt "no chat application" 'cloudflare_zero_trust_access_application" "chat"'
hasnt "no llm destination" 'uri[[:space:]]*=[[:space:]]*"llm\.'
hasnt "no chat destination" 'uri[[:space:]]*=[[:space:]]*"chat\.'
hasnt "no nanobot destination" 'uri[[:space:]]*=[[:space:]]*"nanobot\.'

echo "== CAA"
caa=$(grep -cE '^[[:space:]]*type[[:space:]]*=[[:space:]]*"CAA"' "$work/code.tf")
eq "$caa" "2" "two CAA records (issue and issuewild)"
has 'CAA issue carries accounturi' 'tag[[:space:]]*=[[:space:]]*"issue"' 
has 'CAA issuewild carries accounturi' 'tag[[:space:]]*=[[:space:]]*"issuewild"'
accounturi=$(grep -c 'accounturi=\${local.acme_account_uri}' "$work/code.tf")
eq "$accounturi" "2" "both CAA records pin the ACME account"
has 'acme_account_uri derives from the account id variable' 'acme_account_uri = "\$\{trimsuffix\(var\.acme_directory, "/directory"\)\}/acme/acct/\$\{var\.acme_account_id\}"'
has 'acme_account_id is a variable' 'variable "acme_account_id"'
has 'the CAA pin is conditional on the account id' 'count[[:space:]]*=[[:space:]]*var\.acme_account_id == "" \? 0 : 1'
has 'an empty acme_account_id is valid' 'var\.acme_account_id == "" || can\(regex'

echo "== tunnels"
has 'host tunnel CNAME comes from the host tunnel variable' 'host_tunnel_cname[[:space:]]*=[[:space:]]*"\$\{var\.host_tunnel_id\}\.cfargotunnel\.com"'
wildcard_dns=$(extract cloudflare_dns_record.wildcard)
if grep -q 'content = local.host_tunnel_cname' <<<"$wildcard_dns"; then ok "wildcard DNS points at the host tunnel"; else bad "wildcard DNS points at the host tunnel"; fi
if grep -q 'proxied = true' <<<"$wildcard_dns"; then ok "wildcard DNS is proxied"; else bad "wildcard DNS is proxied"; fi
cluster_dns=$(extract cloudflare_dns_record.cluster)
if grep -q 'for_each = toset(local.cluster_hosts)' <<<"$cluster_dns"; then ok "cluster DNS follows the derived host set"; else bad "cluster DNS follows the derived host set"; fi
has 'cluster_hosts defaults to the ingress map' 'var\.cluster_hosts == null \? sort\(keys\(local\.cluster_ingress\)\) : var\.cluster_hosts'
if grep -q 'content = local.cluster_tunnel_cname' <<<"$cluster_dns"; then ok "cluster DNS points at the cluster tunnel"; else bad "cluster DNS points at the cluster tunnel"; fi
if grep -q 'condition     = var.cluster_tunnel_id != ""' <<<"$cluster_dns"; then ok "cluster DNS refuses an empty tunnel id"; else bad "cluster DNS refuses an empty tunnel id"; fi
has 'cluster_tunnel_id is a variable' 'variable "cluster_tunnel_id"'
hasnt "no tunnel UUID is authored in the config" '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'

# The cluster tunnel's hostname config lives here, not in a dashboard (SDLC #583).
echo "== cluster tunnel ingress"
cluster_cfg=$(extract cloudflare_zero_trust_tunnel_cloudflared_config.cluster)
if [[ -z $cluster_cfg ]]; then
  bad "cluster tunnel config exists"
else
  ok "cluster tunnel config exists"
  if grep -qF 'tunnel_id  = var.cluster_tunnel_id' <<<"$cluster_cfg"; then ok "cluster config targets the cluster tunnel"; else bad "cluster config targets the cluster tunnel"; fi
  if grep -qF 'count = var.cluster_tunnel_id == "" ? 0 : 1' <<<"$cluster_cfg"; then ok "cluster config tolerates a missing tunnel"; else bad "cluster config tolerates a missing tunnel"; fi
fi
for pair in 'agent=http://nanobot.tenant-apps.svc.cluster.local:80' \
            'photos=http://immich-server.immich.svc.cluster.local:2283' \
            'music=http://navidrome.navidrome.svc.cluster.local:4533' \
            'opds=http://opdshelf.opdshelf.svc.cluster.local:8083' \
            'memory=http://memory-mcp.graphiti.svc.cluster.local:8182'; do
  name=${pair%%=*}
  url=${pair#*=}
  # `tofu fmt` aligns the `=`, so match the mapping rather than one spacing.
  if grep -qE "^[[:space:]]*${name}[[:space:]]*=[[:space:]]*\"${url//./\\.}\"" "$work/code.tf"; then
    ok "$name maps to its in-cluster Service"
  else
    bad "$name maps to its in-cluster Service"
  fi
done
if grep -qF 'http_status:404' "$work/code.tf"; then ok "cluster ingress ends with a 404 catch-all"; else bad "cluster ingress ends with a 404 catch-all"; fi
if grep -qF 'contains(keys(local.cluster_ingress), host)' "$work/code.tf"; then
  ok "cluster DNS and ingress must agree"
else
  bad "cluster DNS and ingress must agree"
fi

# The SSH tunnel is gone (design #767 T6): no `ssh` DNS record, no tunnel ingress
# and no `ssh_tunnel_id` to gate them on. An id that came back would plan a route
# the tailnet already replaced, so each assertion fails on one.
echo "== ssh tunnel is gone"
absent cloudflare_dns_record.ssh 'no ssh DNS record is declared'
absent cloudflare_zero_trust_tunnel_cloudflared_config.ssh 'no ssh tunnel ingress is declared'
hasnt 'no ssh tunnel CNAME local' 'ssh_tunnel_cname'
hasnt 'ssh_tunnel_id is not a variable' 'variable "ssh_tunnel_id"'
hasnt 'no ingress hands an ssh service to a tunnel' 'service[[:space:]]*=[[:space:]]*"ssh://'
hasnt 'no cfargotunnel content is built from an ssh id' '\$\{var\.ssh_tunnel_id\}\.cfargotunnel\.com'
if [[ -f tofu/terraform.tfvars ]]; then ok "committed tfvars exists"; else bad "committed tfvars exists"; fi
for key in account_id domain email host_tunnel_id cluster_tunnel_id tailnet; do
  if grep -qE "^[[:space:]]*${key}[[:space:]]*=" tofu/terraform.tfvars 2>/dev/null; then
    ok "tfvars sets $key"
  else
    bad "tfvars sets $key"
  fi
done
if grep -qiE 'token|secret|password' tofu/terraform.tfvars 2>/dev/null; then
  bad "tfvars carries no credential"
else
  ok "tfvars carries no credential"
fi
if [[ -x scripts/tofu-cloudflare.sh ]]; then ok "zone apply wrapper is executable"; else bad "zone apply wrapper is executable"; fi
if grep -qF "sops -d --extract" scripts/tofu-cloudflare.sh 2>/dev/null; then
  ok "zone apply wrapper reads the credential from SOPS"
else
  bad "zone apply wrapper reads the credential from SOPS"
fi
if grep -qF '/var/lib/cloudflare-tofu' scripts/tofu-cloudflare.sh 2>/dev/null; then
  ok "zone apply wrapper refuses the legacy state directory"
else
  bad "zone apply wrapper refuses the legacy state directory"
fi
# The identifiers live in tofu/terraform.tfvars, and the host set follows the
# ingress map, so an apply needs no TF_VAR_ exports.
if grep -qF 'TF_VAR_cluster_hosts' docs/manual-steps.md; then
  bad "manual steps do not export cluster_hosts"
else
  ok "manual steps do not export cluster_hosts"
fi

echo "== preserved objects"
for addr in cloudflare_pages_project.recovery cloudflare_r2_bucket_cors.restic \
  cloudflare_notification_policy.tunnel_health cloudflare_notification_policy.service_token_expiry \
  cloudflare_ruleset.dav_rate_limit cloudflare_zero_trust_access_policy.email \
  cloudflare_zero_trust_access_policy.service_auth; do
  if [[ -n $(extract "$addr") ]]; then ok "preserved: $addr"; else bad "preserved: $addr"; fi
done
has 'tunnel health covers both tunnels' 'tunnel_id = compact\(\[var\.host_tunnel_id, var\.cluster_tunnel_id\]\)'
has 'rate limit still covers the three public apps' 'http\.host eq \\"music\.\$\{var\.domain\}\\".*photos.*opds'
# The receiver is excluded on purpose: a shared per-IP budget would drop a
# legitimate delivery burst, and the capability URL plus HMAC is the gate.
if grep -q 'agent-hooks' <<<"$(extract cloudflare_ruleset.dav_rate_limit)"; then
  bad "the rate-limit rule does not cover the webhook receiver"
else
  ok "the rate-limit rule does not cover the webhook receiver"
fi

echo "== state backend"
# The state lives in R2 (SDLC #622). The block has to be the S3 shim pointed at
# this account's R2 endpoint, with no credential in it, and the apply path has to
# stay a reviewed dispatch rather than an apply on push.
backend=tofu/backend.tf
if [[ -f $backend ]] && grep -qE '^[[:space:]]*backend[[:space:]]+"s3"' "$backend"; then
  ok "the state backend is the S3-compatible one"
else
  bad "the state backend is the S3-compatible one" "tofu/backend.tf"
fi
eq "$(grep -cE '^[[:space:]]*backend[[:space:]]+"' "$work/code.tf")" "1" \
  "there is exactly one backend block"
account_id=$(sed -nE 's/^[[:space:]]*account_id[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' tofu/terraform.tfvars)
if grep -qE "^[[:space:]]*s3[[:space:]]*=[[:space:]]*\"https://${account_id}\.r2\.cloudflarestorage\.com\"" "$backend"; then
  ok "the backend endpoint is this account's R2 endpoint"
else
  bad "the backend endpoint is this account's R2 endpoint" "expected https://${account_id}.r2.cloudflarestorage.com"
fi
eq "$(sed -nE 's/^[[:space:]]*bucket[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$backend")" \
  "homelab-tofu-state" "the state bucket is the reviewed one"
eq "$(sed -nE 's/^[[:space:]]*key[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$backend")" \
  "cloudflare/terraform.tfstate" "the state key names the zone's state"
for flag in skip_credentials_validation skip_region_validation skip_requesting_account_id skip_s3_checksum use_path_style; do
  if grep -qE "^[[:space:]]*${flag}[[:space:]]*=[[:space:]]*true" "$backend"; then
    ok "backend sets $flag"
  else
    bad "backend sets $flag"
  fi
done
if grep -qE '(access_key|secret_key|token)[[:space:]]*=' "$backend"; then
  bad "the backend block carries no credential" "credentials come from the environment"
else
  ok "the backend block carries no credential"
fi
if grep -qE 'encryption[[:space:]]*\{' "$work/code.tf"; then
  bad "no client-side state encryption without a key store" "R2 encrypts at rest; state holds identifiers only"
else
  ok "no client-side state encryption without a key store"
fi
# The apply path (SDLC #622): the merge is the approval, so a merge to main
# plans and applies, a destructive plan does not apply unattended, and only the
# owner may run it.
apply=.github/workflows/tofu-apply.yml
if grep -qE '^[[:space:]]*branches: \[main\]' "$apply"; then
  ok "tofu-apply runs on a merge to main"
else
  bad "tofu-apply runs on a merge to main"
fi
if grep -qE '^[[:space:]]*pull_request' "$apply"; then
  bad "the apply workflow never runs on a pull request"
else
  ok "the apply workflow never runs on a pull request"
fi
if grep -q 'workflow_dispatch' "$apply"; then ok "tofu-apply keeps an owner dispatch"; else bad "tofu-apply keeps an owner dispatch"; fi
if grep -q -- '-auto-approve' "$apply"; then
  bad "no -auto-approve in the apply workflow"
else
  ok "no -auto-approve in the apply workflow"
fi
if grep -q -- '-detailed-exitcode' "$apply" && grep -q 'apply .*tfplan' "$apply"; then
  ok "the apply workflow applies the saved plan from its own run"
else
  bad "the apply workflow applies the saved plan from its own run"
fi
if grep -q 'github.repository_owner' "$apply"; then
  ok "the apply workflow refuses actors other than the owner"
else
  bad "the apply workflow refuses actors other than the owner"
fi
if grep -qE 'must be replaced|will be destroyed' "$apply"; then
  ok "the apply workflow stops instead of applying a destructive plan"
  if grep -q "github.event_name != 'workflow_dispatch'" "$apply"; then
    ok "an owner dispatch can apply a destructive plan"
  else
    bad "an owner dispatch can apply a destructive plan"
  fi
else
  bad "the apply workflow stops instead of applying a destructive plan"
fi
if grep -q 'secrets.CLOUDFLARE_API_TOKEN' "$apply"; then
  ok "the write token lives only in the apply workflow"
else
  bad "the write token lives only in the apply workflow"
fi
# The tailscale provider configures whenever a tailscale resource is in the
# configuration, `count = 0` included, so an apply needs the OAuth client even
# while `tailnet` is empty: it travels with the Cloudflare pair in the same steps.
for name in TAILSCALE_OAUTH_CLIENT_ID TAILSCALE_OAUTH_CLIENT_SECRET; do
  if grep -qF "$name: \${{ secrets.$name }}" "$apply"; then
    ok "the apply workflow exports $name"
  else
    bad "the apply workflow exports $name"
  fi
done

# The pre-merge plan: the required check that makes the merge meaningful, with
# read-only credentials because on a pull_request the head workflow runs.
pr=.github/workflows/tofu-plan-pr.yml
if grep -qE '^[[:space:]]*pull_request:' "$pr"; then ok "the pre-merge plan runs on pull requests"; else bad "the pre-merge plan runs on pull requests"; fi
if grep -q 'environment: cloudflare-plan' "$pr"; then ok "the pre-merge plan uses the read-only environment"; else bad "the pre-merge plan uses the read-only environment"; fi
if grep -qE '^    environment: cloudflare-plan$' "$pr"; then
  ok "the pre-merge plan declares the environment on the job"
else
  bad "the pre-merge plan declares the environment on the job"
fi
if grep -qE 'environment: cloudflare$' "$pr"; then
  bad "the pre-merge plan never enters the write-token environment"
else
  ok "the pre-merge plan never enters the write-token environment"
fi
if grep -q 'secrets.CLOUDFLARE_PLAN_API_TOKEN' "$pr"; then ok "the pre-merge plan holds the read-only token"; else bad "the pre-merge plan holds the read-only token"; fi
if grep -qE 'secrets\.(CLOUDFLARE_API_TOKEN|R2_STATE_ACCESS_KEY_ID|R2_STATE_SECRET_ACCESS_KEY)\b' "$pr"; then
  bad "the pre-merge plan never holds the write credentials"
else
  ok "the pre-merge plan never holds the write credentials"
fi
# The same client the apply holds, because the provider configures before it
# reads a resource. `policy_file` has no read-only scope, so the guards are what
# bound it; scripts/check-pr-secret-boundary.sh allowlists the two names.
for name in TAILSCALE_OAUTH_CLIENT_ID TAILSCALE_OAUTH_CLIENT_SECRET; do
  if grep -qF "$name: \${{ secrets.$name }}" "$pr"; then
    ok "the pre-merge plan exports $name"
  else
    bad "the pre-merge plan exports $name"
  fi
done
if grep -q 'head.repo.full_name' "$pr"; then ok "the pre-merge plan fails closed for forks"; else bad "the pre-merge plan fails closed for forks"; fi
if grep -qE '\\?\(\\?\.github|\.github\|scripts' "$pr"; then
  ok "the pre-merge plan refuses a PR that changes CI"
else
  bad "the pre-merge plan refuses a PR that changes CI"
fi
if grep -q 'tofu-allow-exec' "$pr"; then ok "the pre-merge plan gates executable HCL on a label"; else bad "the pre-merge plan gates executable HCL on a label"; fi
if grep -qE 'ref: \$\{\{ github.event.pull_request.head.sha \}\}' "$pr"; then
  ok "the pre-merge plan plans the PR head"
else
  bad "the pre-merge plan plans the PR head"
fi

# Drift is read-only and never applies.
drift=.github/workflows/tofu-drift.yml
if grep -qE '^[[:space:]]*- cron:' "$drift"; then ok "drift detection is scheduled"; else bad "drift detection is scheduled"; fi
if grep -qE 'tofu .*apply' "$drift"; then bad "drift detection never applies"; else ok "drift detection never applies"; fi
if grep -q 'environment: cloudflare-plan' "$drift"; then ok "drift uses the read-only environment"; else bad "drift uses the read-only environment"; fi
if grep -q 'secrets.CLOUDFLARE_API_TOKEN' "$drift"; then
  bad "drift detection holds no write token"
else
  ok "drift detection holds no write token"
fi
if grep -q 'tofu-drift' "$drift"; then ok "drift detection reports through one issue"; else bad "drift detection reports through one issue"; fi
for name in TAILSCALE_OAUTH_CLIENT_ID TAILSCALE_OAUTH_CLIENT_SECRET; do
  if grep -qF "$name: \${{ secrets.$name }}" "$drift"; then
    ok "drift exports $name"
  else
    bad "drift exports $name"
  fi
done

# `|| status=$?` only assigns on failure, so every plan needs the initializer or
# a successful plan falls into the error branch and reports "exit ".
for workflow in "$apply" "$pr" "$drift"; do
  if grep -qE '^[[:space:]]*status=0$' "$workflow"; then
    ok "$workflow initialises the plan status"
  else
    bad "$workflow initialises the plan status"
  fi
done
if git ls-files | grep -q '\.tfstate'; then
  bad "no state file is tracked"
else
  ok "no state file is tracked"
fi
hasnt "no token variable" 'variable "[^"]*token'
hasnt "no API token attribute" '(api_token|api-key|apikey)[[:space:]]*='
hasnt "no bearer secret literal" 'Bearer [A-Za-z0-9]'
if grep -rniE 'cloudflare[_-]?(api[_-])?token' clusters/ | grep -q .; then
  bad "no cluster manifest carries a Cloudflare token"
else
  ok "no cluster manifest carries a Cloudflare token"
fi
if grep -rniE 'cloudflare[_-]?(api[_-])?token' clusters/ | grep -qi nanobot; then
  bad "nanobot holds no Cloudflare token"
else
  ok "nanobot holds no Cloudflare token"
fi

# The tailnet policy (design #767, T1). sshd on smortress answers the tailnet
# only, so the rules that decide who may open port 22 are code, gated on the
# tailnet name the owner supplies at cutover, with the API's own policy tests
# refusing a widening rule before an apply.
echo "== tailnet policy"
has 'the tailnet policy is a tailscale_acl resource' 'resource "tailscale_acl" "this"'
has 'the policy is gated on var.tailnet' 'count[[:space:]]*=[[:space:]]*var\.tailnet == "" \? 0 : 1'
has 'tailnet is a variable' 'variable "tailnet"'
has 'an empty tailnet is valid' 'var\.tailnet == "" \|\| can\(regex'
has 'the ACL is the jsonencode of one local' 'acl[[:space:]]*=[[:space:]]*jsonencode\(local\.tailnet_policy\)'
has 'the ACL replaces the whole policy' 'overwrite_existing_content[[:space:]]*=[[:space:]]*true'
has 'the policy pins the host it names' 'smortress = "100\.122\.171\.11"'
has 'the policy admits the owner to sshd' '"smortress:22"'
has 'the policy admits Serve traffic' '"smortress:443", "smortress:8443", "smortress:10000"'
has 'the policy admits Syncthing' '"smortress:22000"'
has 'the policy keeps the owner in one group' '"group:owner"[[:space:]]*=[[:space:]]*\[var\.email\]'
has 'the policy carries tests' 'tests[[:space:]]*=[[:space:]]*\['
has 'a test proves every admitted port reaches the owner' \
  'accept[[:space:]]*=[[:space:]]*\["smortress:22", "smortress:443", "smortress:8443", "smortress:10000", "smortress:22000"\]'
has 'a test proves a tagged device reaches none of them' \
  'deny[[:space:]]*=[[:space:]]*\["smortress:22", "smortress:443", "smortress:8443", "smortress:10000", "smortress:22000"\]'
has 'the tailscale provider is declared' 'provider "tailscale" \{\}'
has 'the tailscale provider is pinned to the 0.29 line' 'version[[:space:]]*=[[:space:]]*"~> 0\.29'
if grep -qE 'oauth_client_(id|secret)[[:space:]]*=[[:space:]]*"[^"]' "$work/code.tf"; then
  bad "no OAuth client is authored in the config" "credentials come from the environment"
else
  ok "no OAuth client is authored in the config"
fi
# The provider's attributes are environment-only, so an authored credential is
# one assignment away from being committed: assert the whole config has none.
if grep -qE '^(api_key|oauth_client_id|oauth_client_secret|identity_token)[[:space:]]*=[[:space:]]*"[^"]' "$work/code.tf"; then
  bad "no Tailscale credential is authored in the config"
else
  ok "no Tailscale credential is authored in the config"
fi
# The same assertion over every file the client could leak into: a credential in
# a tfvars, a README or a lock file is committed just the same.
leaked=$(git ls-files 'tofu/*' | while IFS= read -r f; do
  grep -qE '^(oauth_client_id|oauth_client_secret|api_key|identity_token)[[:space:]]*=[[:space:]]*"[^"]' "$f" && echo "$f"
done)
if [[ -n $leaked ]]; then
  bad "no Tailscale OAuth client is authored under tofu/" "$leaked"
else
  ok "no Tailscale OAuth client is authored under tofu/"
fi
if [[ -f tofu/.terraform.lock.hcl ]]; then
  for provider in registry.opentofu.org/cloudflare/cloudflare registry.opentofu.org/tailscale/tailscale; do
    if grep -qF "provider \"$provider\"" tofu/.terraform.lock.hcl; then
      ok "$provider is locked"
    else
      bad "$provider is locked"
    fi
  done
else
  bad "the provider lock file is committed"
fi

echo "== provider pin and workflows"
has 'provider is pinned to v5' 'version = "~> 5\.0"'
hasnt "no v4 record resource" 'resource "cloudflare_record"'
hasnt "no deprecated self_hosted_domains" 'self_hosted_domains'
if scripts/check-action-pins.sh >"$work/pins.log" 2>&1; then ok "Actions stay SHA-pinned (scripts/check-action-pins.sh)"; else bad "Actions stay SHA-pinned (scripts/check-action-pins.sh)" "$(cat "$work/pins.log")"; fi
if grep -q 'tests/tofu/check.sh' .github/workflows/ci.yml; then ok "ci.yml runs this check"; else bad "ci.yml runs this check"; fi

printf '\n%s: %d passed, %d failed\n' tofu "$pass" "$fail"
((fail == 0)) || exit 1
