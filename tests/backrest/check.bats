#!/usr/bin/env bats
# bats file_tags=backrest
# Offline shape tests for the hosted Backrest reader (#707).
#
# The gate needs a Cloudflare account, restic and hours of streaming; this checks
# the half that does not: the deployment config, the pinned image, the read-only
# surface, the redaction and verified-only rules, and that no secret or
# falling-open default is committed.
#
#   bats tests/backrest/check.bats
#
# The shell suite this replaced kept a running count and skipped the two node
# checks in place; here each assertion is its own test, and a missing toolchain
# is a skipped test rather than an absent line.
# Several assertions grep the source for literal $VAR needles; that is the point.
load ../helpers

dir=backrest
index=$dir/src/index.ts
wire=$dir/src/wire.ts
entry=$dir/container/entrypoint.sh
gate=$dir/scripts/gate.sh
deploy=$dir/scripts/deploy.sh

# has <needle> <file>: the file must carry the literal text.
has() {
    grep -qF -- "$1" "$2" && return 0
    printf '%s not found in %s\n' "$1" "$2" >&2
    return 1
}

# hasnt <needle> <file>: the file must not carry the literal text.
hasnt() {
    grep -qF -- "$1" "$2" || return 0
    printf '%s found in %s\n' "$1" "$2" >&2
    return 1
}

# --- the files it is made of -------------------------------------------------

exists() { # file
    [ -f "$1" ]
}

for f in "$index" "$entry" "$gate" "$deploy" "$dir/wrangler.json" "$dir/package.json" \
    "$dir/container/Dockerfile"; do
    register "exists: $f" exists "$f"
done

# --- deployment configuration ------------------------------------------------

@test "wrangler.json is valid JSON" {
    jq -e . "$dir/wrangler.json" >/dev/null 2>&1
}

@test "isolated worker on a custom domain" {
    jq -e '.name == "smortress-backrest" and .workers_dev == false' "$dir/wrangler.json"
}

@test "durable_object scheduling policy" {
    jq -e '.containers[0].scheduling_policy == "durable_object"' "$dir/wrangler.json"
}

@test "Durable Object export declared" {
    jq -e '.exports.Backrest.type == "durable-object"' "$dir/wrangler.json"
}

# The reader moved to the edge (T2): the Worker must not claim the name, or
# Cloudflare keeps a proxied custom domain in front of the VPS record.
@test "no Worker custom domain claims recovery.sammohr.dev" {
    jq -e '([.routes // [] | .[].pattern] | index("recovery.sammohr.dev")) == null' "$dir/wrangler.json"
}

@test "the edge serves recovery.sammohr.dev" {
    has "recovery.sammohr.dev {" provision/edge/Caddyfile
}

@test "repository location is not a checked-in default" {
    jq -e '(.vars | has("BACKREST_REPO_URI") | not) and (.vars | has("BACKREST_REPO_GUID") | not)' "$dir/wrangler.json"
}

@test "no credential in wrangler.json" {
    hasnt "api_token" "$dir/wrangler.json"
}

# --- pinned image ------------------------------------------------------------

@test "base image pinned by tag and digest" {
    grep -Eq '^FROM ghcr\.io/garethgeorge/backrest:v1\.14\.1@sha256:[0-9a-f]{64}$' "$dir/container/Dockerfile"
}

# --- ephemeral state, failing closed ----------------------------------------

@test "entrypoint refuses a missing repository" {
    has 'BACKREST_REPO_URI is required' "$entry"
}

@test "entrypoint enables errexit" {
    has 'set -eu' "$entry"
}

@test "entrypoint renders the config" {
    has 'jq -n' "$entry"
}

@test "entrypoint refuses a plaintext restic password var" {
    has 'RESTIC_PASSWORD is required' "$entry"
}

@test "entrypoint drops credentials before exec" {
    has 'unset RESTIC_PASSWORD R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY' "$entry"
}

@test "entrypoint uses the bundled restic" {
    has 'BACKREST_RESTIC_COMMAND=/bin/restic' "$entry"
}

@test "entrypoint binds the container port" {
    has 'BACKREST_PORT=0.0.0.0:9898' "$entry"
}

# --- read-only recovery reader ----------------------------------------------

@test "repository runs with --no-lock" {
    has '"--no-lock"' "$entry"
}

@test "repository runs with --no-cache" {
    has '"--no-cache"' "$entry"
}

@test "auto-initialisation stays off" {
    has 'autoInitialize: false' "$entry"
}

@test "auto-unlock stays off" {
    has 'autoUnlock: false' "$entry"
}

@test "no schedules exist" {
    has 'plans: []' "$entry"
}

@test "authentication stays enabled" {
    has 'disabled: false' "$entry"
}

@test "container egress is explicit" {
    has 'enableInternet: true' "$index"
}

@test "no plaintext bcrypt in the worker source" {
    hasnt 'passwordBcrypt: "' "$index"
}

