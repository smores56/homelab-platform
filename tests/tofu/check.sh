#!/usr/bin/env bash
# Static checks for the Cloudflare OpenTofu config (SDLC #581).
#
# No credentials, no API calls, no state: it reads `tofu/*.tf` as text and
# asserts the reviewed shape of the zone. The live half is
# scripts/verify-public-edge.sh, which resolves the names and checks each answers
# as its own application; the token-driven Access probe retired with the Access
# objects (SDLC #833).
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

# Access is gone (SDLC #833 T1): nothing in the zone is behind the gate any
# more, so the applications and policies must not come back. Absence, not shape:
# a re-introduced block fails here rather than passing silently.
echo "== no Access objects"
hasnt "no Access application is declared" 'resource[[:space:]]+"cloudflare_zero_trust_access_application"'
hasnt "no Access policy is declared" 'resource[[:space:]]+"cloudflare_zero_trust_access_policy"'
absent cloudflare_zero_trust_access_application.wildcard 'the wildcard default-deny application is gone'
absent cloudflare_zero_trust_access_application.public 'the public bypass application set is gone'
absent cloudflare_zero_trust_access_policy.email 'the owner email policy is gone'
absent cloudflare_zero_trust_access_policy.service_auth 'the service-auth policy is gone'
absent cloudflare_zero_trust_access_policy.bypass 'the bypass policy is gone'
hasnt "local.public_apps is gone with the public set" 'local\.public_apps'

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
#
# The name has NO identity gate (design #701, re-affirmed 2026-11-20): family
# has to reach the reader with nothing set up in advance, and since #833 T1 no
# Access object is left to carry one, so the reader's own password is the only
# login.
# What makes that acceptable is the write denial at the Backrest and R2 layers,
# which the exposed surface is: `docs/core/backrest.md`.
absent cloudflare_zero_trust_access_application.backrest 'no Access application gates recovery.<zone>'
hasnt 'recovery has no application destination of its own' 'uri[[:space:]]*=[[:space:]]*"recovery\.\$\{var\.domain\}"'
# The reader left Cloudflare (T2, #725): recovery is a grey A record at the
# edge, so an Access bypass entry would gate nothing and only suggest the name
# still resolves to a proxied origin.
if grep -qE '^[[:space:]]*"recovery",$' "$work/code.tf"; then
  bad "recovery is no longer a public bypass hostname" "local.public_apps still names recovery"
else
  ok "recovery is no longer a public bypass hostname"
fi
# The static page's own objects went with it (#833 T3): the Pages project and
# the R2 browser CORS policy existed only so a browser could fetch the
# repository directly, which the reader replaced with server-side reads. Absence,
# not shape: a re-added block fails here.
hasnt "no Pages project is declared" 'resource[[:space:]]+"cloudflare_pages_project"'
hasnt "no R2 bucket CORS policy is declared" 'resource[[:space:]]+"cloudflare_r2_bucket_cors"'

# nanobot.sammohr.dev is retired in favour of agent.sammohr.dev (SDLC #583).
if [[ -n $(extract cloudflare_zero_trust_access_application.nanobot) ]]; then
  bad "no nanobot application remains"
else
  ok "no nanobot application remains"
fi

# Kanbei's Access application is deleted (#833 T1), as is the private WARP route
# it replaced. The wildcard it resolved through is gone too (#833 T2), so the
# name has no DNS path at all.
echo "== kanbei access application"
absent cloudflare_zero_trust_access_application.kanbei 'no kanbei Access application is declared'
if [[ -n $(extract cloudflare_zero_trust_network_hostname_route.kanbei) ]]; then
  bad "the private kanbei hostname route is gone"
else
  ok "the private kanbei hostname route is gone"
fi
hasnt "kanbei has no public DNS record" '^[[:space:]]*name[[:space:]]*=[[:space:]]*"kanbei\.'
hasnt "kanbei has no tunnel ingress rule" 'kanbei[[:space:]]*=[[:space:]]*"http'
if [[ -n $(extract cloudflare_dns_record.kanbei) ]]; then
  bad "kanbei has no cloudflare_dns_record"
else
  ok "kanbei has no cloudflare_dns_record"
fi

# The operator-facing half of the same contract. `prevent_destroy` is read from
# configuration, so a deleted block plans a destroy: the steps must not send the
# operator through a `state rm` for an Access object, which is what they said
# while the block was still there and what would now fail on a missing entry.
if grep -rqE 'state rm cloudflare_zero_trust_access' docs/; then
  bad "no doc sends the operator through a state rm for an Access object" \
    "$(grep -rnE 'state rm cloudflare_zero_trust_access' docs/)"
else
  ok "no doc sends the operator through a state rm for an Access object"
fi
if grep -qF 'kanbei.sammohr.dev' docs/manual-steps.md; then
  ok "manual steps still account for the Kanbei route"
else
  bad "manual steps still account for the Kanbei route"
fi
# The connector caches live on operator machines, outside every check here, so
# the manual step is the only thing that removes them.
if grep -qF '/.cloudflared' docs/manual-steps.md; then
  ok "manual steps remove the stale cloudflared connector caches"
else
  bad "manual steps remove the stale cloudflared connector caches"
fi

echo "== retired hostnames"
hasnt "no llm application" 'cloudflare_zero_trust_access_application" "llm"'
hasnt "no chat application" 'cloudflare_zero_trust_access_application" "chat"'
hasnt "no llm destination" 'uri[[:space:]]*=[[:space:]]*"llm\.'
hasnt "no chat destination" 'uri[[:space:]]*=[[:space:]]*"chat\.'
hasnt "no nanobot destination" 'uri[[:space:]]*=[[:space:]]*"nanobot\.'

