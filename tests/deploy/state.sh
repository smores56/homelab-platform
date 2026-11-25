#!/usr/bin/env bash
# Offline checks for the deploy state library and the queue drain (SDLC #798, T1).
#
# The drain is the only writer of state.json, so the pieces it stands on -- an
# atomic write, a fsynced journal that rotates, the denylist, the held/apply/
# pending records, the queue order and its same-repo coalescing, and the lock --
# are driven here against a throwaway state directory. No root, no bootc, no
# network.
#
#   tests/deploy/state.sh
set -uo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root" || exit 1

lib=scripts/deploy-state.sh
drain=scripts/deploy-drain.sh
for file in "$lib" "$drain"; do
  [[ -r $file ]] || {
    printf 'FAIL %s is missing\n' "$file" >&2
    exit 1
  }
done
for tool in jq timeout; do
  command -v "$tool" >/dev/null || {
    printf 'FAIL %s is required\n' "$tool" >&2
    exit 1
  }
done

# shellcheck source=tests/deploy/lib.sh
source "$root/tests/deploy/lib.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

export DEPLOY_STATE_DIR=$work/state
export DEPLOY_LOCK_FILE=$work/deploy.lock
# shellcheck source=/dev/null
source "$lib"

if deploy_state_init; then
  ok "deploy_state_init creates the tree"
else
  bad "deploy_state_init creates the tree"
fi
check_eq "$(stat -c %a "$DEPLOY_STATE_DIR")" 700 "the state root is root-only"
check_eq "$(stat -c %a "$DEPLOY_STATE_DIR/queue")" 700 "the queue directory is root-only"
if [[ -d $DEPLOY_STATE_DIR/work ]]; then
  ok "the work directory exists"
else
  bad "the work directory exists" "not a directory"
fi

# --- atomic_write ------------------------------------------------------------
if printf 'first\n' | atomic_write "$DEPLOY_STATE_DIR/state.json"; then
  ok "atomic_write writes the file"
else
  bad "atomic_write writes the file"
fi
check_eq "$(cat "$DEPLOY_STATE_DIR/state.json")" "first" "atomic_write keeps the content"
check_eq "$(stat -c %a "$DEPLOY_STATE_DIR/state.json")" 600 "atomic_write writes 0600"
leftovers=$(find "$DEPLOY_STATE_DIR" -maxdepth 1 -name '.*.tmp' | wc -l)
check_eq "$leftovers" 0 "atomic_write leaves no temp file"
printf 'second\n' | atomic_write "$DEPLOY_STATE_DIR/state.json"
check_eq "$(cat "$DEPLOY_STATE_DIR/state.json")" "second" "atomic_write replaces in place"

# --- state read and field ----------------------------------------------------
platform_commit=0123456789abcdef0123456789abcdef01234567
jq -nc --arg commit "$platform_commit" \
  '{schema:1,repos:{"homelab-platform":{commit:$commit,indexDigest:null,manifestDigest:null}},
    apps:{unitsHash:null,secretsHash:null}}' | atomic_write "$DEPLOY_STATE_DIR/state.json"
check_eq "$(state_field repos.homelab-platform.commit)" "$platform_commit" \
  "state_field reads a nested field"
if state_field repos.homelab-apps.commit >/dev/null 2>&1; then
  bad "state_field fails on a missing field"
else
  ok "state_field fails on a missing field"
fi
check_eq "$(state_read | jq -r .schema)" 1 "state_read prints the record"
if (rm -f "$DEPLOY_STATE_DIR/state.json" && state_read >/dev/null); then
  bad "state_read fails when the record is absent"
else
  ok "state_read fails when the record is absent"
fi

# --- journal -----------------------------------------------------------------
: >"$work/journal-check"
if journal_append 'queue-enqueued' "$(jq -nc --arg id 'x' '{id:$id}')"; then
  ok "journal_append writes a record"
else
  bad "journal_append writes a record"
fi
record=$(tail -n 1 "$DEPLOY_STATE_DIR/journal.jsonl")
check_eq "$(jq -r .event <<<"$record")" queue-enqueued "the journal carries the event"
check_eq "$(jq -r .id <<<"$record")" x "the journal carries the details"
if jq -e '.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")' <<<"$record" >/dev/null; then
  ok "the journal carries a UTC timestamp"
else
  bad "the journal carries a UTC timestamp" "$record"
fi
if journal_append 'broken' 'not-json' >/dev/null 2>&1; then
  bad "journal_append refuses details that are not a JSON object"
else
  ok "journal_append refuses details that are not a JSON object"
fi

# Rotation: a bounded journal cannot grow without limit on a host that deploys
# for years. The rotated file keeps the oldest records; the live one keeps the
# newest, and no record is lost across the boundary.
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
check_file "$DEPLOY_STATE_DIR/journal.1.jsonl" "the journal rotates past its limit"
if [[ $(stat -c %s "$DEPLOY_STATE_DIR/journal.jsonl") -lt 512 ]]; then
  ok "the live journal stays under its limit"
