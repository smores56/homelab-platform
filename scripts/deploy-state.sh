#!/usr/bin/env bash
# Deploy state: the atomic record, journal, denylist, held/apply/pending
# documents, the request queue and the single-writer lock (SDLC #798, T1).
#
# Sourced by deploy-drain and, from T2 on, by the verifier, the platform and
# apps applies and the CLI; never run on its own. The receiver listener reads
# the same files but writes only its own nonce ring, so two writers never
# interleave inside state.json.
#
# Every knob is environment-overridable so tests/deploy/*.sh can drive this
# exact code against a throwaway directory. Production sets none of them: the
# defaults are the host paths, and a wrong override is a wrong host path, not a
# way to skip a check.
#
# shellcheck disable=SC2034  # sourced library: consumers use a subset

deploy_state_dir=${DEPLOY_STATE_DIR:-/var/lib/homelab/deploy}
# /run is tmpfs: a lock there cannot survive as a stale file across a reboot, and
# the drain unit and a hand-run drain must serialize on the same inode.
deploy_lock_file=${DEPLOY_LOCK_FILE:-/run/smortress/deploy.lock}
deploy_lock_wait=${DEPLOY_LOCK_WAIT:-3600}
deploy_journal_max=${DEPLOY_JOURNAL_MAX_BYTES:-5242880}

deploy_state_file=$deploy_state_dir/state.json
deploy_journal=$deploy_state_dir/journal.jsonl
deploy_journal_rotated=$deploy_state_dir/journal.1.jsonl
deploy_denylist_file=$deploy_state_dir/denylist.json
# The verifier's 120 s API cache. Written by deploy-verify while the drain holds
# the lock, so no helper here writes it; only clearing it.
deploy_cache_file=$deploy_state_dir/cache.json
deploy_queue_dir=$deploy_state_dir/queue
deploy_work_dir=$deploy_state_dir/work

deploy_lock_fd=

deploy_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Root-only tree under /var/lib/homelab/deploy. tmpfiles creates it at boot; the
# drain calls this too so a hand-run drain against a restored host still works.
deploy_state_init() {
  install -d -m 0700 "$deploy_state_dir" "$deploy_queue_dir" "$deploy_work_dir"
}

# atomic_write <path>; content on stdin.
#
# temp + fsync + rename + directory fsync: a reader either sees the previous
# document or the complete new one, and a reboot cannot leave a half-written
# record that the next drain would then read as truth. bash has no fsync(2), so
# `sync` on the file and on its directory is the portable stand-in -- on a local
# filesystem it flushes exactly that inode and that directory entry.
atomic_write() {
  local path=$1 dir tmp rc=0
  dir=$(dirname -- "$path")
  tmp=$(mktemp "$dir/.$(basename -- "$path").XXXXXX") || return 1
  if ! cat >"$tmp"; then rc=1; fi
  if ((rc == 0)) && ! chmod 0600 "$tmp"; then rc=1; fi
  if ((rc == 0)) && ! sync -- "$tmp" 2>/dev/null; then rc=1; fi
  if ((rc == 0)) && ! mv -f -- "$tmp" "$path"; then rc=1; fi
  if ((rc != 0)); then
    rm -f -- "$tmp"
    return 1
  fi
  # The rename itself is only durable once the directory is.
  sync -- "$dir" 2>/dev/null || return 1
  return 0
}

# The documents a drain may write. nonces.json and listener.lock are the
# listener's alone: naming them here would be how a drain loses a nonce and
# reopens a replay window.
record_path() {
  case $1 in
    state | held | apply | pending | denylist) printf '%s/%s.json\n' "$deploy_state_dir" "$1" ;;
    *) return 2 ;;
  esac
}

record_exists() {
  local file
  file=$(record_path "$1") || return 2
  [[ -s $file ]]
}

record_read() {
  local file
  file=$(record_path "$1") || return 2
  [[ -s $file ]] || return 1
  cat -- "$file"
}

record_field() { # <name> <dotted.jq.path>
  local file
  file=$(record_path "$1") || return 2
  [[ -s $file ]] || return 1
  jq -er --arg path "$2" 'getpath($path | split("."))' "$file"
}

record_write() { # <name>; content on stdin
  local file
  file=$(record_path "$1") || return 2
  atomic_write "$file"
}

# Removing a record is a rename away from the name, not an in-place truncation:
# a reader that already opened it still sees the complete previous document.
record_clear() {
  local file
  file=$(record_path "$1") || return 2
  rm -f -- "$file" || return 1
  sync -- "$deploy_state_dir" 2>/dev/null || return 1
}