# The proxy, not Backrest, is the read-only boundary. SetConfig alone could
# disable auth and drop the repository; RunCommand is arbitrary restic.
proxy_refuses() { # rpc
    ! sed -n '/const ALLOWED_RPCS/,/]);/p' "$index" | grep -q "\"$1\""
}

for forbidden in SetConfig AddRepo RemoveRepo Backup Forget DoRepoTask Restore RunCommand; do
    register "proxy refuses $forbidden" proxy_refuses "$forbidden"
done

@test "proxy allows the explicit read surface" {
    has '"ListSnapshots"' "$index"
}

# GetConfig leaks the repo password and R2 keys upstream; only the proxy strips
# them, so the redaction is the security control.
@test "config redaction drops the repo password" {
    has 'delete repo.password' "$index"
}

@test "config redaction drops restic env" {
    has 'delete repo.env' "$index"
}

@test "snapshots are filtered to verified" {
    has 'snapshot.tags.includes("verified")' "$index"
}

@test "downloads are refused for unverified snapshots" {
    has '"snapshot is not verified"' "$index"
}

# connect-web calls response.json() on a non-2xx body labelled as JSON, so
# relabelling Backrest's text/plain 401 broke the UI before its login form.
# Only a successful body may be rewritten, and only in the caller's format.
@test "only successful bodies are rewritten" {
    has 'jsonTransform !== undefined && response.ok' "$index"
}

@test "rewrites keep the upstream headers" {
    has 'new Headers(response.headers)' "$index"
}

@test "error bodies carry a Connect code" {
    has 'failed_precondition' "$index"
}

@test "download ids are read from protobuf requests" {
    has 'readUint64Field' "$index"
}

# The Web UI negotiates application/proto, so JSON-only redaction never ran for
# it. The wire module drops Repo.password (field 3) and Repo.env (field 4).
@test "protobuf config redaction drops the repo password and env" {
    has 'inner.number !== 3 && inner.number !== 4' "$wire"
}

@test "protobuf redaction is applied to GetConfig" {
    has 'redactConfigProto' "$index"
}

@test "a rewritten config is checked against the real secrets" {
    has 'containsSecret' "$index"
}

# Indexing has no operation of its own (TASK_INDEX_SNAPSHOTS has a nil ProtoOp),
# so readiness must compare live snapshots with indexed ones.
@test "readiness compares live and indexed snapshots" {
    has 'live.every((id) => indexed.has(id))' "$index"
}

@test "indexed set comes from the operation log" {
    has 'operationIndexSnapshot' "$index"
}

@test "readiness never waits on a task id" {
    hasnt 'scheduled.operationId' "$index"
}

@test "readiness is single-flight" {
    has 'this.booting ??=' "$index"
}

@test "listing snapshots schedules an index" {
    has 'ensureIndexed' "$index"
}

@test "a stale container is replaced" {
    has 'stale configuration' "$index"
}

@test "the running config is compared with the deployment" {
    has 'configMatches' "$index"
}

@test "internal calls carry a timeout" {
    has 'AbortSignal.timeout(timeoutMs)' "$index"
}

@test "inactivity timeout at the platform maximum" {
    grep -Eq 'INACTIVITY_TIMEOUT_MS = 6 \* 60 \* 60 \* 1000' "$index"
}

# --- deploy wrapper ----------------------------------------------------------

@test "deploy requires the repository id" {
    has 'BACKREST_REPO_ID is required' "$deploy"
}

@test "deploy requires the repository uri" {
    has 'BACKREST_REPO_URI is required' "$deploy"
}

@test "deploy requires the repository guid" {
    has 'BACKREST_REPO_GUID is required' "$deploy"
}

@test "deploy validates the guid shape" {
    has '=~ ^[0-9a-f]{64}$' "$deploy"
}

@test "deploy uses podman through wrangler" {
    has 'WRANGLER_DOCKER_BIN' "$deploy"
}

@test "deploy pins the image by registry digest" {
    has 'registry.cloudflare.com/$account_id/$image_repo@$digest' "$deploy"
}

@test "deploy reads the digest from the registry" {
    has 'docker-content-digest' "$deploy"
}

@test "deploy renders a non-committed config" {
    has 'wrangler.deploy.json' "$deploy"
}

@test "npm run deploy cannot skip the required inputs" {
    jq -e '.scripts.deploy == "./scripts/deploy.sh"' "$dir/package.json"
}

# --- gate matrix -------------------------------------------------------------

@test "denial uses the real restic token" {
    has 'R2_READ_ACCESS_KEY_ID' "$gate"
}

@test "denial: init probe" {
    has '"$probe" init' "$gate"
}

@test "denial: backup attempt" {
    has 'backup --no-lock --host gate-denial' "$gate"
}

@test "denial: forget attempt" {
    has 'forget "$snap"' "$gate"
}

@test "denial: prune attempt" {
    has 'restic -r "$RESTIC_REPOSITORY" prune' "$gate"
}

@test "denial: purge attempt" {
    has 'forget --prune' "$gate"
}

@test "denial: unlock is a no-op" {
    has 'nothing to remove' "$gate"
}