echo "== CAA"
# Two unpinned records (design #842 T4): the policy names the CA and the account
# is deliberately absent, because the edge's Caddy account is disposable and a
# pin expires with it. The proxied names' CA set is Cloudflare's and is not this
# repository's to declare (docs/cloudflare.md, "CAA").
eq "$(grep -cE '^[[:space:]]*type[[:space:]]*=[[:space:]]*"CAA"' "$work/code.tf")" "2" \
  "exactly two CAA records (issue and issuewild)"
for tag in issue issuewild; do
  caa=$(extract "cloudflare_dns_record.caa_$tag")
  if [[ -z $caa ]]; then
    bad "CAA $tag record is declared"
    continue
  fi
  ok "CAA $tag record is declared"
  if grep -qF "tag   = \"$tag\"" <<<"$caa"; then ok "CAA $tag carries tag = \"$tag\""; else bad "CAA $tag carries tag = \"$tag\"" "$caa"; fi
  if grep -qF 'value = "letsencrypt.org"' <<<"$caa"; then ok "CAA $tag names letsencrypt.org"; else bad "CAA $tag names letsencrypt.org" "$caa"; fi
  if grep -qF 'flags = 0' <<<"$caa"; then ok "CAA $tag is a non-critical record"; else bad "CAA $tag is a non-critical record" "$caa"; fi
  if grep -qE '^[[:space:]]*ttl[[:space:]]*=[[:space:]]*3600' <<<"$caa"; then ok "CAA $tag sets ttl 3600"; else bad "CAA $tag sets ttl 3600" "$caa"; fi
  if grep -qE '^[[:space:]]*name[[:space:]]*=[[:space:]]*var\.domain' <<<"$caa"; then ok "CAA $tag sits at the zone apex"; else bad "CAA $tag sits at the zone apex" "$caa"; fi
  if grep -qE '^[[:space:]]*count[[:space:]]*=' <<<"$caa"; then bad "CAA $tag is unconditional" "$caa"; else ok "CAA $tag is unconditional"; fi
done
hasnt 'no CAA value pins an ACME account' 'accounturi='
hasnt 'acme_account_id is not a variable' 'variable "acme_account_id"'
hasnt 'acme_account_uri is not a local' 'acme_account_uri'

# Both tunnels are gone (SDLC #833): the wildcard CNAME that fronted the host
# tunnel, the cluster tunnel's CNAMEs and its remotely-managed ingress, and the
# ids and host sets that gated them. Absence, not shape: a re-introduced block,
# variable or local fails here rather than passing silently.
echo "== tunnels are gone"
absent cloudflare_dns_record.wildcard 'no wildcard DNS record is declared'
absent cloudflare_dns_record.cluster 'no cluster DNS record is declared'
absent cloudflare_zero_trust_tunnel_cloudflared_config.cluster 'no cluster tunnel ingress is declared'
hasnt 'host_tunnel_id is not a variable' 'variable "host_tunnel_id"'
hasnt 'cluster_tunnel_id is not a variable' 'variable "cluster_tunnel_id"'
hasnt 'cluster_hosts is not a variable' 'variable "cluster_hosts"'
hasnt 'no tunnel CNAME local is left' 'tunnel_cname'
hasnt 'the cluster ingress map is gone' 'local\.cluster_ingress'
hasnt 'no notification policy is declared' 'resource[[:space:]]+"cloudflare_notification_policy"'
hasnt "no tunnel UUID is authored in the config" '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'

# The public edge (design #725): an empty edge_ipv4 plans no record, and setting
# it creates the grey-cloud A records. The proxied CNAMEs the edge names used to
# hold are retired (SDLC #833), so no name is written by two records.
echo "== public edge DNS"
has 'edge_ipv4 is a variable' 'variable "edge_ipv4"'
has 'an empty edge_ipv4 is valid' 'var\.edge_ipv4 == "" \|\| can\(regex'
has 'the edge names are the served names' 'edge_hosts[[:space:]]*=[[:space:]]*\["photos", "opds", "recovery"\]'
has 'the edge DNS set is empty until the cutover' 'var\.edge_ipv4 == "" \? \[\] : local\.edge_hosts'
edge_dns=$(extract cloudflare_dns_record.edge)
if [[ -z $edge_dns ]]; then
  bad "edge DNS record exists"
else
  ok "edge DNS record exists"
  if grep -qF 'for_each = toset(local.edge_dns_hosts)' <<<"$edge_dns"; then ok "edge DNS follows the gated set"; else bad "edge DNS follows the gated set"; fi
  if grep -qF 'type    = "A"' <<<"$edge_dns"; then ok "edge DNS is an address record"; else bad "edge DNS is an address record"; fi
  if grep -qF 'content = var.edge_ipv4' <<<"$edge_dns"; then ok "edge DNS points at the edge address"; else bad "edge DNS points at the edge address"; fi
  if grep -qF 'proxied = false' <<<"$edge_dns"; then ok "edge DNS is grey cloud"; else bad "edge DNS is grey cloud"; fi
  if grep -qE 'ttl[[:space:]]*=[[:space:]]*300' <<<"$edge_dns"; then ok "edge DNS carries an explicit TTL"; else bad "edge DNS carries an explicit TTL"; fi
  if grep -qE 'ttl[[:space:]]*=[[:space:]]*1$' <<<"$edge_dns"; then
    bad "edge DNS does not use the proxied-record TTL" "ttl = 1 is only legal on a proxied record"
  else
    ok "edge DNS does not use the proxied-record TTL"
  fi
  if grep -qF 'condition     = alltrue([for host in local.edge_only_hosts : contains(local.edge_hosts, host)])' <<<"$edge_dns"; then
    ok "edge DNS asserts the edge-only names are among the served names"
  else
    bad "edge DNS asserts the edge-only names are among the served names"
  fi
