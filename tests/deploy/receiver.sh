#!/usr/bin/env bash
# Offline checks for the deploy receiver listener (SDLC #798, T1).
#
# The listener is the only thing on the tailnet side of the deploy path, so the
# whole contract is driven here against a real process on a loopback port: the
# HMAC over the exact bytes, the timestamp skew, the nonce ring, the repository
# allowlist, the body cap, the queue cap, the denylist, the already-deployed
# answer, the atomic queue write, the listener-only nonce file and the refusal
# to start without a secret. No root, no network, no bootc.
#
#   tests/deploy/receiver.sh
set -uo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root" || exit 1

receiver=image/rootfs/usr/libexec/deploy-receiver.py
lib=scripts/deploy-state.sh
for file in "$receiver" "$lib"; do
  [[ -r $file ]] || {
    printf 'FAIL %s is missing\n' "$file" >&2
    exit 1
  }
done
for tool in curl jq python3 timeout; do
  command -v "$tool" >/dev/null || {
    printf 'FAIL %s is required\n' "$tool" >&2
    exit 1
  }
done

pass=0
fail=0
ok() {
  pass=$((pass + 1))
  printf 'ok   %s\n' "$1"
}
bad() {
  fail=$((fail + 1))
  printf 'FAIL %s\n' "$1" >&2
  [[ -n ${2:-} ]] && printf '     %s\n' "${2//$'\n'/$'\n'     }" >&2
  return 0
}
check_eq() { # got want label
  if [[ $1 == "$2" ]]; then ok "$3"; else bad "$3" "want '$2', got '$1'"; fi
}

work=$(mktemp -d)
listener_pids=()
cleanup() {
  for pid in "${listener_pids[@]}"; do kill "$pid" 2>/dev/null; done
  wait 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

state_dir=$work/state
secrets_dir=$work/secrets
mkdir -p "$state_dir/queue" "$state_dir/work" "$secrets_dir"
chmod 0700 "$state_dir" "$state_dir/queue" "$secrets_dir"

# Two single-scalar ciphertexts is the whole secret contract: the current one is
# required, the next one only widens the rotation window.
secret=$(printf 'current-%04d' "$RANDOM")
secret_next=$(printf 'next-%04d' "$RANDOM")
printf 'value: %s\n' "$secret" >"$secrets_dir/webhook-secret.yaml"
printf 'value: %s\n' "$secret_next" >"$secrets_dir/webhook-secret-next.yaml"

# The state library is the one definition of the denylist and state shape; the
# listener reads what it writes, never the other way round.
export DEPLOY_STATE_DIR=$state_dir
export DEPLOY_LOCK_FILE=$work/deploy.lock
# shellcheck source=/dev/null
source "$lib"

free_port() {
  python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()'
}

hmac_hex() { # <secret> < body
  python3 -c 'import hashlib, hmac, sys
print(hmac.new(sys.argv[1].encode(), sys.stdin.buffer.read(), hashlib.sha256).hexdigest())' "$1"
}

# Assigns `listener_pid`: a command substitution would run in a subshell and the
# trap would then have no pid to kill.
start_listener() { # <state-dir> <secrets-dir> <port> [log]
  local log=${4:-$work/listener.log}
  DEPLOY_STATE_DIR=$1 DEPLOY_SECRETS_DIR=$2 DEPLOY_LISTEN_PORT=$3 \
    DEPLOY_LISTEN_HOST=127.0.0.1 python3 "$receiver" >>"$log" 2>&1 &
  listener_pid=$!
  listener_pids+=("$listener_pid")
}

# A listener that never answers must not hang the suite.
wait_for() { # <port> <expected-code>
  local port=$1 want=$2 code
  for _ in $(seq 1 100); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 1 \
      "http://127.0.0.1:$port/healthz" 2>/dev/null)
    [[ $code == "$want" ]] && return 0
    sleep 0.1
  done
  return 1
}

port=$(free_port)
base=http://127.0.0.1:$port
start_listener "$state_dir" "$secrets_dir" "$port"
if wait_for "$port" 200; then ok "/healthz answers 200 with a secret loaded"; else
  bad "/healthz answers 200 with a secret loaded" "$(tail -n 5 "$work/listener.log")"
