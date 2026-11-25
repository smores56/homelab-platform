#!/usr/bin/env bats
# bats file_tags=deploy
# Offline checks for the deploy state library and the queue drain (SDLC #798, T1).
#
# The drain is the only writer of state.json, so the pieces it stands on -- an
# atomic write, a fsynced journal that rotates, the denylist, the held/apply/
# pending records, the queue order and its same-repo coalescing, and the lock --
# are driven here against a throwaway state directory. No root, no bootc, no
# network.
#
#   bats tests/deploy/state.bats
#
# The shell suite this replaced ran every check in one process against one
# growing fixture; here each check is its own test with its own state directory
# under $BATS_TEST_TMPDIR, and the fixture a check needs is rebuilt by a helper
# named for it.
load ../helpers

state_lib=scripts/deploy-state.sh
drain=scripts/deploy-drain.sh

# The identity the queue, denylist and state fixtures use. queued_at is epoch
# seconds, so the fixtures pick small numbers and the order is explicit.
id_a=11111111-1111-4111-8111-111111111111
id_b=22222222-2222-4222-8222-222222222222
id_c=33333333-3333-4333-8333-333333333333
id_d=99999999-9999-4999-8999-999999999999
id_e=00000000-0000-4000-8000-000000000000
id_park=55555555-5555-4555-8555-555555555555
sha_old=1111111111111111111111111111111111111111
sha_new=2222222222222222222222222222222222222222
platform_commit=0123456789abcdef0123456789abcdef01234567
denylisted_commit=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef

# The stubs are the same for every test, so they are written once per file; the
# per-test state directory, the logs and the library below are per test.
setup_file() {
    install_stubs
}

setup() {
    export DEPLOY_STATE_DIR=$BATS_TEST_TMPDIR/state
    export DEPLOY_LOCK_FILE=$BATS_TEST_TMPDIR/deploy.lock
    export DEPLOY_JOURNAL_MAX_BYTES=5242880
    export DEPLOY_DRAIN_RESCAN_PAUSE=0
    export FAKE_PLATFORM_LOG=$BATS_TEST_TMPDIR/platform-calls
    export FAKE_APPS_LOG=$BATS_TEST_TMPDIR/apps-calls
    export FAKE_VERIFY_LOG=$BATS_TEST_TMPDIR/verify-calls
    export FAKE_TIP_FILE=$BATS_TEST_TMPDIR/tip
    export DEPLOY_VERIFY_BIN=$BATS_FILE_TMPDIR/stubs/fake-verify
    export DEPLOY_PLATFORM_BIN=$BATS_FILE_TMPDIR/stubs/fake-platform
    export DEPLOY_APPS_BIN=$BATS_FILE_TMPDIR/stubs/fake-apps
    stubs=$BATS_FILE_TMPDIR/stubs
    : >"$FAKE_PLATFORM_LOG"
    : >"$FAKE_APPS_LOG"
    : >"$FAKE_VERIFY_LOG"
    # The library reads its paths at source time, so it is sourced after the
    # environment above; every test body then calls the library directly.
    # shellcheck source=/dev/null
    source "$state_lib"
}

# --- the drain's collaborators -----------------------------------------------
# Verification is an external program (T2), and this suite is about the queue
# mechanics around it, so the drain is pointed at a stub that accepts everything:
# the verdicts themselves are tests/deploy/verify.sh. The platform snapshot gate
# (T3) and the apps apply/revert (T5) get the same treatment -- what is asserted
# here is what the drain hands them. Every tool resolves through deploy_resolve,
# which prefers the environment override these exports set.
install_stubs() {
    local bin=$BATS_FILE_TMPDIR/stubs
    mkdir -p "$bin"
    cat >"$bin/fake-verify" <<'STUB'
#!/usr/bin/env bash
repo= commit=
while (($#)); do
  case $1 in
    --repo) repo=$2; shift 2 ;;
    --commit) commit=$2; shift 2 ;;
    *) shift ;;
  esac
done
digests=null
if [[ $repo == homelab-platform ]]; then
  digests='{"index":"sha256:1111111111111111111111111111111111111111111111111111111111111111","manifest":"sha256:2222222222222222222222222222222222222222222222222222222222222222"}'
fi
printf '{"verdict":"verified","repo":"%s","commit":"%s","digests":%s}\n' "$repo" "$commit" "$digests"
STUB
    cat >"$bin/fake-platform" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_PLATFORM_LOG"
# prepare and stage are separate decisions: the gate can be green while the
# switch is an outage, and the drain must treat those differently.
if [[ ${1:-} == stage ]]; then exit "${FAKE_STAGE_EXIT:-0}"; fi
exit "${FAKE_PLATFORM_EXIT:-0}"
STUB
    cat >"$bin/fake-apps" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_APPS_LOG"
if [[ ${1:-} == revert ]]; then
  rm -f "$DEPLOY_STATE_DIR/apply.json"
fi
exit "${FAKE_APPS_EXIT:-0}"
STUB
    cat >"$bin/fake-verify-infra" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_VERIFY_LOG"
printf '{"verdict":"infra-failure","reason":"rate-limited"}\n'
exit 4
STUB
    # A stand-in with the verifier's own 120 s cache: it answers from
    # cache.json when the drain has not cleared it, so a stale tip is visible.
    cat >"$bin/fake-verify-cached" <<'STUB'
#!/usr/bin/env bash
repo= commit=
while (($#)); do
  case $1 in
    --repo) repo=$2; shift 2 ;;
    --commit) commit=$2; shift 2 ;;
    *) shift ;;
  esac
done
url=https://api.invalid/repos/smores56/$repo/git/ref/heads/main
tip=
if [[ -s $DEPLOY_STATE_DIR/cache.json ]]; then
  tip=$(jq -r --arg u "$url" '.entries[$u].value.object.sha // ""' \
    "$DEPLOY_STATE_DIR/cache.json" 2>/dev/null)
