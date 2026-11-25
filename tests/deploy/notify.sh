#!/usr/bin/env bash
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
#   tests/deploy/notify.sh
# shellcheck disable=SC2016  # the patterns below are the step's own literal text
set -uo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root" || exit 1

workflow=.github/workflows/publish-server-image.yml
ci=.github/workflows/ci.yml
for file in "$workflow" "$ci" scripts/check-action-pins.sh scripts/check-pr-secret-boundary.sh; do
  [[ -r $file ]] || {
    printf 'FAIL %s is missing\n' "$file" >&2
    exit 1
  }
done
for tool in jq python3 git; do
  command -v "$tool" >/dev/null || {
    printf 'FAIL %s is required\n' "$tool" >&2
    exit 1
  }
done

# shellcheck source=tests/deploy/lib.sh
source "$root/tests/deploy/lib.sh"

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

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

job_block "$workflow" notify >"$work/notify.yml"

if [[ -s $work/notify.yml ]]; then
  ok "the publish workflow has a notify job"
else
  bad "the publish workflow has a notify job"
fi
job=$(cat "$work/notify.yml")

# --- the job is a notification, not a gate ------------------------------------

check_match "$job" '^    needs: publish$' "notify runs after the build, not before it"
check_match "$job" "^    if: github\.event_name == 'workflow_dispatch' && github\.ref == 'refs/heads/main'$" \
  "notify runs from a main dispatch only"
check_match "$job" '^    environment: deploy-notify$' "notify uses its own Environment"
check_match "$job" '^    permissions: \{\}$' "notify holds no permission on the repository"
# The signing key lives in the `server-image` Environment and nowhere else: a job
# that could read it would make the deploy node part of the same trust domain.
check_no_match "$job" 'COSIGN_' "notify never names the signing key"
if grep -qE '^    environment: server-image$' <<<"$job"; then
  bad "notify never joins the signing Environment"
else
  ok "notify never joins the signing Environment"
fi
check_no_match "$job" 'actions/checkout' "notify checks nothing out (it needs no repository content)"
named=$(grep -oE '\$\{\{ *secrets\.[A-Za-z0-9_]+' <<<"$job" | sed 's/.*secrets\.//' | sort -u | tr '\n' ' ')
check_eq "$named" 'DEPLOY_WEBHOOK_SECRET TS_OAUTH_CLIENT_ID TS_OAUTH_CLIENT_SECRET ' \
  "notify reads only the deploy credentials"

# --- the tailnet node ---------------------------------------------------------

action=$(grep -E '^[[:space:]]*(- )?uses:[[:space:]]*tailscale/github-action@' <<<"$job" || true)
if [[ -z $action ]]; then
  bad "notify joins the tailnet through the Tailscale action"