fi

body() { # repo commit ts nonce
  jq -nc --arg repo "$1" --arg commit "$2" --argjson ts "$3" --arg nonce "$4" \
    '{repo:$repo,commit:$commit,ts:$ts,nonce:$nonce}'
}
post_raw() { # <body> <signature> <timestamp>
  local payload=$1 signature=$2 ts=$3 file
  file=$(mktemp "$work/body.XXXXXX")
  printf '%s' "$payload" >"$file"
  curl -sS --max-time 20 -o "$work/response" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' \
    -H "X-Deploy-Signature: $signature" -H "X-Deploy-Timestamp: $ts" \
    --data-binary "@$file" "$base/v1/deploy"
  rm -f "$file"
}
post() { # <body> <secret> [<timestamp>]
  local payload=$1 secret=$2 ts=${3:-$(date +%s)} signature
  signature="sha256=$(printf '%s' "$payload" | hmac_hex "$secret")"
  post_raw "$payload" "$signature" "$ts"
}

commit_ok=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
nonce_ok=0000aaaabbbbccccddddeeeeffff0001
now=$(date +%s)

accepted=$(body homelab-platform "$commit_ok" "$now" "$nonce_ok")
check_eq "$(post "$accepted" "$secret")" 202 "a signed request is queued"
queue_id=$(jq -r .id "$work/response")
if [[ $queue_id =~ ^[0-9a-f-]{36}$ ]] && [[ -s $state_dir/queue/$queue_id.json ]]; then
  ok "the response carries the queue id"
else
  bad "the response carries the queue id" "$(cat "$work/response")"
fi
check_eq "$(jq -r .repo "$state_dir/queue/$queue_id.json")" homelab-platform \
  "the queue entry carries the repository"
check_eq "$(jq -r .commit "$state_dir/queue/$queue_id.json")" "$commit_ok" \
  "the queue entry carries the commit"
if jq -e . "$state_dir/queue/$queue_id.json" >/dev/null 2>&1; then
  ok "the queue entry is complete JSON"
else
  bad "the queue entry is complete JSON"
fi
check_eq "$(find "$state_dir/queue" -name '*.tmp' -o -name '.*' | wc -l)" 0 \
  "the queue write leaves no temp file behind"

check_eq "$(post "$accepted" "${secret}wrong")" 401 "a bad HMAC is refused"
check_eq "$(post_raw "$accepted" '' "$now")" 401 "a missing signature is refused"
check_eq "$(post_raw "$accepted" 'sha256=nothex' "$now")" 401 "a malformed signature is refused"
check_eq "$(post "$accepted" "$secret" $((now - 400)))" 401 "a stale timestamp is refused"
check_eq "$(post "$accepted" "$secret" $((now + 400)))" 401 "a future timestamp is refused"
check_eq "$(post "$accepted" "$secret")" 401 "a replayed nonce is refused"
if jq -e 'select(.event == "deploy-rejected" and .reason == "replayed-nonce")' \
  "$state_dir/journal.jsonl" >/dev/null 2>&1; then
  ok "a refusal is journaled with its reason"
else
  bad "a refusal is journaled with its reason" "$(cat "$state_dir/journal.jsonl" 2>&1)"
fi

replay_nonce=0000aaaabbbbccccddddeeeeffff0002
check_eq "$(post '{"repo": ' "$secret")" 400 "a malformed body is refused"
check_eq "$(post "$(body homelab-other "$commit_ok" "$now" "$replay_nonce")" "$secret")" 400 \
  "a repository outside the allowlist is refused"
check_eq "$(post "$(body homelab-apps 'deadbeef' "$now" "$replay_nonce")" "$secret")" 400 \
  "a commit that is not a 40-hex sha is refused"
check_eq "$(post "$(body homelab-apps "$commit_ok" "$now" 'short')" "$secret")" 400 \
  "a nonce that is not 32 hex is refused"