# state.json is the host's answer to "what is running", one entry per
# repository, and the listener reads exactly `.repos.<repo>.commit` from it to
# answer "already deployed". Both digest forms are recorded because bootc reports
# either the index or the platform manifest form:
#
#   {"schema": 1,
#    "repos": {"homelab-platform": {"commit": ..., "indexDigest": ..., "manifestDigest": ...},
#              "homelab-apps": {"commit": ...}},
#    "apps": {"unitsHash": ..., "secretsHash": ...},
#    "updated": "<iso>"}
state_read() { record_read state; }
state_field() { record_field state "$1"; }

# The deployed commit for a repository, or nothing when the state has none: a
# listener that cannot answer "already deployed" queues one redundant request,
# which is the safe direction. Every consumer that needs an ancestor (verifying a
# descendancy, checking a boot) asks here rather than parsing state.json itself.
deployed_commit() {
  state_field "repos.$1.commit" 2>/dev/null
}

# state_record_verified <repo> <commit> [<index-digest>] [<manifest-digest>]
#
# What the host is running now, written only after a deployment lands. Journaled
# first: a crash between the two calls leaves the journal as the truth and this
# file rebuildable, which is the rule for every record here. Both digest forms
# are stored because bootc reports either the index digest or the platform
# manifest digest, and the boot gate compares what it reports to what is here.
state_record_verified() {
  local repo=$1 commit=$2 index=${3:-} manifest=${4:-} current
  [[ -n $repo && -n $commit ]] || return 2
  case $repo in
    homelab-platform | homelab-apps) ;;
    *) return 2 ;;
  esac
  journal_append state-verified "$(jq -nc --arg repo "$repo" --arg commit "$commit" \
    --arg index "$index" --arg manifest "$manifest" \
    '{repo:$repo,commit:$commit,indexDigest:$index,manifestDigest:$manifest}')" || return 1
  current=$(state_read 2>/dev/null) || current='{}'
  jq -c --arg repo "$repo" --arg commit "$commit" --arg index "$index" --arg manifest "$manifest" \
    --arg now "$(deploy_now)" '
      . as $s
      | {schema: ($s.schema // 1),
         repos: (($s.repos // {}) | .[$repo] = ({commit: $commit}
           + (if $index == "" then {} else {indexDigest: $index} end)
           + (if $manifest == "" then {} else {manifestDigest: $manifest} end))),
         apps: ($s.apps // {}),
         updated: $now}
    ' <<<"$current" | atomic_write "$deploy_state_file"
}

held_read() { record_read held; }
held_write() { record_write held; }
apply_read() { record_read apply; }
apply_write() { record_write apply; }
pending_read() { record_read pending; }
pending_write() { record_write pending; }
pending_clear() { record_clear pending; }

# journal_append <event> [<json-object-of-details>]
#
# Append-only, and durable before the action it describes: a drain that dies
# after this call leaves the host a record of what it was about to do. Past the
# limit the live file rotates to journal.1.jsonl, so the record of the last few
# thousand deploys survives without the file growing without bound. The listener
# appends single lines too; it reopens the file per write, so a rotation here
# cannot leave it writing into the rotated inode.
journal_append() {
  local event=$1 details=${2:-'{}'} line size
  if ! line=$(jq -c --arg ts "$(deploy_now)" --arg event "$event" \
    'if type == "object" then . else error("details must be a JSON object") end
     | {ts: $ts, event: $event} + .' <<<"$details" 2>/dev/null); then
    return 1
  fi
  size=$(stat -c %s "$deploy_journal" 2>/dev/null) || size=0
  if ((size >= deploy_journal_max)); then
    mv -f -- "$deploy_journal" "$deploy_journal_rotated" || return 1
    sync -- "$deploy_state_dir" 2>/dev/null || return 1
  fi
  printf '%s\n' "$line" >>"$deploy_journal" || return 1
  sync -- "$deploy_journal" 2>/dev/null || return 1
  return 0
}

# denylist_add <commit|digest> <value> [<reason>]
#
# Platform digests and apps commits live in one file with two tables: a gate
# failure names whichever of the two it rejected, and both are refusals at the
# listener. Removal is by hand (T7's `unblock`) and journaled there.
denylist_add() {
  local kind=$1 value=$2 reason=${3:-} table current
  case $kind in
    commit) table=commits ;;
    digest) table=digests ;;
    *) return 2 ;;
  esac
  [[ -n $value ]] || return 2
  current=$(denylist_read)
  jq -c --arg table "$table" --arg value "$value" --arg reason "$reason" \
    --arg at "$(deploy_now)" \
    '. as $d | $d[$table] = (($d[$table] // {}) + {($value): {reason: $reason, at: $at}})' \
    <<<"$current" | atomic_write "$deploy_denylist_file"
}

denylist_read() {
  if [[ -s $deploy_denylist_file ]]; then
    cat -- "$deploy_denylist_file"
  else
    printf '{"schema":1,"commits":{},"digests":{}}\n'
  fi
}

