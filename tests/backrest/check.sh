#!/usr/bin/env bash
# Offline shape tests for the hosted Backrest reader (#707).
#
# The gate needs a Cloudflare account, an Access service token, restic and
# hours of streaming; this checks the half that does not: the deployment
# config, the pinned image, the read-only surface, the redaction and
# verified-only rules, and that no secret or falling-open default is committed.
#
#   tests/backrest/check.sh
# Several assertions grep the source for literal $VAR needles; that is the point.
# shellcheck disable=SC2016

set -uo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root" || exit 1

dir=backrest
index=$dir/src/index.ts
entry=$dir/container/entrypoint.sh
gate=$dir/scripts/gate.sh
deploy=$dir/scripts/deploy.sh

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
note() { printf 'skip %s\n' "$1"; }
has() { if grep -qF -- "$3" "$2"; then ok "$1"; else bad "$1" "$3 not found in $2"; fi; }
hasnt() { if grep -qF -- "$3" "$2"; then bad "$1" "$3 found in $2"; else ok "$1"; fi; }
assert() { # label, command...
  local label=$1
  shift
  if "$@" >/dev/null 2>&1; then ok "$label"; else bad "$label"; fi
}

for f in "$index" "$entry" "$gate" "$deploy" "$dir/wrangler.json" "$dir/package.json" "$dir/container/Dockerfile"; do
  if [[ -f $f ]]; then ok "exists: $f"; else bad "exists: $f"; fi
done

# --- deployment configuration ------------------------------------------------
if jq -e . "$dir/wrangler.json" >/dev/null 2>&1; then
  ok "wrangler.json is valid JSON"
  assert "isolated worker on a custom domain" \
    jq -e '.name == "smortress-backrest" and .workers_dev == false' "$dir/wrangler.json"
  assert "durable_object scheduling policy" \
    jq -e '.containers[0].scheduling_policy == "durable_object"' "$dir/wrangler.json"
  assert "Durable Object export declared" \
    jq -e '.exports.Backrest.type == "durable-object"' "$dir/wrangler.json"
  assert "serves recovery.sammohr.dev" \
    jq -e '[.routes[].pattern] == ["recovery.sammohr.dev"]' "$dir/wrangler.json"
  assert "repository location is not a checked-in default" \
    jq -e '(.vars | has("BACKREST_REPO_URI") | not) and (.vars | has("BACKREST_REPO_GUID") | not)' "$dir/wrangler.json"
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
has "entrypoint refuses a missing repository" "$entry" 'BACKREST_REPO_URI is required'
has "entrypoint enables errexit" "$entry" 'set -eu'
has "entrypoint renders the config" "$entry" 'jq -n'
has "entrypoint refuses a plaintext restic password var" "$entry" 'RESTIC_PASSWORD is required'
has "entrypoint drops credentials before exec" "$entry" 'unset RESTIC_PASSWORD R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY'
has "entrypoint uses the bundled restic" "$entry" 'BACKREST_RESTIC_COMMAND=/bin/restic'
has "entrypoint binds the container port" "$entry" 'BACKREST_PORT=0.0.0.0:9898'

# --- read-only recovery reader ----------------------------------------------
has "repository runs with --no-lock" "$entry" '"--no-lock"'
has "repository runs with --no-cache" "$entry" '"--no-cache"'
has "auto-initialisation stays off" "$entry" 'autoInitialize: false'
has "auto-unlock stays off" "$entry" 'autoUnlock: false'
has "no schedules exist" "$entry" 'plans: []'
has "authentication stays enabled" "$entry" 'disabled: false'
has "container egress is explicit" "$index" 'enableInternet: true'
hasnt "no plaintext bcrypt in the worker source" "$index" 'passwordBcrypt: "'

# The proxy, not Backrest, is the read-only boundary. SetConfig alone could
# disable auth and drop the repository; RunCommand is arbitrary restic.
for forbidden in SetConfig AddRepo RemoveRepo Backup Forget DoRepoTask Restore RunCommand; do
  if sed -n '/const ALLOWED_RPCS/,/]);/p' "$index" | grep -q "\"$forbidden\""; then
    bad "proxy refuses $forbidden" "listed in ALLOWED_RPCS"
  else
    ok "proxy refuses $forbidden"
  fi
done
has "proxy allows the explicit read surface" "$index" '"ListSnapshots"'

# GetConfig leaks the repo password and R2 keys upstream; only the proxy strips
# them, so the redaction is the security control.
has "config redaction drops the repo password" "$index" 'delete repo.password'
has "config redaction drops restic env" "$index" 'delete repo.env'
has "snapshots are filtered to verified" "$index" 'snapshot.tags.includes("verified")'
has "downloads are refused for unverified snapshots" "$index" '"snapshot is not verified"'