fi
if [[ -z $tip ]]; then
  tip=$(cat "$FAKE_TIP_FILE")
  jq -cn --arg u "$url" --arg sha "$tip" --argjson at "$(date +%s)" \
    '{schema:1,entries:{($u):{at:$at,value:{object:{sha:$sha}}}}}' \
    >"$DEPLOY_STATE_DIR/cache.json"
fi
if [[ $tip != "$commit" ]]; then
  printf '{"verdict":"rejected","reason":"tip-mismatch","repo":"%s","commit":"%s"}\n' "$repo" "$commit"
  exit 3
fi
printf '{"verdict":"verified","repo":"%s","commit":"%s","digests":null}\n' "$repo" "$commit"
STUB
    cat >"$bin/fake-verify-noimage" <<'STUB'
#!/usr/bin/env bash
printf '{"verdict":"not-deployable","reason":"tag-missing","repo":"%s","commit":"%s"}\n' "$2" "$4"
exit 5
STUB
    chmod 0755 "$bin"/fake-verify "$bin"/fake-platform "$bin"/fake-apps \
        "$bin"/fake-verify-infra "$bin"/fake-verify-cached "$bin"/fake-verify-noimage
}

# --- waiting without a clock -------------------------------------------------
# Nothing in this suite waits on the clock: every point where the shell suite
# guessed at a duration is a handshake instead, and a handshake that breaks has
# to fail rather than hang. A fifo opened read-write never reports EOF, so
# `read -t` on it is a bounded pause of that length.
tick() { # a 10 ms pause
    if [[ -z ${tick_fd:-} ]]; then
        mkfifo "$BATS_TEST_TMPDIR/tick"
        exec {tick_fd}<>"$BATS_TEST_TMPDIR/tick"
    fi
    read -r -t 0.01 -u "$tick_fd" || :
    return 0
}

wait_until() { # <predicate...>: poll it for 2 s, then fail the test
    local i
    for ((i = 0; i < 200; i++)); do
        "$@" && return 0
        tick
    done
    printf 'timed out waiting for: %s\n' "$*" >&2
    return 1
}

# --- fixtures ----------------------------------------------------------------
# queue_seed <id> <repo> <queued_at> [commit]: one accepted request in the shape
# the listener writes.
queue_seed() {
    jq -nc --arg id "$1" --arg repo "$2" --argjson at "$3" \
        --arg commit "${4:-1111111111111111111111111111111111111111}" \
        '{schema:1,id:$id,repo:$repo,commit:$commit,queued_at:$at,source:"event"}' |
        atomic_write "$DEPLOY_STATE_DIR/queue/$1.json"
}

journal_field() { # <event> <jq-path>
    jq -r "select(.event==\"$1\") | $2" "$DEPLOY_STATE_DIR/journal.jsonl"
}

journal_events() { # <event> -> count
    grep -c "\"event\":\"$1\"" "$DEPLOY_STATE_DIR/journal.jsonl" 2>/dev/null || true
}

journal_has() { # <event>: what the drain's own start record is waited for
    grep -qF "\"event\":\"$1\"" "$DEPLOY_STATE_DIR/journal.jsonl" 2>/dev/null
}

# drain_once [VAR=value ...]: one bounded run of the drain; its exit code in
# $drain_rc. A drain that hangs is a failing unit, so it runs under timeout.
drain_once() {
    drain_rc=0
    env "$@" timeout "${drain_timeout:-30}" bash "$drain" >/dev/null 2>&1 || drain_rc=$?
}

# --- deploy_state_init -------------------------------------------------------
@test "deploy_state_init creates the tree" {
    run deploy_state_init
    assert_success
}

@test "the state root is root-only" {
    deploy_state_init
    assert_equal "$(stat -c %a "$DEPLOY_STATE_DIR")" 700
}

@test "the queue directory is root-only" {
    deploy_state_init
    assert_equal "$(stat -c %a "$DEPLOY_STATE_DIR/queue")" 700
}

@test "the work directory exists" {
    deploy_state_init
    assert [ -d "$DEPLOY_STATE_DIR/work" ]
}

# --- atomic_write ------------------------------------------------------------
@test "atomic_write writes the file" {
    deploy_state_init
    run atomic_write "$DEPLOY_STATE_DIR/state.json" <<<'first'
    assert_success
}

@test "atomic_write keeps the content" {
    deploy_state_init
    printf 'first\n' | atomic_write "$DEPLOY_STATE_DIR/state.json"
    assert_equal "$(cat "$DEPLOY_STATE_DIR/state.json")" "first"
}

@test "atomic_write writes 0600" {
    deploy_state_init
    printf 'first\n' | atomic_write "$DEPLOY_STATE_DIR/state.json"
    assert_equal "$(stat -c %a "$DEPLOY_STATE_DIR/state.json")" 600
}

@test "atomic_write leaves no temp file" {
    deploy_state_init
    printf 'first\n' | atomic_write "$DEPLOY_STATE_DIR/state.json"
    assert_equal "$(find "$DEPLOY_STATE_DIR" -maxdepth 1 -name '.*.tmp' | wc -l)" 0
}

@test "atomic_write replaces in place" {
    deploy_state_init
    printf 'first\n' | atomic_write "$DEPLOY_STATE_DIR/state.json"
    printf 'second\n' | atomic_write "$DEPLOY_STATE_DIR/state.json"
    assert_equal "$(cat "$DEPLOY_STATE_DIR/state.json")" "second"
}

# --- state read and field ----------------------------------------------------
seed_platform_state() {
    deploy_state_init
    jq -nc --arg commit "$platform_commit" \
        '{schema:1,repos:{"homelab-platform":{commit:$commit,indexDigest:null,manifestDigest:null}},
          apps:{unitsHash:null,secretsHash:null}}' | atomic_write "$DEPLOY_STATE_DIR/state.json"
}

