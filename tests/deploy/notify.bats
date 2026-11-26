#!/usr/bin/env bats
# bats file_tags=deploy
# Offline checks for the CI notify job (SDLC #798, T6).
#
# The event is the primary trigger, and its whole contract is in the job's shape:
# a separate job that inherits nothing from the build, joins the tailnet as an
# ephemeral `tag:deploy` node from a main-only Environment, and posts a signed
# body whose *sent* bytes are the *signed* bytes. Nothing here needs a runner or a
# tailnet: the workflow text is read for the Environment, the empty permission
# set, the main-only guard and the SHA-pinned action, and the step's own script is
# extracted and executed with a fake curl, so the HMAC is recomputed from the file
# curl was handed.
#
#   bats tests/deploy/notify.bats
load ../helpers

workflow=.github/workflows/publish-server-image.yml
ci=.github/workflows/ci.yml

# The fake curl records argv and answers with a queued response: this suite is
# about the bytes the step builds and hands over, and the HMAC it recomputes.
setup_file() {
    bin=$BATS_FILE_TMPDIR/bin
    mkdir -p "$bin"
    cat >"$bin/curl" <<'CURL'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >>"$FAKE_CURL_LOG"
for arg in "$@"; do printf '%s\n' "$arg" >>"$FAKE_ARGV_LOG"; done
[[ -n ${FAKE_CURL_RESPONSE:-} ]] && printf '%s\n' "$FAKE_CURL_RESPONSE"
exit 0
CURL
    chmod 0755 "$bin/curl"
}

# A job's own lines, from its key to the next job key. Both files keep jobs at
# two-space indentation, so the block is the text between them.
job_block() { # <file> <job>
    awk -v job="  $2:" '
    $0 == job { inside = 1; next }
    inside && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { exit }
    inside { print }
  ' "$1"
}

# The body of the job's single `run: |` step, dedented. Extracting it rather than
# describing it is what lets this test sign and "send" the real bytes.
run_block() { # <job-block-file>
    awk '
    /^        run: \|$/ { inside = 1; next }
    inside && /^[ ]{0,9}[^ ]/ { exit }
    inside { sub(/^ {10}/, ""); print }
  ' "$1"
}

# The job block and its step's script are read once per test: both are small text
# extractions from the workflow, and every assertion below is about that text.
setup() {
    work=$BATS_TEST_TMPDIR
    job_block "$workflow" notify >"$work/notify.yml"
    job=$(cat "$work/notify.yml")
    run_block "$work/notify.yml" >"$work/step.sh"
    step=$(cat "$work/step.sh")
}

