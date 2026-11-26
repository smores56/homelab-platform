#!/usr/bin/env bats
# bats file_tags=deploy
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
#   tests/deploy/receiver.bats
load ../helpers

receiver=image/rootfs/usr/libexec/deploy-receiver.py
lib=scripts/deploy-state.sh

commit_ok=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
# A commit no other test names: the burst-refusal case must be able to say its
# own window carried exactly one line, and a commit an earlier test already
# queued or marked deployed can add a line of its own (issue #156).
burst_only=1111111111111111111111111111111111111111
denied=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
deployed=cccccccccccccccccccccccccccccccccccccccc
apps_deployed=dddddddddddddddddddddddddddddddddddddddd

# The listener is the subject of almost every scenario below and its nonce ring,
# journal and queue are the state the later ones read, so one process serves the
# whole file: setup_file starts it under $BATS_FILE_TMPDIR, teardown_file kills
# it. bats runs a file's tests in order, and the old suite ran them in this order
# against one listener. Every other listener (a capped one, an unwritable-queue
# one, a bare-secret one) is started and killed by the single test that needs it.
setup_file() {
    local work=$BATS_FILE_TMPDIR state=$BATS_FILE_TMPDIR/state
    local secrets=$BATS_FILE_TMPDIR/secrets port secret next

    mkdir -p "$state/queue" "$state/work" "$secrets"
    chmod 0700 "$state" "$state/queue" "$secrets"

    # Two single-scalar ciphertexts is the whole secret contract: the current one
    # is required, the next one only widens the rotation window.
    secret=$(printf 'current-%04d' "$RANDOM")
    next=$(printf 'next-%04d' "$RANDOM")
    printf 'value: %s\n' "$secret" >"$secrets/webhook-secret.yaml"
    printf 'value: %s\n' "$next" >"$secrets/webhook-secret-next.yaml"
    printf '%s\n' "$secret" >"$work/secret"
    printf '%s\n' "$next" >"$work/secret-next"

    port=$(free_port)
    printf '%s\n' "$port" >"$work/port"
    start_listener "$state" "$secrets" "$port" "$work/listener.log"
    printf '%s\n' "$listener_pid" >"$work/listener.pid"
    # A listener that never answers must not hang the suite: failing here fails
    # the file, with its log, instead of one check per scenario.
    wait_for "$port" 200 || {
        tail -n 5 "$work/listener.log" >&2
        return 1
    }
}

teardown_file() {
    local pid
    pid=$(cat "$BATS_FILE_TMPDIR/listener.pid" 2>/dev/null) || return 0
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 50); do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.1
    done
}

setup() {
    work=$BATS_FILE_TMPDIR
    state_dir=$work/state
    secrets_dir=$work/secrets
    port=$(cat "$work/port")
    base=http://127.0.0.1:$port
    secret=$(cat "$work/secret")
    secret_next=$(cat "$work/secret-next")
    now=$(date +%s)
    accepted=$(body homelab-platform "$commit_ok" "$now" "$(nonce)")
    pids=()
    stall_pids=()

    for file in "$receiver" "$lib"; do
        [[ -r $file ]] || fail "$file is missing"
    done
    for tool in curl jq python3 timeout; do
        command -v "$tool" >/dev/null || fail "$tool is required"
    done

    # The state library is the one definition of the denylist and state shape;
    # the listener reads what it writes, never the other way round.
    export DEPLOY_STATE_DIR=$state_dir
    export DEPLOY_LOCK_FILE=$work/deploy.lock
    # shellcheck source=/dev/null
    source "$lib"
}

teardown() {
    local pid
    for pid in "${pids[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    wait 2>/dev/null || true
}

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
# teardown would then have no pid to kill.
start_listener() { # <state-dir> <secrets-dir> <port> <log> [<VAR=value>...]
    local state=$1 secrets=$2 port=$3 log=$4
    shift 4
    env "$@" DEPLOY_STATE_DIR="$state" DEPLOY_SECRETS_DIR="$secrets" \
        DEPLOY_LISTEN_PORT="$port" DEPLOY_LISTEN_HOST=127.0.0.1 \
        python3 "$receiver" >>"$log" 2>&1 &
    listener_pid=$!
}