@test "state_field reads a nested field" {
    seed_platform_state
    assert_equal "$(state_field repos.homelab-platform.commit)" "$platform_commit"
}

@test "state_field fails on a missing field" {
    seed_platform_state
    run state_field repos.homelab-apps.commit
    assert_failure
}

@test "state_read prints the record" {
    seed_platform_state
    assert_equal "$(state_read | jq -r .schema)" 1
}

@test "state_read fails when the record is absent" {
    deploy_state_init
    run state_read
    assert_failure
}

# --- journal -----------------------------------------------------------------
@test "journal_append writes a record" {
    deploy_state_init
    run journal_append 'queue-enqueued' "$(jq -nc --arg id 'x' '{id:$id}')"
    assert_success
}

@test "the journal carries the event" {
    deploy_state_init
    journal_append 'queue-enqueued' "$(jq -nc --arg id 'x' '{id:$id}')"
    assert_equal "$(jq -r .event <<<"$(tail -n 1 "$DEPLOY_STATE_DIR/journal.jsonl")")" queue-enqueued
}

@test "the journal carries the details" {
    deploy_state_init
    journal_append 'queue-enqueued' "$(jq -nc --arg id 'x' '{id:$id}')"
    assert_equal "$(jq -r .id <<<"$(tail -n 1 "$DEPLOY_STATE_DIR/journal.jsonl")")" x
}

@test "the journal carries a UTC timestamp" {
    deploy_state_init
    journal_append 'queue-enqueued' "$(jq -nc --arg id 'x' '{id:$id}')"
    run jq -e '.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")' "$DEPLOY_STATE_DIR/journal.jsonl"
    assert_success
}

@test "journal_append refuses details that are not a JSON object" {
    deploy_state_init
    run journal_append 'broken' 'not-json'
    assert_failure
}

# Rotation: a bounded journal cannot grow without limit on a host that deploys
# for years. The rotated file keeps the oldest records; the live one keeps the
# newest, and no record is lost across the boundary.
rotate_journal() {
    deploy_state_init
    deploy_journal_max=512
    : >"$DEPLOY_STATE_DIR/journal.jsonl"
    rm -f "$DEPLOY_STATE_DIR/journal.1.jsonl"
    appended=0
    for i in $(seq 1 20); do
        journal_append 'rotate-probe' "$(jq -nc --argjson i "$i" \
            '{i:$i,pad:"0123456789012345678901234567890123456789"}')" || break
        appended=$((appended + 1))
        [[ -f $DEPLOY_STATE_DIR/journal.1.jsonl ]] && break
    done
}

@test "the journal rotates past its limit" {
    rotate_journal
    assert [ -s "$DEPLOY_STATE_DIR/journal.1.jsonl" ]
}

@test "the live journal stays under its limit" {
    rotate_journal
    assert [ "$(stat -c %s "$DEPLOY_STATE_DIR/journal.jsonl")" -lt 512 ]
}

# A single rotation must lose nothing: every record is in one of the two files,
# in order, and the live file holds the newest one.
@test "a rotation loses no record" {
    rotate_journal
    assert_equal "$(cat "$DEPLOY_STATE_DIR"/journal.1.jsonl "$DEPLOY_STATE_DIR"/journal.jsonl | wc -l)" \
        "$appended"
}

@test "the live journal holds the newest record" {
    rotate_journal
    assert_equal "$(tail -n 1 "$DEPLOY_STATE_DIR/journal.jsonl" | jq -r .i)" "$appended"
}

# --- denylist ----------------------------------------------------------------
@test "denylist_has is false before any entry" {
    deploy_state_init
    run denylist_has commit "$denylisted_commit"
    assert_failure
}

@test "denylist_add records a commit" {
    deploy_state_init
    run denylist_add commit "$denylisted_commit" 'failed the boot gate'
    assert_success
}

@test "denylist_add records a digest" {
    deploy_state_init
    run denylist_add digest 'sha256:1111111111111111111111111111111111111111111111111111111111111111' 'unsigned'
    assert_success
}

seed_denylist() {
    deploy_state_init
    denylist_add commit "$denylisted_commit" 'failed the boot gate'
    denylist_add digest 'sha256:1111111111111111111111111111111111111111111111111111111111111111' 'unsigned'
}

@test "denylist_has finds a denied commit" {
    seed_denylist
    run denylist_has commit "$denylisted_commit"
    assert_success
}

@test "denylist_has ignores a value that was never added" {
    seed_denylist
    run denylist_has digest 'sha256:2222222222222222222222222222222222222222222222222222222222222222'
    assert_failure
}

@test "the denylist keeps the reason" {
    seed_denylist
    assert_equal "$(jq -r ".commits[\"$denylisted_commit\"].reason" "$DEPLOY_STATE_DIR/denylist.json")" \
        'failed the boot gate'
}

@test "denylist_add refuses an unknown kind" {
    deploy_state_init
    run denylist_add nonsense value
    assert_failure
}

# --- held, apply and pending are distinct records ----------------------------
# seed_records writes the four documents the drain may write and the denylist it
# reads before it acts; the round-trip tests below each assert one of them lands.
seed_records() {
    deploy_state_init
    jq -nc '{schema:1,repos:{},apps:{}}' | atomic_write "$DEPLOY_STATE_DIR/state.json"
    jq -nc '{phase:"staged",commit:"cccc",digest:"sha256:aa",budget:300}' | pending_write
    jq -nc '{phase:"pulling",previous:{apps:[]},intended:{apps:["opdshelf"]}}' | apply_write
    jq -nc '{digest:"sha256:bb",missing:["photos"]}' | held_write
    denylist_add commit "$denylisted_commit" 'failed the boot gate'
}

@test "pending_write round-trips" {
    seed_records
    assert_equal "$(pending_read | jq -r .phase)" staged
}

