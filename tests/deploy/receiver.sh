#!/usr/bin/env bash
# Offline checks for the deploy receiver listener (SDLC #798, T1).
#
# The listener is the only thing on the tailnet side of the deploy path, so the
# whole contract is driven here against a real process on a loopback port: the
# HMAC over the exact bytes, the skew of the signed body's `ts`, the nonce ring,
# the repository allowlist, the body cap, the queue cap, the denylist, the
# already-deployed answer, the atomic queue write, the listener-only nonce file,
# the admission cap, the in-memory refusal tally (and that a refusal writes no
# journal line), and the refusal to start without a secret. No root, no network,
# no bootc.
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

# shellcheck source=tests/deploy/lib.sh
source "$root/tests/deploy/lib.sh"

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
# No timestamp header: the receiver reads the skew from the signed body's `ts`,
# so an extra header would be an unsigned second answer it has to ignore.
post_raw() { # <body> <signature> [<extra header>...]
  local payload=$1 signature=$2 file extra
  shift 2
  local -a headers=(--header 'Content-Type: application/json')
  if [[ -n $signature ]]; then headers+=(--header "X-Deploy-Signature: $signature"); fi
  for extra in "$@"; do headers+=(--header "$extra"); done
  file=$(mktemp "$work/body.XXXXXX")
  printf '%s' "$payload" >"$file"
  curl -sS --max-time 20 -o "$work/response" -w '%{http_code}' -X POST \
    "${headers[@]}" --data-binary "@$file" "$base/v1/deploy"
  rm -f "$file"
}
post() { # <body> <secret> [<extra header>...]
  local payload=$1 secret=$2 signature
  shift 2
  signature="sha256=$(printf '%s' "$payload" | hmac_hex "$secret")"
  post_raw "$payload" "$signature" "$@"
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

journal_before=$(sha256sum "$state_dir/journal.jsonl" 2>/dev/null || printf 'absent\n')
check_eq "$(post "$accepted" "${secret}wrong")" 401 "a bad HMAC is refused"
check_eq "$(post_raw "$accepted" '')" 401 "a missing signature is refused"
check_eq "$(post_raw "$accepted" 'sha256=nothex')" 401 "a malformed signature is refused"
stale=$(body homelab-platform "$commit_ok" $((now - 400)) "$nonce_ok")
future=$(body homelab-platform "$commit_ok" $((now + 400)) "$nonce_ok")
check_eq "$(post "$stale" "$secret")" 401 "a stale body timestamp is refused"
check_eq "$(post "$future" "$secret")" 401 "a future body timestamp is refused"
# A header that disagreed with the body is not read at all: the signed `ts` is
# the only clock, so a stale body stays refused however fresh the header claims
# to be, and a fresh body is queued however stale the header claims to be.
check_eq "$(post "$stale" "$secret" "X-Deploy-Timestamp: $now")" 401 \
  "a fresh timestamp header does not rescue a stale body"
check_eq "$(sha256sum "$state_dir/journal.jsonl" 2>/dev/null || printf 'absent\n')" \
  "$journal_before" "refused requests write no journal line"
# The refusal is still observable: it is counted in memory and reported by
# /healthz, so an fsync per unauthenticated attempt is not the price of seeing it.
tally=$(curl -sS --max-time 5 "$base/healthz" | jq -r '.rejected["bad-signature"] // 0')
if [[ $tally =~ ^[0-9]+$ ]] && ((tally >= 2)); then
  ok "/healthz counts the refusals instead of journaling them"
else
  bad "/healthz counts the refusals instead of journaling them" "$(curl -sS "$base/healthz")"
fi
check_eq "$(post "$accepted" "$secret")" 401 "a replayed nonce is refused"

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
# A refusal only a caller holding the secret can reach keeps its journal line:
# it names a commit a gate rejected, which is what an operator reads afterwards.
if jq -e 'select(.event == "deploy-rejected" and .reason == "denylisted-commit")' \
  "$state_dir/journal.jsonl" >/dev/null 2>&1; then
  ok "an authorized refusal is journaled with its reason"
else
  bad "an authorized refusal is journaled with its reason" "$(cat "$state_dir/journal.jsonl" 2>&1)"
fi

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
  -H "X-Deploy-Signature: $big_signature" \
  --data-binary "@$big" "$base/v1/deploy")" 413 "an oversize body is refused"

# --- admission: a refusal costs no lock and no disk write -------------------
# The lock serializes "nonce unseen -> queue it", so a request that will be
# refused must never take it: one authenticated request is answered while twenty
# unauthenticated ones are in flight, and none of the twenty appends a journal
# line (each line is an fsync an unauthenticated caller could then ask for).
burst_before=$(wc -l <"$state_dir/journal.jsonl")
burst_pids=()
for _ in $(seq 1 20); do
  (post "$accepted" "${secret}wrong" >/dev/null 2>&1) &
  burst_pids+=("$!")