# A listener that never answers must not hang the suite.
wait_for() { # <port> <expected-code>
    local want=$2 code
    for _ in $(seq 1 100); do
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 1 \
            "http://127.0.0.1:$1/healthz" 2>/dev/null) || true
        if [[ $code == "$want" ]]; then return 0; fi
        sleep 0.1
    done
    return 1
}

# A GET's status is the assertion, so a transport error is the code curl prints
# (`000`) rather than a test abort.
status_of() { # <url>
    curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || true
}

# journal_lines: the journal's line count, zero when the file is absent. Earlier
# tests in the file create it, so a filtered run must not read the difference
# from a missing file (#156).
journal_lines() {
    if [[ -f $state_dir/journal.jsonl ]]; then
        wc -l <"$state_dir/journal.jsonl" | tr -d ' '
    else
        printf '0\n'
    fi
}

# Every request needs a nonce the ring has not seen: a reused one would exercise
# the replay refusal instead of the case at hand.
nonce() { head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

body() { # repo commit ts nonce
    jq -nc --arg repo "$1" --arg commit "$2" --argjson ts "$3" --arg nonce "$4" \
        '{repo:$repo,commit:$commit,ts:$ts,nonce:$nonce}'
}

# No timestamp header: the receiver reads the skew from the signed body's `ts`,
# so an extra header would be an unsigned second answer it has to ignore.
post_raw() { # <base> <body> <signature> [<extra header>...]
    local base_url=$1 payload=$2 signature=$3 file extra
    shift 3
    local -a headers=(--header 'Content-Type: application/json')
    if [[ -n $signature ]]; then headers+=(--header "X-Deploy-Signature: $signature"); fi
    for extra in "$@"; do headers+=(--header "$extra"); done
    file=$(mktemp "$BATS_TEST_TMPDIR/body.XXXXXX")
    printf '%s' "$payload" >"$file"
    curl -sS --max-time 20 -o "$BATS_TEST_TMPDIR/response" -w '%{http_code}' -X POST \
        "${headers[@]}" --data-binary "@$file" "$base_url/v1/deploy"
    rm -f "$file"
}

post() { # <base> <body> <secret> [<extra header>...]
    local base_url=$1 payload=$2 key=$3 signature
    shift 3
    signature="sha256=$(printf '%s' "$payload" | hmac_hex "$key")"
    post_raw "$base_url" "$payload" "$signature" "$@"
}

# The fixture of a "wrote nothing" or "answered 200" case: the answer really was
# $2, so the assertion below cannot pass for the wrong reason.
guard() { # <got> <want> <what>
    [[ $1 == "$2" ]] ||
        fail "$3: expected $2, got $1: $(cat "$BATS_TEST_TMPDIR/response" 2>/dev/null)"
}

# Queues one request and prints its id: the 202 is the fixture these cases need,
# the entry's own assertions are theirs.
queue_one() { # <repo> <commit>
    local request code
    request=$(body "$1" "$2" "$now" "$(nonce)")
    code=$(post "$base" "$request" "$secret")
    guard "$code" 202 "queueing failed"
    jq -r .id "$BATS_TEST_TMPDIR/response"
}

# queue_count against a state dir other than the one this test exported.
queue_count_in() { # <state-dir>
    DEPLOY_STATE_DIR=$1 bash -c 'source "$1" >/dev/null; queue_count' _ "$lib"
}

# The drain's state.json, the only drain document the listener reads.
state_fixture() {
    jq -nc --arg commit "$deployed" --arg apps "$apps_deployed" \
        '{schema:1,
          repos:{"homelab-platform":{commit:$commit,indexDigest:null,manifestDigest:null},
                 "homelab-apps":{commit:$apps}},
          apps:{unitsHash:null,secretsHash:null}}' |
        atomic_write "$state_dir/state.json"
}

@test "/healthz answers 200 with a secret loaded" {
    assert_equal "$(status_of "$base/healthz")" 200
}

@test "a signed request is queued" {
    request=$(body homelab-platform "$commit_ok" "$now" "$(nonce)")
    assert_equal "$(post "$base" "$request" "$secret")" 202
}

@test "the response carries the queue id" {
    queue_id=$(queue_one homelab-platform "$commit_ok")
    assert_regex "$queue_id" '^[0-9a-f-]{36}$'
    assert [ -s "$state_dir/queue/$queue_id.json" ]
}

@test "the queue entry carries the repository" {
    queue_id=$(queue_one homelab-platform "$commit_ok")
    assert_equal "$(jq -r .repo "$state_dir/queue/$queue_id.json")" homelab-platform
}