@test "apply_write round-trips" {
    seed_records
    assert_equal "$(apply_read | jq -r .phase)" pulling
}

@test "held_write round-trips" {
    seed_records
    assert_equal "$(held_read | jq -r '.missing[0]')" photos
    for name in state held apply pending denylist; do
        assert [ -s "$DEPLOY_STATE_DIR/$name.json" ]
    done
}

@test "pending_clear removes the record" {
    seed_records
    pending_clear
    run pending_read
    assert_failure
}

@test "the generic writer refuses the listener's own files" {
    deploy_state_init
    run record_write nonces
    assert_failure
}

# --- queue -------------------------------------------------------------------
# Three pending requests, two of them for the same repository: homelab-apps at
# 30 and 20, homelab-platform at 10, so FIFO by queued_at is b, c, a.
seed_queue() {
    deploy_state_init
    queue_seed "$id_a" homelab-apps 30
    queue_seed "$id_b" homelab-platform 10
    queue_seed "$id_c" homelab-apps 20
}

@test "queue_list is FIFO by queued_at" {
    seed_queue
    assert_equal "$(queue_list | tr '\n' ' ')" "${id_b} ${id_c} ${id_a} "
}

@test "queue_count counts the entries" {
    seed_queue
    assert_equal "$(queue_count)" 3
}

@test "queue_field reads the entry" {
    seed_queue
    assert_equal "$(queue_field "$id_a" repo)" homelab-apps
}

@test "queue_pop refuses an id that is not a uuid" {
    seed_queue
    run queue_pop '../state'
    assert_failure
}

@test "a refused queue_pop removes nothing" {
    seed_queue
    run queue_pop '../state'
    assert_equal "$(queue_count)" 3
}

# Coalescing: two pending requests for one repository are one deploy. The older
# entry is dropped and the newer one keeps its place in the queue.
@test "queue_coalesce reports the superseded entry" {
    seed_queue
    assert_equal "$(queue_coalesce)" "$id_c"
}

@test "queue_coalesce keeps the newest per repo" {
    seed_queue
    queue_coalesce >/dev/null
    assert_equal "$(queue_list | tr '\n' ' ')" "${id_b} ${id_a} "
}

@test "queue_coalesce removes the superseded entry" {
    seed_queue
    queue_coalesce >/dev/null
    assert_equal "$(queue_count)" 2
}