denylist_has() { # <commit|digest> <value>
  local kind=$1 value=$2 table
  case $kind in
    commit) table=commits ;;
    digest) table=digests ;;
    *) return 2 ;;
  esac
  [[ -s $deploy_denylist_file ]] || return 1
  jq -e --arg table "$table" --arg value "$value" \
    '.[$table] // {} | has($value)' "$deploy_denylist_file" >/dev/null 2>&1
}

# Either digest form is a refusal: bootc reports one or the other for the same
# boot, so a check on a single form would let a denied image through.
denylist_has_digest() { denylist_has digest "$1"; }

# cache_clear drops the verifier's 120 s API cache, so the next verification
# looks at GitHub again. The verifier is the only writer of that file; this is
# the hand-run and test-side reset, not a second writer.
cache_clear() {
  rm -f -- "$deploy_cache_file" || return 1
  sync -- "$deploy_state_dir" 2>/dev/null || return 1
}

# The queue is the listener's outbox: one file per accepted request, named by the
# id it answered with. FIFO is the order the requests arrived in, which is why it
# is ordered by queued_at and not by the random file name.
queue_list() {
  [[ -d $deploy_queue_dir ]] || return 0
  local file id queued
  local -a rows=()
  while IFS= read -r file; do
    [[ -n $file ]] || continue
    id=$(basename -- "$file" .json)
    # An unreadable entry cannot be ordered: put it first so the drain reaches it
    # and drops it instead of leaving it behind every valid request forever.
    queued=$(jq -er '.queued_at | tonumber' "$file" 2>/dev/null) || queued=0
    rows+=("$queued $id")
  done < <(find "$deploy_queue_dir" -maxdepth 1 -type f -name '*.json' | sort)
  ((${#rows[@]})) || return 0
  printf '%s\n' "${rows[@]}" | sort -k1,1n -k2,2 | cut -d' ' -f2-
}

queue_count() {
  [[ -d $deploy_queue_dir ]] || { printf '0\n'; return 0; }
  find "$deploy_queue_dir" -maxdepth 1 -type f -name '*.json' -printf '.' | wc -c | tr -d ' '
}

queue_field() { # <id> <dotted.jq.path>
  local file=$deploy_queue_dir/$1.json
  [[ -s $file ]] || return 1
  jq -er --arg path "$2" 'getpath($path | split("."))' "$file" 2>/dev/null
}

# The id becomes a path component: only the uuid the listener mints is allowed,
# so no queued document can name a file outside the queue.
queue_pop() {
  [[ ${1-} =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || return 2
  local file=$deploy_queue_dir/$1.json
  [[ -f $file ]] || return 1
  rm -f -- "$file" || return 1
  sync -- "$deploy_queue_dir" 2>/dev/null || return 0
  return 0
}

# queue_coalesce: remove every pending request a newer request for the same
# repository has superseded, and print the ids it removed in queue order.
#
# One repository has one deployable revision at a time, so two pending requests
# for it are one deploy: the drain must not stage the older commit and then the
# newer one, which would reboot twice and roll the host forward through a
# revision nothing asked to keep.
queue_coalesce() {
  local -a ids=() dropped=()
  local id repo i
  local -A seen=()
  mapfile -t ids < <(queue_list)
  ((${#ids[@]})) || return 0
  # Backwards: the last entry for a repository is the one that survives.
  for ((i = ${#ids[@]} - 1; i >= 0; i--)); do
    id=${ids[i]}
    repo=$(queue_field "$id" repo 2>/dev/null) || repo="unreadable/$id"
    if [[ -n ${seen[$repo]:-} ]]; then
      dropped=("$id" "${dropped[@]}")
    else
      seen[$repo]=1
    fi
  done
  for id in "${dropped[@]}"; do
    if queue_pop "$id"; then
      printf '%s\n' "$id"
    fi
  done
}

# One writer at a time for state.json and the queue. The fd is held for the life
# of the calling shell, so `flock -w` bounds the wait and an exiting process
# releases the lock even after a kill -9.
deploy_lock_acquire() { # [<seconds>]
  if [[ -n $deploy_lock_fd ]]; then
    return 0
  fi
  exec {deploy_lock_fd}>"$deploy_lock_file" || {
    deploy_lock_fd=
    return 1
  }
  if ! flock -w "${1:-$deploy_lock_wait}" "$deploy_lock_fd"; then
    exec {deploy_lock_fd}>&-
    deploy_lock_fd=
    return 1
  fi
  return 0
}

deploy_lock_release() {
  if [[ -n $deploy_lock_fd ]]; then
    exec {deploy_lock_fd}>&-
    deploy_lock_fd=
  fi
  return 0
}