@test "the queue entry carries the commit" {
    queue_id=$(queue_one homelab-platform "$commit_ok")
    assert_equal "$(jq -r .commit "$state_dir/queue/$queue_id.json")" "$commit_ok"
}

@test "the queue entry is complete JSON" {
    queue_id=$(queue_one homelab-platform "$commit_ok")
    run jq -e . "$state_dir/queue/$queue_id.json"
    assert_success
}

@test "the queue write leaves no temp file behind" {
    queue_one homelab-platform "$commit_ok" >/dev/null
    assert_equal "$(find "$state_dir/queue" -name '*.tmp' -o -name '.*' | wc -l)" 0
}

@test "a bad HMAC is refused" {
    request=$(body homelab-platform "$commit_ok" "$now" "$(nonce)")
    assert_equal "$(post "$base" "$request" "${secret}wrong")" 401
}

@test "a missing signature is refused" {
    request=$(body homelab-platform "$commit_ok" "$now" "$(nonce)")
    assert_equal "$(post_raw "$base" "$request" '')" 401
}

@test "a malformed signature is refused" {
    request=$(body homelab-platform "$commit_ok" "$now" "$(nonce)")
    assert_equal "$(post_raw "$base" "$request" 'sha256=nothex')" 401
}

@test "a stale body timestamp is refused" {
    request=$(body homelab-platform "$commit_ok" "$((now - 400))" "$(nonce)")
    assert_equal "$(post "$base" "$request" "$secret")" 401
}

@test "a future body timestamp is refused" {
    request=$(body homelab-platform "$commit_ok" "$((now + 400))" "$(nonce)")
    assert_equal "$(post "$base" "$request" "$secret")" 401
}

# A header that disagreed with the body is not read at all: the signed `ts` is
# the only clock, so a stale body stays refused however fresh the header claims
# to be, and a fresh body is queued however stale the header claims to be.
@test "a fresh timestamp header does not rescue a stale body" {
    request=$(body homelab-platform "$commit_ok" "$((now - 400))" "$(nonce)")
    assert_equal "$(post "$base" "$request" "$secret" "X-Deploy-Timestamp: $now")" 401
}

@test "refused requests write no journal line" {
    journal_before=$(sha256sum "$state_dir/journal.jsonl" 2>/dev/null || printf 'absent\n')
    request=$(body homelab-platform "$commit_ok" "$now" "$(nonce)")
    refusal=$(post "$base" "$request" "${secret}wrong")
    guard "$refusal" 401 "the request was not refused"
    assert_equal \
        "$(sha256sum "$state_dir/journal.jsonl" 2>/dev/null || printf 'absent\n')" \
        "$journal_before"
}

# The refusal is still observable: it is counted in memory and reported by
# /healthz, so an fsync per unauthenticated attempt is not the price of seeing it.
@test "/healthz counts the refusals instead of journaling them" {
    for _ in 1 2 3; do
        post "$base" "$accepted" "${secret}wrong" >/dev/null
    done
    tally=$(curl -sS --max-time 5 "$base/healthz" | jq -r '.rejected["bad-signature"] // 0')
    assert_regex "$tally" '^[0-9]+$'
    assert [ "$tally" -ge 2 ]
}

@test "a replayed nonce is refused" {
    request=$(body homelab-platform "$commit_ok" "$now" "$(nonce)")
    first=$(post "$base" "$request" "$secret")
    guard "$first" 202 "the first request was not queued"
    assert_equal "$(post "$base" "$request" "$secret")" 401
}

@test "a malformed body is refused" {
    assert_equal "$(post "$base" '{"repo": ' "$secret")" 400
}

@test "a repository outside the allowlist is refused" {
    request=$(body homelab-other "$commit_ok" "$now" "$(nonce)")
    assert_equal "$(post "$base" "$request" "$secret")" 400
}

@test "a commit that is not a 40-hex sha is refused" {
    request=$(body homelab-apps deadbeef "$now" "$(nonce)")
    assert_equal "$(post "$base" "$request" "$secret")" 400
}

@test "a nonce that is not 32 hex is refused" {
    request=$(body homelab-apps "$commit_ok" "$now" 'short')
    assert_equal "$(post "$base" "$request" "$secret")" 400
}