else
  bad "the live journal stays under its limit" "$(stat -c %s "$DEPLOY_STATE_DIR/journal.jsonl") bytes"
fi
# A single rotation must lose nothing: every record is in one of the two files,
# in order, and the live file holds the newest one.
records=$(cat "$DEPLOY_STATE_DIR"/journal.1.jsonl "$DEPLOY_STATE_DIR"/journal.jsonl | wc -l)
check_eq "$records" "$appended" "a rotation loses no record"
check_eq "$(tail -n 1 "$DEPLOY_STATE_DIR/journal.jsonl" | jq -r .i)" "$appended" \
  "the live journal holds the newest record"
# shellcheck disable=SC2034  # the journal limit is read by the sourced library
deploy_journal_max=5242880

# --- denylist ----------------------------------------------------------------
denylisted_commit=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
if denylist_has commit "$denylisted_commit"; then
  bad "denylist_has is false before any entry"
else
  ok "denylist_has is false before any entry"
fi
if denylist_add commit "$denylisted_commit" 'failed the boot gate'; then
  ok "denylist_add records a commit"
else
  bad "denylist_add records a commit"
fi
if denylist_add digest 'sha256:1111111111111111111111111111111111111111111111111111111111111111' 'unsigned'; then
  ok "denylist_add records a digest"
else
  bad "denylist_add records a digest"
fi
if denylist_has commit "$denylisted_commit"; then
  ok "denylist_has finds a denied commit"
else
  bad "denylist_has finds a denied commit"
fi
if denylist_has digest 'sha256:2222222222222222222222222222222222222222222222222222222222222222'; then
  bad "denylist_has ignores a value that was never added"
else
  ok "denylist_has ignores a value that was never added"
fi
check_eq "$(jq -r ".commits[\"$denylisted_commit\"].reason" "$DEPLOY_STATE_DIR/denylist.json")" \
  'failed the boot gate' "the denylist keeps the reason"
if denylist_add nonsense value >/dev/null 2>&1; then
  bad "denylist_add refuses an unknown kind"
else
  ok "denylist_add refuses an unknown kind"
fi

# --- held, apply and pending are distinct records ----------------------------
jq -nc '{schema:1,repos:{},apps:{}}' | atomic_write "$DEPLOY_STATE_DIR/state.json"
jq -nc '{phase:"staged",commit:"cccc",digest:"sha256:aa",budget:300}' | pending_write
check_eq "$(pending_read | jq -r .phase)" staged "pending_write round-trips"
jq -nc '{phase:"pulling",previous:{apps:[]},intended:{apps:["opdshelf"]}}' | apply_write
check_eq "$(apply_read | jq -r .phase)" pulling "apply_write round-trips"
jq -nc '{digest:"sha256:bb",missing:["photos"]}' | held_write
check_eq "$(held_read | jq -r '.missing[0]')" photos "held_write round-trips"
for name in state held apply pending denylist; do
  [[ -s $DEPLOY_STATE_DIR/$name.json ]] && continue
  bad "record_write keeps $name.json"
done
pending_clear
if pending_read >/dev/null 2>&1; then
  bad "pending_clear removes the record"
else
  ok "pending_clear removes the record"
fi
if record_write nonces </dev/null >/dev/null 2>&1; then
  bad "the generic writer refuses the listener's own files"
else
  ok "the generic writer refuses the listener's own files"
fi

# --- queue -------------------------------------------------------------------
id_a=11111111-1111-4111-8111-111111111111
id_b=22222222-2222-4222-8222-222222222222
id_c=33333333-3333-4333-8333-333333333333
queue_seed() { # id repo queued_at [commit]
  jq -nc --arg id "$1" --arg repo "$2" --argjson at "$3" \
    --arg commit "${4:-1111111111111111111111111111111111111111}" \
    '{schema:1,id:$id,repo:$repo,commit:$commit,queued_at:$at,source:"event"}' |
    atomic_write "$DEPLOY_STATE_DIR/queue/$1.json"
}

queue_seed "$id_a" homelab-apps 30
queue_seed "$id_b" homelab-platform 10
queue_seed "$id_c" homelab-apps 20
check_eq "$(queue_list | tr '\n' ' ')" "${id_b} ${id_c} ${id_a} " "queue_list is FIFO by queued_at"
check_eq "$(queue_count)" 3 "queue_count counts the entries"
check_eq "$(queue_field "$id_a" repo)" homelab-apps "queue_field reads the entry"
if queue_pop '../state' >/dev/null 2>&1; then
  bad "queue_pop refuses an id that is not a uuid"
