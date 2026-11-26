#!/usr/bin/env bash
# Deploy state: the atomic record, journal, denylist, held/apply/pending
# documents, the request queue and the single-writer lock (SDLC #798, T1).
#
# Sourced by the drain, the platform and apps applies, the poll, the heartbeat,
# the boot gate and the CLI; never run on its own. The verifier is the Python
# deploy-verify.py, which answers the same files but does not source this: it
# writes only the API cache, while the drain holds the lock. The receiver
# listener reads state.json but writes only its own nonce ring, so two writers
# never interleave inside state.json.
#
# Every knob is environment-overridable so tests/deploy/*.sh can drive this
# exact code against a throwaway directory. Production sets none of them: the
# defaults are the host paths, and a wrong override is a wrong host path, not a
# way to skip a check.
#
# shellcheck disable=SC2034  # sourced library: consumers use a subset

deploy_state_dir=${DEPLOY_STATE_DIR:-/var/lib/homelab/deploy}
# /run is tmpfs: a lock there cannot survive as a stale file across a reboot, and
# the drain unit and a hand-run drain must serialize on the same inode. Its own
# directory and not /run/smortress: that tree holds the decrypted secrets, and a
# writable lock file inside it would be a write capability the units would have
# to grant over the ciphertexts' own directory. `RuntimeDirectory=smortress-deploy`
# is what creates this one.
deploy_lock_file=${DEPLOY_LOCK_FILE:-/run/smortress-deploy/deploy.lock}
deploy_lock_wait=${DEPLOY_LOCK_WAIT:-3600}
deploy_journal_max=${DEPLOY_JOURNAL_MAX_BYTES:-5242880}

deploy_state_file=$deploy_state_dir/state.json
deploy_journal=$deploy_state_dir/journal.jsonl
deploy_journal_rotated=$deploy_state_dir/journal.1.jsonl
deploy_denylist_file=$deploy_state_dir/denylist.json
# The verifier's 120 s API cache, written by deploy-verify while the drain holds
# the lock, and the poll's own copy of the same rule under a separate name: the
# poll runs outside the lock, so a shared file would lose one of the two. No
# helper here writes either; cache_clear removes both.
deploy_cache_file=$deploy_state_dir/cache.json
deploy_poll_cache_file=$deploy_state_dir/poll-cache.json
deploy_queue_dir=$deploy_state_dir/queue
deploy_work_dir=$deploy_state_dir/work

deploy_lock_fd=

# The schema every state document this library writes carries (the `// 1` in the
# writers below). A saved state.json of another schema is not this code's truth,
# so the apps revert refuses to restore one that disagrees with this value.
deploy_state_schema=1

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
  # `$s + {...}` and not a fresh object: a top-level key this writer does not
  # know -- added by another writer or a newer library -- must survive the
  # round trip, or a downgrade silently drops a field the others still read.
  jq -c --arg repo "$repo" --arg commit "$commit" --arg index "$index" --arg manifest "$manifest" \
    --arg now "$(deploy_now)" '
      . as $s
      | $s
      + {schema: ($s.schema // 1),
         repos: (($s.repos // {}) | .[$repo] = ({commit: $commit}
           + (if $index == "" then {} else {indexDigest: $index} end)
           + (if $manifest == "" then {} else {manifestDigest: $manifest} end))),
         updated: $now}
    ' <<<"$current" | atomic_write "$deploy_state_file"
}