@test "the queue route refuses a GET" {
    assert_equal "$(status_of "$base/v1/deploy")" 404
}

# The next secret is accepted during the rotation window; a request signed with
# neither is not.
@test "the next secret is accepted" {
    request=$(body homelab-apps "$commit_ok" "$now" "$(nonce)")
    assert_equal "$(post "$base" "$request" "$secret_next")" 202
}

@test "a denylisted commit is refused" {
    denylist_add commit "$denied" 'failed the boot gate'
    request=$(body homelab-platform "$denied" "$now" "$(nonce)")
    assert_equal "$(post "$base" "$request" "$secret")" 409
}

# A refusal only a caller holding the secret can reach keeps its journal line:
# it names a commit a gate rejected, which is what an operator reads afterwards.
@test "an authorized refusal is journaled with its reason" {
    denylist_add commit "$denied" 'failed the boot gate'
    request=$(body homelab-platform "$denied" "$now" "$(nonce)")
    guard "$(post "$base" "$request" "$secret")" 409 "the denylisted commit was not refused"
    run jq -e 'select(.event == "deploy-rejected" and .reason == "denylisted-commit")' \
        "$state_dir/journal.jsonl"
    assert_success
}

# An already-deployed commit answers 200 and queues nothing: the caller learns
# the request was a no-op instead of waiting for a deploy that will not happen.
@test "a commit already deployed answers 200" {
    state_fixture
    request=$(body homelab-platform "$deployed" "$now" "$(nonce)")
    assert_equal "$(post "$base" "$request" "$secret")" 200
}

@test "an already-deployed commit queues no work" {
    state_fixture
    request=$(body homelab-platform "$deployed" "$now" "$(nonce)")
    queued_before=$(queue_count)
    guard "$(post "$base" "$request" "$secret")" 200 "the deployed commit was not answered 200"
    assert_equal "$(queue_count)" "$queued_before"
}

@test "the apps repository answers 200 for its own deployed commit" {
    state_fixture
    request=$(body homelab-apps "$apps_deployed" "$now" "$(nonce)")
    assert_equal "$(post "$base" "$request" "$secret")" 200
}

# Oversize: the cap is checked from Content-Length before a byte is buffered.
@test "an oversize body is refused" {
    big=$BATS_TEST_TMPDIR/big.json
    head -c 65537 /dev/zero | tr '\0' 'a' >"$big"
    big_signature="sha256=$(hmac_hex "$secret" <"$big")"
    code=$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' -X POST \
        -H 'Content-Type: application/json' -H 'Expect:' \
        -H "X-Deploy-Signature: $big_signature" \
        --data-binary "@$big" "$base/v1/deploy")
    assert_equal "$code" 413
}

# --- admission: a refusal costs no lock and no disk write -------------------
# The lock serializes "nonce unseen -> queue it", so a request that will be
# refused must never take it: one authenticated request is answered while twenty
# unauthenticated ones are in flight, and none of the twenty appends a journal
# line (each line is an fsync an unauthenticated caller could then ask for).
@test "a valid request is answered while refusals are in flight" {
    burst_pids=()
    for _ in $(seq 1 20); do
        (post "$base" "$accepted" "${secret}wrong" >/dev/null 2>&1) &
        burst_pids+=("$!")
    done
    request=$(body homelab-apps "$commit_ok" "$now" "$(nonce)")
    code=$(post "$base" "$request" "$secret")
    wait "${burst_pids[@]}" 2>/dev/null || true
    assert_equal "$code" 202
}

@test "a burst of refusals writes only the queued request's line" {
    local before new
    before=$(journal_lines)
    burst_pids=()
    for _ in $(seq 1 20); do
        (post "$base" "$accepted" "${secret}wrong" >/dev/null 2>&1) &
        burst_pids+=("$!")
    done
    request=$(body homelab-apps "$burst_only" "$now" "$(nonce)")
    code=$(post "$base" "$request" "$secret")
    wait "${burst_pids[@]}" 2>/dev/null || true
    guard "$code" 202 "the valid request was not queued"
    # One line for the request that was queued, nothing for the twenty that were
    # refused: the difference is what an unauthenticated caller can make the
    # receiver write. The event is named because a count alone cannot tell a
    # refusal that got journaled from an unrelated line: this test reported "1,
    # got 2" on CI and had no way to say which event it was (#156). The commit is
    # one no earlier test touches, so nothing else in this window can journal.
    new=$(sed -n "$((before + 1)),\$p" "$state_dir/journal.jsonl" 2>/dev/null || true)
    assert_equal "$(grep -c . <<<"$new" | tr -d ' ')" "1"
    assert_equal "$(jq -r '.event' <<<"$new")" "queue-enqueued"
    assert_equal "$(jq -r '.commit' <<<"$new")" "$burst_only"
}