# Indexing has no operation of its own (TASK_INDEX_SNAPSHOTS has a nil ProtoOp),
# so readiness must compare live snapshots with indexed ones.
has "readiness compares live and indexed snapshots" "$index" 'live.every((id) => indexed.has(id))'
has "indexed set comes from the operation log" "$index" 'operationIndexSnapshot'
hasnt "readiness never waits on a task id" "$index" 'scheduled.operationId'
has "readiness is single-flight" "$index" 'this.booting ??='
has "listing snapshots schedules an index" "$index" 'ensureIndexed'
has "a stale container is replaced" "$index" 'stale configuration'
has "the running config is compared with the deployment" "$index" 'configMatches'
has "internal calls carry a timeout" "$index" 'AbortSignal.timeout(timeoutMs)'

if grep -Eq 'INACTIVITY_TIMEOUT_MS = 6 \* 60 \* 60 \* 1000' "$index"; then
  ok "inactivity timeout at the platform maximum"
else
  bad "inactivity timeout must be 6h, the documented maximum"
fi

# --- deploy wrapper ----------------------------------------------------------
has "deploy requires the repository id" "$deploy" 'BACKREST_REPO_ID is required'
has "deploy requires the repository uri" "$deploy" 'BACKREST_REPO_URI is required'
has "deploy requires the repository guid" "$deploy" 'BACKREST_REPO_GUID is required'
has "deploy validates the guid shape" "$deploy" '=~ ^[0-9a-f]{64}$'
has "deploy uses podman through wrangler" "$deploy" 'WRANGLER_DOCKER_BIN'
has "deploy pins the image by registry digest" "$deploy" 'registry.cloudflare.com/$account_id/$image_repo@$digest'
has "deploy reads the digest from the registry" "$deploy" 'docker-content-digest'
has "deploy renders a non-committed config" "$deploy" 'wrangler.deploy.json'
assert "npm run deploy cannot skip the required inputs" \
  jq -e '.scripts.deploy == "./scripts/deploy.sh"' "$dir/package.json"

# --- gate matrix -------------------------------------------------------------
has "denial uses the real restic token" "$gate" 'R2_READ_ACCESS_KEY_ID'
has "denial: init probe" "$gate" '"$probe" init'
has "denial: backup attempt" "$gate" 'backup --no-lock --host gate-denial'
has "denial: forget attempt" "$gate" 'forget "$snap"'
has "denial: prune attempt" "$gate" 'restic -r "$RESTIC_REPOSITORY" prune'
has "denial: purge attempt" "$gate" 'forget --prune'
has "denial: unlock is a no-op" "$gate" 'nothing to remove'
has "denial: snapshot list must not move" "$gate" 'a denied write changed the snapshot list'
has "denial: proxy refusals" "$gate" 'returned $code through the proxy, expected 403'
has "download URL field is .value" "$gate" 'jq -er .value'
has "download URL is resolved against the host" "$gate" 'value="$BACKREST_URL/${value#./}"'
has "directory streams are checked as tar" "$gate" 'tar -tf -'
has "same-origin download URL is asserted" "$gate" 'is not same-origin'
has "anonymous access is probed" "$gate" 'Access-only'
has "redaction is asserted" "$gate" 'GetConfig still exposes repository credentials'
has "four-hour stream budget" "$gate" 'BACKREST_STREAM_TIMEOUT:-14400'
has "streamed files are hash-checked" "$gate" 'does not match $expected'
has "cancellation is exercised" "$gate" 'context canceled'
has "Access service token is required" "$gate" 'CF_ACCESS_CLIENT_ID'
has "secrets never travel in argv" "$gate" 'url.cfg'

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

# --- scripts and types -------------------------------------------------------
for f in "$gate" "$deploy" "$dir/scripts/hash-password.sh"; do
  if bash -n "$f" 2>/dev/null; then ok "syntax: $f"; else bad "syntax: $f"; fi
done
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -S warning "$gate" "$deploy" "$dir/scripts/hash-password.sh" "$entry" >/dev/null 2>&1; then
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

if command -v npx >/dev/null 2>&1 && [[ -d $dir/node_modules ]]; then
  if (cd "$dir" && npx tsc --noEmit >/dev/null 2>&1); then
    ok "TypeScript typecheck"
  else
    bad "TypeScript typecheck"
  fi
else
  note "typecheck: run 'cd backrest && npm ci && npm run typecheck' (node not installed here)"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