fi

# The agent UI's Service VIP (design #834) is the one address that Tailscale
# computes. A specific record overrides `*.<zone>`, so each name has to be grey
# cloud with an explicit TTL: a proxied record over a tailnet address has no
# origin Cloudflare can reach.
#
# Both names (task #847) are that record with a different label, because Caddy
# routes by SNI behind one Service. The per-name loop is what keeps that
# property: a second address, a proxied record or an ungated one fails here.
for name in assistant agent; do
  dns=$(extract "cloudflare_dns_record.$name")
  if [[ -z $dns ]]; then
    bad "$name DNS record exists"
    continue
  fi
  ok "$name DNS record exists"
  if grep -qF "name    = \"$name.\${var.domain}\"" <<<"$dns"; then
    ok "$name DNS publishes $name.<zone>"
  else
    bad "$name DNS publishes $name.<zone>"
  fi
  if grep -qF 'type    = "A"' <<<"$dns"; then ok "$name DNS is an address record"; else bad "$name DNS is an address record"; fi
  if grep -qF 'content = tailscale_service.agent_ui[0].addrs[0]' <<<"$dns"; then
    ok "$name DNS points at the Service's computed address"
  else
    bad "$name DNS points at the Service's computed address"
  fi
  if grep -qF 'proxied = false' <<<"$dns"; then ok "$name DNS is grey cloud"; else bad "$name DNS is grey cloud"; fi
  if grep -qE 'ttl[[:space:]]*=[[:space:]]*300' <<<"$dns"; then ok "$name DNS carries an explicit TTL"; else bad "$name DNS carries an explicit TTL"; fi
  if grep -qE 'count[[:space:]]*=[[:space:]]*var\.tailnet == "" \? 0 : 1' <<<"$dns"; then
    ok "$name DNS is gated on var.tailnet"
  else
    bad "$name DNS is gated on var.tailnet"
  fi
done
# One VIP answers both names, which is what lets one grant and one set of deny
# tests cover them. A record of its own would need its own destination.
eq "$(grep -c 'content = tailscale_service.agent_ui\[0\].addrs\[0\]' "$work/code.tf")" "2" \
  "both names answer with the one Service VIP"

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
for key in account_id domain tailscale_login edge_ipv4 tailnet; do
  if grep -qE "^[[:space:]]*${key}[[:space:]]*=" tofu/terraform.tfvars 2>/dev/null; then
    ok "tfvars sets $key"
  else
    bad "tfvars sets $key"
  fi
done
# The tunnel ids, the cluster host set and the alert recipient went with the
# tunnels and the notification policies they fed (SDLC #833).
for key in email host_tunnel_id cluster_tunnel_id cluster_hosts; do
  if grep -qE "^[[:space:]]*${key}[[:space:]]*=" tofu/terraform.tfvars 2>/dev/null; then
    bad "tfvars no longer sets $key"
  else
    ok "tfvars no longer sets $key"
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
# The identifiers live in tofu/terraform.tfvars, so an apply needs no TF_VAR_
# exports.
if grep -qF 'TF_VAR_cluster_hosts' docs/manual-steps.md; then
  bad "manual steps do not export cluster_hosts"
else
  ok "manual steps do not export cluster_hosts"
fi

echo "== preserved objects"
if [[ -n $(extract cloudflare_ruleset.dav_rate_limit) ]]; then
  ok "preserved: cloudflare_ruleset.dav_rate_limit"
else
  bad "preserved: cloudflare_ruleset.dav_rate_limit"
fi
# The zone plan allows exactly one http_ratelimit rule and the reader's login
# takes it, so the media rule is gone rather than relocated or kept beside it.
# The cost of losing it is recorded as a residual in docs/core/backrest.md, and
# the assertions below pin both halves: absence here, the record there.
hasnt 'no rate-limit rule covers the media hosts' 'http\.host eq \\"music\.\$\{var\.domain\}\\".*photos.*opds'
hasnt 'no media host survives in the ruleset expression' 'http\.host eq \\"(photos|music|opds)\.\$\{var\.domain\}\\"'
# The receiver is excluded on purpose: a shared per-IP budget would drop a
# legitimate delivery burst, and the capability URL plus HMAC is the gate.
if grep -q 'agent-hooks' <<<"$(extract cloudflare_ruleset.dav_rate_limit)"; then
  bad "the rate-limit rule does not cover the webhook receiver"
else
  ok "the rate-limit rule does not cover the webhook receiver"
fi

# The reader is public, but it is no longer on Cloudflare: its login budget is
# enforced by the guard on the VPS, where no rate-limit phase can apply. The
# zone's single slot is therefore empty on purpose, and the assertions pin that
# rather than a rule that would silently stop matching.
echo "== the rate-limit slot is empty"
rl=$(extract cloudflare_ruleset.dav_rate_limit)
if [[ -n $rl ]]; then
  ok "the rate-limit ruleset still exists"
else
  bad "the rate-limit ruleset still exists"
fi
eq "$(grep -c 'ratelimit = {' <<<"$rl")" "0" "no rule holds the zone's one rate-limit slot"
if grep -q 'v1\\.Authentication/Login' <<<"$rl"; then
  bad "no rule targets a name Cloudflare does not proxy"
else
  ok "no rule targets a name Cloudflare does not proxy"
fi
if grep -qF 'rules = []' tofu/rate-limit.tf; then
  ok "the empty slot is explicit"
else
  bad "the empty slot is explicit"