@test "denial: snapshot list must not move" {
    has 'a denied write changed the snapshot list' "$gate"
}

@test "denial: proxy refusals" {
    has 'returned $code through the proxy, expected 403' "$gate"
}

@test "download URL field is .value" {
    has 'jq -er .value' "$gate"
}

@test "download URL is resolved against the host" {
    has 'value="$BACKREST_URL/${value#./}"' "$gate"
}

@test "directory streams are checked as tar" {
    has 'tar -tf -' "$gate"
}

@test "same-origin download URL is asserted" {
    has 'is not same-origin' "$gate"
}

@test "anonymous access is probed" {
    has 'an anonymous request reached Backrest' "$gate"
}

@test "redaction is asserted" {
    has 'GetConfig still exposes repository credentials' "$gate"
}

@test "the protobuf config path is probed" {
    has 'protobuf GetConfig is redacted' "$gate"
}

@test "the anonymous refusal keeps its content type" {
    has 'text/plain refusal' "$gate"
}

@test "four-hour stream budget" {
    has 'BACKREST_STREAM_TIMEOUT:-14400' "$gate"
}

@test "streamed files are hash-checked" {
    has 'does not match $expected' "$gate"
}

@test "cancellation is exercised" {
    has 'context canceled' "$gate"
}

@test "the Access service token is optional" {
    has '[[ -n ${CF_ACCESS_CLIENT_ID:-} ]]' "$gate"
}

@test "a set Access token is still sent" {
    has 'CF-Access-Client-Secret' "$gate"
}

@test "secrets never travel in argv" {
    has 'url.cfg' "$gate"
}

# --- deterministic toolchain -------------------------------------------------

@test "npm dependencies pinned exactly" {
    jq -e '[.devDependencies[] | test("^[0-9]+\\.[0-9]+\\.[0-9]+")] | all' "$dir/package.json" >/dev/null 2>&1
}

# --- no committed secrets ----------------------------------------------------

@test "no base64 bcrypt hash is committed" {
    ! grep -rEq 'JDJ[aby]J[A-Za-z0-9+/]{20,}' "$dir" --exclude-dir=node_modules
}

@test "no key material or restic password is committed" {
    ! grep -rEq '(BEGIN [A-Z ]*PRIVATE KEY|RESTIC_PASSWORD=[A-Za-z0-9])' "$dir" --exclude-dir=node_modules
}

# --- scripts and types -------------------------------------------------------

script_syntax() { # file
    bash -n "$1" 2>/dev/null
}

for f in "$gate" "$deploy" "$dir/scripts/hash-password.sh"; do
    register "syntax: $f" script_syntax "$f"
done

# The guard is the only thing refusing the admin RPCs on a host without the
# Worker, so its refusals and rewrites run here rather than being asserted from
# source shape alone. Its assertion text carries how many checks it made, and a
# description is resolved before a test body runs: setup_file runs the guard once
# per file and the top level reads the count it left behind.
setup_file() {
    rc=0
    bash tests/backrest/guard.sh >"$BATS_FILE_TMPDIR/guard.out" 2>&1 || rc=$?
    printf '%s' "$rc" >"$BATS_FILE_TMPDIR/guard.rc"
}

guard_ok=0
if [[ -s ${BATS_FILE_TMPDIR:-}/guard.out ]]; then
    guard_ok=$(grep -c '^ok' "$BATS_FILE_TMPDIR/guard.out")
fi

@test "shellcheck clean" {
    command -v shellcheck >/dev/null 2>&1 || {
        printf 'shellcheck is required for this test\n' >&2
        return 1
    }
    shellcheck -S warning "$gate" "$deploy" "$dir/scripts/hash-password.sh" "$entry" >/dev/null 2>&1
}

@test "password hashing refuses terminal stdin" {
    has 'if [[ -t 0 ]]' "$dir/scripts/hash-password.sh"
}

@test "guard refusals and rewrites ($guard_ok checks)" {
    run cat "$BATS_FILE_TMPDIR/guard.rc"
    printf '%s\n' "$(cat "$BATS_FILE_TMPDIR/guard.out")"
    assert_equal "$output" 0
}

# The two node checks are skipped together when this host cannot run them, which
# is what the shell suite did: the toolchain is check-all.sh's to install, not
# this suite's.
typecheck() { (cd "$dir" && npx tsc --noEmit >/dev/null 2>&1); }
unit_tests() { (cd "$dir" && npm test >/dev/null 2>&1); }

if command -v npx >/dev/null 2>&1 && [[ -d $dir/node_modules ]]; then
    register "TypeScript typecheck" typecheck
else
    register_skip "TypeScript typecheck" \
        "run 'cd backrest && npm ci && npm run typecheck' (node not installed here)"
fi

if command -v npm >/dev/null 2>&1 && [[ -d $dir/node_modules ]]; then
    register "protobuf wire unit tests" unit_tests
else
    register_skip "protobuf wire unit tests" "run 'cd backrest && npm test' (node not installed here)"
fi
