#!/usr/bin/env bats
# bats file_tags=tofu
# Static checks for the Cloudflare OpenTofu config (SDLC #581).
#
# No credentials, no API calls, no state: it reads `tofu/*.tf` as text and
# asserts the reviewed shape of the zone. The live half is
# scripts/verify-public-edge.sh, which resolves the names and checks each answers
# as its own application; the token-driven Access probe retired with the Access
# objects (SDLC #833).
#
#   bats tests/tofu/check.bats
#
# The shell suite this replaced ran every assertion in one process against one
# assembled copy of the config; here each assertion is its own test. That copy is
# still assembled once per file -- bats re-runs a file's top level in every test
# process, so building it there would rebuild it 303 times -- and every test only
# reads it.
load ../helpers

apply=.github/workflows/tofu-apply.yml
plan_pr=.github/workflows/tofu-plan-pr.yml
drift=.github/workflows/tofu-drift.yml
backend=tofu/backend.tf
providers=scripts/check-tofu-providers.py

setup_file() {
    # Marker comment lines are file boundaries; a match is reported with its file.
    for f in tofu/*.tf; do
        printf '# %s\n' "$f"
        cat "$f"
    done >"$BATS_FILE_TMPDIR/all.tf"
    # Comment lines are dropped for the assertions: a comment naming a retired
    # resource or a deprecated argument must not read as one being present.
    grep -Ev '^[[:space:]]*#' "$BATS_FILE_TMPDIR/all.tf" >"$BATS_FILE_TMPDIR/code.tf"
    # `tofu init` fills the provider schema cache that `tofu validate` reads. It
    # is a bootstrap, not an assertion, so it runs once here; the verdict on the
    # init-plus-validate pair is the toolchain check's to make.
    if command -v tofu >/dev/null 2>&1; then
        (cd tofu && tofu init -backend=false -input=false >/dev/null 2>&1) || true
    fi
}

# code: the comment-free copy of every tofu/*.tf.
code() { printf '%s' "$BATS_FILE_TMPDIR/code.tf"; }

# has <pattern>: the pattern must appear in the whole config.
has() {
    grep -Eq -- "$1" "$BATS_FILE_TMPDIR/code.tf" && return 0
    printf 'no match for /%s/ in tofu/*.tf\n' "$1" >&2
    return 1
}

# hasnt <pattern>: the pattern must not appear in the whole config.
hasnt() {
    grep -Eq -- "$1" "$BATS_FILE_TMPDIR/code.tf" || return 0
    printf 'matched /%s/ in tofu/*.tf\n' "$1" >&2
    return 1
}

# count <pattern> / count_fixed <string>: how many lines of the config match.
count() { grep -cE -- "$1" "$BATS_FILE_TMPDIR/code.tf" || :; }
count_fixed() { grep -cF -- "$1" "$BATS_FILE_TMPDIR/code.tf" || :; }

# eq <actual> <expected>: the two strings, reported when they differ.
eq() {
    [ "$1" = "$2" ] && return 0
    printf "got '%s' want '%s'\n" "$1" "$2" >&2
    return 1
}

# extract <type.name>: prints the resource block with that address.
extract() {
    awk -v want="$1" '
    /^resource "/ {
      n = split($0, parts, "\"")
      inblock = (n >= 4 && parts[2] "." parts[4] == want)
    }
    inblock { print }
    inblock && /^}/ { inblock = 0 }
  ' "$BATS_FILE_TMPDIR/code.tf"
}

# hasnt_block <type.name> <pattern>: the named block either is not declared or
# does not carry the pattern.
hasnt_block() {
    ! grep -Eq -- "$2" <<<"$(extract "$1")"
}

# absent <type.name>: the resource address must not be declared. The address is a
# dotted pair only in `extract`'s awk split, never in the text, so a regex over
# `tofu/*.tf` would pass whether the block is there or not.
absent() {
    [ -z "$(extract "$1")" ] && return 0
    printf '%s is still declared\n' "$1" >&2
    return 1
}

# bats resolves a registered description with `eval`, so a value carrying a
# quote, a backslash or a backtick has to survive that round trip to keep the
# assertion text the shell suite printed.
registered() { # description command...
    local escaped=${1//\\/\\\\}
    escaped=${escaped//\"/\\\"}
    escaped=${escaped//\`/\\\`}
    escaped=${escaped//\$/\\\$}
    register "$escaped" "${@:2}"
}

# --- toolchain ---------------------------------------------------------------

fmt_check() { tofu fmt -check -recursive tofu; }

init_validate() {
    (cd tofu && tofu init -backend=false -input=false >/dev/null \
        && tofu validate >"$BATS_TEST_TMPDIR/validate.log" 2>&1) && return 0
    printf 'run: tofu fmt -recursive tofu\n' >&2
    tail -5 "$BATS_TEST_TMPDIR/validate.log" >&2
    return 1
}

if command -v tofu >/dev/null 2>&1; then
    register "tofu fmt -check" fmt_check
    register "tofu init -backend=false + validate" init_validate
else
    register_skip "tofu fmt -check" "tofu is not on PATH; CI runs both"
    register_skip "tofu init -backend=false + validate" "tofu is not on PATH; CI runs both"
fi

# --- no Access objects -------------------------------------------------------
# Access is gone (SDLC #833 T1): nothing in the zone is behind the gate any more,
# so the applications and policies must not come back. Absence, not shape: a
# re-introduced block fails here rather than passing silently.

@test "no Access application is declared" {
    hasnt 'resource[[:space:]]+"cloudflare_zero_trust_access_application"'
}

@test "no Access policy is declared" {
    hasnt 'resource[[:space:]]+"cloudflare_zero_trust_access_policy"'
}

@test "the wildcard default-deny application is gone" {
    absent cloudflare_zero_trust_access_application.wildcard
}

@test "the public bypass application set is gone" {
    absent cloudflare_zero_trust_access_application.public
}

@test "the owner email policy is gone" {
    absent cloudflare_zero_trust_access_policy.email
}

@test "the service-auth policy is gone" {
    absent cloudflare_zero_trust_access_policy.service_auth
}

@test "the bypass policy is gone" {
    absent cloudflare_zero_trust_access_policy.bypass
}

@test "local.public_apps is gone with the public set" {
    hasnt 'local\.public_apps'
}

# No Cloudflare SSH route (design #767 T6). SSH is tailnet-only, so the edge
# objects that carried it are gone and must stay gone: an `ssh` application, a
# dedicated token, its scoped policy, or an `ssh.<zone>` destination anywhere in
# the config would put the route back.
@test "no ssh Access application is declared" {
    absent cloudflare_zero_trust_access_application.ssh
}

@test "no dedicated ssh service token is declared" {
    absent cloudflare_zero_trust_access_service_token.ssh
}

@test "no ssh service-token policy is declared" {
    absent cloudflare_zero_trust_access_policy.service_auth_ssh
}

@test "no ssh destination is routed" {
    hasnt 'uri[[:space:]]*=[[:space:]]*"ssh\.\$\{var\.domain\}"'
}

@test "no service-token credential is authored in the config" {
    ! grep -qE '^[[:space:]]*(client_secret|client_id)[[:space:]]*=' "$BATS_FILE_TMPDIR/code.tf"
}

# The hosted Backrest reader (#707) owns recovery.sammohr.dev; the static letter
# and its Pages domain are retired.
#
# The name has NO identity gate (design #701, re-affirmed 2026-11-20): family has
# to reach the reader with nothing set up in advance, and since #833 T1 no Access
# object is left to carry one, so the reader's own password is the only login.
# What makes that acceptable is the write denial at the Backrest and R2 layers,
# which the exposed surface is: `docs/core/backrest.md`.
@test "no Access application gates recovery.<zone>" {
    absent cloudflare_zero_trust_access_application.backrest
}

@test "recovery has no application destination of its own" {
    hasnt 'uri[[:space:]]*=[[:space:]]*"recovery\.\$\{var\.domain\}"'
}

# The reader left Cloudflare (T2, #725): recovery is a grey A record at the edge,
# so an Access bypass entry would gate nothing and only suggest the name still
# resolves to a proxied origin.
@test "recovery is no longer a public bypass hostname" {
    ! grep -qE '^[[:space:]]*"recovery",$' "$BATS_FILE_TMPDIR/code.tf"
}

# The static page's own objects went with it (#833 T3): the Pages project and the
# R2 browser CORS policy existed only so a browser could fetch the repository
# directly, which the reader replaced with server-side reads. Absence, not shape:
# a re-added block fails here.
@test "no Pages project is declared" {
    hasnt 'resource[[:space:]]+"cloudflare_pages_project"'
}

@test "no R2 bucket CORS policy is declared" {
    hasnt 'resource[[:space:]]+"cloudflare_r2_bucket_cors"'
}

# nanobot.sammohr.dev is retired in favour of agent.sammohr.dev (SDLC #583).
@test "no nanobot application remains" {
    absent cloudflare_zero_trust_access_application.nanobot
}

# --- kanbei access application ----------------------------------------------
# Kanbei's Access application is deleted (#833 T1), as is the private WARP route
# it replaced. The wildcard it resolved through is gone too (#833 T2), so the
# name has no DNS path at all.

@test "no kanbei Access application is declared" {
    absent cloudflare_zero_trust_access_application.kanbei
}

@test "the private kanbei hostname route is gone" {
    absent cloudflare_zero_trust_network_hostname_route.kanbei
}

@test "kanbei has no public DNS record" {
    hasnt '^[[:space:]]*name[[:space:]]*=[[:space:]]*"kanbei\.'
}

@test "kanbei has no tunnel ingress rule" {
    hasnt 'kanbei[[:space:]]*=[[:space:]]*"http'
}

@test "kanbei has no cloudflare_dns_record" {
    absent cloudflare_dns_record.kanbei
}

# The operator-facing half of the same contract. `prevent_destroy` is read from
# configuration, so a deleted block plans a destroy: the steps must not send the
# operator through a `state rm` for an Access object, which is what they said
# while the block was still there and what would now fail on a missing entry.
@test "no doc sends the operator through a state rm for an Access object" {
    ! grep -rqE 'state rm cloudflare_zero_trust_access' docs/
}

@test "manual steps still account for the Kanbei route" {
    grep -qF 'kanbei.sammohr.dev' docs/manual-steps.md
}

# The connector caches live on operator machines, outside every check here, so
# the manual step is the only thing that removes them.
@test "manual steps remove the stale cloudflared connector caches" {
    grep -qF '/.cloudflared' docs/manual-steps.md
}

# --- retired hostnames -------------------------------------------------------

@test "no llm application" {
    hasnt 'cloudflare_zero_trust_access_application" "llm"'
}

@test "no chat application" {
    hasnt 'cloudflare_zero_trust_access_application" "chat"'
}

@test "no llm destination" {
    hasnt 'uri[[:space:]]*=[[:space:]]*"llm\.'
}

@test "no chat destination" {
    hasnt 'uri[[:space:]]*=[[:space:]]*"chat\.'
}

@test "no nanobot destination" {
    hasnt 'uri[[:space:]]*=[[:space:]]*"nanobot\.'
}

# --- CAA ---------------------------------------------------------------------
# Two unpinned records (design #842 T4): the policy names the CA and the account
# is deliberately absent, because the edge's Caddy account is disposable and a
# pin expires with it. The proxied names' CA set is Cloudflare's and is not this
# repository's to declare (docs/cloudflare.md, "CAA").
@test "exactly two CAA records (issue and issuewild)" {
    eq "$(count '^[[:space:]]*type[[:space:]]*=[[:space:]]*"CAA"')" 2
}

caa_block() { extract "cloudflare_dns_record.caa_$1"; }
caa_declared() { [ -n "$(caa_block "$1")" ]; }
caa_carries_tag() { grep -qF "tag   = \"$1\"" <<<"$(caa_block "$1")"; }
caa_names_ca() { grep -qF 'value = "letsencrypt.org"' <<<"$(caa_block "$1")"; }
caa_noncritical() { grep -qF 'flags = 0' <<<"$(caa_block "$1")"; }
caa_ttl() { grep -qE '^[[:space:]]*ttl[[:space:]]*=[[:space:]]*3600' <<<"$(caa_block "$1")"; }
caa_apex() { grep -qE '^[[:space:]]*name[[:space:]]*=[[:space:]]*var\.domain' <<<"$(caa_block "$1")"; }
caa_unconditional() { ! grep -qE '^[[:space:]]*count[[:space:]]*=' <<<"$(caa_block "$1")"; }

# `register` owns a global named `tag` (helpers.bash), so this loop borrows no
# such name.
for caa_tag in issue issuewild; do
    registered "CAA $caa_tag record is declared" caa_declared "$caa_tag"
    registered "CAA $caa_tag carries tag = \"$caa_tag\"" caa_carries_tag "$caa_tag"
    registered "CAA $caa_tag names letsencrypt.org" caa_names_ca "$caa_tag"
    registered "CAA $caa_tag is a non-critical record" caa_noncritical "$caa_tag"
    registered "CAA $caa_tag sets ttl 3600" caa_ttl "$caa_tag"
    registered "CAA $caa_tag sits at the zone apex" caa_apex "$caa_tag"
    registered "CAA $caa_tag is unconditional" caa_unconditional "$caa_tag"
done

@test "no CAA value pins an ACME account" {
    hasnt 'accounturi='
}

@test "acme_account_id is not a variable" {
    hasnt 'variable "acme_account_id"'
}

@test "acme_account_uri is not a local" {
    hasnt 'acme_account_uri'
}

# --- tunnels are gone --------------------------------------------------------
# Both tunnels are gone (SDLC #833): the wildcard CNAME that fronted the host
# tunnel, the cluster tunnel's CNAMEs and its remotely-managed ingress, and the
# ids and host sets that gated them. Absence, not shape: a re-introduced block,
# variable or local fails here rather than passing silently.

@test "no wildcard DNS record is declared" {
    absent cloudflare_dns_record.wildcard
}

@test "no cluster DNS record is declared" {
    absent cloudflare_dns_record.cluster
}

@test "no cluster tunnel ingress is declared" {
    absent cloudflare_zero_trust_tunnel_cloudflared_config.cluster
}

@test "host_tunnel_id is not a variable" {
    hasnt 'variable "host_tunnel_id"'
}

@test "cluster_tunnel_id is not a variable" {
    hasnt 'variable "cluster_tunnel_id"'
}

@test "cluster_hosts is not a variable" {
    hasnt 'variable "cluster_hosts"'
}

@test "no tunnel CNAME local is left" {
    hasnt 'tunnel_cname'
}

@test "the cluster ingress map is gone" {
    hasnt 'local\.cluster_ingress'
}

@test "no notification policy is declared" {
    hasnt 'resource[[:space:]]+"cloudflare_notification_policy"'
}

@test "no tunnel UUID is authored in the config" {
    hasnt '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
}

# --- public edge DNS ---------------------------------------------------------
# The public edge (design #725): an empty edge_ipv4 plans no record, and setting
# it creates the grey-cloud A records. The proxied CNAMEs the edge names used to
# hold are retired (SDLC #833), so no name is written by two records.

@test "edge_ipv4 is a variable" {
    has 'variable "edge_ipv4"'
}

@test "an empty edge_ipv4 is valid" {
    has 'var\.edge_ipv4 == "" \|\| can\(regex'
}

@test "the edge names are the served names" {
    has 'edge_hosts[[:space:]]*=[[:space:]]*\["photos", "opds", "recovery"\]'
}

@test "the edge DNS set is empty until the cutover" {
    has 'var\.edge_ipv4 == "" \? \[\] : local\.edge_hosts'
}

edge_block() { extract cloudflare_dns_record.edge; }

@test "edge DNS record exists" {
    [ -n "$(edge_block)" ]
}

@test "edge DNS follows the gated set" {
    grep -qF 'for_each = toset(local.edge_dns_hosts)' <<<"$(edge_block)"
}

@test "edge DNS is an address record" {
    grep -qF 'type    = "A"' <<<"$(edge_block)"
}

@test "edge DNS points at the edge address" {
    grep -qF 'content = var.edge_ipv4' <<<"$(edge_block)"
}

@test "edge DNS is grey cloud" {
    grep -qF 'proxied = false' <<<"$(edge_block)"
}

@test "edge DNS carries an explicit TTL" {
    grep -qE 'ttl[[:space:]]*=[[:space:]]*300' <<<"$(edge_block)"
}

@test "edge DNS does not use the proxied-record TTL" {
    ! grep -qE 'ttl[[:space:]]*=[[:space:]]*1$' <<<"$(edge_block)"
}

@test "edge DNS asserts the edge-only names are among the served names" {
    grep -qF 'condition     = alltrue([for host in local.edge_only_hosts : contains(local.edge_hosts, host)])' \
        <<<"$(edge_block)"
}

# The two agent names the host's own Caddy answered (`assistant.<zone>` and
# `agent.<zone>`) went with that terminator and its Service: each application now
# answers on `<app>.<tailnet>.ts.net` through a Service of its own, and the zone
# publishes nothing for a tailnet VIP any more.
@test "no assistant A record is declared" {
    absent cloudflare_dns_record.assistant
}

@test "no agent A record is declared" {
    absent cloudflare_dns_record.agent
}

@test "no record points at a Service VIP" {
    hasnt 'tailscale_service\.[a-z_]+\[0\]\.addrs'
}

# --- ssh tunnel is gone ------------------------------------------------------
# The SSH tunnel is gone (design #767 T6): no `ssh` DNS record, no tunnel ingress
# and no `ssh_tunnel_id` to gate them on. An id that came back would plan a route
# the tailnet already replaced, so each assertion fails on one.

@test "no ssh DNS record is declared" {
    absent cloudflare_dns_record.ssh
}

@test "no ssh tunnel ingress is declared" {
    absent cloudflare_zero_trust_tunnel_cloudflared_config.ssh
}

@test "no ssh tunnel CNAME local" {
    hasnt 'ssh_tunnel_cname'
}

@test "ssh_tunnel_id is not a variable" {
    hasnt 'variable "ssh_tunnel_id"'
}

@test "no ingress hands an ssh service to a tunnel" {
    hasnt 'service[[:space:]]*=[[:space:]]*"ssh://'
}

@test "no cfargotunnel content is built from an ssh id" {
    hasnt '\$\{var\.ssh_tunnel_id\}\.cfargotunnel\.com'
}

@test "committed tfvars exists" {
    [ -f tofu/terraform.tfvars ]
}

tfvars_sets() { grep -qE "^[[:space:]]*$1[[:space:]]*=" tofu/terraform.tfvars 2>/dev/null; }
tfvars_unsets() { ! grep -qE "^[[:space:]]*$1[[:space:]]*=" tofu/terraform.tfvars 2>/dev/null; }

for key in account_id domain tailscale_login edge_ipv4 tailnet; do
    register "tfvars sets $key" tfvars_sets "$key"
done

# The tunnel ids, the cluster host set and the alert recipient went with the
# tunnels and the notification policies they fed (SDLC #833).
for key in email host_tunnel_id cluster_tunnel_id cluster_hosts; do
    register "tfvars no longer sets $key" tfvars_unsets "$key"
done

@test "tfvars carries no credential" {
    ! grep -qiE 'token|secret|password' tofu/terraform.tfvars
}

@test "zone apply wrapper is executable" {
    [ -x scripts/tofu-cloudflare.sh ]
}

@test "zone apply wrapper reads the credential from SOPS" {
    grep -qF "sops -d --extract" scripts/tofu-cloudflare.sh
}

@test "zone apply wrapper refuses the legacy state directory" {
    grep -qF '/var/lib/cloudflare-tofu' scripts/tofu-cloudflare.sh
}

# The identifiers live in tofu/terraform.tfvars, so an apply needs no TF_VAR_
# exports.
@test "manual steps do not export cluster_hosts" {
    ! grep -qF 'TF_VAR_cluster_hosts' docs/manual-steps.md
}

# --- preserved objects -------------------------------------------------------

@test "preserved: cloudflare_ruleset.dav_rate_limit" {
    [ -n "$(extract cloudflare_ruleset.dav_rate_limit)" ]
}

# The zone plan allows exactly one http_ratelimit rule and the reader's login
# takes it, so the media rule is gone rather than relocated or kept beside it.
# The cost of losing it is recorded as a residual in docs/core/backrest.md, and
# the assertions below pin both halves: absence here, the record there.
@test "no rate-limit rule covers the media hosts" {
    hasnt 'http\.host eq \\"music\.\$\{var\.domain\}\\".*photos.*opds'
}

@test "no media host survives in the ruleset expression" {
    hasnt 'http\.host eq \\"(photos|music|opds)\.\$\{var\.domain\}\\"'
}

# The receiver is excluded on purpose: a shared per-IP budget would drop a
# legitimate delivery burst, and the capability URL plus HMAC is the gate.
@test "the rate-limit rule does not cover the webhook receiver" {
    hasnt_block cloudflare_ruleset.dav_rate_limit 'agent-hooks'
}

# --- the rate-limit slot is empty -------------------------------------------
# The reader is public, but it is no longer on Cloudflare: its login budget is
# enforced by the guard on the VPS, where no rate-limit phase can apply. The
# zone's single slot is therefore empty on purpose, and the assertions pin that
# rather than a rule that would silently stop matching.

@test "the rate-limit ruleset still exists" {
    [ -n "$(extract cloudflare_ruleset.dav_rate_limit)" ]
}

@test "no rule holds the zone's one rate-limit slot" {
    eq "$(grep -c 'ratelimit = {' <<<"$(extract cloudflare_ruleset.dav_rate_limit)")" 0
}

@test "no rule targets a name Cloudflare does not proxy" {
    ! grep -q 'v1\\.Authentication/Login' <<<"$(extract cloudflare_ruleset.dav_rate_limit)"
}

@test "the empty slot is explicit" {
    grep -qF 'rules = []' tofu/rate-limit.tf
}

@test "the empty slot names where the budget went" {
    grep -q 'guard' tofu/rate-limit.tf
}

# --- the dropped media rule is recorded as a residual ------------------------
# Dropping the media rule is a real loss of an edge control, so the decision and
# its trigger for revisiting have to be written down where the rationale lives.

# residual: the "### The single rate-limit slot" section of backrest.md.
residual() {
    awk '/^### The single rate-limit slot/ { f = 1 } f && /^## / { f = 0 } f' docs/core/backrest.md
}

@test "backrest.md records the dropped media rule" {
    [ -n "$(residual)" ] && return 0
    printf "expected a '### The single rate-limit slot' section\n" >&2
    return 1
}

@test "the residual names every host the media rule covered" {
    local media_hosts=0 host
    for host in photos music opds; do
        if [[ $(residual) == *"$host"* ]]; then media_hosts=$((media_hosts + 1)); fi
    done
    eq "$media_hosts" 3
}

@test "the residual states the cost in bandwidth" {
    grep -qiF 'bandwidth' <<<"$(residual)"
}

@test "the residual names observed abuse as the revisit trigger" {
    grep -qiE 'observed abuse' <<<"$(residual)"
}

@test "cloudflare.md no longer claims two rate-limit rules" {
    ! grep -qF 'two `http_ratelimit` rules' docs/cloudflare.md
}

# --- recovery access model in the docs --------------------------------------
# The same contract in prose: the deployed model is password-only, and the
# control that replaced the gate is write denial, not the gate.

@test "backrest.md states the reader has no Access gate" {
    grep -qiE 'no (Cloudflare )?Access gate|has no Access gate' docs/core/backrest.md
}

@test "backrest.md carries the write-denial safety argument" {
    grep -qiE 'write RPCs? (are |is )?denied' docs/core/backrest.md
}

@test "cloudflare.md lists recovery in the public surface, password-only" {
    grep -qE '^[[:space:]]*\| `recovery\.sammohr\.dev` \|.*password' docs/cloudflare.md
}

@test "no doc calls the reader Access-protected" {
    ! { grep -rniE 'access-protected' docs/ | grep -qi backrest; }
}

@test "cloudflare.md states prevent_destroy is read from configuration" {
    grep -qF '`prevent_destroy` is read from' docs/cloudflare.md
}

# --- state backend -----------------------------------------------------------
# The state lives in R2 (SDLC #622). The block has to be the S3 shim pointed at
# this account's R2 endpoint, with no credential in it, and the apply path has to
# stay a reviewed dispatch rather than an apply on push.

@test "the state backend is the S3-compatible one" {
    grep -qE '^[[:space:]]*backend[[:space:]]+"s3"' "$backend"
}

@test "there is exactly one backend block" {
    eq "$(count '^[[:space:]]*backend[[:space:]]+"')" 1
}

@test "the backend endpoint is this account's R2 endpoint" {
    local account_id
    account_id=$(sed -nE 's/^[[:space:]]*account_id[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' tofu/terraform.tfvars)
    grep -qE "^[[:space:]]*s3[[:space:]]*=[[:space:]]*\"https://${account_id}\.r2\.cloudflarestorage\.com\"" "$backend" && return 0
    printf 'expected https://%s.r2.cloudflarestorage.com\n' "$account_id" >&2
    return 1
}

@test "the state bucket is the reviewed one" {
    eq "$(sed -nE 's/^[[:space:]]*bucket[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$backend")" \
        homelab-tofu-state
}

@test "the state key names the zone's state" {
    eq "$(sed -nE 's/^[[:space:]]*key[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$backend")" \
        cloudflare/terraform.tfstate
}

backend_flag() { grep -qE "^[[:space:]]*$1[[:space:]]*=[[:space:]]*true" "$backend"; }

for flag in skip_credentials_validation skip_region_validation skip_requesting_account_id \
    skip_s3_checksum use_path_style; do
    register "backend sets $flag" backend_flag "$flag"
done

@test "the backend block carries no credential" {
    ! grep -qE '(access_key|secret_key|token)[[:space:]]*=' "$backend"
}

@test "no client-side state encryption without a key store" {
    ! grep -qE 'encryption[[:space:]]*\{' "$BATS_FILE_TMPDIR/code.tf"
}

# --- the apply path ----------------------------------------------------------
# The apply path (SDLC #622): the merge is the approval, so a merge to main plans
# and applies, a destructive plan does not apply unattended, and only the owner
# may run it.

@test "tofu-apply runs on a merge to main" {
    grep -qE '^[[:space:]]*branches: \[main\]' "$apply"
}

@test "the apply workflow never runs on a pull request" {
    ! grep -qE '^[[:space:]]*pull_request' "$apply"
}

@test "tofu-apply keeps an owner dispatch" {
    grep -q 'workflow_dispatch' "$apply"
}

@test "no -auto-approve in the apply workflow" {
    ! grep -q -- '-auto-approve' "$apply"
}

@test "the apply workflow applies the saved plan from its own run" {
    grep -q -- '-detailed-exitcode' "$apply" && grep -q 'apply .*tfplan' "$apply"
}

@test "the apply workflow refuses actors other than the owner" {
    grep -q 'github.repository_owner' "$apply"
}

@test "the apply workflow stops instead of applying a destructive plan" {
    grep -qE 'must be replaced|will be destroyed' "$apply"
}

@test "an owner dispatch can apply a destructive plan" {
    grep -q "github.event_name != 'workflow_dispatch'" "$apply"
}

@test "the write token lives only in the apply workflow" {
    grep -q 'secrets.CLOUDFLARE_API_TOKEN' "$apply"
}

# The tailscale provider configures whenever a tailscale resource is in the
# configuration, `count = 0` included, so an apply needs the OAuth client even
# while `tailnet` is empty: it travels with the Cloudflare pair in the same steps.
apply_exports() { grep -qF "$1: \${{ secrets.$1 }}" "$apply"; }

for name in TAILSCALE_OAUTH_CLIENT_ID TAILSCALE_OAUTH_CLIENT_SECRET; do
    register "the apply workflow exports $name" apply_exports "$name"
done

# --- the pre-merge plan ------------------------------------------------------
# The pre-merge plan: the required check that makes the merge meaningful, with
# read-only credentials because on a pull_request the head workflow runs.

@test "the pre-merge plan runs on pull requests" {
    grep -qE '^[[:space:]]*pull_request:' "$plan_pr"
}

@test "the pre-merge plan uses the read-only environment" {
    grep -q 'environment: cloudflare-plan' "$plan_pr"
}

@test "the pre-merge plan declares the environment on the job" {
    grep -qE '^    environment: cloudflare-plan$' "$plan_pr"
}

@test "the pre-merge plan never enters the write-token environment" {
    ! grep -qE 'environment: cloudflare$' "$plan_pr"
}

@test "the pre-merge plan holds the read-only token" {
    grep -q 'secrets.CLOUDFLARE_PLAN_API_TOKEN' "$plan_pr"
}

@test "the pre-merge plan never holds the write credentials" {
    ! grep -qE 'secrets\.(CLOUDFLARE_API_TOKEN|R2_STATE_ACCESS_KEY_ID|R2_STATE_SECRET_ACCESS_KEY)\b' "$plan_pr"
}

# The plan's own client, not the apply's (design #841 T1): the provider still
# reads TAILSCALE_OAUTH_CLIENT_*, so those two names are the environment keys,
# but the values behind them are the read-only pair in `cloudflare-plan`.
# scripts/check-pr-secret-boundary.sh allowlists exactly those two secrets.
plan_holds() { grep -qF "secrets.$1 }}" "$plan_pr"; }

for name in TAILSCALE_PLAN_OAUTH_CLIENT_ID TAILSCALE_PLAN_OAUTH_CLIENT_SECRET; do
    register "the pre-merge plan holds $name" plan_holds "$name"
done

@test "the pre-merge plan never holds the write Tailscale client" {
    ! grep -qE 'secrets\.TAILSCALE_OAUTH_CLIENT_(ID|SECRET)' "$plan_pr"
}

# Narrowing is asked for: the provider takes local.tailscale_plan_scopes only in
# a read-only checkout, which is what tells this plan's client's four scopes from
# the apply's write set.
@test "the pre-merge plan asks the provider for the read-only scope set" {
    grep -qF 'TF_VAR_tailscale_readonly: true' "$plan_pr"
}

# Read-only is an observation, not a contract: the job probes a write and fails
# unless it is refused, so a client minted with write scopes cannot pass. The
# probe runs before `init`, i.e. before provider code sees the credential.
@test "the pre-merge plan carries the read-only probe" {
    grep -qE '^[[:space:]]*# guard: read-only-probe$' "$plan_pr"
}

plan_line() { grep -n -- "$1" "$plan_pr" | cut -d: -f1; }

@test "the probe runs before tofu init" {
    local probe_line init_line
    probe_line=$(plan_line '# guard: read-only-probe')
    init_line=$(plan_line 'tofu -chdir=tofu init')
    [[ -n $probe_line && -n $init_line ]] && ((probe_line < init_line))
}

probe_writes_to() { grep -qF -- "$1" "$plan_pr"; }

for endpoint in 'api.cloudflare.com/client/v4/zones/$zone/dns_records' \
    'api.tailscale.com/api/v2/tailnet/-/acl'; do
    registered "the probe attempts a write to $endpoint" probe_writes_to "$endpoint"
done

@test "the probe fails the job unless a write answers 403" {
    (($(grep -cF '[[ $code == 403 ]]' "$plan_pr") >= 2))
}

@test "the probe refuses a client that can mint the policy_file write scope" {
    grep -qF "scope=policy_file'" "$plan_pr"
}

@test "the pre-merge plan fails closed for forks" {
    grep -q 'head.repo.full_name' "$plan_pr"
}

@test "the pre-merge plan refuses a PR that changes CI" {
    grep -qE '\\?\(\\?\.github|\.github\|scripts' "$plan_pr"
}

@test "the executable-HCL label is gone" {
    ! grep -q 'tofu-allow-exec' "$plan_pr"
}

# Task #886: a Write collaborator labels their own PR, and on a `synchronize` run
# the sender is the pusher, so who applied a label is only knowable from the issue
# timeline. The refusal is therefore unconditional, and the trigger no longer
# carries the label events that existed to re-run it.
@test "the guard reads no pull request labels" {
    ! grep -qE 'LABELS|github\.event\.pull_request\.labels' "$plan_pr"
}

@test "the plan no longer triggers on label events" {
    grep -qE '^[[:space:]]*types: \[opened, synchronize, reopened\]$' "$plan_pr"
}

@test "the executable-HCL guard carries its marker" {
    grep -qE '^[[:space:]]*# guard: exec-refused$' "$plan_pr"
}

# `data` and its type are two tokens, and HCL may break the line between them, so
# the scan reads each file whole (`-z`) rather than line by line.
scan_cmd() { sed -nE "s/.*(grep -rlzE '[^']+' tofu\/).*/\1/p" "$plan_pr"; }

@test "the executable-HCL scan reads whole files, not lines" {
    [ -n "$(scan_cmd)" ]
}

scan_refuses() { [[ $(scan_cmd) == *"$1"* ]]; }

for construct in local-exec remote-exec provisioner 'data[[:space:]]+"external"'; do
    registered "the executable-HCL scan refuses $construct" scan_refuses "$construct"
done

# The scan is the refusal, not a gate on a condition: it has to catch the
# line-broken form and end the job.
@test "a line-broken data \"external\" is refused" {
    local scan
    scan=$(scan_cmd)
    mkdir -p "$BATS_TEST_TMPDIR/exec/tofu"
    printf 'data\n  "external" "x" {\n  program = ["true"]\n}\n' >"$BATS_TEST_TMPDIR/exec/tofu/main.tf"
    [ -n "$scan" ] || return 1
    (cd "$BATS_TEST_TMPDIR/exec" && bash -c "$scan" | tr '\0' '\n' | grep -qx 'tofu/main.tf')
}

@test "executable HCL fails the guard with no way to allow it" {
    local exec_body
    exec_body=$(awk '/# guard: exec-refused/ { f = 1 } f { print } f && /echo "run=true"/ { exit }' "$plan_pr")
    grep -qF 'exit 1' <<<"$exec_body" && ! grep -qE '\[\[ .*(label|allow)' <<<"$exec_body"
}

# OpenTofu loads `*.tf.json` beside the HCL, where a provisioner is JSON the
# keyword grep cannot be trusted to read: the guard refuses the file outright.
@test "the pre-merge plan refuses JSON config under tofu/" {
    grep -qF '^tofu/.*\.tf\.json$' "$plan_pr" && grep -qF '# guard: json-config-refused' "$plan_pr"
}

@test "the pre-merge plan plans the PR head" {
    grep -qE 'ref: \$\{\{ github.event.pull_request.head.sha \}\}' "$plan_pr"
}

# The fetch set is closed before `tofu init` can act on it (task #886): `init`
# downloads and runs every provider the config names, with the plan's credentials
# already in the environment.
@test "the pre-merge plan carries the provider allowlist step" {
    grep -qE '^[[:space:]]*# guard: provider-allowlist$' "$plan_pr"
}

@test "the provider allowlist step runs the checker" {
    grep -qF 'scripts/check-tofu-providers.py tofu' "$plan_pr"
}

@test "the provider allowlist runs before tofu init" {
    local allow_line init_line
    allow_line=$(plan_line '# guard: provider-allowlist')
    init_line=$(plan_line 'tofu -chdir=tofu init')
    [[ -n $allow_line && -n $init_line ]] && ((allow_line < init_line))
}

# --- drift -------------------------------------------------------------------
# Drift is read-only and never applies.

@test "drift detection is scheduled" {
    grep -qE '^[[:space:]]*- cron:' "$drift"
}

@test "drift detection never applies" {
    ! grep -qE 'tofu .*apply' "$drift"
}

@test "drift uses the read-only environment" {
    grep -q 'environment: cloudflare-plan' "$drift"
}

@test "drift declares the read-only environment on the job" {
    grep -qE '^    environment: cloudflare-plan$' "$drift"
}

@test "drift detection holds no write token" {
    ! grep -q 'secrets.CLOUDFLARE_API_TOKEN' "$drift"
}

@test "drift detection reports through one issue" {
    grep -q 'tofu-drift' "$drift"
}

drift_exports() { # key secret
    grep -qF "$1: \${{ secrets.$2 }}" "$drift"
}

for pair in TAILSCALE_OAUTH_CLIENT_ID:TAILSCALE_PLAN_OAUTH_CLIENT_ID \
    TAILSCALE_OAUTH_CLIENT_SECRET:TAILSCALE_PLAN_OAUTH_CLIENT_SECRET; do
    key=${pair%%:*}
    register "drift exports $key from the plan client" drift_exports "${pair%%:*}" "${pair#*:}"
done

@test "drift asks the provider for the read-only scope set" {
    grep -qF 'TF_VAR_tailscale_readonly: true' "$drift"
}

# `|| status=$?` only assigns on failure, so every plan needs the initializer or
# a successful plan falls into the error branch and reports "exit ".
initialises_status() { grep -qE '^[[:space:]]*status=0$' "$1"; }

for workflow in "$apply" "$plan_pr" "$drift"; do
    register "$workflow initialises the plan status" initialises_status "$workflow"
done

@test "no state file is tracked" {
    ! git ls-files | grep -q '\.tfstate'
}

@test "no token variable" {
    hasnt 'variable "[^"]*token'
}

@test "no API token attribute" {
    hasnt '(api_token|api-key|apikey)[[:space:]]*='
}

@test "no bearer secret literal" {
    hasnt 'Bearer [A-Za-z0-9]'
}

# The cluster tree that carried these manifests is retired, so the trees that
# remain are what the assertion covers. A grep over a path that no longer exists
# exits 2 and asserts nothing, which reads as a pass.
@test "no shipped tree carries a Cloudflare token" {
    ! grep -rniE --exclude='*.md' 'cloudflare[_-]?(api[_-])?token' \
        apps units image ignition provision deploy images | grep -q .
}

# --- tailnet policy ----------------------------------------------------------
# The tailnet policy (design #767, T1). sshd on smortress answers the tailnet
# only, so the rules that decide who may open port 22 are code, gated on the
# tailnet name the owner supplies at cutover, with the API's own policy tests
# refusing a widening rule before an apply.

@test "the tailnet policy is a tailscale_acl resource" {
    has 'resource "tailscale_acl" "this"'
}

@test "the policy is gated on var.tailnet" {
    has 'count[[:space:]]*=[[:space:]]*var\.tailnet == "" \? 0 : 1'
}

@test "tailnet is a variable" {
    has 'variable "tailnet"'
}

@test "an empty tailnet is valid" {
    has 'var\.tailnet == "" \|\| can\(regex'
}

@test "the ACL is the jsonencode of one local" {
    has 'acl[[:space:]]*=[[:space:]]*jsonencode\(local\.tailnet_policy\)'
}

@test "the ACL replaces the whole policy" {
    has 'overwrite_existing_content[[:space:]]*=[[:space:]]*true'
}

@test "the policy names the host by tag" {
    has '"tag:smortress:22"'
}

@test "the policy admits Serve traffic" {
    has '"tag:smortress:443", "tag:smortress:8443", "tag:smortress:8444", "tag:smortress:8445", "tag:smortress:8448", "tag:smortress:10000"'
}

@test "the policy admits Syncthing" {
    has '"tag:smortress:22000"'
}

@test "the device is resolved by hostname" {
    has 'hostname[[:space:]]*=[[:space:]]*"smortress"'
}

@test "the device carries the tag declaratively" {
    has 'resource "tailscale_device_tags" "smortress"'
}

@test "the device tag and the Services exist before the policy names them" {
    has 'depends_on[[:space:]]*=[[:space:]]*\[tailscale_device_tags\.smortress, tailscale_service\.opds, tailscale_service\.immich, tailscale_service\.navidrome, tailscale_service\.assistant, tailscale_service\.agent, tailscale_service\.sync, tailscale_service\.terminal\]'
}

@test "the policy keeps the owner in one group" {
    has '"group:owner"[[:space:]]*=[[:space:]]*\[var\.tailscale_login\]'
}

@test "the tailnet login is its own variable" {
    has 'variable "tailscale_login"'
}

@test "the tests name the tailnet login, not the Access email" {
    has 'src[[:space:]]*=[[:space:]]*var\.tailscale_login'
}

@test "the host tag is owned by the owner group" {
    has '"tag:smortress"[[:space:]]*=[[:space:]]*\["group:owner"\]'
}

@test "the edge tag is owned by the owner group" {
    has '"tag:vps"[[:space:]]*=[[:space:]]*\["group:owner"\]'
}

# The edge had a rule of its own for the two host Serve ports; it proxies the two
# Services now, and a Service destination cannot appear in an `acl`, so a rule
# that gave tag:vps a host port is a widening nobody decided.
@test "no acl rule gives the edge a host port" {
    hasnt 'tag:smortress:844[67]'
}

@test "the policy admits the owner to the edge" {
    has '"tag:vps:22"'
}

@test "the policy admits the deploy receiver" {
    has '"tag:smortress:8484"'
}

# The edge's receiver is the same program on the other host, so the CI identity
# that notifies smortress notifies the public box as well (design #939, T11).
@test "the policy admits the deploy node to the edge's receiver" {
    has 'src[[:space:]]*=[[:space:]]*\["tag:deploy"\]'
    has 'dst[[:space:]]*=[[:space:]]*\["tag:vps:8484"\]'
}

@test "the deploy tag is owned by the owner group" {
    has '"tag:deploy"[[:space:]]*=[[:space:]]*\["group:owner"\]'
}

@test "a test proves the deploy node reaches both receivers and the six Service names" {
    has 'accept[[:space:]]*=[[:space:]]*\["tag:smortress:8484", "tag:vps:8484", "svc:immich:443", "svc:navidrome:443", "svc:assistant:443", "svc:agent:443", "svc:sync:443", "svc:opds:443"\]'
}

# The edge login is the one host port on the public box that is not the receiver,
# so it staying in this list is what keeps T11's grant a widening of exactly one
# port rather than the first of several.
@test "a test proves the deploy node reaches no other host port" {
    has 'deny[[:space:]]*=[[:space:]]*\["tag:smortress:22", "tag:smortress:443", "tag:smortress:8443", "tag:smortress:8444", "tag:smortress:8445", "tag:smortress:8448", "tag:smortress:10000", "tag:smortress:22000", "tag:vps:22"\]'
}

@test "the policy carries tests" {
    has 'tests[[:space:]]*=[[:space:]]*\['
}

@test "a test proves every admitted port reaches the owner" {
    has 'accept[[:space:]]*=[[:space:]]*\["tag:smortress:22", "tag:smortress:443", "tag:smortress:8443", "tag:smortress:8444", "tag:smortress:8445", "tag:smortress:8448", "tag:smortress:10000", "tag:smortress:22000", "tag:vps:22", "svc:opds:443", "svc:immich:443", "svc:navidrome:443", "svc:assistant:443", "svc:agent:443", "svc:sync:443", "svc:terminal:443"\]'
}

@test "a test proves the owner does not reach either deploy receiver" {
    has 'deny[[:space:]]*=[[:space:]]*\["tag:smortress:8484", "tag:vps:8484"\]'
}

# Five places and no more: the grant, the deploy node's accept, the two denies
# that keep the owner and an untagged device off it, and the edge's own deny of
# every host port. A sixth line is a second port opened on the public box.
@test "the edge's receiver is granted once and denied to everyone else" {
    eq "$(count_fixed 'tag:vps:8484')" 5
}

# One test entry for the edge, and it denies: the two Service destinations come
# from the grants above and cannot be named here, so every host port and the edge
# login are the whole guard.
@test "the edge has one test, its deny of every host port" {
    eq "$(count 'src[[:space:]]*=[[:space:]]*"tag:vps"')" 1
}

@test "a test proves a tagged device reaches none of them" {
    has 'deny[[:space:]]*=[[:space:]]*\["tag:smortress:22", "tag:smortress:443", "tag:smortress:8443", "tag:smortress:8444", "tag:smortress:8445", "tag:smortress:8448", "tag:smortress:10000", "tag:smortress:22000", "tag:vps:22", "tag:vps:8484", "svc:opds:443", "svc:immich:443", "svc:navidrome:443", "svc:assistant:443", "svc:agent:443", "svc:sync:443", "svc:terminal:443", "svc:recovery:443"\]'
}

@test "a test proves the edge does not reach the other Services" {
    has 'deny[[:space:]]*=[[:space:]]*\["tag:smortress:22", "tag:smortress:443", "tag:smortress:8443", "tag:smortress:8444", "tag:smortress:8445", "tag:smortress:8448", "tag:smortress:10000", "tag:smortress:22000", "tag:smortress:8484", "tag:vps:8484", "svc:navidrome:443", "svc:assistant:443", "svc:agent:443", "svc:sync:443", "svc:terminal:443"\]'
}

# --- the Services -----------------------------------------------------------
# The agent UI's Service is gone (design #834's first Service): it fronted the
# `sammohr.dev` aliases through a Caddy that no longer exists, and the two
# applications had Services of their own before it was retired. A Service left
# behind would be a VIP with nothing advertised on it, and a policy that still
# named it would admit a destination no host answers.

@test "the agent UI Service is retired" {
    absent tailscale_service.agent_ui
}

@test "no grant reaches the retired Service" {
    hasnt 'svc:agent-ui'
}

@test "OPDShelf is a tailscale_service of its own" {
    has 'resource "tailscale_service" "opds"'
}

# The first application off the per-port scheme carries the same shape as the UI's
# Service: one gated Service on the tailnet's own address, the same 443, and an
# auto-approver so the host's advertisement needs no hand approval.
service_block() { extract "tailscale_service.$1"; }

@test "the OPDShelf Service exists" {
    [ -n "$(service_block opds)" ]
}

@test "the OPDShelf Service is svc:opds" {
    grep -qF 'name  = "svc:opds"' <<<"$(service_block opds)"
}

@test "the OPDShelf Service advertises tcp:443" {
    grep -qF 'ports = ["tcp:443"]' <<<"$(service_block opds)"
}

@test "the OPDShelf Service is gated on var.tailnet" {
    grep -qE 'count[[:space:]]*=[[:space:]]*var\.tailnet == "" \? 0 : 1' <<<"$(service_block opds)"
}

# The core apps that followed the catalogue off the per-port scheme carry the same
# shape: one gated Service per application, on the same 443. The Syncthing GUI is
# among them now that its host check is off (docs/manual-steps.md).
service_exists() { [ -n "$(service_block "$1")" ]; }
service_is() { grep -qF "name  = \"svc:$1\"" <<<"$(service_block "$1")"; }
service_advertises() { grep -qF 'ports = ["tcp:443"]' <<<"$(service_block "$1")"; }
service_gated() { grep -qE 'count[[:space:]]*=[[:space:]]*var\.tailnet == "" \? 0 : 1' <<<"$(service_block "$1")"; }

for spec in 'immich:Immich' 'navidrome:Navidrome' 'assistant:personal web UI' \
    'agent:general web UI' 'sync:Syncthing GUI' 'recovery:recovery reader'; do
    address=${spec%%:*}
    label=${spec#*:}
    register "the $label Service exists" service_exists "$address"
    register "the $label Service is svc:$address" service_is "$address"
    register "the $label Service advertises tcp:443" service_advertises "$address"
    register "the $label Service is gated on var.tailnet" service_gated "$address"
done

@test "the policy grants the owner the OPDShelf Service" {
    has 'dst[[:space:]]*=[[:space:]]*\["svc:opds"\]'
}

grant_to() { has "dst[[:space:]]*=[[:space:]]*\\[\"$1\"\\]"; }

for dst in svc:immich svc:navidrome svc:assistant svc:agent svc:sync svc:terminal; do
    register "the policy grants the owner $dst" grant_to "$dst"
done

# The reader is the edge's alone (SDLC #953): no owner grant, no probe grant, so
# its password is the only login anybody gets at it.
@test "the policy grants the edge the reader Service" {
    grant_to svc:recovery
}

@test "the owner has no grant on the reader Service" {
    eq "$(grep -cF 'dst = ["svc:recovery"]' "$BATS_FILE_TMPDIR/code.tf")" 1
}

@test "the grant names the one service port" {
    has 'ip[[:space:]]*=[[:space:]]*\["443"\]'
}

@test "the grant source is the owner group" {
    has 'grants[[:space:]]*=[[:space:]]*\['
}

@test "the host auto-approves the OPDShelf Service" {
    has '"svc:opds"[[:space:]]*=[[:space:]]*\["tag:smortress"\]'
}

auto_approves() { has "\"$1\"[[:space:]]*=[[:space:]]*\\[\"tag:smortress\"\\]"; }

for dst in svc:immich svc:navidrome svc:assistant svc:agent svc:sync svc:terminal svc:recovery; do
    register "the host auto-approves $dst" auto_approves "$dst"
done

@test "the auto-approver is declared under services" {
    has 'autoApprovers[[:space:]]*=[[:space:]]*\{'
}

# The destination is the service and the port, never the name, so a source needs
# one grant per Service it reaches. Sixteen grants are the whole admitted set --
# the owner's on seven of the eight Services (#834: the catalogue's, the four core
# apps', the Syncthing GUI's and the web terminal's), the CI names probe's on the
# same six (#848) and the public edge's on the three it proxies (#725, #953) -- so
# a seventeenth, a second port on any, or a grant no test below reads, is a
# widening nobody decided.
grants_block() {
    awk '/^    grants = \[/ { f = 1 } f { print } f && /^    \]/ { exit }' "$BATS_FILE_TMPDIR/code.tf"
}

@test "the grants list is declared" {
    [ -n "$(grants_block)" ]
}

@test "the Services are granted to exactly sixteen sources" {
    eq "$(grep -cE '^        src = ' <<<"$(grants_block)")" 16
}

@test "the owner reaches all seven Services" {
    eq "$(grep -cF 'src = ["group:owner"]' <<<"$(grants_block)")" 7
}

@test "the names probe reaches the six Service names" {
    eq "$(grep -cF 'src = ["tag:deploy"]' <<<"$(grants_block)")" 6
}

@test "the public edge reaches the three it proxies" {
    eq "$(grep -cF 'src = ["tag:vps"]' <<<"$(grants_block)")" 3
}

@test "every grant names the one Service port" {
    eq "$(grep -cF 'ip  = ["443"]' <<<"$(grants_block)")" 16
}

# No test names the retired Service at all: a destination a grant no longer
# admits has to leave the deny lists with it, or the policy save refuses a test
# for something no rule admits.
@test "no test names the retired Service port" {
    hasnt 'svc:agent-ui:443'
}

# The web terminal is the one other Service no probe reads and the edge does not
# proxy (design #954): one accept, the owner's, and the two denies.
@test "the terminal Service port is one accept and two denies in the tests" {
    eq "$(count_fixed '"svc:terminal:443"')" 3
}

# The reader's Service port is granted to the edge and to nothing a test accepts,
# so the one entry naming it is the untagged device's deny. It is not in the
# edge's own deny either: a deny test may not name a destination its source is
# granted.
@test "the reader Service port is one deny and no accept in the tests" {
    eq "$(count_fixed '"svc:recovery:443"')" 1
}

# The catalogue and Immich keep their grant to the edge, which is why the edge's
# deny test stops naming them: two accepts (the owner's and tag:deploy's) and one
# deny, for the device in no group. A grants entry is not a test entry, so the
# edge's own grant appears nowhere here.
service_port_twice() { eq "$(count_fixed "\"$1:443\"")" 3; }
service_port_four() { eq "$(count_fixed "\"$1:443\"")" 4; }

for dst in svc:opds svc:immich; do
    register "the $dst Service port is two accepts and one deny in the tests" \
        service_port_twice "$dst"
done

# The four the edge does not proxy carry only the owner and the probe: two accepts
# and the same two denies.
for dst in svc:navidrome svc:assistant svc:agent svc:sync; do
    register "the $dst Service port is two accepts and two denies in the tests" \
        service_port_four "$dst"
done

# --- the tailscale provider --------------------------------------------------
# The provider is declared with an explicit scope list (design #841 T1): a plan
# asks its read-only client for exactly the four read scopes, so the token it
# mints cannot save a policy, delete a device or rewrite a Service, and a client
# granted less fails the plan at configure time instead of widening it.

@test "the tailscale provider declares explicit scopes" {
    has 'scopes[[:space:]]*=[[:space:]]*var\.tailscale_readonly \? local\.tailscale_plan_scopes : null'
}

@test "the read-only switch is a variable" {
    has 'variable "tailscale_readonly"'
}

plan_scope() { has "\"$1\""; }

for scope in 'policy_file:read' 'devices:core:read' 'devices:posture_attributes:read' 'services:read'; do
    register "the plan scope set names $scope" plan_scope "$scope"
done

@test "the plan scope set asks for no write scope" {
    hasnt '"(policy_file|services|devices:core|devices:posture_attributes)",'
}

@test "the tailscale provider is pinned to the 0.29 line" {
    has 'version[[:space:]]*=[[:space:]]*"~> 0\.29'
}

@test "no OAuth client is authored in the config" {
    ! grep -qE 'oauth_client_(id|secret)[[:space:]]*=[[:space:]]*"[^"]' "$BATS_FILE_TMPDIR/code.tf"
}

# The provider's attributes are environment-only, so an authored credential is one
# assignment away from being committed: assert the whole config has none.
@test "no Tailscale credential is authored in the config" {
    ! grep -qE '^(api_key|oauth_client_id|oauth_client_secret|identity_token)[[:space:]]*=[[:space:]]*"[^"]' "$BATS_FILE_TMPDIR/code.tf"
}

# The same assertion over every file the client could leak into: a credential in
# a tfvars, a README or a lock file is committed just the same.
@test "no Tailscale OAuth client is authored under tofu/" {
    local leaked='' f
    while IFS= read -r f; do
        if grep -qE '^(oauth_client_id|oauth_client_secret|api_key|identity_token)[[:space:]]*=[[:space:]]*"[^"]' "$f"; then
            leaked="$leaked $f"
        fi
    done < <(git ls-files 'tofu/*')
    [ -z "$leaked" ] && return 0
    printf '%s\n' "$leaked" >&2
    return 1
}

# The lock file is the allowlist below, so both of its entries are asserted; a
# missing file fails them rather than passing on an absent list.
locked_provider() {
    local provider=$1
    [ -f tofu/.terraform.lock.hcl ] || {
        printf 'the provider lock file is committed\n' >&2
        return 1
    }
    grep -qF "provider \"$provider\"" tofu/.terraform.lock.hcl
}

for provider in registry.opentofu.org/cloudflare/cloudflare registry.opentofu.org/tailscale/tailscale; do
    register "$provider is locked" locked_provider "$provider"
done

# --- provider and module allowlist ------------------------------------------
# The fetch set, asserted statically (task #886). `tofu init` downloads every
# provider the config names and runs it at plan time with the plan's credentials,
# so the committed lock file is the allowlist and no `module` may name a remote
# source. The fixtures are what keep the checker from passing everything. The
# checker being executable is part of the same assertion: a run of a file without
# the bit fails the check it is asked to make.

@test "the committed config declares only locked providers and local modules" {
    "$providers" tofu >"$BATS_TEST_TMPDIR/providers.log" 2>&1 && return 0
    cat "$BATS_TEST_TMPDIR/providers.log" >&2
    return 1
}

# fixture <name>: an empty config directory carrying the committed lock file.
fixture() {
    mkdir -p "$BATS_TEST_TMPDIR/$1"
    cp tofu/.terraform.lock.hcl "$BATS_TEST_TMPDIR/$1/"
}

@test "the checker refuses a provider the lock file does not name" {
    fixture added
    cat >"$BATS_TEST_TMPDIR/added/main.tf" <<'EOF'
terraform {
  required_providers {
    cloudflare = { source = "cloudflare/cloudflare" }
    aws        = { source = "hashicorp/aws" }
  }
}
EOF
    ! "$providers" "$BATS_TEST_TMPDIR/added" >"$BATS_TEST_TMPDIR/added.log" 2>&1
}

@test "the refusal names the added provider" {
    fixture added
    cat >"$BATS_TEST_TMPDIR/added/main.tf" <<'EOF'
terraform {
  required_providers {
    cloudflare = { source = "cloudflare/cloudflare" }
    aws        = { source = "hashicorp/aws" }
  }
}
EOF
    "$providers" "$BATS_TEST_TMPDIR/added" >"$BATS_TEST_TMPDIR/added.log" 2>&1 || :
    grep -q 'hashicorp/aws' "$BATS_TEST_TMPDIR/added.log"
}

@test "the checker refuses a remote module source" {
    fixture remote
    cat >"$BATS_TEST_TMPDIR/remote/main.tf" <<'EOF'
module "vpc" {
  source = "registry.opentofu.org/terraform-aws-modules/vpc/aws"
}
EOF
    ! "$providers" "$BATS_TEST_TMPDIR/remote" >"$BATS_TEST_TMPDIR/remote.log" 2>&1
}

@test "the refusal names the remote module" {
    fixture remote
    cat >"$BATS_TEST_TMPDIR/remote/main.tf" <<'EOF'
module "vpc" {
  source = "registry.opentofu.org/terraform-aws-modules/vpc/aws"
}
EOF
    "$providers" "$BATS_TEST_TMPDIR/remote" >"$BATS_TEST_TMPDIR/remote.log" 2>&1 || :
    grep -q 'terraform-aws-modules/vpc/aws' "$BATS_TEST_TMPDIR/remote.log"
}

@test "the checker allows a local module source" {
    fixture local
    cat >"$BATS_TEST_TMPDIR/local/main.tf" <<'EOF'
module "x" {
  source = "./modules/x"
}
EOF
    mkdir -p "$BATS_TEST_TMPDIR/local/modules/x"
    "$providers" "$BATS_TEST_TMPDIR/local" >"$BATS_TEST_TMPDIR/local.log" 2>&1 && return 0
    cat "$BATS_TEST_TMPDIR/local.log" >&2
    return 1
}

# A missing lock file is not an empty allowlist: it fails closed rather than
# passing every declaration.
@test "the checker fails closed without a lock file" {
    fixture nolock
    rm -f "$BATS_TEST_TMPDIR/nolock/.terraform.lock.hcl"
    ! "$providers" "$BATS_TEST_TMPDIR/nolock" >"$BATS_TEST_TMPDIR/nolock.log" 2>&1
}

# --- provider pin and workflows ----------------------------------------------

@test "provider is pinned to v5" {
    has 'version = "~> 5\.0"'
}

@test "no v4 record resource" {
    hasnt 'resource "cloudflare_record"'
}

@test "no deprecated self_hosted_domains" {
    hasnt 'self_hosted_domains'
}

@test "Actions stay SHA-pinned (scripts/check-action-pins.sh)" {
    scripts/check-action-pins.sh >"$BATS_TEST_TMPDIR/pins.log" 2>&1 && return 0
    cat "$BATS_TEST_TMPDIR/pins.log" >&2
    return 1
}

@test "ci.yml runs this check" {
    grep -qF -- '--filter-tags tofu' .github/workflows/ci.yml
}