check_eq "$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' "$base/v1/deploy")" 404 \
  "the queue route refuses a GET"

# The next secret is accepted during the rotation window; a request signed with
# neither is not.
check_eq "$(post "$(body homelab-apps "$commit_ok" "$now" 0000aaaabbbbccccddddeeeeffff0003)" "$secret_next")" 202 \
  "the next secret is accepted"

denied=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
denylist_add commit "$denied" 'failed the boot gate'
check_eq "$(post "$(body homelab-platform "$denied" "$now" 0000aaaabbbbccccddddeeeeffff0004)" "$secret")" 409 \
  "a denylisted commit is refused"

# An already-deployed commit answers 200 and queues nothing: the caller learns
# the request was a no-op instead of waiting for a deploy that will not happen.
deployed=cccccccccccccccccccccccccccccccccccccccc
apps_deployed=dddddddddddddddddddddddddddddddddddddddd
jq -nc --arg commit "$deployed" --arg apps "$apps_deployed" \
  '{schema:1,
    repos:{"homelab-platform":{commit:$commit,indexDigest:null,manifestDigest:null},
           "homelab-apps":{commit:$apps}},
    apps:{unitsHash:null,secretsHash:null}}' |
  atomic_write "$state_dir/state.json"
state_before=$(sha256sum "$state_dir/state.json")
queued_before=$(queue_count)
check_eq "$(post "$(body homelab-platform "$deployed" "$now" 0000aaaabbbbccccddddeeeeffff0005)" "$secret")" 200 \
  "a commit already deployed answers 200"
check_eq "$(queue_count)" "$queued_before" "an already-deployed commit queues no work"
check_eq "$(post "$(body homelab-apps "$apps_deployed" "$now" 0000aaaabbbbccccddddeeeeffff0006)" "$secret")" 200 \
  "the apps repository answers 200 for its own deployed commit"

# Oversize: the cap is checked from Content-Length before a byte is buffered.
big=$work/big.json
head -c 65537 /dev/zero | tr '\0' 'a' >"$big"
big_signature="sha256=$(hmac_hex "$secret" <"$big")"
check_eq "$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' -X POST \
  -H 'Content-Type: application/json' -H 'Expect:' \
  -H "X-Deploy-Signature: $big_signature" -H "X-Deploy-Timestamp: $now" \
  --data-binary "@$big" "$base/v1/deploy")" 413 "an oversize body is refused"

# Queue cap: the listener must not grow the backlog past what the drain can
# answer; over the cap it refuses instead of queueing.
for _ in $(seq 1 32); do
  [[ $(queue_count) -lt 32 ]] || break
  filler=$(python3 -c 'import uuid; print(uuid.uuid4())')
  jq -nc --arg id "$filler" --argjson at "$((now - 100))" \
    '{schema:1,id:$id,repo:"homelab-platform",commit:"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
      queued_at:$at,source:"event"}' |
    atomic_write "$state_dir/queue/$filler.json"
done
check_eq "$(post "$(body homelab-apps "$commit_ok" "$now" 0000aaaabbbbccccddddeeeeffff0007)" "$secret")" 429 \
  "a full queue is refused"
check_eq "$(queue_count)" 32 "a refused request grows no queue"

# The nonce ring is the listener's own file, written under its own lock, and it
# must never touch the drain's state.json.
if jq -e '.nonces | length > 0' "$state_dir/nonces.json" >/dev/null 2>&1; then
  ok "the listener records accepted nonces"
else
  bad "the listener records accepted nonces" "$(cat "$state_dir/nonces.json" 2>&1)"
fi
if jq -e --arg nonce "$nonce_ok" '.nonces | has($nonce)' "$state_dir/nonces.json" >/dev/null; then
  ok "the recorded nonce is the accepted one"
else
  bad "the recorded nonce is the accepted one"
fi
check_eq "$(sha256sum "$state_dir/state.json")" "$state_before" \
  "the listener never writes state.json"
if [[ -f $state_dir/listener.lock ]]; then
  ok "the listener takes its own lock file"
else
  bad "the listener takes its own lock file"
fi