@test "a refused signature is never journaled" {
    burst_pids=()
    for _ in $(seq 1 20); do
        (post "$base" "$accepted" "${secret}wrong" >/dev/null 2>&1) &
        burst_pids+=("$!")
    done
    wait "${burst_pids[@]}" 2>/dev/null || true
    rejected=''
    if jq -e 'select(.event == "deploy-rejected" and .reason == "bad-signature")' \
        "$state_dir/journal.jsonl" >/dev/null 2>&1; then
        rejected=$(jq -c 'select(.event == "deploy-rejected")' "$state_dir/journal.jsonl" | head -n 3)
    fi
    assert_equal "$rejected" ""
}

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
    pids+=("$stall_pid")
}

# A listener with two read slots: each assertion about the cap needs its own, so
# no scenario inherits a slot or a refusal from a sibling test.
capped_listener() { # -> flood_base, flood_signature, flood body
    flood_port=$(free_port)
    start_listener "$state_dir" "$secrets_dir" "$flood_port" \
        "$BATS_TEST_TMPDIR/flood.log" DEPLOY_MAX_CONCURRENCY=2
    pids+=("$listener_pid")
    flood_base=http://127.0.0.1:$flood_port
    wait_for "$flood_port" 200 ||
        fail "the capped listener never answered: $(tail -n 5 "$BATS_TEST_TMPDIR/flood.log")"
    flood_signature="sha256=$(printf '%s' "$accepted" | hmac_hex "${secret}bad")"
    printf '%s' "$accepted" >"$BATS_TEST_TMPDIR/flood-body"
}

stall_two() { # the two senders that take the capped listener's read slots
    stall "$flood_port" 6
    stall_pids+=("$stall_pid")
    stall "$flood_port" 6
    stall_pids+=("$stall_pid")
}

flood_code() {
    curl -sS --max-time 5 -o /dev/null -w '%{http_code}' -X POST \
        -H 'Content-Type: application/json' -H "X-Deploy-Signature: $flood_signature" \
        --data-binary "@$BATS_TEST_TMPDIR/flood-body" "$flood_base/v1/deploy" || true
}

@test "/healthz answers on the capped listener before any slot is taken" {
    capped_listener
    assert_equal "$(status_of "$flood_base/healthz")" 200
}

@test "a request past the concurrency cap is refused at once" {
    capped_listener
    stall_two
    flooded=''
    for _ in $(seq 1 60); do
        flooded=$(flood_code)
        if [[ $flooded == 503 ]]; then break; fi
        sleep 0.1
    done
    assert_equal "$flooded" 503
}

# The dead-man asks /healthz, so it must not queue behind a saturated listener.
@test "/healthz answers while every read slot is taken" {
    capped_listener
    stall_two
    assert_equal "$(status_of "$flood_base/healthz")" 200
}

@test "the slots are released when the stalled senders give up" {
    capped_listener
    stall_two
    wait "${stall_pids[@]}" 2>/dev/null || true
    request=$(body homelab-apps "$commit_ok" "$now" "$(nonce)")
    assert_equal "$(post "$base" "$request" "$secret")" 202
}

# Queue cap: the listener must not grow the backlog past what the drain can
# answer; over the cap it refuses instead of queueing.
fill_queue() { # <state-dir>: the listener's cap, 32 entries
    local dir=$1 id i
    for i in $(seq 1 32); do
        id=$(python3 -c 'import uuid; print(uuid.uuid4())')
        jq -nc --arg id "$id" --argjson at "$((now - 100))" \
            '{schema:1,id:$id,repo:"homelab-platform",commit:"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
              queued_at:$at,source:"event"}' |
            atomic_write "$dir/queue/$id.json"
    done
}