fi
if grep -q 'guard' tofu/rate-limit.tf; then
  ok "the empty slot names where the budget went"
else
  bad "the empty slot names where the budget went"
fi

# Dropping the media rule is a real loss of an edge control, so the decision and
# its trigger for revisiting have to be written down where the rationale lives.
echo "== the dropped media rule is recorded as a residual"
residual=$(awk '/^### The single rate-limit slot/ { f = 1 } f && /^## / { f = 0 } f' docs/core/backrest.md)
if [[ -n $residual ]]; then
  ok "backrest.md records the dropped media rule"
else
  bad "backrest.md records the dropped media rule" "expected a '### The single rate-limit slot' section"
fi
media_hosts=0
for host in photos music opds; do [[ $residual == *"$host"* ]] && media_hosts=$((media_hosts + 1)); done
eq "$media_hosts" "3" "the residual names every host the media rule covered"
if grep -qiF 'bandwidth' <<<"$residual"; then
  ok "the residual states the cost in bandwidth"
else
  bad "the residual states the cost in bandwidth"
fi
if grep -qiE 'observed abuse' <<<"$residual"; then
  ok "the residual names observed abuse as the revisit trigger"
else
  bad "the residual names observed abuse as the revisit trigger"
fi
if grep -qF 'two `http_ratelimit` rules' docs/cloudflare.md; then
  bad "cloudflare.md no longer claims two rate-limit rules"
else
  ok "cloudflare.md no longer claims two rate-limit rules"
fi

# The same contract in prose: the deployed model is password-only, and the
# control that replaced the gate is write denial, not the gate.
echo "== recovery access model in the docs"
if grep -qiE 'no (Cloudflare )?Access gate|has no Access gate' docs/core/backrest.md; then
  ok "backrest.md states the reader has no Access gate"
else
  bad "backrest.md states the reader has no Access gate"
fi
if grep -qiE 'write RPCs? (are |is )?denied' docs/core/backrest.md; then
  ok "backrest.md carries the write-denial safety argument"
else
  bad "backrest.md carries the write-denial safety argument"
fi
if grep -qE '^[[:space:]]*\| `recovery\.sammohr\.dev` \|.*password' docs/cloudflare.md; then
  ok "cloudflare.md lists recovery in the public surface, password-only"
else
  bad "cloudflare.md lists recovery in the public surface, password-only" \
    "expected a public-surface table row for recovery.sammohr.dev that names its password"
fi
if grep -rniE 'access-protected' docs/ | grep -qi backrest; then
  bad "no doc calls the reader Access-protected" "$(grep -rniE 'access-protected' docs/ | grep -i backrest)"
else
  ok "no doc calls the reader Access-protected"
fi
if grep -qF '`prevent_destroy` is read from' docs/cloudflare.md; then
  ok "cloudflare.md states prevent_destroy is read from configuration"
else
  bad "cloudflare.md states prevent_destroy is read from configuration"
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
# The plan's own client, not the apply's (design #841 T1): the provider still
# reads TAILSCALE_OAUTH_CLIENT_*, so those two names are the environment keys,
# but the values behind them are the read-only pair in `cloudflare-plan`.
# scripts/check-pr-secret-boundary.sh allowlists exactly those two secrets.
for name in TAILSCALE_PLAN_OAUTH_CLIENT_ID TAILSCALE_PLAN_OAUTH_CLIENT_SECRET; do
  if grep -qF "secrets.$name }}" "$pr"; then
    ok "the pre-merge plan holds $name"
  else
    bad "the pre-merge plan holds $name"
  fi
done
if grep -qE 'secrets\.TAILSCALE_OAUTH_CLIENT_(ID|SECRET)' "$pr"; then
  bad "the pre-merge plan never holds the write Tailscale client"
else
  ok "the pre-merge plan never holds the write Tailscale client"
fi
# Narrowing is asked for: the provider takes local.tailscale_plan_scopes only in
# a read-only checkout, which is what tells this plan's client's four scopes
# from the apply's write set.
if grep -qF 'TF_VAR_tailscale_readonly: true' "$pr"; then
  ok "the pre-merge plan asks the provider for the read-only scope set"
else
  bad "the pre-merge plan asks the provider for the read-only scope set"
fi
# Read-only is an observation, not a contract: the job probes a write and fails
# unless it is refused, so a client minted with write scopes cannot pass. The
# probe runs before `init`, i.e. before provider code sees the credential.
if grep -qE '^[[:space:]]*# guard: read-only-probe$' "$pr"; then
  ok "the pre-merge plan carries the read-only probe"
else
  bad "the pre-merge plan carries the read-only probe"
fi
probe_line=$(grep -n '# guard: read-only-probe' "$pr" | cut -d: -f1)
init_line=$(grep -n 'tofu -chdir=tofu init' "$pr" | cut -d: -f1)
if [[ -n $probe_line && -n $init_line ]] && ((probe_line < init_line)); then
  ok "the probe runs before tofu init"
else
  bad "the probe runs before tofu init"
fi
for endpoint in 'api.cloudflare.com/client/v4/zones/$zone/dns_records' \
  'api.tailscale.com/api/v2/tailnet/-/acl'; do
  if grep -qF -- "$endpoint" "$pr"; then
    ok "the probe attempts a write to $endpoint"
  else
    bad "the probe attempts a write to $endpoint"
  fi
done
if (($(grep -cF '[[ $code == 403 ]]' "$pr") >= 2)); then
  ok "the probe fails the job unless a write answers 403"
else
  bad "the probe fails the job unless a write answers 403"
fi
if grep -qF "scope=policy_file'" "$pr"; then
  ok "the probe refuses a client that can mint the policy_file write scope"