else
  ok "queue_pop refuses an id that is not a uuid"
fi
check_eq "$(queue_count)" 3 "a refused queue_pop removes nothing"

# Coalescing: two pending requests for one repository are one deploy. The older
# entry is dropped and the newer one keeps its place in the queue.
dropped=$(queue_coalesce)
check_eq "$dropped" "$id_c" "queue_coalesce reports the superseded entry"
check_eq "$(queue_list | tr '\n' ' ')" "${id_b} ${id_a} " "queue_coalesce keeps the newest per repo"
check_eq "$(queue_count)" 2 "queue_coalesce removes the superseded entry"

# Two requests that land in the same second: queued_at is equal and the listener
# and the poll both mint a random uuid, so only the file's own mtime says which
# arrived last. The uuid order below is the wrong way round on purpose: ordering
# by it would coalesce onto the older commit and deploy the one main had moved
# past.
id_d=99999999-9999-4999-8999-999999999999
id_e=00000000-0000-4000-8000-000000000000
for entry in "$DEPLOY_STATE_DIR"/queue/*.json; do rm -f "$entry"; done
queue_seed "$id_d" homelab-platform 50 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
queue_seed "$id_e" homelab-platform 50 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
touch -d '2026-01-01 00:00:00.100000000' "$DEPLOY_STATE_DIR/queue/$id_d.json"
touch -d '2026-01-01 00:00:00.900000000' "$DEPLOY_STATE_DIR/queue/$id_e.json"
check_eq "$(queue_list | tr '\n' ' ')" "${id_d} ${id_e} " \
  "a same-second queue is ordered by mtime, not by uuid"
dropped=$(queue_coalesce)
check_eq "$dropped" "$id_d" "the same-second older request is the one superseded"
check_eq "$(queue_field "$id_e" commit 2>/dev/null)" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  "the same-second newer commit is the one kept"
check_eq "$(queue_count)" 1 "the same-second older entry is removed"

# An infrastructure failure is not a verdict about the commit: the entry stays,
# stamped with when it may be tried again, and the drain exits 0 so the path unit
# is not re-fired into a loop that spends the start limit and freezes the queue.
queue_seed "$id_a" homelab-platform 60
retry_at=$(queue_field "$id_a" retry_at 2>/dev/null) || retry_at=""
check_eq "$retry_at" "" "a fresh entry carries no retry stamp"
if queue_defer "$id_a" "$(($(date +%s) + 300))" verify-infra-failure; then
  ok "queue_defer stamps the entry"
else
  bad "queue_defer stamps the entry"
fi
check_eq "$(queue_field "$id_a" attempts 2>/dev/null)" 1 "a deferral counts the attempt"
if queue_ready "$id_a"; then
  bad "a deferred entry is not ready before its retry_at"
else
  ok "a deferred entry is not ready before its retry_at"
fi
queue_defer "$id_a" "$(($(date +%s) - 1))" verify-infra-failure
if queue_ready "$id_a"; then
  ok "a deferred entry is ready once its retry_at passes"
else
  bad "a deferred entry is ready once its retry_at passes"
fi
check_eq "$(queue_field "$id_a" attempts 2>/dev/null)" 2 "each deferral counts an attempt"

# --- the queue-directory contract, shared with the Python receiver ------------
# Count regular `.json` files one level deep and nothing else: a directory or a
# non-JSON name is not a queued request. tests/deploy/receiver.sh asserts the
# Python listener's count agrees on the same fixture.
mkdir -p "$DEPLOY_STATE_DIR/queue/not-an-entry.json"
: >"$DEPLOY_STATE_DIR/queue/entry.txt"
check_eq "$(queue_count)" 2 "queue_count ignores a directory and a non-json file"
rm -rf "${DEPLOY_STATE_DIR:?}/queue/not-an-entry.json" "${DEPLOY_STATE_DIR:?}/queue/entry.txt"
if queue_has homelab-platform 1111111111111111111111111111111111111111; then
  ok "queue_has finds a queued revision"
else
  bad "queue_has finds a queued revision"
fi
if queue_has homelab-platform 2222222222222222222222222222222222222222; then
  bad "queue_has refuses a revision that is not queued"
else
  ok "queue_has refuses a revision that is not queued"
fi
read -r oldest_age oldest_id < <(queue_oldest)
check_eq "$oldest_id" "$id_e" "queue_oldest names the oldest entry"
# An entry nobody can read is a record the drain must reach, so it counts as
# infinitely old rather than as fresh.
printf 'not json\n' | atomic_write "$DEPLOY_STATE_DIR/queue/unreadable.json"
read -r _ oldest_id < <(queue_oldest)
check_eq "$oldest_id" unreadable "queue_oldest treats an unreadable entry as oldest"
rm -f "$DEPLOY_STATE_DIR/queue/unreadable.json"
for entry in "$DEPLOY_STATE_DIR"/queue/*.json; do rm -f "$entry"; done
read -r oldest_age oldest_id < <(queue_oldest)
check_eq "$oldest_age $oldest_id" "0 " "queue_oldest reports an empty queue as age 0"

# --- timers and caches ------------------------------------------------------
# `timeout 0` is no limit at all, so a zeroed knob or an exhausted budget must
# still reach the child as a one-second bound.
check_eq "$(clamp_timeout 0)" 1 "a zero timeout is clamped to one second"
check_eq "$(clamp_timeout -5)" 1 "a negative timeout is clamped to one second"
check_eq "$(clamp_timeout 30)" 30 "a positive timeout is left alone"
check_eq "$(clamp_timeout nonsense)" 1 "an unset timeout is clamped to one second"

: >"$DEPLOY_STATE_DIR/cache.json"
: >"$DEPLOY_STATE_DIR/poll-cache.json"
cache_clear
if [[ ! -e $DEPLOY_STATE_DIR/cache.json && ! -e $DEPLOY_STATE_DIR/poll-cache.json ]]; then
  ok "cache_clear drops the verifier's and the poll's cache"
else
  bad "cache_clear drops the verifier's and the poll's cache"
fi

# --- the drain ---------------------------------------------------------------
# Verification is an external program (T2), and this suite is about the queue
# mechanics around it, so the drain is pointed at a stub that accepts everything:
# the verdicts themselves are tests/deploy/verify.sh.
cat >"$work/fake-verify" <<'STUB'
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
chmod 0755 "$work/fake-verify"
export DEPLOY_VERIFY_BIN=$work/fake-verify
# The platform snapshot gate (T3) is driven by tests/deploy/platform.sh; what
# this suite proves is that the drain hands a verified platform entry to it.
cat >"$work/fake-platform" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_PLATFORM_LOG"
# prepare and stage are separate decisions: the gate can be green while the
# switch is an outage, and the drain must treat those differently.
if [[ ${1:-} == stage ]]; then exit "${FAKE_STAGE_EXIT:-0}"; fi
exit "${FAKE_PLATFORM_EXIT:-0}"
STUB
chmod 0755 "$work/fake-platform"
export DEPLOY_PLATFORM_BIN=$work/fake-platform
export FAKE_PLATFORM_LOG=$work/platform-calls
: >"$work/platform-calls"
# The apps apply/revert is T5's own suite; this suite proves the drain hands a
# verified apps entry to it and reverts an interrupted apply before the queue.
cat >"$work/fake-apps" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_APPS_LOG"
if [[ ${1:-} == revert ]]; then
  rm -f "$DEPLOY_STATE_DIR/apply.json"
fi
exit "${FAKE_APPS_EXIT:-0}"
STUB
chmod 0755 "$work/fake-apps"
export DEPLOY_APPS_BIN=$work/fake-apps
export FAKE_APPS_LOG=$work/apps-calls
: >"$work/apps-calls"
for entry in "$DEPLOY_STATE_DIR"/queue/*.json; do rm -f "$entry"; done
export DEPLOY_JOURNAL_MAX_BYTES=5242880
: >"$DEPLOY_STATE_DIR/journal.jsonl"
# The apps entry goes first: a staged platform deploy ends the drain by design (the
# host is rebooting), so the late entry this case is about has to be drainable
# before it.
queue_seed "$id_a" homelab-apps 1
# The rescan window is what closes the exit race: a request that lands while the
# drain is finishing must still be drained by the same run.
DEPLOY_DRAIN_RESCAN_PAUSE=1 timeout 30 bash "$drain" &
drain_pid=$!
sleep 0.5
queue_seed "$id_c" homelab-platform 2
if wait "$drain_pid"; then
  ok "the drain exits 0 on an empty queue"
else
  bad "the drain exits 0 on an empty queue" "exit $?"
fi
check_eq "$(queue_count)" 0 "the drain empties the queue"
check_eq "$(grep -c '"event":"verified"' "$DEPLOY_STATE_DIR/journal.jsonl")" 2 \
  "the drain rescans and drains the late entry"
check_eq "$(grep -c '"event":"drain-start"' "$DEPLOY_STATE_DIR/journal.jsonl")" 1 \
  "the drain journals its start once"
check_eq "$(grep -c '"event":"drain-finish"' "$DEPLOY_STATE_DIR/journal.jsonl")" 1 \
  "the drain journals its finish once"
check_eq "$(jq -r 'select(.event=="verified") | .repo' "$DEPLOY_STATE_DIR/journal.jsonl" | sort | tr '\n' ' ')" \
  'homelab-apps homelab-platform ' "each drained entry carries its repository"
check_eq "$(jq -r 'select(.event=="drain-finish") | .drained' "$DEPLOY_STATE_DIR/journal.jsonl")" 2 \
  "the drain counts what it drained"
check_eq "$(grep -c 'apply --commit' "$work/apps-calls")" 1 \
  "the drain hands the verified apps entry to the apps apply"

# An interrupted apps apply is reverted before anything is drained: the next
# entry would otherwise be applied on top of half of the previous revision.
: >"$work/apps-calls"
printf '{"schema":1,"phase":"installing","previousUnits":[],"intendedUnits":[]}\n' |
  apply_write
: >"$DEPLOY_STATE_DIR/journal.jsonl"
if DEPLOY_DRAIN_RESCAN_PAUSE=0 timeout 30 bash "$drain" >/dev/null 2>&1; then
  ok "the drain reverts an interrupted apps apply"
else
  bad "the drain reverts an interrupted apps apply"
fi
check_eq "$(head -n 1 "$work/apps-calls")" revert \
  "the interrupted apply is reverted before the queue is drained"
check_eq "$(jq -r 'select(.event=="apply-reverted") | .by' "$DEPLOY_STATE_DIR/journal.jsonl")" drain \
  "the drain journals the reverted apply"
if [[ -e $DEPLOY_STATE_DIR/apply.json ]]; then
  bad "the reverted apply clears the record"
else
  ok "the reverted apply clears the record"
fi

# An entry that cannot be read must never wedge the queue behind it.
printf '{"id":"%s"}\n' "$id_b" | atomic_write "$DEPLOY_STATE_DIR/queue/$id_b.json"
if DEPLOY_DRAIN_RESCAN_PAUSE=0 timeout 30 bash "$drain"; then
  ok "the drain accepts an unreadable entry"
else
  bad "the drain accepts an unreadable entry"
fi
check_eq "$(queue_count)" 0 "an invalid entry is removed, not retried forever"
check_eq "$(jq -r 'select(.event=="queue-invalid") | .id' "$DEPLOY_STATE_DIR/journal.jsonl")" "$id_b" \
  "the invalid entry is journaled with its id"
# Every tree an interrupted apply left behind is plaintext secrets; the drain
# sweeps the stale ones before it drains anything.
if (($(grep -c '^sweep$' "$work/apps-calls" 2>/dev/null) >= 1)); then
  ok "the drain sweeps the apps work trees"
else
  bad "the drain sweeps the apps work trees" "$(cat "$work/apps-calls")"
fi

# --- a staged reboot ends the drain ------------------------------------------
# `stage` writes pending.json and asks for the reboot: every later entry would be
# handled by a process the shutdown is about to kill, and an apps apply behind it
# would be half-applied with the reboot already on its way.
for entry in "$DEPLOY_STATE_DIR"/queue/*.json; do rm -f "$entry"; done
printf '{"schema":1,"repos":{}}' | atomic_write "$DEPLOY_STATE_DIR/state.json"
: >"$work/platform-calls"
: >"$work/apps-calls"
: >"$DEPLOY_STATE_DIR/journal.jsonl"
queue_seed "$id_a" homelab-platform 80 cccccccccccccccccccccccccccccccccccccccc
queue_seed "$id_b" homelab-apps 81 dddddddddddddddddddddddddddddddddddddddd
if DEPLOY_DRAIN_RESCAN_PAUSE=0 timeout 30 bash "$drain" >/dev/null 2>&1; then
  ok "the drain exits 0 after a staged platform deploy"
else
  bad "the drain exits 0 after a staged platform deploy"
fi
if grep -q '^stage ' "$work/platform-calls" 2>/dev/null; then
  ok "the drain stages the platform entry"
else
  bad "the drain stages the platform entry" "$(cat "$work/platform-calls")"
fi
if grep -q 'apply --commit' "$work/apps-calls" 2>/dev/null; then
  bad "a staged reboot applies no later apps entry" "$(cat "$work/apps-calls")"
else
  ok "a staged reboot applies no later apps entry"
fi
check_eq "$(queue_count)" 1 "the entry behind a staged reboot stays queued"
check_eq "$(queue_field "$id_b" repo 2>/dev/null)" homelab-apps \
  "the entry left queued is the later one"
# Without the stop the drain reaches the reboot's own entry again and stages it
# twice, so a reboot is requested while the host is going down.
check_eq "$(grep -c '^stage ' "$work/platform-calls" 2>/dev/null)" 1 \
  "a staged reboot is staged once"

# --- an infrastructure failure defers the entry ------------------------------
# A 429 or a dead tailnet says nothing about the commit, and retrying at once is
# worse than waiting: the path unit re-fires the drain the moment it exits, so an
# immediate retry is a loop that spends the unit's start limit and freezes the
# queue behind it.
cat >"$work/fake-verify-infra" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_VERIFY_LOG"
printf '{"verdict":"infra-failure","reason":"rate-limited"}\n'
exit 4
STUB
chmod 0755 "$work/fake-verify-infra"
export FAKE_VERIFY_LOG=$work/verify-calls
for entry in "$DEPLOY_STATE_DIR"/queue/*.json; do rm -f "$entry"; done
: >"$DEPLOY_STATE_DIR/journal.jsonl"
: >"$work/verify-calls"
queue_seed "$id_b" homelab-apps 85 eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
DEPLOY_VERIFY_BIN=$work/fake-verify-infra DEPLOY_DRAIN_RESCAN_PAUSE=0 \
  timeout 30 bash "$drain" >/dev/null 2>&1
check_eq "$?" 0 "an infrastructure failure defers the entry and exits 0"
check_eq "$(queue_count)" 1 "a deferred entry keeps its place in the queue"
check_eq "$(journal_field deferred '.reason')" rate-limited \
  "the deferral is journaled with its reason"
deferred_until=$(queue_field "$id_b" retry_at 2>/dev/null) || deferred_until=0
if ((deferred_until >= $(date +%s) + 250)); then
  ok "the deferral stamps a retry at least five minutes out"
else
  bad "the deferral stamps a retry at least five minutes out" "retry_at=$deferred_until"
fi
check_eq "$(queue_field "$id_b" attempts 2>/dev/null)" 1 "the deferral counts the attempt"
: >"$work/verify-calls"
DEPLOY_VERIFY_BIN=$work/fake-verify-infra DEPLOY_DRAIN_RESCAN_PAUSE=0 \
  timeout 30 bash "$drain" >/dev/null 2>&1
if [[ -s $work/verify-calls ]]; then
  bad "a deferred entry is skipped until its retry_at" "$(cat "$work/verify-calls")"
else
  ok "a deferred entry is skipped until its retry_at"
fi
queue_defer "$id_b" "$(($(date +%s) - 1))" rate-limited
DEPLOY_VERIFY_BIN=$work/fake-verify-infra DEPLOY_DRAIN_RESCAN_PAUSE=0 \
  timeout 30 bash "$drain" >/dev/null 2>&1
check_eq "$(grep -c 'rate-limited\|--commit' "$work/verify-calls" 2>/dev/null)" 1 \
  "a deferred entry is verified again once its retry_at passes"

# --- a verification looks at the tip, not at the cache ----------------------
# The verifier answers from a 120 s cache; a commit pushed inside that window
# would be rejected as a tip mismatch for every entry that arrived there. The
# drain clears the cache before it verifies, so the second request in the same
# second sees the tip main is at now.
cat >"$work/fake-verify-cached" <<'STUB'
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
chmod 0755 "$work/fake-verify-cached"
export FAKE_TIP_FILE=$work/tip
sha_old=1111111111111111111111111111111111111111
sha_new=2222222222222222222222222222222222222222
rm -f "$DEPLOY_STATE_DIR/cache.json"
for entry in "$DEPLOY_STATE_DIR"/queue/*.json; do rm -f "$entry"; done
: >"$DEPLOY_STATE_DIR/journal.jsonl"
printf '%s\n' "$sha_old" >"$FAKE_TIP_FILE"
queue_seed "$id_a" homelab-apps 90 "$sha_old"
DEPLOY_VERIFY_BIN=$work/fake-verify-cached DEPLOY_DRAIN_RESCAN_PAUSE=0 \
  timeout 30 bash "$drain" >/dev/null 2>&1
printf '%s\n' "$sha_new" >"$FAKE_TIP_FILE"
queue_seed "$id_b" homelab-apps 91 "$sha_new"
DEPLOY_VERIFY_BIN=$work/fake-verify-cached DEPLOY_DRAIN_RESCAN_PAUSE=0 \
  timeout 30 bash "$drain" >/dev/null 2>&1
check_eq "$(grep -c '"event":"verified"' "$DEPLOY_STATE_DIR/journal.jsonl")" 2 \
  "a second request in the same second sees the fresh tip"
check_eq "$(grep -c '"event":"verify-rejected"' "$DEPLOY_STATE_DIR/journal.jsonl")" 0 \
  "no request is rejected on a cached tip"

# --- a commit with no image is skipped, not paged ----------------------------
# The publish workflow only builds image-bearing paths, so the poll sees a main
# tip with no tag. That must pop the entry without a rejection page or a
# denylist entry, or a docs-only commit would page every hour.
cat >"$work/fake-verify-noimage" <<STUB
#!/usr/bin/env bash
printf '{"verdict":"not-deployable","reason":"tag-missing","repo":"%s","commit":"%s"}\n' "\$2" "\$4"
exit 5
STUB
chmod 0755 "$work/fake-verify-noimage"
rm -f "$DEPLOY_STATE_DIR"/queue/*.json
: >"$DEPLOY_STATE_DIR/journal.jsonl"
queue_seed "$id_c" homelab-platform 92 "$sha_old"
DEPLOY_VERIFY_BIN=$work/fake-verify-noimage DEPLOY_DRAIN_RESCAN_PAUSE=0 \
  timeout 30 bash "$drain" >/dev/null 2>&1
check_eq "$(grep -c '"event":"verify-not-deployable"' "$DEPLOY_STATE_DIR/journal.jsonl")" 1 \
  "a commit without an image is journaled as not deployable"
check_eq "$(grep -c '"event":"verify-rejected"' "$DEPLOY_STATE_DIR/journal.jsonl")" 0 \
  "a commit without an image is not a rejection"
check_eq "$(find "$DEPLOY_STATE_DIR/queue" -name '*.json' | wc -l)" 0 \
  "the skipped entry is popped"

# --- a staging outage is deferred, never a hot loop --------------------------
# systemd re-fires a path-triggered service as soon as it exits, so exiting on a
# stage failure re-ran verification, the gate and `bootc switch` every fourteen
# seconds on the host until the entry was deferred.
rm -f "$DEPLOY_STATE_DIR"/queue/*.json
: >"$DEPLOY_STATE_DIR/journal.jsonl"
queue_seed "$id_d" homelab-platform 93 "$sha_old"
FAKE_STAGE_EXIT=4 DEPLOY_DRAIN_RESCAN_PAUSE=0 \
  timeout 30 bash "$drain" >/dev/null 2>&1
rc=$?
check_eq "$rc" 0 "a staging outage ends the drain without failing it"
check_eq "$(grep -c '"event":"deferred"' "$DEPLOY_STATE_DIR/journal.jsonl")" 1 \
  "a staging outage is deferred"
check_eq "$(find "$DEPLOY_STATE_DIR/queue" -name '*.json' | wc -l)" 1 \
  "the deferred entry stays queued"
if [[ -n $(queue_field "$id_d" retry_at 2>/dev/null) ]]; then
  ok "the deferred entry carries a retry time"
else
  bad "the deferred entry carries a retry time"
fi

# --- a drain with only deferred work parks, never exits ----------------------
# The path unit re-fires a oneshot the instant it exits while the queue is
# non-empty, so exiting on "all deferred" spun the host into start-limit-hit and
# a failed path unit. The drain waits for the stamp instead.
rm -f "$DEPLOY_STATE_DIR"/queue/*.json
: >"$DEPLOY_STATE_DIR/journal.jsonl"
id_e=55555555-5555-4555-8555-555555555555
queue_seed "$id_e" homelab-platform 94 "$sha_old"
queue_defer "$id_e" "$(($(date +%s) + 3600))" test-hold
DEPLOY_DRAIN_RESCAN_PAUSE=0 timeout 2 bash "$drain" >/dev/null 2>&1
rc=$?
check_eq "$rc" 124 "a drain with only deferred work parks instead of exiting"
check_eq "$(grep -c '"event":"drain-parked"' "$DEPLOY_STATE_DIR/journal.jsonl")" 1 \
  "the parked drain journals why it is waiting"

# --- bootc runs with the scratch it needs, and nothing wider -----------------
# bootc creates /run/bootc/storage while it stages a pull; ProtectSystem=strict
# leaves /run read-only, and the failure is a staging exit on every deploy.
for unit in units/systemd/smortress-deploy.service units/systemd/smortress-boot-gate.service; do
  for dir in bootc ostree; do
    if grep -qx "RuntimeDirectory=$dir" "$unit"; then
      ok "$(basename "$unit") gives bootc /run/$dir"
    else
      bad "$(basename "$unit") gives bootc /run/$dir"
    fi
  done
done

# --- the deploy lock ---------------------------------------------------------
# The drain unit, the hourly poll and the CLI all write state.json; the lock is
# what keeps one of them from losing another's write.
bash -c '
  set -uo pipefail
  export DEPLOY_STATE_DIR DEPLOY_LOCK_FILE
  # shellcheck source=/dev/null
  source "'"$lib"'"
  deploy_lock_acquire 10 || exit 1
  sleep 3
' &
holder=$!
sleep 0.5
if deploy_lock_acquire 1; then
  bad "a held deploy lock refuses a second holder"
  deploy_lock_release
else
  ok "a held deploy lock refuses a second holder"
fi
wait "$holder"
if deploy_lock_acquire 5; then
  ok "the deploy lock is free once the holder exits"
  deploy_lock_release
else
  bad "the deploy lock is free once the holder exits"
fi

# The lock's home, and the units that create it. /run/smortress holds the
# decrypted secrets: a lock file there would be a write the units have to allow
# inside the ciphertexts' own tree, so the lock moved to its own RuntimeDirectory
# and neither unit may name /run/smortress as a writable path.
default_lock=$(sed -nE 's/^deploy_lock_file=\$\{DEPLOY_LOCK_FILE:-([^}]+)\}$/\1/p' "$lib")
check_eq "$default_lock" /run/smortress-deploy/deploy.lock \
  "the deploy lock defaults to its own runtime directory"
for unit in units/systemd/smortress-deploy.service units/systemd/smortress-boot-gate.service; do
  if grep -qxF 'RuntimeDirectory=smortress-deploy' "$unit"; then
    ok "$(basename -- "$unit") creates the lock's runtime directory"
  else
    bad "$(basename -- "$unit") creates the lock's runtime directory" "$(cat "$unit")"
  fi
  # A oneshot's RuntimeDirectory is removed when it exits, and a hand-run command
  # holding the lock would then be locking an unlinked inode.
  if grep -qxF 'RuntimeDirectoryPreserve=yes' "$unit"; then
    ok "$(basename -- "$unit") keeps the runtime directory across its exits"
  else
    bad "$(basename -- "$unit") keeps the runtime directory across its exits"
  fi
  # Directive lines only: both files explain the move in a comment.
  if grep -vE '^[[:space:]]*#' "$unit" | grep -qF '/run/smortress'; then
    bad "$(basename -- "$unit") never widens /run/smortress" \
      "$(grep -vE '^[[:space:]]*#' "$unit" | grep -F '/run/smortress')"
  else
    ok "$(basename -- "$unit") never widens /run/smortress"
  fi
done
# A hand-run command has no unit, so the library creates the directory itself;
# without that, every CLI command on a host whose drain has not run yet reports
# "another drain holds the lock".
fresh_lock=$work/fresh-run/deploy.lock
if DEPLOY_LOCK_FILE=$fresh_lock bash -c '
  set -uo pipefail
  export DEPLOY_LOCK_FILE
  # shellcheck source=/dev/null
  source "'"$lib"'"
  deploy_lock_acquire 5
' 2>/dev/null && [[ -f $fresh_lock ]]; then
  ok "the library creates the lock's directory when no unit has"
else
  bad "the library creates the lock's directory when no unit has"
fi

# Every tool a deploy script runs -- apps-schema, deploy-verify.py,
# deploy-platform, deploy-apps, smortress-restic-verify, smortress-restic-backup
# and storage-layout -- resolves through one function. The gate and the apps
# apply each carried a copy, and the drain carried three inline blocks with a
# different order; a fix to one missed the others.
check_eq "$(grep -c '^deploy_resolve()' scripts/*.sh | awk -F: '{ sum += $2 } END { print sum }')" 1 \
  "deploy_resolve has one definition"
check_eq "$(grep -c '^resolve_tool()' scripts/*.sh | awk -F: '{ sum += $2 } END { print sum }')" 0 \
  "the per-script resolver copies are gone"
# The drain and the gate must not carry an inline `/usr/libexec` probe for a
# tool; only the state-library bootstrap may name that path in those scripts.
for script in scripts/deploy-drain.sh scripts/deploy-platform.sh scripts/deploy-apps.sh; do
  if grep -qE 'if \[\[ -[xr] /usr/libexec/(deploy-|apps-schema|smortress-restic|storage-layout)' "$script"; then
    bad "$(basename -- "$script") resolves a tool inline"
  else
    ok "$(basename -- "$script") resolves tools through deploy_resolve"
  fi
done
check_eq "$(DEPLOY_STATE_DIR=$DEPLOY_STATE_DIR bash -c '
  export DEPLOY_STATE_DIR
  # shellcheck source=/dev/null
  source "'"$lib"'"
  deploy_resolve overridden apps-schema /nowhere/apps-schema.py
')" overridden "deploy_resolve keeps its environment override"
mkdir -p "$work/tools"
printf '#!/usr/bin/env bash\n' >"$work/tools/apps-schema"
chmod 0755 "$work/tools/apps-schema"
check_eq "$(DEPLOY_STATE_DIR=$DEPLOY_STATE_DIR PATH=$work/tools:$PATH bash -c '
  export DEPLOY_STATE_DIR PATH
  # shellcheck source=/dev/null
  source "'"$lib"'"
  deploy_resolve "" apps-schema /nowhere/apps-schema.py
')" "$work/tools/apps-schema" "deploy_resolve prefers a PATH stand-in over the sibling"
check_eq "$(DEPLOY_STATE_DIR=$DEPLOY_STATE_DIR PATH=/usr/bin:/bin bash -c '
  export DEPLOY_STATE_DIR PATH
  # shellcheck source=/dev/null
  source "'"$lib"'"
  deploy_resolve "" no-such-tool-812 /nowhere/no-such-tool-812
')" /nowhere/no-such-tool-812 "deploy_resolve falls back to the checkout sibling"

finish