else
  ok "notify joins the tailnet through the Tailscale action"
  ref=${action##*@}
  ref=${ref%%[[:space:]]*}
  if [[ $ref =~ ^[0-9a-f]{40}$ ]]; then
    ok "the Tailscale action is pinned to a full commit SHA"
  else
    bad "the Tailscale action is pinned to a full commit SHA" "$ref"
  fi
fi
check_match "$job" 'tags: tag:deploy' "the notify node carries tag:deploy"
check_match "$job" 'oauth-client-id: \$\{\{ secrets\.TS_OAUTH_CLIENT_ID \}\}' \
  "the node is minted from the deploy OAuth client"
check_match "$job" 'oauth-secret: \$\{\{ secrets\.TS_OAUTH_CLIENT_SECRET \}\}' \
  "the node is minted from the deploy OAuth client secret"

# --- the body, the signature and the send ------------------------------------

run_block "$work/notify.yml" >"$work/step.sh"
step=$(cat "$work/step.sh")
if [[ -s $work/step.sh ]]; then
  ok "the notify step carries a script to run"
else
  bad "the notify step carries a script to run"
fi
check_match "$step" '"repo": os\.environ\["REPO_NAME"\]' "the body names the repository"
check_match "$step" '"commit": os\.environ\["COMMIT_SHA"\]' "the body names the commit"
check_match "$step" '"ts": now' "the body carries a unix timestamp"
check_match "$step" '"nonce": secrets\.token_hex\(16\)' "the body carries a 32-hex nonce"
check_match "$step" 'hmac\.new\(' "the signature is HMAC"
check_match "$step" 'hashlib\.sha256' "the signature is SHA-256"
check_match "$step" 'X-Deploy-Signature: sha256=\$sig' "the signature header is the design's"
# The skew is read from the body's `ts`, the one value the HMAC covers. An
# unsigned timestamp header was a second answer to the same question: the sender
# and the receiver could disagree and neither could be shown to be right.
check_no_match "$step" 'X-Deploy-Timestamp' "no unsigned timestamp header is sent"
check_match "$step" '--data-binary @"\$body"' "the body is sent with --data-binary from the file"
check_match "$step" '--fail-with-body --max-time 30' "the send is bounded and fails on a bad status"
check_match "$step" 'http://smortress:8484/v1/deploy' "the send targets the receiver over the tailnet"
# A `-d @file` strips newlines and re-encodes the body, so the bytes curl sends
# are not the bytes that were signed. The regression is silent on the wire and
# only shows up as a rejected HMAC.
check_no_match "$step" '(-d|--data) [`"]?@' "the body is never sent with -d/--data"
check_eq "$(grep -cF 'X-Deploy-Signature: sha256=$sig' <<<"$step")" 1 \
  "exactly one signature header is built, from the HMAC"
check_eq "$(grep -cF -- '--data-binary @"$body"' <<<"$step")" 1 "exactly one request sends the signed file"

# --- the step signs what it sends --------------------------------------------

# The script is executed as it ships, with a curl that records argv instead of
# dialling. The HMAC is then recomputed here from the file curl was handed: equal
# means the signed bytes and the sent bytes are the same file.
bin=$work/bin
mkdir -p "$bin" "$work/runner"
install_fake_curl "$bin"
: >"$work/argv"
export FAKE_CURL_LOG=$work/log
export FAKE_ARGV_LOG=$work/argv
export FAKE_CURL_RESPONSE='{"status":"queued","id":"00000000-0000-4000-8000-000000000000"}'
export PATH="$bin:$PATH"
export RUNNER_TEMP=$work/runner
export REPO_NAME=homelab-platform
export COMMIT_SHA=0123456789abcdef0123456789abcdef01234567
export DEPLOY_WEBHOOK_SECRET=$work/webhook-secret
printf '%s\n' "s3cr3t-$(printf '%032d' 0)" >"$DEPLOY_WEBHOOK_SECRET"

step_rc=0
bash "$work/step.sh" >"$work/stdout" 2>"$work/stderr" || step_rc=$?
check_eq "$step_rc" 0 "the notify step succeeds against a recording curl"

sent=$(awk 'prev == "--data-binary" { print; exit } { prev = $0 }' "$work/argv")
body=${sent#@}
if [[ -n $body && -s $body ]]; then
  ok "the step hands curl a body file"
else
  bad "the step hands curl a body file" "$(cat "$work/argv")"
fi

if [[ -s $body ]]; then
  check_eq "$(jq -r '.repo' "$body" 2>/dev/null)" homelab-platform "the body's repo is the short repository name"
  check_eq "$(jq -r '.commit' "$body" 2>/dev/null)" "$COMMIT_SHA" "the body's commit is the pushed sha"
  check_eq "$(jq -r '.ts | type' "$body" 2>/dev/null)" number "the body's ts is a number"
  check_eq "$(jq -r '.nonce | test("^[0-9a-f]{32}$")' "$body" 2>/dev/null)" true "the body's nonce is 32 hex"
  check_eq "$(jq -r 'keys_unsorted | join(",")' "$body" 2>/dev/null)" 'repo,commit,ts,nonce' \
    "the body is exactly the four keys"
fi

signature=$(awk 'prev == "-H" && /^X-Deploy-Signature: sha256=/ { sub(/^X-Deploy-Signature: sha256=/, ""); print; exit } { prev = $0 }' "$work/argv")
if [[ -s $body ]]; then
  expected=$(DEPLOY_WEBHOOK_SECRET=$DEPLOY_WEBHOOK_SECRET python3 - "$body" <<'PY'
import hashlib
import hmac
import os
import sys

with open(sys.argv[1], "rb") as handle:
    data = handle.read()
print(hmac.new(os.environ["DEPLOY_WEBHOOK_SECRET"].encode(), data, hashlib.sha256).hexdigest())
PY
)
  check_eq "$signature" "$expected" "the signature is the HMAC of the sent bytes"
fi
# The whole point of dropping the header: the wire carries the timestamp once,
# inside the signed bytes, so a header/body disagreement cannot exist.
if grep -qE '^X-Deploy-Timestamp' "$work/argv" 2>/dev/null; then
  bad "the request carries no timestamp header" "$(grep -E '^X-Deploy-Timestamp' "$work/argv")"
else
  ok "the request carries no timestamp header"
fi
if grep -qF -- "$DEPLOY_WEBHOOK_SECRET" "$work/log" "$work/argv" 2>/dev/null; then
  bad "the webhook secret never reaches curl's argv"
else
  ok "the webhook secret never reaches curl's argv"
fi

# --- no PR can reach the job -------------------------------------------------

triggers=$(awk '/^on:/ { inside = 1; next } inside && /^[a-z]/ { exit } inside { print }' "$workflow")
check_no_match "$triggers" 'pull_request' "the publish workflow has no pull_request trigger"
if scripts/check-pr-secret-boundary.sh >"$work/boundary" 2>&1; then
  ok "no pull_request workflow references a secret"
else
  bad "no pull_request workflow references a secret" "$(cat "$work/boundary")"
fi
if scripts/check-action-pins.sh >"$work/pins" 2>&1; then
  ok "every action reference is SHA-pinned"
else
  bad "every action reference is SHA-pinned" "$(cat "$work/pins")"
fi

# --- the suite runs in CI ----------------------------------------------------

if grep -qE 'check-all\.sh --only [A-Za-z0-9_,-]*deploy' "$ci"; then
  ok "CI runs the deploy group (notify, poll, heartbeat included)"
else
  bad "CI runs the deploy group (notify, poll, heartbeat included)"
fi

finish