# A full queue in a state dir of its own, so the shared listener's queue stays
# as short as the cases above left it. The fill is a fixture, not the subject,
# but it has to be per test: bats runs the file's cases concurrently under
# --jobs, and a fill shared through $BATS_FILE_TMPDIR let both cases fill the
# same directory, so the second one counted 64 entries.
capped_queue() { # -> cap_base
    cap_state=$BATS_TEST_TMPDIR/cap-state
    mkdir -p "$cap_state/queue" "$cap_state/work"
    chmod 0700 "$cap_state" "$cap_state/queue"
    fill_queue "$cap_state"
    cap_port=$(free_port)
    start_listener "$cap_state" "$secrets_dir" "$cap_port" "$BATS_TEST_TMPDIR/cap.log"
    pids+=("$listener_pid")
    cap_base=http://127.0.0.1:$cap_port
    wait_for "$cap_port" 200 ||
        fail "the capped-queue listener never answered: $(tail -n 5 "$BATS_TEST_TMPDIR/cap.log")"
}

@test "a full queue is refused" {
    capped_queue
    request=$(body homelab-apps "$commit_ok" "$now" "$(nonce)")
    assert_equal "$(post "$cap_base" "$request" "$secret")" 429
}

@test "a refused request grows no queue" {
    capped_queue
    request=$(body homelab-apps "$commit_ok" "$now" "$(nonce)")
    guard "$(post "$cap_base" "$request" "$secret")" 429 "the full queue did not refuse"
    assert_equal "$(queue_count_in "$cap_state")" 32
}

# --- the queue-directory contract agrees across languages --------------------
# The listener counts entries in Python and the drain in bash. The contract,
# documented in scripts/deploy-state.sh, is one regular `.json` file directly
# inside the queue: a directory or a non-JSON name is not an entry. Both readers
# must agree on one fixture, or the listener's cap and the drain's view drift
# apart -- the listener would refuse at 33 while the drain sees 32.
reader_fixture() { # -> fixture
    fixture=$BATS_TEST_TMPDIR/reader-fixture
    mkdir -p "$fixture/queue/nested.json"
    printf '{}\n' >"$fixture/queue/a.json"
    printf '{}\n' >"$fixture/queue/b.json"
    printf 'not an entry\n' >"$fixture/queue/notes.txt"
}

@test "the bash queue reader counts the two entries" {
    reader_fixture
    assert_equal "$(queue_count_in "$fixture")" 2
}

@test "the Python and bash queue readers agree on a fixture" {
    reader_fixture
    bash_entries=$(queue_count_in "$fixture")
    py_entries=$(DEPLOY_STATE_DIR=$fixture python3 - "$receiver" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("deploy_receiver", sys.argv[1])
module = importlib.util.module_from_spec(spec)
sys.modules["deploy_receiver"] = module
spec.loader.exec_module(module)
print(module.Receiver._queue_count())
PY
)
    assert_equal "$py_entries" "$bash_entries"
}

# The nonce ring is the listener's own file, written under its own lock, and it
# must never touch the drain's state.json.
@test "the listener records accepted nonces" {
    request=$(body homelab-platform "$commit_ok" "$now" "$(nonce)")
    guard "$(post "$base" "$request" "$secret")" 202 "the request was not queued"
    run jq -e '.nonces | length > 0' "$state_dir/nonces.json"
    assert_success
}

@test "the recorded nonce is the accepted one" {
    n=$(nonce)
    request=$(body homelab-platform "$commit_ok" "$now" "$n")
    guard "$(post "$base" "$request" "$secret")" 202 "the request was not queued"
    run jq -e --arg nonce "$n" '.nonces | has($nonce)' "$state_dir/nonces.json"
    assert_success
}

@test "the listener never writes state.json" {
    state_fixture
    state_before=$(sha256sum "$state_dir/state.json")
    request=$(body homelab-platform "$commit_ok" "$now" "$(nonce)")
    guard "$(post "$base" "$request" "$secret")" 202 "the request was not queued"
    assert_equal "$(sha256sum "$state_dir/state.json")" "$state_before"
}

@test "the listener takes its own lock file" {
    request=$(body homelab-platform "$commit_ok" "$now" "$(nonce)")
    guard "$(post "$base" "$request" "$secret")" 202 "the request was not queued"
    assert [ -f "$state_dir/listener.lock" ]
}