# The queue is the health signal: a listener that cannot write it must say so
# rather than accept a request it will lose.
ro_state=$work/ro-state
mkdir -p "$ro_state/queue"
chmod 0500 "$ro_state/queue"
ro_port=$(free_port)
start_listener "$ro_state" "$secrets_dir" "$ro_port" "$work/ro.log"
if [[ $EUID -eq 0 ]]; then
  ok "/healthz reflects an unwritable queue (skipped as root)"
elif wait_for "$ro_port" 503; then
  ok "/healthz answers 503 when the queue is unwritable"
else
  bad "/healthz answers 503 when the queue is unwritable" "$(tail -n 5 "$work/ro.log")"
fi

# sops-decrypt's `value` format writes the scalar alone, not `value: <scalar>`,
# and every host gets its webhook secrets that way. A listener that only understood
# `value:` would pass every fixture that spells the key out and refuse to start on
# the real host, which is the deploy path down with no page.
bare_secrets=$work/bare-secrets
bare_state=$work/bare-state
mkdir -p "$bare_secrets" "$bare_state/queue" "$bare_state/work"
chmod 0700 "$bare_secrets" "$bare_state" "$bare_state/queue"
printf '%s\n' "$secret" >"$bare_secrets/webhook-secret.yaml"
printf '%s\n' "$secret_next" >"$bare_secrets/webhook-secret-next.yaml"
bare_port=$(free_port)
start_listener "$bare_state" "$bare_secrets" "$bare_port" "$work/bare.log"
if wait_for "$bare_port" 200; then
  ok "the listener starts from the bare scalar sops-decrypt writes"
else
  bad "the listener starts from the bare scalar sops-decrypt writes" "$(tail -n 5 "$work/bare.log")"
fi
bare_ts=$(date +%s)
bare_body=$(body homelab-apps "$commit_ok" "$bare_ts" 0000aaaabbbbccccddddeeeeffff0009)
bare_signature="sha256=$(printf '%s' "$bare_body" | hmac_hex "$secret")"
printf '%s' "$bare_body" >"$work/bare-body"
check_eq "$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' -X POST \
  -H 'Content-Type: application/json' -H "X-Deploy-Signature: $bare_signature" \
  -H "X-Deploy-Timestamp: $bare_ts" --data-binary "@$work/bare-body" \
  "http://127.0.0.1:$bare_port/v1/deploy")" 202 \
  "a request signed with the bare-scalar secret is queued"

# No secret means no listener: an empty `value:` is a failed decrypt, and a
# listener that started anyway would answer 202 to nothing.
empty_secrets=$work/empty-secrets
mkdir -p "$empty_secrets"
printf 'value:\n' >"$empty_secrets/webhook-secret.yaml"
empty_port=$(free_port)
DEPLOY_STATE_DIR=$state_dir DEPLOY_SECRETS_DIR=$empty_secrets DEPLOY_LISTEN_PORT=$empty_port \
  timeout 20 python3 "$receiver" >"$work/empty.log" 2>&1
rc=$?
if ((rc != 0 && rc != 124)); then
  ok "the listener refuses to start without a secret"
else
  bad "the listener refuses to start without a secret" "exit $rc"
fi
missing_port=$(free_port)
DEPLOY_STATE_DIR=$state_dir DEPLOY_SECRETS_DIR=$work/no-such-dir DEPLOY_LISTEN_PORT=$missing_port \
  timeout 20 python3 "$receiver" >"$work/missing.log" 2>&1
rc=$?
if ((rc != 0 && rc != 124)); then
  ok "the listener refuses to start without the secret file"
else
  bad "the listener refuses to start without the secret file" "exit $rc"
fi

# The listener is loopback-only by construction; a wildcard bind would violate
# the image's no-wildcard assertion and add no reach the tailnet needs.
if grep -nE '\b0\.0\.0\.0\b|\[::\]' "$receiver" >/dev/null; then
  bad "the listener binds loopback only" "$(grep -nE '\b0\.0\.0\.0\b|\[::\]' "$receiver")"
else
  ok "the listener binds loopback only"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