# run_step: the step's script executed as it ships, with a curl that records argv
# instead of dialling. `step_rc` is its status; `argv` the request's arguments,
# `body` the file handed to --data-binary and `signature` the HMAC header built
# from it.
run_step() {
    mkdir -p "$work/runner"
    argv=$work/argv
    : >"$argv"
    : >"$work/log"
    export PATH="$BATS_FILE_TMPDIR/bin:$PATH"
    export FAKE_CURL_LOG=$work/log
    export FAKE_ARGV_LOG=$argv
    export FAKE_CURL_RESPONSE='{"status":"queued","id":"00000000-0000-4000-8000-000000000000"}'
    export RUNNER_TEMP=$work/runner
    export REPO_NAME=homelab-platform
    export COMMIT_SHA=0123456789abcdef0123456789abcdef01234567
    export DEPLOY_WEBHOOK_SECRET=$work/webhook-secret
    printf '%s\n' "s3cr3t-$(printf '%032d' 0)" >"$DEPLOY_WEBHOOK_SECRET"
    step_rc=0
    bash "$work/step.sh" >"$work/stdout" 2>"$work/stderr" || step_rc=$?
    sent=$(awk 'prev == "--data-binary" { print; exit } { prev = $0 }' "$argv")
    body=${sent#@}
    signature=$(awk 'prev == "-H" && /^X-Deploy-Signature: sha256=/ { sub(/^X-Deploy-Signature: sha256=/, ""); print; exit } { prev = $0 }' "$argv")
}

@test "the publish workflow has a notify job" {
    assert [ -s "$work/notify.yml" ]
}

# --- the job is a notification, not a gate -----------------------------------

@test "notify runs after the build, not before it" {
    assert grep -qE '^    needs: publish$' <<<"$job"
}

@test "notify runs from a main dispatch only" {
    assert grep -qE "^    if: github\.event_name == 'workflow_dispatch' && github\.ref == 'refs/heads/main'\$" <<<"$job"
}

@test "notify uses its own Environment" {
    assert grep -qE '^    environment: deploy-notify$' <<<"$job"
}

@test "notify holds no permission on the repository" {
    assert grep -qE '^    permissions: \{\}$' <<<"$job"
}

# The signing key lives in the `server-image` Environment and nowhere else: a job
# that could read it would make the deploy node part of the same trust domain.
@test "notify never names the signing key" {
    refute grep -qE 'COSIGN_' <<<"$job"
}

@test "notify never joins the signing Environment" {
    refute grep -qE '^    environment: server-image$' <<<"$job"
}

@test "notify checks nothing out (it needs no repository content)" {
    refute grep -qE 'actions/checkout' <<<"$job"
}

@test "notify reads only the deploy credentials" {
    named=$(grep -oE '\$\{\{ *secrets\.[A-Za-z0-9_]+' <<<"$job" | sed 's/.*secrets\.//' | sort -u | tr '\n' ' ')
    assert_equal "$named" 'DEPLOY_WEBHOOK_SECRET TS_OAUTH_CLIENT_ID TS_OAUTH_CLIENT_SECRET '
}

# --- the tailnet node ---------------------------------------------------------

tailscale_action() { # the job's `uses:` line for the Tailscale action
    grep -E '^[[:space:]]*(- )?uses:[[:space:]]*tailscale/github-action@' <<<"$job" || true
}

@test "notify joins the tailnet through the Tailscale action" {
    action=$(tailscale_action)
    assert [ -n "$action" ]
}

@test "the Tailscale action is pinned to a full commit SHA" {
    action=$(tailscale_action)
    assert [ -n "$action" ]
    ref=${action##*@}
    ref=${ref%%[[:space:]]*}
    assert_equal "$(grep -cE '^[0-9a-f]{40}$' <<<"$ref")" 1
}

@test "the notify node carries tag:deploy" {
    assert grep -qE 'tags: tag:deploy' <<<"$job"
}

@test "the node is minted from the deploy OAuth client" {
    assert grep -qE 'oauth-client-id: \$\{\{ secrets\.TS_OAUTH_CLIENT_ID \}\}' <<<"$job"
}

@test "the node is minted from the deploy OAuth client secret" {
    assert grep -qE 'oauth-secret: \$\{\{ secrets\.TS_OAUTH_CLIENT_SECRET \}\}' <<<"$job"
}

# --- the body, the signature and the send ------------------------------------

@test "the notify step carries a script to run" {
    assert [ -s "$work/step.sh" ]
}

@test "the body names the repository" {
    assert grep -qE '"repo": os\.environ\["REPO_NAME"\]' <<<"$step"
}

@test "the body names the commit" {
    assert grep -qE '"commit": os\.environ\["COMMIT_SHA"\]' <<<"$step"
}

@test "the body carries a unix timestamp" {
    assert grep -qE '"ts": now' <<<"$step"
}

@test "the body carries a 32-hex nonce" {
    assert grep -qE '"nonce": secrets\.token_hex\(16\)' <<<"$step"
}

@test "the signature is HMAC" {
    assert grep -qE 'hmac\.new\(' <<<"$step"
}

@test "the signature is SHA-256" {
    assert grep -qE 'hashlib\.sha256' <<<"$step"
}

@test "the signature header is the design's" {
    assert grep -qE 'X-Deploy-Signature: sha256=\$sig' <<<"$step"
}

# The skew is read from the body's `ts`, the one value the HMAC covers. An
# unsigned timestamp header was a second answer to the same question: the sender
# and the receiver could disagree and neither could be shown to be right.
@test "no unsigned timestamp header is sent" {
    refute grep -qE 'X-Deploy-Timestamp' <<<"$step"
}

@test "the body is sent with --data-binary from the file" {
    assert grep -qE -- '--data-binary @"\$body"' <<<"$step"
}

@test "the send is bounded and fails on a bad status" {
    assert grep -qE -- '--fail-with-body --max-time 30' <<<"$step"
}

@test "the send targets the receiver over the tailnet" {
    assert grep -qE 'http://smortress:8484/v1/deploy' <<<"$step"
}

# A `-d @file` strips newlines and re-encodes the body, so the bytes curl sends
# are not the bytes that were signed. The regression is silent on the wire and
# only shows up as a rejected HMAC.
@test "the body is never sent with -d/--data" {
    refute grep -qE '(-d|--data) [`"]?@' <<<"$step"
}

# Exactly one of each: a second header or a second request is a second signature
# over a body the receiver is asked to trust twice.
@test "exactly one signature header is built, from the HMAC" {
    assert_equal "$(grep -cF 'X-Deploy-Signature: sha256=$sig' <<<"$step")" 1
}

@test "exactly one request sends the signed file" {
    assert_equal "$(grep -cF -- '--data-binary @"$body"' <<<"$step")" 1
}

# --- the step signs what it sends --------------------------------------------

@test "the notify step succeeds against a recording curl" {
    run_step
    assert_equal "$step_rc" 0
}

@test "the step hands curl a body file" {
    run_step
    assert [ -n "$body" ]
    assert [ -s "$body" ]
}

@test "the body's repo is the short repository name" {
    run_step
    assert_equal "$(jq -r '.repo' "$body" 2>/dev/null)" homelab-platform
}

@test "the body's commit is the pushed sha" {
    run_step
    assert_equal "$(jq -r '.commit' "$body" 2>/dev/null)" "$COMMIT_SHA"
}

@test "the body's ts is a number" {
    run_step
    assert_equal "$(jq -r '.ts | type' "$body" 2>/dev/null)" number
}

@test "the body's nonce is 32 hex" {
    run_step
    assert_equal "$(jq -r '.nonce | test("^[0-9a-f]{32}$")' "$body" 2>/dev/null)" true
}

@test "the body is exactly the four keys" {
    run_step
    assert_equal "$(jq -r 'keys_unsorted | join(",")' "$body" 2>/dev/null)" 'repo,commit,ts,nonce'
}

# The HMAC is recomputed here from the file curl was handed: equal means the
# signed bytes and the sent bytes are the same file.
@test "the signature is the HMAC of the sent bytes" {
    run_step
    expected=$(python3 - "$body" <<'PY'
import hashlib
import hmac
import os
import sys

with open(sys.argv[1], "rb") as handle:
    data = handle.read()
print(hmac.new(os.environ["DEPLOY_WEBHOOK_SECRET"].encode(), data, hashlib.sha256).hexdigest())
PY
    )
    assert_equal "$signature" "$expected"
}

# The whole point of dropping the header: the wire carries the timestamp once,
# inside the signed bytes, so a header/body disagreement cannot exist.
@test "the request carries no timestamp header" {
    run_step
    refute grep -qE '^X-Deploy-Timestamp' "$argv"
}

@test "the webhook secret never reaches curl's argv" {
    run_step
    refute grep -qF -- "$DEPLOY_WEBHOOK_SECRET" "$work/log" "$argv"
}

# --- no PR can reach the job -------------------------------------------------

@test "the publish workflow has no pull_request trigger" {
    triggers=$(awk '/^on:/ { inside = 1; next } inside && /^[a-z]/ { exit } inside { print }' "$workflow")
    refute grep -qE 'pull_request' <<<"$triggers"
}

@test "no pull_request workflow references a secret" {
    run scripts/check-pr-secret-boundary.sh
    assert_success
}

@test "every action reference is SHA-pinned" {
    run scripts/check-action-pins.sh
    assert_success
}

# --- the suite runs in CI ----------------------------------------------------
# The deploy area job is what runs this suite. Asserting its filter expression --
# and not a prefix of one -- keeps this honest: an expression that stops naming
# the area fails here instead of quietly selecting nothing.
@test "CI runs the deploy area job (notify, poll, heartbeat included)" {
    assert grep -qE -- "--filter-tags 'deploy'" "$ci"
}