else
  bad "the probe refuses a client that can mint the policy_file write scope"
fi
if grep -q 'head.repo.full_name' "$pr"; then ok "the pre-merge plan fails closed for forks"; else bad "the pre-merge plan fails closed for forks"; fi
if grep -qE '\\?\(\\?\.github|\.github\|scripts' "$pr"; then
  ok "the pre-merge plan refuses a PR that changes CI"
else
  bad "the pre-merge plan refuses a PR that changes CI"
fi
if grep -q 'tofu-allow-exec' "$pr"; then
  bad "the executable-HCL label is gone"
else
  ok "the executable-HCL label is gone"
fi
# Task #886: a Write collaborator labels their own PR, and on a `synchronize`
# run the sender is the pusher, so who applied a label is only knowable from the
# issue timeline. The refusal is therefore unconditional, and the trigger no
# longer carries the label events that existed to re-run it.
if grep -qE 'LABELS|github\.event\.pull_request\.labels' "$pr"; then
  bad "the guard reads no pull request labels"
else
  ok "the guard reads no pull request labels"
fi
if grep -qE '^[[:space:]]*types: \[opened, synchronize, reopened\]$' "$pr"; then
  ok "the plan no longer triggers on label events"
else
  bad "the plan no longer triggers on label events"
fi
if grep -qE '^[[:space:]]*# guard: exec-refused$' "$pr"; then
  ok "the executable-HCL guard carries its marker"
else
  bad "the executable-HCL guard carries its marker"
fi
# `data` and its type are two tokens, and HCL may break the line between them,
# so the scan reads each file whole (`-z`) rather than line by line.
scan=$(sed -nE "s/.*(grep -rlzE '[^']+' tofu\/).*/\1/p" "$pr")
if [[ -n $scan ]]; then
  ok "the executable-HCL scan reads whole files, not lines"
else
  bad "the executable-HCL scan reads whole files, not lines"
fi
for construct in local-exec remote-exec provisioner 'data[[:space:]]+"external"'; do
  if [[ $scan == *"$construct"* ]]; then
    ok "the executable-HCL scan refuses $construct"
  else
    bad "the executable-HCL scan refuses $construct"
  fi
done
# The scan is the refusal, not a gate on a condition: it has to catch the
# line-broken form and end the job.
mkdir -p "$work/exec/tofu"
printf 'data\n  "external" "x" {\n  program = ["true"]\n}\n' >"$work/exec/tofu/main.tf"
if [[ -n $scan ]] && (cd "$work/exec" && bash -c "$scan" | tr '\0' '\n' | grep -qx 'tofu/main.tf'); then
  ok "a line-broken data \"external\" is refused"
else
  bad "a line-broken data \"external\" is refused"
fi
exec_body=$(awk '/# guard: exec-refused/ { f = 1 } f { print } f && /echo "run=true"/ { exit }' "$pr")
if grep -qF 'exit 1' <<<"$exec_body" && ! grep -qE '\[\[ .*(label|allow)' <<<"$exec_body"; then
  ok "executable HCL fails the guard with no way to allow it"
else
  bad "executable HCL fails the guard with no way to allow it"
fi
# OpenTofu loads `*.tf.json` beside the HCL, where a provisioner is JSON the
# keyword grep cannot be trusted to read: the guard refuses the file outright.
if grep -qF '^tofu/.*\.tf\.json$' "$pr" && grep -qF '# guard: json-config-refused' "$pr"; then
  ok "the pre-merge plan refuses JSON config under tofu/"
else
  bad "the pre-merge plan refuses JSON config under tofu/"
fi
if grep -qE 'ref: \$\{\{ github.event.pull_request.head.sha \}\}' "$pr"; then
  ok "the pre-merge plan plans the PR head"
else
  bad "the pre-merge plan plans the PR head"
fi
# The fetch set is closed before `tofu init` can act on it (task #886): `init`
# downloads and runs every provider the config names, with the plan's
# credentials already in the environment.
if grep -qE '^[[:space:]]*# guard: provider-allowlist$' "$pr"; then
  ok "the pre-merge plan carries the provider allowlist step"
else
  bad "the pre-merge plan carries the provider allowlist step"
fi
if grep -qF 'scripts/check-tofu-providers.py tofu' "$pr"; then
  ok "the provider allowlist step runs the checker"
else
  bad "the provider allowlist step runs the checker"
fi
allow_line=$(grep -n '# guard: provider-allowlist' "$pr" | cut -d: -f1)
if [[ -n $allow_line && -n $init_line ]] && ((allow_line < init_line)); then
  ok "the provider allowlist runs before tofu init"
else
  bad "the provider allowlist runs before tofu init"
fi

# Drift is read-only and never applies.
drift=.github/workflows/tofu-drift.yml
if grep -qE '^[[:space:]]*- cron:' "$drift"; then ok "drift detection is scheduled"; else bad "drift detection is scheduled"; fi
if grep -qE 'tofu .*apply' "$drift"; then bad "drift detection never applies"; else ok "drift detection never applies"; fi
if grep -q 'environment: cloudflare-plan' "$drift"; then ok "drift uses the read-only environment"; else bad "drift uses the read-only environment"; fi
if grep -qE '^    environment: cloudflare-plan$' "$drift"; then
  ok "drift declares the read-only environment on the job"
else
  bad "drift declares the read-only environment on the job"
fi
if grep -q 'secrets.CLOUDFLARE_API_TOKEN' "$drift"; then
  bad "drift detection holds no write token"
else
  ok "drift detection holds no write token"