done
burst_code=$(post "$(body homelab-apps "$commit_ok" "$now" 0000aaaabbbbccccddddeeeeffff0010)" "$secret")
wait "${burst_pids[@]}" 2>/dev/null
check_eq "$burst_code" 202 "a valid request is answered while refusals are in flight"
# One line for the request that was queued, nothing for the twenty that were
# refused: the difference is what an unauthenticated caller can make the
# receiver write.
check_eq "$(($(wc -l <"$state_dir/journal.jsonl") - burst_before))" 1 \
  "a burst of refusals writes only the queued request's line"
if jq -e 'select(.event == "deploy-rejected" and .reason == "bad-signature")' \
  "$state_dir/journal.jsonl" >/dev/null 2>&1; then
  bad "a refused signature is never journaled" \
    "$(jq -c 'select(.event == "deploy-rejected")' "$state_dir/journal.jsonl" | head -n 3)"
else
  ok "a refused signature is never journaled"
fi

# --- the concurrency cap ----------------------------------------------------
# A sender that connects and stalls holds a read slot for at most the read
# timeout; past the cap the answer is immediate, so a flood costs the listener a
# short-lived thread per connection instead of an unbounded body buffer.
stall() { # <port> <seconds>; sets stall_pid
  python3 - "$1" "$2" <<'PYSTALL' &
import socket
import sys
import time

sock = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=5)
sock.sendall(b"POST /v1/deploy HTTP/1.1\r\nHost: flood\r\nContent-Length: 64\r\n\r\n")
time.sleep(float(sys.argv[2]))
sock.close()
PYSTALL
  stall_pid=$!
}
flood_port=$(free_port)
DEPLOY_MAX_CONCURRENCY=2 start_listener "$state_dir" "$secrets_dir" "$flood_port" "$work/flood.log"
flood_base=http://127.0.0.1:$flood_port
if wait_for "$flood_port" 200; then
  ok "/healthz answers on the capped listener before any slot is taken"
else
  bad "/healthz answers on the capped listener before any slot is taken" "$(tail -n 5 "$work/flood.log")"
fi
flood_signature="sha256=$(printf '%s' "$accepted" | hmac_hex "${secret}bad")"
flood_code() {
  curl -sS --max-time 5 -o /dev/null -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' -H "X-Deploy-Signature: $flood_signature" \
    --data-binary "@$work/flood-body" "$flood_base/v1/deploy"
}
printf '%s' "$accepted" >"$work/flood-body"
stall "$flood_port" 6
flood_one=$stall_pid
stall "$flood_port" 6
flood_two=$stall_pid
flooded=
for _ in $(seq 1 60); do
  flooded=$(flood_code)
  [[ $flooded == 503 ]] && break
  sleep 0.1
done
check_eq "$flooded" 503 "a request past the concurrency cap is refused at once"
# The dead-man asks /healthz, so it must not queue behind a saturated listener.
check_eq "$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "$flood_base/healthz")" 200 \
  "/healthz answers while every read slot is taken"
wait "$flood_one" "$flood_two" 2>/dev/null
check_eq "$(post "$(body homelab-apps "$commit_ok" "$now" 0000aaaabbbbccccddddeeeeffff0011)" "$secret")" 202 \
  "the slots are released when the stalled senders give up"

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

# --- the queue-directory contract agrees across languages --------------------
# The listener counts entries in Python and the drain in bash. The contract,
# documented in scripts/deploy-state.sh, is one regular `.json` file directly
# inside the queue: a directory or a non-JSON name is not an entry. Both readers
# must agree on one fixture, or the listener's cap and the drain's view drift
# apart -- the listener would refuse at 33 while the drain sees 32.
fixture=$work/reader-fixture
mkdir -p "$fixture/queue/nested.json"
printf '{}\n' >"$fixture/queue/a.json"
printf '{}\n' >"$fixture/queue/b.json"
printf 'not an entry\n' >"$fixture/queue/notes.txt"
bash_entries=$(DEPLOY_STATE_DIR=$fixture bash -c '
  # shellcheck source=/dev/null
  source "'"$lib"'"
  queue_count
')
py_entries=$(DEPLOY_STATE_DIR=$fixture python3 - "$receiver" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("deploy_receiver", sys.argv[1])
module = importlib.util.module_from_spec(spec)
sys.modules["deploy_receiver"] = module
spec.loader.exec_module(module)
print(module.Receiver._queue_count())
PY
)
check_eq "$bash_entries" 2 "the bash queue reader counts the two entries"
check_eq "$py_entries" "$bash_entries" "the Python and bash queue readers agree on a fixture"

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
  --data-binary "@$work/bare-body" \
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

finish