# state_record_reconciled <commit> <manifest-digest> <operator>
#
# The operator's repair for a host whose record and `bootc status` disagree: the
# digest is the booted one (read from the host, never entered) and the commit is
# the one the operator asserts, because a digest-pinned boot carries no commit.
# It is deliberately not `state_record_verified`: nothing verified a deployment
# here, and the journal keeps the value the record held before -- the previous
# commit is otherwise lost, and it is what an operator reads to decide whether
# the repair was right.
state_record_reconciled() {
  local commit=$1 manifest=$2 operator=$3 current from
  [[ $commit =~ ^[0-9a-f]{40}$ && $manifest =~ ^sha256:[0-9a-f]{64}$ ]] || return 2
  [[ -n $operator ]] || operator=$(id -u)
  current=$(state_read 2>/dev/null) || current='{}'
  from=$(jq -r '.repos["homelab-platform"].commit // ""' <<<"$current" 2>/dev/null) || from=''
  journal_append state-reconciled "$(jq -nc --arg commit "$commit" --arg digest "$manifest" \
    --arg from "$from" --arg by "$operator" \
    '{commit:$commit,digest:$digest,from:$from,operator:$by}')" || return 1
  # The stale index digest is dropped, not kept beside the booted one: two
  # different digests in one record is how the record got wrong in the first place.
  jq -c --arg commit "$commit" --arg manifest "$manifest" --arg now "$(deploy_now)" '
    . as $s
    | $s
    + {schema: ($s.schema // 1),
       repos: (($s.repos // {})
         | .["homelab-platform"] = {commit: $commit, manifestDigest: $manifest}),
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

# deploy_notify <success|fail> [<reason>]
#
# The deploy check is the only notification path the receiver has, and its URL is
# the capability to keep that check green: it is read from the decrypted secret
# and never echoed, journaled or put in a log line. An absent secret is a
# journaled skip rather than a failure, because a host without the secret is a
# host mid-bootstrap, not a broken deploy -- and the caller must not treat a
# missing page as a failed deploy.
deploy_ping_secret=${DEPLOY_PING_SECRET:-/run/smortress/secrets/deploy-ping-url.yaml}
deploy_notify_timeout=${DEPLOY_NOTIFY_TIMEOUT:-10}
deploy_curl_bin=${DEPLOY_CURL_BIN:-curl}

# curl_config_url <url>: a curl config document on stdout.
#
# `url = "<value>"` is curl's own long option in config form; the quoting is
# escaped so a value carrying a quote or a backslash stays one string.
curl_config_url() { # <url>
  local url=$1
  url=${url//\\/\\\\}
  url=${url//\"/\\\"}
  printf 'url = "%s"\n' "$url"
}

deploy_notify() {
  local kind=$1 reason=${2:-} url
  case $kind in
    success | fail) ;;
    *) return 2 ;;
  esac
  # `value` format: sops-decrypt writes the scalar alone, so the first non-empty
  # line is the URL and there is no YAML to parse here.
  url=$(sed -n 's/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d; p; q' "$deploy_ping_secret" 2>/dev/null) ||
    url=""
  if [[ -z $url ]]; then
    journal_append notify-skipped "$(jq -nc --arg kind "$kind" --arg reason "${reason:-no ping url}" \
      '{kind:$kind,reason:$reason}')" || true
    return 0
  fi
  if [[ $kind == fail ]]; then url=${url%/}/fail; fi
  # The URL is the capability to keep the check green, and argv is world-readable
  # (/proc/<pid>/cmdline, `ps`): it goes to curl as a config on stdin instead.
  if ! curl_config_url "$url" | "$deploy_curl_bin" --fail --silent --show-error \
    --max-time "$deploy_notify_timeout" --config - >/dev/null 2>&1; then
    journal_append notify-failed "$(jq -nc --arg kind "$kind" --arg reason "${reason:-}" \
      '{kind:$kind,reason:$reason}')" || true
    return 1
  fi
  journal_append notify-sent "$(jq -nc --arg kind "$kind" --arg reason "${reason:-}" \
    '{kind:$kind,reason:$reason}')" || true
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

# denylist_remove <commit|digest> <value>
#
# The only way off the list, and it is the operator's: a denylisted tip stops the
# hourly poll until *that* entry is gone, so the removal is one value from one
# table, journaled by the caller with who ran it. Removing the whole list would
# reopen every refusal a gate ever made.
denylist_remove() {
  local kind=$1 value=$2 table current
  case $kind in
    commit) table=commits ;;
    digest) table=digests ;;
    *) return 2 ;;
  esac
  [[ -n $value ]] || return 2
  current=$(denylist_read)
  jq -c --arg table "$table" --arg value "$value" \
    '.[$table] = ((.[$table] // {}) | del(.[$value]))' <<<"$current" |
    atomic_write "$deploy_denylist_file"
}

# cache_clear drops both 120 s API caches, so the next verification looks at
# GitHub again. The drain calls it before every verification: a cached tip is by
# definition the tip of an earlier second, and a commit pushed inside the window
# would be rejected as a tip mismatch for as long as the entry lives. The poll's
# copy is dropped with the verifier's because they answer the same question about
# the same URL -- leaving one would serve the stale answer this call exists to
# avoid. Neither is written here; this is only the clear.
cache_clear() {
  rm -f -- "$deploy_cache_file" "$deploy_poll_cache_file" || return 1
  sync -- "$deploy_state_dir" 2>/dev/null || return 1
}

# deploy_resolve <env override> <installed name> <checkout file>
#
# The one tool-resolution rule: an explicit override, then a stand-in on $PATH,
# then the image's /usr/libexec, then the file beside the calling script. $PATH
# comes before /usr/libexec so a test can put a stand-in in front of an installed
# helper without touching /usr/libexec; root's PATH does not contain /usr/libexec,
# so on the host the installed name wins over the checkout sibling. Every tool a
# deploy script runs -- apps-schema, deploy-verify.py, deploy-platform,
# deploy-apps, smortress-restic-verify, smortress-restic-backup and
# storage-layout -- goes through here. The state library itself cannot: a script
# needs this function to exist before it can be sourced, so that one bootstrap
# stays beside each script.
deploy_resolve() {
  local override=${1:-} name=$2 sibling=$3 found
  if [[ -n $override ]]; then
    printf '%s\n' "$override"
    return 0
  fi
  if found=$(command -v "$name" 2>/dev/null); then
    printf '%s\n' "$found"
    return 0
  fi
  if [[ -x /usr/libexec/$name ]]; then
    printf '%s\n' "/usr/libexec/$name"
    return 0
  fi
  printf '%s\n' "$sibling"
}

# clamp_timeout <seconds>
#
# `timeout 0` is not a one-second bound: it is no bound at all, so a computed
# budget that reached zero (the snapshot gate's remaining time) or a knob a
# caller zeroed would hand the child unlimited time instead of none. Every
# deadline in this tree passes through here.
clamp_timeout() {
  local seconds=${1:-}
  [[ $seconds =~ ^[0-9]+$ ]] || {
    printf '1\n'
    return 0
  }
  ((10#$seconds > 0)) || seconds=1
  printf '%s\n' "$seconds"
}

# The queue is the listener's outbox: one file per accepted request, named by the
# id it answered with. FIFO is the order the requests arrived in, which is why it
# is ordered by queued_at and not by the random file name. queued_at has one-
# second resolution and both the listener and the poll mint a random uuid, so two
# requests that land in the same second have no order in either field: the file's
# own nanosecond mtime is what says which one arrived last. Ordering those two by
# uuid would let coalescing drop the newer commit and deploy the older one.
#
# The queue-directory contract, shared with the Python receiver (which cannot
# source this file) and asserted by tests/deploy/receiver.bats: an entry is a
# regular file directly inside $deploy_queue_dir whose name ends in `.json`.
# Anything else -- a subdirectory, a temporary file, a non-JSON name -- is not an
# entry. Each entry is one JSON object carrying schema, id, repo, commit,
# queued_at (epoch seconds) and source. The listener writes that shape; the
# drain, the poll and the heartbeat read only it. Changing the counting rule in
# one language without the other would let the listener's cap drift from what
# the drain sees.
queue_entries() {
  [[ -d $deploy_queue_dir ]] || return 0
  find "$deploy_queue_dir" -maxdepth 1 -type f -name '*.json' | sort
}

queue_list() {
  local file id queued written
  local -a rows=()
  while IFS= read -r file; do
    [[ -n $file ]] || continue
    id=$(basename -- "$file" .json)
    # An unreadable entry cannot be ordered: put it first so the drain reaches it
    # and drops it instead of leaving it behind every valid request forever.
    queued=$(jq -er '.queued_at | tonumber' "$file" 2>/dev/null) || queued=0
    written=$(date -r "$file" +%s%N 2>/dev/null) || written=0
    rows+=("$queued $written $id")
  done < <(queue_entries)
  ((${#rows[@]})) || return 0
  printf '%s\n' "${rows[@]}" | sort -k1,1n -k2,2n -k3,3 | cut -d' ' -f3-
}

# queue_next_retry_in <cap>: seconds until the earliest deferred entry may be
# tried, capped. The drain parks on this instead of exiting: a path-triggered
# oneshot is re-fired the moment it exits while the queue is non-empty, so
# exiting on "all deferred" is the same storm one layer up.
queue_next_retry_in() {
  local cap=$1 now best="" id retry delta
  now=$(date +%s)
  while IFS= read -r id; do
    retry=$(queue_field "$id" retry_at 2>/dev/null) || continue
    [[ $retry =~ ^[0-9]+$ ]] || continue
    ((retry > now)) || retry=$now
    if ((best == 0 || retry < best)); then best=$retry; fi
  done < <(queue_list)
  if ((best == 0)); then printf '%s\n' "$cap"; return 0; fi
  delta=$((best - now))
  ((delta < 1)) && delta=1
  ((delta > cap)) && delta=$cap
  printf '%s\n' "$delta"
}

# queue_ready <id>: an entry the drain deferred after an infrastructure failure
# carries a retry_at, and until that passes it is not this drain's work. A missing
# or malformed stamp is ready: only a recorded deferral holds an entry back.
queue_ready() {
  local at
  at=$(queue_field "${1-}" retry_at 2>/dev/null) || return 0
  [[ $at =~ ^[0-9]+$ ]] || return 0
  (($(date +%s) >= at))
}

# queue_defer <id> <retry-at> <reason>
#
# An infrastructure failure -- a 429, a dead tailnet, a full image store -- says
# nothing about the commit, so the entry keeps its place. It also may not be
# retried at once: the path unit re-fires the drain the moment it exits, which
# turns one unreachable API into a tight loop that spends the start limit and
# freezes the queue. The stamp is written into the entry itself, so the deferral
# survives both the drain that made it and a reboot.
queue_defer() {
  local id=${1-} retry_at=${2-} reason=${3:-} file attempts rc=0
  [[ $id =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || return 2
  [[ $retry_at =~ ^[0-9]+$ ]] || return 2
  file=$deploy_queue_dir/$id.json
  [[ -s $file ]] || return 1
  attempts=$(jq -er '.attempts // 0 | tonumber' "$file" 2>/dev/null) || attempts=0
  jq -c --argjson at "$retry_at" --argjson attempts "$((attempts + 1))" --arg reason "$reason" \
    '. + {retry_at: $at, attempts: $attempts, deferred: $reason}' "$file" |
    atomic_write "$file" || rc=$?
  return "$rc"
}

queue_count() {
  local count=0 _
  while IFS= read -r _; do count=$((count + 1)); done < <(queue_entries)
  printf '%s\n' "$count"
}

# queue_has <repo> <commit>: a request already in the queue is the same
# decision, so the poll enqueues nothing for it and the drain sees one entry.
queue_has() {
  local file
  while IFS= read -r file; do
    [[ -n $file ]] || continue
    if jq -e --arg repo "$1" --arg commit "$2" \
      '.repo == $repo and .commit == $commit' "$file" >/dev/null 2>&1; then
      return 0
    fi
  done < <(queue_entries)
  return 1
}

# queue_oldest: print "<age> <id>" for the oldest entry, or "0" when the queue is
# empty. The heartbeat pages on the age, never on the count: one entry younger
# than a minute is a deploy in flight, and one entry older than the limit is a
# drain that is not running. An unreadable entry counts as infinitely old -- the
# drain drops it next run, but until then it is a record nobody can read -- and
# a queued_at in the future is a clock that stepped, not an old request.
queue_oldest() {
  local file id queued age now oldest_age=0 oldest_id=''
  now=$(date +%s)
  while IFS= read -r file; do
    [[ -n $file ]] || continue
    queued=$(jq -er '.queued_at | tonumber' "$file" 2>/dev/null) || queued=0
    age=$((now - queued))
    ((age < 0)) && age=0
    if ((age >= oldest_age)); then
      oldest_age=$age
      oldest_id=$(basename -- "$file" .json)
    fi
  done < <(queue_entries)
  printf '%s %s\n' "$oldest_age" "$oldest_id"
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
  # The unit's RuntimeDirectory creates this on the host; a hand-run command and
  # a test have no unit, and a missing directory would make every one of them
  # report "another drain holds the lock" instead of taking it.
  install -d -m 0700 "$(dirname -- "$deploy_lock_file")" 2>/dev/null || true
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