fi
if grep -q 'tofu-drift' "$drift"; then ok "drift detection reports through one issue"; else bad "drift detection reports through one issue"; fi
for pair in TAILSCALE_OAUTH_CLIENT_ID:TAILSCALE_PLAN_OAUTH_CLIENT_ID TAILSCALE_OAUTH_CLIENT_SECRET:TAILSCALE_PLAN_OAUTH_CLIENT_SECRET; do
  key=${pair%%:*}
  secret=${pair#*:}
  if grep -qF "$key: \${{ secrets.$secret }}" "$drift"; then
    ok "drift exports $key from the plan client"
  else
    bad "drift exports $key from the plan client"
  fi
done
if grep -qF 'TF_VAR_tailscale_readonly: true' "$drift"; then
  ok "drift asks the provider for the read-only scope set"
else
  bad "drift asks the provider for the read-only scope set"
fi

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
# The cluster tree that carried these manifests is retired, so the trees that
# remain are what the assertion covers. A grep over a path that no longer
# exists exits 2 and asserts nothing, which reads as a pass.
shipped=(apps units image ignition provision deploy images)
if grep -rniE --exclude='*.md' 'cloudflare[_-]?(api[_-])?token' "${shipped[@]}" | grep -q .; then
  bad "no shipped tree carries a Cloudflare token"
else
  ok "no shipped tree carries a Cloudflare token"
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
has 'the policy names the host by tag' '"tag:smortress:22"'
has 'the policy admits Serve traffic' '"tag:smortress:443", "tag:smortress:8443", "tag:smortress:8444", "tag:smortress:8445", "tag:smortress:8448", "tag:smortress:10000"'
has 'the policy admits Syncthing' '"tag:smortress:22000"'
has 'the device is resolved by hostname' 'hostname[[:space:]]*=[[:space:]]*"smortress"'
has 'the device carries the tag declaratively' 'resource "tailscale_device_tags" "smortress"'
has 'the device tag and the Services exist before the policy names them' \
  'depends_on[[:space:]]*=[[:space:]]*\[tailscale_device_tags\.smortress, tailscale_service\.agent_ui, tailscale_service\.opds, tailscale_service\.immich, tailscale_service\.navidrome, tailscale_service\.assistant, tailscale_service\.agent\]'
has 'the policy keeps the owner in one group' '"group:owner"[[:space:]]*=[[:space:]]*\[var\.tailscale_login\]'
has 'the tailnet login is its own variable' 'variable "tailscale_login"'
has 'the tests name the tailnet login, not the Access email' 'src[[:space:]]*=[[:space:]]*var\.tailscale_login'
has 'the host tag is owned by the owner group' '"tag:smortress"[[:space:]]*=[[:space:]]*\["group:owner"\]'
has 'the edge tag is owned by the owner group' '"tag:vps"[[:space:]]*=[[:space:]]*\["group:owner"\]'
has 'the policy admits the edge to the two Serve ports' '"tag:smortress:8446", "tag:smortress:8447"'
has 'the policy admits the owner to the edge' '"tag:vps:22"'
has 'the policy admits the deploy receiver' '"tag:smortress:8484"'
has 'the deploy tag is owned by the owner group' '"tag:deploy"[[:space:]]*=[[:space:]]*\["group:owner"\]'
has 'a test proves the deploy node reaches the receiver and the names probe its port' \
  'accept[[:space:]]*=[[:space:]]*\["tag:smortress:8484", "svc:agent-ui:443"\]'
has 'a test proves the deploy node reaches no other host port' \
  'deny[[:space:]]*=[[:space:]]*\["tag:smortress:22", "tag:smortress:443", "tag:smortress:8443", "tag:smortress:8444", "tag:smortress:8445", "tag:smortress:8448", "tag:smortress:10000", "tag:smortress:22000", "tag:smortress:8446", "tag:smortress:8447", "tag:vps:22"\]'
has 'the policy carries tests' 'tests[[:space:]]*=[[:space:]]*\['
has 'a test proves every admitted port reaches the owner' \
  'accept[[:space:]]*=[[:space:]]*\["tag:smortress:22", "tag:smortress:443", "tag:smortress:8443", "tag:smortress:8444", "tag:smortress:8445", "tag:smortress:8448", "tag:smortress:10000", "tag:smortress:22000", "tag:vps:22", "svc:agent-ui:443", "svc:opds:443", "svc:immich:443", "svc:navidrome:443", "svc:assistant:443", "svc:agent:443"\]'
has 'a test proves the owner does not reach the edge ports' \
  'deny[[:space:]]*=[[:space:]]*\["tag:smortress:8446", "tag:smortress:8447", "tag:smortress:8484"\]'
has 'a test proves the edge reaches only the two Serve ports' \
  'accept[[:space:]]*=[[:space:]]*\["tag:smortress:8446", "tag:smortress:8447"\]'
has 'a test proves a tagged device reaches none of them' \
  'deny[[:space:]]*=[[:space:]]*\["tag:smortress:22", "tag:smortress:443", "tag:smortress:8443", "tag:smortress:8444", "tag:smortress:8445", "tag:smortress:8448", "tag:smortress:10000", "tag:smortress:22000", "tag:smortress:8446", "tag:smortress:8447", "tag:vps:22", "svc:agent-ui:443", "svc:opds:443", "svc:immich:443", "svc:navidrome:443", "svc:assistant:443", "svc:agent:443"\]'
has 'a test proves the edge does not reach the Services' \
  'deny[[:space:]]*=[[:space:]]*\["tag:smortress:22", "tag:smortress:443", "tag:smortress:8443", "tag:smortress:8444", "tag:smortress:8445", "tag:smortress:8448", "tag:smortress:10000", "tag:smortress:22000", "tag:smortress:8484", "svc:agent-ui:443", "svc:opds:443", "svc:immich:443", "svc:navidrome:443", "svc:assistant:443", "svc:agent:443"\]'

# The agent UI's Service VIP (design #834). Tailscale owns the address, so it is
# a grant destination and a test destination, never an `acl`: a grant names the
# service and the port, and the auto-approver is what lets the host advertise it
# without the owner approving each advertisement by hand.
has 'the agent UI is a tailscale_service' 'resource "tailscale_service" "agent_ui"'
has 'OPDShelf is a tailscale_service of its own' 'resource "tailscale_service" "opds"'
service_block=$(extract tailscale_service.agent_ui)
if [[ -z $service_block ]]; then
  bad "the agent UI Service exists"
else
  ok "the agent UI Service exists"
  if grep -qF 'name  = "svc:agent-ui"' <<<"$service_block"; then ok "the Service is svc:agent-ui"; else bad "the Service is svc:agent-ui"; fi
  if grep -qF 'ports = ["tcp:443"]' <<<"$service_block"; then ok "the Service advertises tcp:443"; else bad "the Service advertises tcp:443"; fi
  if grep -qE 'count[[:space:]]*=[[:space:]]*var\.tailnet == "" \? 0 : 1' <<<"$service_block"; then
    ok "the Service is gated on var.tailnet"
  else
    bad "the Service is gated on var.tailnet"
  fi
fi
# The first application off the per-port scheme carries the same shape as the UI's
# Service: one gated Service on the tailnet's own address, the same 443, and an
# auto-approver so the host's advertisement needs no hand approval.
opds_block=$(extract tailscale_service.opds)
if [[ -z $opds_block ]]; then
  bad "the OPDShelf Service exists"
else
  ok "the OPDShelf Service exists"
  if grep -qF 'name  = "svc:opds"' <<<"$opds_block"; then ok "the OPDShelf Service is svc:opds"; else bad "the OPDShelf Service is svc:opds"; fi
  if grep -qF 'ports = ["tcp:443"]' <<<"$opds_block"; then ok "the OPDShelf Service advertises tcp:443"; else bad "the OPDShelf Service advertises tcp:443"; fi
  if grep -qE 'count[[:space:]]*=[[:space:]]*var\.tailnet == "" \? 0 : 1' <<<"$opds_block"; then
    ok "the OPDShelf Service is gated on var.tailnet"
  else
    bad "the OPDShelf Service is gated on var.tailnet"
  fi
fi
# The four core apps that followed the catalogue off the per-port scheme carry
# the same shape: one gated Service per application, on the same 443.
for spec in 'immich:Immich' 'navidrome:Navidrome' \
  'assistant:personal web UI' 'agent:general web UI'; do
  address=${spec%%:*}
  label=${spec#*:}
  service=svc:$address
  core_block=$(extract "tailscale_service.$address")
  if [[ -z $core_block ]]; then
    bad "the $label Service exists"
  else
    ok "the $label Service exists"
    if grep -qF "name  = \"$service\"" <<<"$core_block"; then ok "the $label Service is $service"; else bad "the $label Service is $service"; fi
    if grep -qF 'ports = ["tcp:443"]' <<<"$core_block"; then ok "the $label Service advertises tcp:443"; else bad "the $label Service advertises tcp:443"; fi
    if grep -qE 'count[[:space:]]*=[[:space:]]*var\.tailnet == "" \? 0 : 1' <<<"$core_block"; then
      ok "the $label Service is gated on var.tailnet"
    else
      bad "the $label Service is gated on var.tailnet"
    fi
  fi
done
has 'the policy grants the owner the Service' 'dst[[:space:]]*=[[:space:]]*\["svc:agent-ui"\]'
has 'the policy grants the owner the OPDShelf Service' 'dst[[:space:]]*=[[:space:]]*\["svc:opds"\]'
for dst in svc:immich svc:navidrome svc:assistant svc:agent; do
  has "the policy grants the owner $dst" "dst[[:space:]]*=[[:space:]]*\\[\"$dst\"\\]"
done
has 'the grant names the one service port' 'ip[[:space:]]*=[[:space:]]*\["443"\]'
has 'the grant source is the owner group' 'grants[[:space:]]*=[[:space:]]*\['
has 'the host auto-approves the Service' '"svc:agent-ui"[[:space:]]*=[[:space:]]*\["tag:smortress"\]'
has 'the host auto-approves the OPDShelf Service' '"svc:opds"[[:space:]]*=[[:space:]]*\["tag:smortress"\]'
for dst in svc:immich svc:navidrome svc:assistant svc:agent; do
  has "the host auto-approves $dst" "\"$dst\"[[:space:]]*=[[:space:]]*\\[\"tag:smortress\"\\]"
done
has 'the auto-approver is declared under services' 'autoApprovers[[:space:]]*=[[:space:]]*\{'
# Both UI names ride one Service, so one grant per admitted source covers them:
# the destination is the service and the port, never the name. Seven grants are
# the whole admitted set -- the owner's on each of the six Services (#834, the
# catalogue's and the four core apps') and the CI names probe's on the UI (#848)
# -- so an eighth, a second port on any, or a probe grant on an application
# Service, is a widening nobody decided.
grants=$(awk '/^    grants = \[/ { f = 1 } f { print } f && /^    \]/ { exit }' "$work/code.tf")
if [[ -z $grants ]]; then
  bad "the grants list is declared"
else
  ok "the grants list is declared"
  eq "$(grep -cE '^        src = ' <<<"$grants")" "7" 'the Services are granted to exactly seven sources'
  eq "$(grep -cF 'src = ["group:owner"]' <<<"$grants")" "6" 'the owner reaches all six Services'
  if grep -qF 'src = ["tag:deploy"]' <<<"$grants"; then ok 'the names probe is the seventh'; else bad 'the names probe is the seventh'; fi
  eq "$(grep -cF 'ip  = ["443"]' <<<"$grants")" "7" 'every grant names the one Service port'
fi
# Two accepts and two denies per Service: the owner and (for the UI) the probe
# reach the port, the edge (tag:vps) and a device in no group (tag:untrusted) do
# not. A further entry would be a destination no other test keeps out.
eq "$(grep -cF -- '"svc:agent-ui:443"' "$work/code.tf")" "4" \
  "the UI Service port is two accepts and two denies in the tests"
# OPDShelf and the four core apps have no probe: one accept each, the owner's,
# and the same two denies.
eq "$(grep -cF -- '"svc:opds:443"' "$work/code.tf")" "3" \
  "the OPDShelf Service port is one accept and two denies in the tests"
for dst in svc:immich svc:navidrome svc:assistant svc:agent; do
  eq "$(grep -cF -- "\"$dst:443\"" "$work/code.tf")" "3" \
    "the $dst Service port is one accept and two denies in the tests"
done
# The provider is declared with an explicit scope list (design #841 T1): a plan
# asks its read-only client for exactly the four read scopes, so the token it
# mints cannot save a policy, delete a device or rewrite a Service, and a client
# granted less fails the plan at configure time instead of widening it.
has 'the tailscale provider declares explicit scopes' \
  'scopes[[:space:]]*=[[:space:]]*var\.tailscale_readonly \? local\.tailscale_plan_scopes : null'
has 'the read-only switch is a variable' 'variable "tailscale_readonly"'
for scope in 'policy_file:read' 'devices:core:read' 'devices:posture_attributes:read' 'services:read'; do
  has "the plan scope set names $scope" "\"$scope\""
done
hasnt 'the plan scope set asks for no write scope' \
  '"(policy_file|services|devices:core|devices:posture_attributes)",'
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

# The fetch set, asserted statically (task #886). `tofu init` downloads every
# provider the config names and runs it at plan time with the plan's credentials,
# so the committed lock file is the allowlist and no `module` may name a remote
# source. The fixtures are what keep the checker from passing everything.
echo "== provider and module allowlist"
providers=scripts/check-tofu-providers.py
if [[ ! -x $providers ]]; then
  bad "the provider allowlist checker is executable" "chmod +x $providers"
fi

# fixture <name>: an empty config directory carrying the committed lock file.
fixture() {
  mkdir -p "$work/$1"
  cp tofu/.terraform.lock.hcl "$work/$1/"
}

if "$providers" tofu >"$work/providers.log" 2>&1; then
  ok "the committed config declares only locked providers and local modules"
else
  bad "the committed config declares only locked providers and local modules" "$(cat "$work/providers.log")"
fi

fixture added
cat >"$work/added/main.tf" <<'EOF'
terraform {
  required_providers {
    cloudflare = { source = "cloudflare/cloudflare" }
    aws        = { source = "hashicorp/aws" }
  }
}
EOF
if "$providers" "$work/added" >"$work/added.log" 2>&1; then
  bad "the checker refuses a provider the lock file does not name"
else
  ok "the checker refuses a provider the lock file does not name"
fi
if grep -q 'hashicorp/aws' "$work/added.log"; then
  ok "the refusal names the added provider"
else
  bad "the refusal names the added provider" "$(cat "$work/added.log")"
fi

fixture remote
cat >"$work/remote/main.tf" <<'EOF'
module "vpc" {
  source = "registry.opentofu.org/terraform-aws-modules/vpc/aws"
}
EOF
if "$providers" "$work/remote" >"$work/remote.log" 2>&1; then
  bad "the checker refuses a remote module source"
else
  ok "the checker refuses a remote module source"
fi
if grep -q 'terraform-aws-modules/vpc/aws' "$work/remote.log"; then
  ok "the refusal names the remote module"
else
  bad "the refusal names the remote module" "$(cat "$work/remote.log")"
fi

fixture local
cat >"$work/local/main.tf" <<'EOF'
module "x" {
  source = "./modules/x"
}
EOF
mkdir -p "$work/local/modules/x"
if "$providers" "$work/local" >"$work/local.log" 2>&1; then
  ok "the checker allows a local module source"
else
  bad "the checker allows a local module source" "$(cat "$work/local.log")"
fi

# A missing lock file is not an empty allowlist: it fails closed rather than
# passing every declaration.
fixture nolock
rm -f "$work/nolock/.terraform.lock.hcl"
if "$providers" "$work/nolock" >"$work/nolock.log" 2>&1; then
  bad "the checker fails closed without a lock file"
else
  ok "the checker fails closed without a lock file"
fi

echo "== provider pin and workflows"
has 'provider is pinned to v5' 'version = "~> 5\.0"'
hasnt "no v4 record resource" 'resource "cloudflare_record"'
hasnt "no deprecated self_hosted_domains" 'self_hosted_domains'
if scripts/check-action-pins.sh >"$work/pins.log" 2>&1; then ok "Actions stay SHA-pinned (scripts/check-action-pins.sh)"; else bad "Actions stay SHA-pinned (scripts/check-action-pins.sh)" "$(cat "$work/pins.log")"; fi
if grep -q 'check-all.sh --only tofu-check' .github/workflows/ci.yml; then ok "ci.yml runs this check"; else bad "ci.yml runs this check"; fi

printf '\n%s: %d passed, %d failed\n' tofu "$pass" "$fail"
((fail == 0)) || exit 1