# The queue is the health signal: a listener that cannot write it must say so
# rather than accept a request it will lose.
@test "/healthz answers 503 when the queue is unwritable" {
    if ((EUID == 0)); then
        # The old suite skipped this check as root: the mode is not enforced for
        # a uid holding CAP_DAC_OVERRIDE, so 503 here would prove nothing.
        skip "the mode is not enforced as root"
    fi
    ro_state=$BATS_TEST_TMPDIR/ro-state
    mkdir -p "$ro_state/queue"
    chmod 0500 "$ro_state/queue"
    ro_port=$(free_port)
    start_listener "$ro_state" "$secrets_dir" "$ro_port" "$BATS_TEST_TMPDIR/ro.log"
    pids+=("$listener_pid")
    rc=0
    wait_for "$ro_port" 503 || rc=$?
    ((rc == 0)) || tail -n 5 "$BATS_TEST_TMPDIR/ro.log" >&2
    chmod 0700 "$ro_state/queue"
    assert_equal "$rc" 0
}

# sops-decrypt's `value` format writes the scalar alone, not `value: <scalar>`,
# and every host gets its webhook secrets that way. A listener that only understood
# `value:` would pass every fixture that spells the key out and refuse to start on
# the real host, which is the deploy path down with no page.
bare_fixture() { # -> bare_state, bare_secrets
    bare_secrets=$BATS_TEST_TMPDIR/bare-secrets
    bare_state=$BATS_TEST_TMPDIR/bare-state
    mkdir -p "$bare_secrets" "$bare_state/queue" "$bare_state/work"
    chmod 0700 "$bare_secrets" "$bare_state" "$bare_state/queue"
    printf '%s\n' "$secret" >"$bare_secrets/webhook-secret.yaml"
    printf '%s\n' "$secret_next" >"$bare_secrets/webhook-secret-next.yaml"
}

@test "the listener starts from the bare scalar sops-decrypt writes" {
    bare_fixture
    bare_port=$(free_port)
    start_listener "$bare_state" "$bare_secrets" "$bare_port" "$BATS_TEST_TMPDIR/bare.log"
    pids+=("$listener_pid")
    rc=0
    wait_for "$bare_port" 200 || rc=$?
    ((rc == 0)) || tail -n 5 "$BATS_TEST_TMPDIR/bare.log" >&2
    assert_equal "$rc" 0
}

@test "a request signed with the bare-scalar secret is queued" {
    bare_fixture
    bare_port=$(free_port)
    start_listener "$bare_state" "$bare_secrets" "$bare_port" "$BATS_TEST_TMPDIR/bare.log"
    pids+=("$listener_pid")
    wait_for "$bare_port" 200 ||
        fail "the bare-scalar listener never answered: $(tail -n 5 "$BATS_TEST_TMPDIR/bare.log")"
    request=$(body homelab-apps "$commit_ok" "$now" "$(nonce)")
    assert_equal "$(post "http://127.0.0.1:$bare_port" "$request" "$secret")" 202
}

# No secret means no listener: an empty `value:` is a failed decrypt, and a
# listener that started anyway would answer 202 to nothing.
@test "the listener refuses to start without a secret" {
    empty_secrets=$BATS_TEST_TMPDIR/empty-secrets
    mkdir -p "$empty_secrets"
    printf 'value:\n' >"$empty_secrets/webhook-secret.yaml"
    rc=0
    DEPLOY_STATE_DIR=$state_dir DEPLOY_SECRETS_DIR=$empty_secrets \
        DEPLOY_LISTEN_PORT="$(free_port)" timeout 20 python3 "$receiver" \
        >"$BATS_TEST_TMPDIR/empty.log" 2>&1 || rc=$?
    assert_not_equal "$rc" 0
    assert_not_equal "$rc" 124
}

@test "the listener refuses to start without the secret file" {
    rc=0
    DEPLOY_STATE_DIR=$state_dir DEPLOY_SECRETS_DIR=$BATS_TEST_TMPDIR/no-such-dir \
        DEPLOY_LISTEN_PORT="$(free_port)" timeout 20 python3 "$receiver" \
        >"$BATS_TEST_TMPDIR/missing.log" 2>&1 || rc=$?
    assert_not_equal "$rc" 0
    assert_not_equal "$rc" 124
}

# The listener is loopback-only by construction; a wildcard bind would violate
# the image's no-wildcard assertion and add no reach the tailnet needs.
@test "the listener binds loopback only" {
    run grep -nE '\b0\.0\.0\.0\b|\[::\]' "$receiver"
    assert_failure
}
