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
check_file() { # path label
  if [[ -f $1 ]]; then ok "$2"; else bad "$2" "missing $1"; fi
}

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

# --- the drain ---------------------------------------------------------------
for entry in "$DEPLOY_STATE_DIR"/queue/*.json; do rm -f "$entry"; done
export DEPLOY_JOURNAL_MAX_BYTES=5242880
: >"$DEPLOY_STATE_DIR/journal.jsonl"
queue_seed "$id_a" homelab-platform 1
# The rescan window is what closes the exit race: a request that lands while the
# drain is finishing must still be drained by the same run.
DEPLOY_DRAIN_RESCAN_PAUSE=1 timeout 30 bash "$drain" &
drain_pid=$!
sleep 0.5
queue_seed "$id_c" homelab-apps 2
if wait "$drain_pid"; then
  ok "the drain exits 0 on an empty queue"
else
  bad "the drain exits 0 on an empty queue" "exit $?"
fi
check_eq "$(queue_count)" 0 "the drain empties the queue"
check_eq "$(grep -c '"event":"drained-stub"' "$DEPLOY_STATE_DIR/journal.jsonl")" 2 \
  "the drain rescans and drains the late entry"
check_eq "$(grep -c '"event":"drain-start"' "$DEPLOY_STATE_DIR/journal.jsonl")" 1 \
  "the drain journals its start once"
check_eq "$(grep -c '"event":"drain-finish"' "$DEPLOY_STATE_DIR/journal.jsonl")" 1 \
  "the drain journals its finish once"
check_eq "$(jq -r 'select(.event=="drained-stub") | .repo' "$DEPLOY_STATE_DIR/journal.jsonl" | sort | tr '\n' ' ')" \
  'homelab-apps homelab-platform ' "each drained entry carries its repository"
check_eq "$(jq -r 'select(.event=="drain-finish") | .drained' "$DEPLOY_STATE_DIR/journal.jsonl")" 2 \
  "the drain counts what it drained"

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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
