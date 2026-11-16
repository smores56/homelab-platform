#!/usr/bin/env bash
# Offline shape tests for the hosted Backrest reader (#707).
#
# The gate itself needs a Cloudflare account, an Access service token and hours
# of streaming; this checks the half that does not: the deployment config, the
# pinned image, the read-only invariants, and that no secret or falling-open
# default can be committed.
#
#   tests/backrest/check.sh
set -uo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root" || exit 1

dir=backrest
index=$dir/src/index.ts
entry=$dir/container/entrypoint.sh
gate=$dir/scripts/gate.sh

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
has() { # label, file, fixed string
  if grep -qF -- "$3" "$2"; then ok "$1"; else bad "$1" "$3 not found in $2"; fi
}
hasnt() {
  if grep -qF -- "$3" "$2"; then bad "$1" "$3 found in $2"; else ok "$1"; fi
}

for f in "$index" "$entry" "$gate" "$dir/wrangler.json" "$dir/package.json" "$dir/container/Dockerfile"; do
  if [[ -f $f ]]; then ok "exists: $f"; else bad "exists: $f"; fi
done

# --- deployment configuration ------------------------------------------------
if jq -e . "$dir/wrangler.json" >/dev/null 2>&1; then
  ok "wrangler.json is valid JSON"
  jq -e '.name == "smortress-backrest" and .workers_dev == false' "$dir/wrangler.json" >/dev/null &&
    ok "isolated worker on a custom domain" || bad "worker name and workers_dev"
  jq -e '.containers[0].scheduling_policy == "durable_object"' "$dir/wrangler.json" >/dev/null &&
    ok "durable_object scheduling policy" || bad "durable_object scheduling policy (default is deprecated)"
  jq -e '.exports.Backrest.type == "durable-object"' "$dir/wrangler.json" >/dev/null &&
    ok "Durable Object export declared" || bad "Durable Object export declared"
  jq -e '[.routes[].pattern] == ["backrest.sammohr.dev"]' "$dir/wrangler.json" >/dev/null &&
    ok "gate hostname stays off recovery.sammohr.dev, which remains the live page" ||
    bad "route must be backrest.sammohr.dev only"
  jq -e '(.vars | has("BACKREST_REPO_URI") | not) and (.vars | has("BACKREST_REPO_GUID") | not)' "$dir/wrangler.json" >/dev/null &&
    ok "repository location is deploy-time input, not a checked-in default" ||
    bad "repository location must not come from wrangler.json"
  hasnt "no credential in wrangler.json" "$dir/wrangler.json" "api_token"
else
  bad "wrangler.json is valid JSON"
fi

# --- pinned image ------------------------------------------------------------
if grep -Eq '^FROM ghcr\.io/garethgeorge/backrest:v1\.14\.1@sha256:[0-9a-f]{64}$' "$dir/container/Dockerfile"; then
  ok "base image pinned by tag and digest"
else
  bad "base image must be pinned by tag and digest" "$(grep '^FROM' "$dir/container/Dockerfile")"
fi

# --- ephemeral state, failing closed ----------------------------------------
has "entrypoint aborts without a config" "$entry" 'BACKREST_CONFIG_JSON is empty; refusing to start'
has "entrypoint enables errexit" "$entry" 'set -eu'
has "entrypoint uses the bundled restic" "$entry" 'BACKREST_RESTIC_COMMAND=/bin/restic'
has "entrypoint binds the container port" "$entry" 'BACKREST_PORT=0.0.0.0:9898'
hasnt "entrypoint does not disable auth" "$entry" '"disabled"'
hasnt "entrypoint has no default password" "$entry" 'PASSWORD='

# --- read-only recovery reader ----------------------------------------------
has "repository runs with --no-lock" "$index" '"--no-lock"'
has "repository runs with --no-cache" "$index" '"--no-cache"'
has "auto-initialisation stays off" "$index" 'autoInitialize: false'
has "auto-unlock stays off" "$index" 'autoUnlock: false'
has "no schedules exist" "$index" 'plans: []'
has "authentication stays enabled" "$index" 'disabled: false'
has "cold start reindexes before serving" "$index" 'TASK_INDEX_SNAPSHOTS'
has "inactivity timeout is bounded" "$index" 'setInactivityTimeout'
has "container egress is explicit" "$index" 'enableInternet: true'
hasnt "no plaintext bcrypt in the worker source" "$index" 'passwordBcrypt: "'

# The inactivity timeout above must not exceed the platform's six-hour cap.
if grep -Eq 'INACTIVITY_TIMEOUT_MS = 6 \* 60 \* 60 \* 1000' "$index"; then
  ok "inactivity timeout at the platform maximum"
else
  bad "inactivity timeout must be 6h, the documented maximum"
fi

# --- gate matrix -------------------------------------------------------------
has "denial: init attempt" "$gate" '\"command\":\"init\"'
has "denial: prune attempt" "$gate" 'TASK_PRUNE'
has "denial: unlock attempt" "$gate" 'TASK_UNLOCK'
has "denial: forget attempt" "$gate" 'Forget'
has "denial: snapshot list must not move" "$gate" 'a denied write changed the snapshot list'
has "only verified snapshots are eligible" "$gate" 'index("verified")'
has "same-origin download URL is asserted" "$gate" 'is not same-origin'
has "four-hour stream budget" "$gate" 'BACKREST_STREAM_TIMEOUT:=15000'
has "cancellation is exercised" "$gate" 'context canceled'
has "Access service token is required" "$gate" 'CF_ACCESS_CLIENT_ID'
has "secrets never travel in argv" "$gate" 'curl.cfg'

# --- deterministic toolchain -------------------------------------------------
if jq -e '[.devDependencies[] | test("^[0-9]+\\.[0-9]+\\.[0-9]+")] | all' "$dir/package.json" >/dev/null 2>&1; then
  ok "npm dependencies pinned exactly"
else
  bad "npm dependencies must be pinned exactly"
fi

# --- no committed secrets ----------------------------------------------------
if grep -rEq 'JDJ[aby]J[A-Za-z0-9+/]{20,}' "$dir" --exclude-dir=node_modules; then
  bad "no base64 bcrypt hash is committed"
else
  ok "no base64 bcrypt hash is committed"
fi
if grep -rEq '(BEGIN [A-Z ]*PRIVATE KEY|RESTIC_PASSWORD=[A-Za-z0-9])' "$dir" --exclude-dir=node_modules; then
  bad "no key material or restic password is committed"
else
  ok "no key material or restic password is committed"
fi

# --- scripts -----------------------------------------------------------------
for f in "$gate" "$dir/scripts/hash-password.sh"; do
  if bash -n "$f" 2>/dev/null; then ok "syntax: $f"; else bad "syntax: $f"; fi
done
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -S warning "$gate" "$dir/scripts/hash-password.sh" "$entry" >/dev/null 2>&1; then
    ok "shellcheck clean"
  else
    bad "shellcheck reports findings"
  fi
else
  bad "shellcheck is required for this test"
fi
if grep -qF 'if [[ -t 0 ]]' "$dir/scripts/hash-password.sh"; then
  ok "password hashing refuses terminal stdin"
else
  bad "hash-password.sh must refuse to read a password from a terminal"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