# Two requests that land in the same second: queued_at is equal and the listener
# and the poll both mint a random uuid, so only the file's own mtime says which
# arrived last. The uuid order below is the wrong way round on purpose: ordering
# by it would coalesce onto the older commit and deploy the one main had moved
# past.
seed_same_second() {
    seed_queue
    for entry in "$DEPLOY_STATE_DIR"/queue/*.json; do rm -f "$entry"; done
    queue_seed "$id_d" homelab-platform 50 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    queue_seed "$id_e" homelab-platform 50 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    touch -d '2026-01-01 00:00:00.100000000' "$DEPLOY_STATE_DIR/queue/$id_d.json"
    touch -d '2026-01-01 00:00:00.900000000' "$DEPLOY_STATE_DIR/queue/$id_e.json"
}

@test "a same-second queue is ordered by mtime, not by uuid" {
    seed_same_second
    assert_equal "$(queue_list | tr '\n' ' ')" "${id_d} ${id_e} "
}

@test "the same-second older request is the one superseded" {
    seed_same_second
    assert_equal "$(queue_coalesce)" "$id_d"
}

@test "the same-second newer commit is the one kept" {
    seed_same_second
    queue_coalesce >/dev/null
    assert_equal "$(queue_field "$id_e" commit)" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
}

@test "the same-second older entry is removed" {
    seed_same_second
    queue_coalesce >/dev/null
    assert_equal "$(queue_count)" 1
}

# An infrastructure failure is not a verdict about the commit: the entry stays,
# stamped with when it may be tried again, and the drain exits 0 so the path unit
# is not re-fired into a loop that spends the start limit and freezes the queue.
seed_deferred_entry() {
    deploy_state_init
    queue_seed "$id_a" homelab-platform 60
}

@test "a fresh entry carries no retry stamp" {
    seed_deferred_entry
    retry_at=$(queue_field "$id_a" retry_at 2>/dev/null) || retry_at=""
    assert_equal "$retry_at" ""
}

@test "queue_defer stamps the entry" {
    seed_deferred_entry
    run queue_defer "$id_a" "$(($(date +%s) + 300))" verify-infra-failure
    assert_success
}

@test "a deferral counts the attempt" {
    seed_deferred_entry
    queue_defer "$id_a" "$(($(date +%s) + 300))" verify-infra-failure
    assert_equal "$(queue_field "$id_a" attempts)" 1
}

@test "a deferred entry is not ready before its retry_at" {
    seed_deferred_entry
    queue_defer "$id_a" "$(($(date +%s) + 300))" verify-infra-failure
    run queue_ready "$id_a"
    assert_failure
}

@test "a deferred entry is ready once its retry_at passes" {
    seed_deferred_entry
    queue_defer "$id_a" "$(($(date +%s) - 1))" verify-infra-failure
    run queue_ready "$id_a"
    assert_success
}

@test "each deferral counts an attempt" {
    seed_deferred_entry
    queue_defer "$id_a" "$(($(date +%s) + 300))" verify-infra-failure
    queue_defer "$id_a" "$(($(date +%s) - 1))" verify-infra-failure
    assert_equal "$(queue_field "$id_a" attempts)" 2
}

# --- the queue-directory contract, shared with the Python receiver ------------
# Count regular `.json` files one level deep and nothing else: a directory or a
# non-JSON name is not a queued request. tests/deploy/receiver.sh asserts the
# Python listener's count agrees on the same fixture.
@test "queue_count ignores a directory and a non-json file" {
    deploy_state_init
    queue_seed "$id_e" homelab-platform 50
    queue_seed "$id_a" homelab-platform 60
    mkdir -p "$DEPLOY_STATE_DIR/queue/not-an-entry.json"
    : >"$DEPLOY_STATE_DIR/queue/entry.txt"
    assert_equal "$(queue_count)" 2
}

@test "queue_has finds a queued revision" {
    seed_deferred_entry
    run queue_has homelab-platform 1111111111111111111111111111111111111111
    assert_success
}

@test "queue_has refuses a revision that is not queued" {
    seed_deferred_entry
    run queue_has homelab-platform 2222222222222222222222222222222222222222
    assert_failure
}

@test "queue_oldest names the oldest entry" {
    deploy_state_init
    queue_seed "$id_e" homelab-platform 50
    queue_seed "$id_a" homelab-platform 60
    read -r oldest_age oldest_id < <(queue_oldest)
    assert_equal "$oldest_id" "$id_e"
}

# An entry nobody can read is a record the drain must reach, so it counts as
# infinitely old rather than as fresh.
@test "queue_oldest treats an unreadable entry as oldest" {
    deploy_state_init
    queue_seed "$id_e" homelab-platform 50
    queue_seed "$id_a" homelab-platform 60
    printf 'not json\n' | atomic_write "$DEPLOY_STATE_DIR/queue/unreadable.json"
    read -r _ oldest_id < <(queue_oldest)
    assert_equal "$oldest_id" unreadable
}

@test "queue_oldest reports an empty queue as age 0" {
    deploy_state_init
    read -r oldest_age oldest_id < <(queue_oldest)
    assert_equal "$oldest_age $oldest_id" "0 "
}

# --- timers and caches ------------------------------------------------------
# `timeout 0` is no limit at all, so a zeroed knob or an exhausted budget must
# still reach the child as a one-second bound.
@test "a zero timeout is clamped to one second" {
    assert_equal "$(clamp_timeout 0)" 1
}

@test "a negative timeout is clamped to one second" {
    assert_equal "$(clamp_timeout -5)" 1
}

@test "a positive timeout is left alone" {
    assert_equal "$(clamp_timeout 30)" 30
}

@test "an unset timeout is clamped to one second" {
    assert_equal "$(clamp_timeout nonsense)" 1
}

@test "cache_clear drops the verifier's and the poll's cache" {
    deploy_state_init
    : >"$DEPLOY_STATE_DIR/cache.json"
    : >"$DEPLOY_STATE_DIR/poll-cache.json"
    cache_clear
    assert [ ! -e "$DEPLOY_STATE_DIR/cache.json" ]
    assert [ ! -e "$DEPLOY_STATE_DIR/poll-cache.json" ]
}

# --- the drain ---------------------------------------------------------------
# The apps entry goes first: a staged platform deploy ends the drain by design (the
# host is rebooting), so a late entry has to be drainable before it.
seed_drain_queue() {
    deploy_state_init
    : >"$DEPLOY_STATE_DIR/journal.jsonl"
    queue_seed "$id_a" homelab-apps 1
}

# The rescan window is what closes the exit race: a request that lands while the
# drain is finishing must still be drained by the same run. The old suite slept
# half a second and hoped; waiting for the drain's own start record makes the
# window explicit, and the late entry lands inside it.
drain_a_late_entry() {
    seed_drain_queue
    DEPLOY_DRAIN_RESCAN_PAUSE=1 timeout 30 bash "$drain" \
        >"$BATS_TEST_TMPDIR/drain.log" 2>&1 &
    drain_pid=$!
    wait_until journal_has drain-start
    queue_seed "$id_c" homelab-platform 2
    drain_rc=0
    wait "$drain_pid" || drain_rc=$?
}

@test "the drain exits 0 on an empty queue" {
    deploy_state_init
    drain_once
    assert_equal "$drain_rc" 0
}

@test "the drain empties the queue" {
    seed_drain_queue
    queue_seed "$id_c" homelab-platform 2
    drain_once
    assert_equal "$(queue_count)" 0
}

@test "the drain rescans and drains the late entry" {
    drain_a_late_entry
    assert_equal "$(journal_events verified)" 2
}

@test "the drain journals its start once" {
    drain_a_late_entry
    assert_equal "$(journal_events drain-start)" 1
}

@test "the drain journals its finish once" {
    drain_a_late_entry
    assert_equal "$(journal_events drain-finish)" 1
}

@test "each drained entry carries its repository" {
    drain_a_late_entry
    assert_equal "$(jq -r 'select(.event=="verified") | .repo' "$DEPLOY_STATE_DIR/journal.jsonl" |
        sort | tr '\n' ' ')" 'homelab-apps homelab-platform '
}

@test "the drain counts what it drained" {
    drain_a_late_entry
    assert_equal "$(journal_field drain-finish .drained)" 2
}

@test "the drain hands the verified apps entry to the apps apply" {
    drain_a_late_entry
    assert_equal "$(grep -c 'apply --commit' "$FAKE_APPS_LOG")" 1
}

# An interrupted apps apply is reverted before anything is drained: the next
# entry would otherwise be applied on top of half of the previous revision.
interrupt_an_apply() {
    deploy_state_init
    printf '{"schema":1,"phase":"installing","previousUnits":[],"intendedUnits":[]}\n' |
        apply_write
    : >"$DEPLOY_STATE_DIR/journal.jsonl"
    drain_once
}

@test "the drain reverts an interrupted apps apply" {
    interrupt_an_apply
    assert_equal "$drain_rc" 0
}

@test "the interrupted apply is reverted before the queue is drained" {
    interrupt_an_apply
    assert_equal "$(head -n 1 "$FAKE_APPS_LOG")" revert
}

@test "the drain journals the reverted apply" {
    interrupt_an_apply
    assert_equal "$(journal_field apply-reverted .by)" drain
}

@test "the reverted apply clears the record" {
    interrupt_an_apply
    assert [ ! -e "$DEPLOY_STATE_DIR/apply.json" ]
}

# An entry that cannot be read must never wedge the queue behind it.
seed_unreadable_entry() {
    deploy_state_init
    printf '{"id":"%s"}\n' "$id_b" | atomic_write "$DEPLOY_STATE_DIR/queue/$id_b.json"
    drain_once
}

@test "the drain accepts an unreadable entry" {
    seed_unreadable_entry
    assert_equal "$drain_rc" 0
}

@test "an invalid entry is removed, not retried forever" {
    seed_unreadable_entry
    assert_equal "$(queue_count)" 0
}

@test "the invalid entry is journaled with its id" {
    seed_unreadable_entry
    assert_equal "$(journal_field queue-invalid .id)" "$id_b"
}

# Every tree an interrupted apply left behind is plaintext secrets; the drain
# sweeps the stale ones before it drains anything.
@test "the drain sweeps the apps work trees" {
    seed_unreadable_entry
    assert [ "$(grep -c '^sweep$' "$FAKE_APPS_LOG")" -ge 1 ]
}

# --- a staged reboot ends the drain ------------------------------------------
# `stage` writes pending.json and asks for the reboot: every later entry would be
# handled by a process the shutdown is about to kill, and an apps apply behind it
# would be half-applied with the reboot already on its way.
drain_a_staged_reboot() {
    deploy_state_init
    printf '{"schema":1,"repos":{}}' | atomic_write "$DEPLOY_STATE_DIR/state.json"
    : >"$DEPLOY_STATE_DIR/journal.jsonl"
    queue_seed "$id_a" homelab-platform 80 cccccccccccccccccccccccccccccccccccccccc
    queue_seed "$id_b" homelab-apps 81 dddddddddddddddddddddddddddddddddddddddd
    drain_once
}

@test "the drain exits 0 after a staged platform deploy" {
    drain_a_staged_reboot
    assert_equal "$drain_rc" 0
}

@test "the drain stages the platform entry" {
    drain_a_staged_reboot
    assert [ "$(grep -c '^stage ' "$FAKE_PLATFORM_LOG")" -ge 1 ]
}

@test "a staged reboot applies no later apps entry" {
    drain_a_staged_reboot
    assert [ "$(grep -c 'apply --commit' "$FAKE_APPS_LOG")" -eq 0 ]
}

@test "the entry behind a staged reboot stays queued" {
    drain_a_staged_reboot
    assert_equal "$(queue_count)" 1
}

@test "the entry left queued is the later one" {
    drain_a_staged_reboot
    assert_equal "$(queue_field "$id_b" repo)" homelab-apps
}

# Without the stop the drain reaches the reboot's own entry again and stages it
# twice, so a reboot is requested while the host is going down.
@test "a staged reboot is staged once" {
    drain_a_staged_reboot
    assert_equal "$(grep -c '^stage ' "$FAKE_PLATFORM_LOG")" 1
}

# --- an infrastructure failure defers the entry ------------------------------
# A 429 or a dead tailnet says nothing about the commit, and retrying at once is
# worse than waiting: the path unit re-fires the drain the moment it exits, so an
# immediate retry is a loop that spends the unit's start limit and freezes the
# queue behind it.
seed_infra_failure() {
    deploy_state_init
    : >"$DEPLOY_STATE_DIR/journal.jsonl"
    queue_seed "$id_b" homelab-apps 85 eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
    drain_once DEPLOY_VERIFY_BIN="$stubs/fake-verify-infra"
}

@test "an infrastructure failure defers the entry and exits 0" {
    seed_infra_failure
    assert_equal "$drain_rc" 0
}

@test "a deferred entry keeps its place in the queue" {
    seed_infra_failure
    assert_equal "$(queue_count)" 1
}

@test "the deferral is journaled with its reason" {
    seed_infra_failure
    assert_equal "$(journal_field deferred .reason)" rate-limited
}

@test "the deferral stamps a retry at least five minutes out" {
    seed_infra_failure
    deferred_until=$(queue_field "$id_b" retry_at 2>/dev/null) || deferred_until=0
    assert [ "$deferred_until" -ge "$(($(date +%s) + 250))" ]
}

@test "the deferral counts the attempt" {
    seed_infra_failure
    assert_equal "$(queue_field "$id_b" attempts)" 1
}

# The stamp is five minutes out, so no bound shorter than that can change the
# outcome: the drain parks on the stamp instead. Three seconds is well past the
# point where it would otherwise have verified the entry.
@test "a deferred entry is skipped until its retry_at" {
    seed_infra_failure
    : >"$FAKE_VERIFY_LOG"
    drain_timeout=3
    drain_once DEPLOY_VERIFY_BIN="$stubs/fake-verify-infra"
    assert_equal "$(cat "$FAKE_VERIFY_LOG")" ""
}

@test "a deferred entry is verified again once its retry_at passes" {
    seed_infra_failure
    queue_defer "$id_b" "$(($(date +%s) - 1))" rate-limited
    : >"$FAKE_VERIFY_LOG"
    drain_once DEPLOY_VERIFY_BIN="$stubs/fake-verify-infra"
    assert_equal "$(grep -c 'rate-limited\|--commit' "$FAKE_VERIFY_LOG")" 1
}

# --- a verification looks at the tip, not at the cache ----------------------
# The verifier answers from a 120 s cache; a commit pushed inside that window
# would be rejected as a tip mismatch for every entry that arrived there. The
# drain clears the cache before it verifies, so the second request in the same
# second sees the tip main is at now.
drain_two_tips() {
    deploy_state_init
    rm -f "$DEPLOY_STATE_DIR/cache.json"
    : >"$DEPLOY_STATE_DIR/journal.jsonl"
    printf '%s\n' "$sha_old" >"$FAKE_TIP_FILE"
    queue_seed "$id_a" homelab-apps 90 "$sha_old"
    drain_once DEPLOY_VERIFY_BIN="$stubs/fake-verify-cached"
    printf '%s\n' "$sha_new" >"$FAKE_TIP_FILE"
    queue_seed "$id_b" homelab-apps 91 "$sha_new"
    drain_once DEPLOY_VERIFY_BIN="$stubs/fake-verify-cached"
}

@test "a second request in the same second sees the fresh tip" {
    drain_two_tips
    assert_equal "$(journal_events verified)" 2
}

@test "no request is rejected on a cached tip" {
    drain_two_tips
    assert_equal "$(journal_events verify-rejected)" 0
}

# --- a commit with no image is skipped, not paged ----------------------------
# The publish workflow only builds image-bearing paths, so the poll sees a main
# tip with no tag. That must pop the entry without a rejection page or a
# denylist entry, or a docs-only commit would page every hour.
drain_a_commit_with_no_image() {
    deploy_state_init
    : >"$DEPLOY_STATE_DIR/journal.jsonl"
    queue_seed "$id_c" homelab-platform 92 "$sha_old"
    drain_once DEPLOY_VERIFY_BIN="$stubs/fake-verify-noimage"
}

@test "a commit without an image is journaled as not deployable" {
    drain_a_commit_with_no_image
    assert_equal "$(journal_events verify-not-deployable)" 1
}

@test "a commit without an image is not a rejection" {
    drain_a_commit_with_no_image
    assert_equal "$(journal_events verify-rejected)" 0
}

@test "the skipped entry is popped" {
    drain_a_commit_with_no_image
    assert_equal "$(find "$DEPLOY_STATE_DIR/queue" -name '*.json' | wc -l)" 0
}

# --- a staging outage is deferred, never a hot loop --------------------------
# systemd re-fires a path-triggered service as soon as it exits, so exiting on a
# stage failure re-ran verification, the gate and `bootc switch` every fourteen
# seconds on the host until the entry was deferred.
drain_a_staging_outage() {
    deploy_state_init
    : >"$DEPLOY_STATE_DIR/journal.jsonl"
    queue_seed "$id_d" homelab-platform 93 "$sha_old"
    drain_once FAKE_STAGE_EXIT=4
}

@test "a staging outage ends the drain without failing it" {
    drain_a_staging_outage
    assert_equal "$drain_rc" 0
}

@test "a staging outage is deferred" {
    drain_a_staging_outage
    assert_equal "$(journal_events deferred)" 1
}

@test "the deferred entry stays queued" {
    drain_a_staging_outage
    assert_equal "$(find "$DEPLOY_STATE_DIR/queue" -name '*.json' | wc -l)" 1
}

@test "the deferred entry carries a retry time" {
    drain_a_staging_outage
    assert [ -n "$(queue_field "$id_d" retry_at 2>/dev/null)" ]
}

# --- a drain with only deferred work parks, never exits ----------------------
# The path unit re-fires a oneshot the instant it exits while the queue is
# non-empty, so exiting on "all deferred" spun the host into start-limit-hit and
# a failed path unit. The drain waits for the stamp instead.
@test "a drain with only deferred work parks instead of exiting" {
    deploy_state_init
    : >"$DEPLOY_STATE_DIR/journal.jsonl"
    queue_seed "$id_park" homelab-platform 94 "$sha_old"
    queue_defer "$id_park" "$(($(date +%s) + 3600))" test-hold
    drain_rc=0
    DEPLOY_DRAIN_RESCAN_PAUSE=0 timeout 2 bash "$drain" >/dev/null 2>&1 || drain_rc=$?
    assert_equal "$drain_rc" 124
}

@test "the parked drain journals why it is waiting" {
    deploy_state_init
    : >"$DEPLOY_STATE_DIR/journal.jsonl"
    queue_seed "$id_park" homelab-platform 94 "$sha_old"
    queue_defer "$id_park" "$(($(date +%s) + 3600))" test-hold
    DEPLOY_DRAIN_RESCAN_PAUSE=0 timeout 2 bash "$drain" >/dev/null 2>&1 || true
    assert_equal "$(journal_events drain-parked)" 1
}

# --- bootc runs with the scratch it needs, and nothing wider -----------------
# bootc creates /run/bootc/storage while it stages a pull; ProtectSystem=strict
# leaves /run read-only, and the failure is a staging exit on every deploy.
check_bootc_runtime_dir() { # <unit> <dir>
    run grep -qx "RuntimeDirectory=$2" "$1"
    assert_success
}

for unit in units/systemd/smortress-deploy.service units/systemd/smortress-boot-gate.service; do
    for dir in bootc ostree; do
        register "$(basename "$unit") gives bootc /run/$dir" check_bootc_runtime_dir "$unit" "$dir"
    done
done

# --- the deploy lock ---------------------------------------------------------
# The drain unit, the hourly poll and the CLI all write state.json; the lock is
# what keeps one of them from losing another's write.
#
# The shell suite this replaced held the lock in a child for three seconds and
# raced the parent's half-second pause. Instead the child touches $lock_ready
# only once it holds the lock -- and blocks until the parent writes to the fifo
# -- so the assertion below runs while the lock is provably held, and on a slow
# machine it still does.
hold_lock() {
    lock_fifo=$BATS_TEST_TMPDIR/hold
    lock_ready=$BATS_TEST_TMPDIR/ready
    mkfifo "$lock_fifo"
    bash -c '
        set -uo pipefail
        export DEPLOY_STATE_DIR DEPLOY_LOCK_FILE
        # shellcheck source=/dev/null
        source "$1" || exit 1
        deploy_lock_acquire 10 || exit 1
        : >"$2"
        # Read-write on the fifo never blocks and never sees EOF: the read below
        # returns when the parent signals, or after 30 s if the test died.
        exec {fd}<>"$3"
        read -r -t 30 -u "$fd"
    ' _ "$state_lib" "$lock_ready" "$lock_fifo" &
    holder_pid=$!
    wait_until test -e "$lock_ready"
}

release_lock_holder() {
    printf 'release\n' >"$lock_fifo"
    wait "$holder_pid"
}

@test "a held deploy lock refuses a second holder" {
    deploy_state_init
    hold_lock
    run deploy_lock_acquire 1
    assert_failure
    release_lock_holder
}

@test "the deploy lock is free once the holder exits" {
    deploy_state_init
    hold_lock
    release_lock_holder
    run deploy_lock_acquire 5
    assert_success
    deploy_lock_release
}

# The lock's home, and the units that create it. /run/smortress holds the
# decrypted secrets: a lock file there would be a write the units have to allow
# inside the ciphertexts' own tree, so the lock moved to its own RuntimeDirectory
# and neither unit may name /run/smortress as a writable path.
@test "the deploy lock defaults to its own runtime directory" {
    assert_equal \
        "$(sed -nE 's/^deploy_lock_file=\$\{DEPLOY_LOCK_FILE:-([^}]+)\}$/\1/p' "$state_lib")" \
        /run/smortress-deploy/deploy.lock
}

check_lock_runtime_directory() { # <unit>
    run grep -qxF 'RuntimeDirectory=smortress-deploy' "$1"
    assert_success
}

# A oneshot's RuntimeDirectory is removed when it exits, and a hand-run command
# holding the lock would then be locking an unlinked inode.
check_runtime_directory_preserved() { # <unit>
    run grep -qxF 'RuntimeDirectoryPreserve=yes' "$1"
    assert_success
}

# Directive lines only: both files explain the move in a comment.
check_no_smortress_wide_path() { # <unit>
    run grep -vE '^[[:space:]]*#' "$1"
    refute_output --partial '/run/smortress'
}

for unit in units/systemd/smortress-deploy.service units/systemd/smortress-boot-gate.service; do
    register "$(basename -- "$unit") creates the lock's runtime directory" \
        check_lock_runtime_directory "$unit"
    register "$(basename -- "$unit") keeps the runtime directory across its exits" \
        check_runtime_directory_preserved "$unit"
    register "$(basename -- "$unit") never widens /run/smortress" \
        check_no_smortress_wide_path "$unit"
done

# A hand-run command has no unit, so the library creates the directory itself;
# without that, every CLI command on a host whose drain has not run yet reports
# "another drain holds the lock".
@test "the library creates the lock's directory when no unit has" {
    fresh_lock=$BATS_TEST_TMPDIR/fresh-run/deploy.lock
    run env DEPLOY_LOCK_FILE="$fresh_lock" bash -c '
        set -uo pipefail
        export DEPLOY_LOCK_FILE
        # shellcheck source=/dev/null
        source scripts/deploy-state.sh
        deploy_lock_acquire 5
    '
    assert_success
    assert [ -f "$fresh_lock" ]
}

# Every tool a deploy script runs -- apps-schema, deploy-verify.py,
# deploy-platform, deploy-apps, smortress-restic-verify, smortress-restic-backup
# and storage-layout -- resolves through one function. The gate and the apps
# apply each carried a copy, and the drain carried three inline blocks with a
# different order; a fix to one missed the others.
@test "deploy_resolve has one definition" {
    assert_equal "$(grep -c '^deploy_resolve()' scripts/*.sh | awk -F: '{ sum += $2 } END { print sum }')" 1
}

@test "the per-script resolver copies are gone" {
    assert_equal "$(grep -c '^resolve_tool()' scripts/*.sh | awk -F: '{ sum += $2 } END { print sum }')" 0
}

# The drain and the gate must not carry an inline `/usr/libexec` probe for a
# tool; only the state-library bootstrap may name that path in those scripts.
check_no_inline_resolver() { # <script>
    run grep -qE 'if \[\[ -[xr] /usr/libexec/(deploy-|apps-schema|smortress-restic|storage-layout)' "$1"
    assert_failure
}

for script in scripts/deploy-drain.sh scripts/deploy-platform.sh scripts/deploy-apps.sh; do
    register "$(basename -- "$script") resolves tools through deploy_resolve" \
        check_no_inline_resolver "$script"
done

@test "deploy_resolve keeps its environment override" {
    assert_equal "$(env DEPLOY_STATE_DIR="$DEPLOY_STATE_DIR" bash -c '
        export DEPLOY_STATE_DIR
        # shellcheck source=/dev/null
        source scripts/deploy-state.sh
        deploy_resolve overridden apps-schema /nowhere/apps-schema.py
    ')" overridden
}

@test "deploy_resolve prefers a PATH stand-in over the sibling" {
    mkdir -p "$BATS_TEST_TMPDIR/tools"
    printf '#!/usr/bin/env bash\n' >"$BATS_TEST_TMPDIR/tools/apps-schema"
    chmod 0755 "$BATS_TEST_TMPDIR/tools/apps-schema"
    assert_equal "$(env DEPLOY_STATE_DIR="$DEPLOY_STATE_DIR" PATH="$BATS_TEST_TMPDIR/tools:$PATH" bash -c '
        export DEPLOY_STATE_DIR PATH
        # shellcheck source=/dev/null
        source scripts/deploy-state.sh
        deploy_resolve "" apps-schema /nowhere/apps-schema.py
    ')" "$BATS_TEST_TMPDIR/tools/apps-schema"
}

@test "deploy_resolve falls back to the checkout sibling" {
    assert_equal "$(env DEPLOY_STATE_DIR="$DEPLOY_STATE_DIR" PATH=/usr/bin:/bin bash -c '
        export DEPLOY_STATE_DIR PATH
        # shellcheck source=/dev/null
        source scripts/deploy-state.sh
        deploy_resolve "" no-such-tool-812 /nowhere/no-such-tool-812
    ')" /nowhere/no-such-tool-812
}
