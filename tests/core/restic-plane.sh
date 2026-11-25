#!/usr/bin/env bash
# Offline checks for the Restic plane (SDLC #706, T3).
#
# The host half — real disks, real repositories, real Healthchecks — is in
# docs/manual-steps.md section 38. This proves the half that does not need root
# or a network: exit-code handling, the verified-tag gate, retention filters,
# stale-staging reconciliation, fail-closed freshness, and that a job cannot
# run before its dataset is ready. restic, zfs, curl and sops are stubs; the
# command lines and the durable state are real.
#
#   tests/core/restic-plane.sh
# shellcheck disable=SC2034  # out is kept for debugging failed assertions
# shellcheck disable=SC2154  # the storage table and helpers are sourced below
set -uo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root" || exit 1

pass=0
fail=0
ok() {
  pass=$((pass + 1))
  printf 'ok   %s\n' "$1"
}
bad() {
  fail=$((fail + 1))
  printf 'FAIL %s\n' "$1"
  [[ -n ${2:-} ]] && printf '     %s\n' "${2//$'\n'/$'\n'     }"
  return 0
}
eq() {
  if [[ $1 == "$2" ]]; then ok "$3"; else bad "$3" "got '$1' want '$2'"; fi
}

# The harness builds its stub tree from the real storage table: the verifier
# fails closed on a unit with no state, so a hardcoded list here would stop
# testing whichever unit was added last without failing.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

bin=$work/bin
install -d -m 0755 "$bin"
state=$work/state
repos=$work/repos
secrets=$work/secrets
install -d -m 0700 "$state" "$repos/ssd" "$repos/hdd" "$secrets"
export STORAGE_MOUNT_ROOT=$work
# shellcheck source=/dev/null
source scripts/storage-layout.sh
for key in "${dataset_order[@]}"; do
  install -d -m 0755 "$(mountpoint_for "$key")/.zfs/snapshot"
done
printf 'hunter2\n' >"$secrets/restic-password.yaml"
chmod 0600 "$secrets/restic-password.yaml"
cat >"$secrets/r2-credentials.yaml" <<'EOF'
r2_access_key_id: stub-id
r2_secret_access_key: stub-secret
EOF
chmod 0600 "$secrets/r2-credentials.yaml"

cat >"$work/mountinfo" <<EOF
36 25 8:1 / $repos/ssd rw,relatime - ext4 /dev/sdb1 rw
37 25 8:2 / $repos/hdd rw,relatime - ext4 /dev/sda1 rw
EOF

log=$work/log
install -d -m 0755 "$log"
: >"$log/restic"; : >"$log/zfs"; : >"$log/curl-urls"; : >"$log/ready"

# --- stubs ---------------------------------------------------------------
cat >"$bin/restic" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG/restic"
cmd=""
i=0
args=("$@")
while ((i < ${#args[@]})); do
  case ${args[i]} in
    -r) repo=${args[i + 1]}; i=$((i + 2)); continue ;;
    --retry-lock) i=$((i + 2)); continue ;;
    -*) i=$((i + 1)); continue ;;
    *) cmd=${args[i]}; break ;;
  esac
done
case $cmd in
  backup)
    # A slow upload is the only way to prove which deadline a run was given.
    [[ -n ${STUB_BACKUP_SLEEP:-} ]] && sleep "$STUB_BACKUP_SLEEP"
    [[ -n ${STUB_BACKUP_ID:-} ]] &&
      printf '{"message_type":"summary","snapshot_id":"%s","tree_id":"%s"}\n' \
        "$STUB_BACKUP_ID" "${STUB_BACKUP_TREE:-tree1}"
    exit "${STUB_BACKUP_EXIT:-0}"
    ;;
  tag)
    if [[ -n ${STUB_TAG_EXIT_ONCE:-} ]]; then
      c="$STUB_LOG/tag-count"; n=$(cat "$c" 2>/dev/null || echo 0)
      if ((n == 0)); then echo 1 >"$c"; exit "$STUB_TAG_EXIT_ONCE"; fi
    fi
    exit "${STUB_TAG_EXIT:-0}" ;;
  cat)
    printf '{"tree":"%s"}\n' "${STUB_BACKUP_TREE:-tree1}"
    exit "${STUB_CAT_EXIT:-0}" ;;
  snapshots)
    if [[ -n ${STUB_SNAPSHOTS_JSON:-} ]]; then
      printf '%s\n' "$STUB_SNAPSHOTS_JSON"
      exit "${STUB_SNAPSHOTS_EXIT:-0}"
    fi
    unit=""
    for ((j = 0; j < ${#args[@]}; j++)); do
      if [[ ${args[j]} == --tag && ${args[j + 1]} == unit:* ]]; then
        unit=${args[j + 1]#unit:}
        unit=${unit%%,*}
      fi
    done
    case $repo in
      */restic) backend=$(basename "$(dirname "$repo")") ;;
      *) backend=r2 ;;
    esac
    export STORAGE_MOUNT_ROOT=$(dirname "$STUB_LOG")
    # shellcheck source=/dev/null
    source "$REPO_ROOT/scripts/storage-layout.sh"
    # shellcheck source=/dev/null
    source "$REPO_ROOT/scripts/restic-plane-common.sh"
    # restic stores a multi-path snapshot with its paths sorted
    paths=$(unit_paths_json "$unit" "$backend" | jq -c "sort")
    printf '[{"id":"%s","tree":"%s","time":"%s","hostname":"smortress","paths":%s,"tags":["unit:%s","host:smortress","verified"]}]\n' \
      "${STUB_VERIFIED_ID:-${STUB_BACKUP_ID:-strepo}}" \
      "${STUB_VERIFIED_TREE:-${STUB_BACKUP_TREE:-tree1}}" \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$paths" "$unit"
    exit 0
    ;;
  forget | prune | check) exit "${STUB_MAINT_EXIT:-0}" ;;
  init) exit "${STUB_INIT_EXIT:-0}" ;;
  restore) exit 0 ;;
esac
exit 0
EOF
cat >"$bin/zfs" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG/zfs"
case $1 in
  list) exit "${STUB_ZFS_LIST_EXIT:-1}" ;;
  destroy)
    # A real zfs says why on stderr; the driver has to keep that sentence.
    if (( ${STUB_ZFS_DESTROY_EXIT:-0} != 0 )); then
      printf '%s\n' "${STUB_ZFS_STDERR:-cannot destroy snapshot}" >&2
      exit "$STUB_ZFS_DESTROY_EXIT"
    fi
    # Fail only snapshots this run created, i.e. the end-of-run cleanup: the
    # reconciliation of a stale one happens before any create.
    if [[ -n ${STUB_ZFS_DESTROY_FAIL_LATE:-} ]] && grep -qx "${2##*@}" "$STUB_LOG/snapshots" 2>/dev/null; then
      printf '%s\n' "${STUB_ZFS_STDERR:-cannot destroy snapshot}" >&2
      exit 1
    fi
    exit 0
    ;;
  snapshot)
    name=${2##*@}
    ds=${2%@*}
    key=${ds#*/}
    printf '%s\n' "$name" >>"$STUB_LOG/snapshots"
    # The scratch root is the harness's work dir, next to the stub log.
    export STORAGE_MOUNT_ROOT=$(dirname "$STUB_LOG")
    # shellcheck source=/dev/null
    source "$REPO_ROOT/scripts/storage-layout.sh"
    install -d -m 0755 "$(mountpoint_for "$key")/.zfs/snapshot/$name"
    exit 0
    ;;
esac
exit 0
EOF
cat >"$bin/zfs-ready" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG/ready"
exit "${STUB_READY_EXIT:-0}"
EOF
cat >"$bin/curl" <<'EOF'
#!/usr/bin/env bash
url=""
for a in "$@"; do url=$a; done
printf '%s\n' "$url" >>"$STUB_LOG/curl-urls"
exit "${STUB_CURL_EXIT:-0}"
EOF
chmod 0755 "$bin"/*

export STUB_LOG=$log REPO_ROOT=$PWD
export PATH="$bin:$PATH"
export RESTIC_BIN=$bin/restic ZFS_BIN=$bin/zfs ZFS_READY_BIN=$bin/zfs-ready CURL_BIN=$bin/curl
export RESTIC_BASE=$repos RESTIC_STATE_ROOT=$state STORAGE_LAYOUT=$PWD/scripts/storage-layout.sh
# The driver refuses to run without a cache it can create; the unit supplies one
# via CacheDirectory, so the harness supplies its own instead of relying on
# /var/cache being writable (it is not on a CI runner).
export RESTIC_CACHE_DIR=$work/cache
mkdir -p "$RESTIC_CACHE_DIR"
export SMORTRESS_SECRETS_DIR=$secrets RESTIC_MOUNTINFO=$work/mountinfo
export RESTIC_ATTEMPTS=1 RESTIC_RETRY_SLEEP_LOCAL=0 RESTIC_RETRY_SLEEP_R2=0
export RESTIC_LOCK_WAIT=5 RESTIC_DEADLINE_LOCAL=20 RESTIC_DEADLINE_R2=20
export RESTIC_DEADLINE_MAINTENANCE=20

reset_state() {
  rm -rf "$state"
  install -d -m 0700 "$state"
  : >"$log/restic"; : >"$log/zfs"; : >"$log/curl-urls"; : >"$log/ready"
  : >"$log/snapshots"
  unset STUB_BACKUP_EXIT STUB_BACKUP_ID STUB_BACKUP_SLEEP STUB_TAG_EXIT STUB_ZFS_LIST_EXIT \
    STUB_ZFS_DESTROY_FAIL_LATE STUB_ZFS_STDERR \
    STUB_SNAPSHOTS_JSON STUB_SNAPSHOTS_EXIT STUB_READY_EXIT STUB_CAT_EXIT \
    STUB_MAINT_EXIT STUB_INIT_EXIT STUB_CURL_EXIT RESTIC_HEALTHCHECK_URL
  for key in "${dataset_order[@]}"; do
    rm -rf "${dataset_mount[$key]}/.zfs/snapshot"/*
  done
}

run() {
  out=$(env "$@" 2>&1)
  rc=$?
}

state_json() {
  jq -r "$2" "$state/state/$1.json" 2>/dev/null
}

# --- 1. exit codes -------------------------------------------------------
reset_state
export STUB_BACKUP_EXIT=1 STUB_BACKUP_ID=""
run scripts/smortress-restic-backup.sh ssd --unit photos --no-maintenance
if ((rc != 0)); then ok "exit 1 is a failed run"; else bad "exit 1 is a failed run" "rc=$rc"; fi
eq "$(state_json ssd-photos '.last_attempt.result')" failure "failed run is recorded as failure"
eq "$(state_json ssd-photos '.last_attempt.reason')" exit-1 "failure reason records the exit code"
if grep -q '^tag ' "$log/restic"; then bad "no verified tag after exit 1"; else ok "no verified tag after exit 1"; fi

reset_state
export STUB_BACKUP_EXIT=3 STUB_BACKUP_ID="incomplete1"
run scripts/smortress-restic-backup.sh ssd --unit photos --no-maintenance
if ((rc != 0)); then ok "exit 3 is a failed run"; else bad "exit 3 is a failed run"; fi
eq "$(state_json ssd-photos '.last_attempt.reason')" exit-3 "exit 3 keeps its own reason"
eq "$(state_json ssd-photos '.pending_reap[0]')" incomplete1 "an incomplete snapshot ID is recorded for reaping"
if grep -q '^tag ' "$log/restic"; then bad "an exit-3 snapshot is never tagged verified"; else ok "an exit-3 snapshot is never tagged verified"; fi

reset_state
export STUB_BACKUP_EXIT=0 STUB_BACKUP_ID="complete1"
run scripts/smortress-restic-backup.sh ssd --unit photos --no-maintenance
eq "$rc" 0 "exit 0 succeeds"
eq "$(state_json ssd-photos '.last_attempt.result')" success "success is recorded"
eq "$(state_json ssd-photos '.final.snapshot')" complete1 "the final snapshot ID is persisted"
if grep -q -- 'tag --add verified complete1' "$log/restic"; then
  ok "the successful snapshot is tagged verified"
else
  bad "the successful snapshot is tagged verified" "$(cat "$log/restic")"
fi

# A second verified snapshot for the same unit and path set is normal. The run
# must pick the one whose tree it just wrote, not whichever is newest by time.
reset_state
export STUB_BACKUP_ID=complete3 STUB_BACKUP_TREE=treeB
STUB_SNAPSHOTS_JSON=$(cat <<'JSON'
[{"id":"older1","tree":"treeA","time":"2026-01-01T00:00:00Z","hostname":"smortress","paths":[],"tags":["unit:photos","host:smortress","verified"]},
{"id":"newer2","tree":"treeB","time":"2026-01-01T00:05:00Z","hostname":"smortress","paths":[],"tags":["unit:photos","host:smortress","verified"]}]
JSON
)
export STUB_SNAPSHOTS_JSON
run scripts/smortress-restic-backup.sh ssd --unit photos --no-maintenance
eq "$rc" 0 "a run succeeds when an older verified snapshot has a different tree"
eq "$(state_json ssd-photos '.final.snapshot')" newer2 "the tree selects the snapshot this attempt wrote"
unset STUB_SNAPSHOTS_JSON
if [[ ! -e $(mountpoint_for raw/photos)/.zfs/snapshot/ssd ]] || [[ -z $(ls -A "$(mountpoint_for raw/photos)/.zfs/snapshot/ssd" 2>/dev/null) ]]; then
  ok "the staging snapshot was destroyed"
else
  bad "the staging snapshot was destroyed"
fi

# restic tag rewrites the snapshot, so the id changes; recording the pre-tag id
# makes the freshness verifier report a snapshot that no longer exists.
reset_state
export STUB_BACKUP_EXIT=0 STUB_BACKUP_ID="pretag1" STUB_VERIFIED_ID="tagged1"
run scripts/smortress-restic-backup.sh ssd --unit photos --no-maintenance
eq "$rc" 0 "a tagged snapshot succeeds"
eq "$(state_json ssd-photos .final.snapshot)" tagged1 "the post-tag snapshot ID is the one recorded"
if grep -q -- "tag --add verified pretag1" "$log/restic"; then
  ok "the tag is applied to the pre-tag snapshot"
else
  bad "the tag is applied to the pre-tag snapshot"
fi
reset_state
export STUB_BACKUP_ID="" STUB_VERIFIED_ID=""

reset_state
export STUB_BACKUP_EXIT=0 STUB_BACKUP_ID="complete2" STUB_TAG_EXIT=1
run scripts/smortress-restic-backup.sh ssd --unit photos --no-maintenance
if ((rc != 0)); then ok "tagging failure fails the run"; else bad "tagging failure fails the run"; fi
eq "$(state_json ssd-photos '.last_attempt.reason')" tag-failed "tagging failure is its own reason"
eq "$(state_json ssd-photos '.pending_reap[0]')" complete2 "an untagged snapshot is reaped by recorded ID"

# restic exit 11 is a lock failure: remove only stale locks, then retry once.
reset_state
export STUB_BACKUP_EXIT=0 STUB_BACKUP_ID="lock1" STUB_VERIFIED_ID="lock1v" STUB_TAG_EXIT_ONCE=11
run scripts/smortress-restic-backup.sh ssd --unit photos --no-maintenance
eq "$rc" 0 "a stale lock is retried after unlocking"
if grep -q ' unlock' "$log/restic"; then ok "stale locks are removed before the retry"; else bad "stale locks are removed before the retry"; fi
export STUB_TAG_EXIT_ONCE=""
reset_state
export STUB_BACKUP_ID="" STUB_VERIFIED_ID=""

# --- 2. stale staging reconciliation ------------------------------------
reset_state
export STUB_BACKUP_EXIT=0 STUB_BACKUP_ID="complete3" STUB_ZFS_LIST_EXIT=0
run scripts/smortress-restic-backup.sh ssd --unit photos --no-maintenance
eq "$rc" 0 "a stale staging snapshot does not block the run"
if [[ $(grep -n '^destroy smortress/raw/photos@ssd' "$log/zfs" | head -n1 | cut -d: -f1) -lt \
  $(grep -n '^snapshot smortress/raw/photos@ssd' "$log/zfs" | head -n1 | cut -d: -f1) ]]; then
  ok "reconciliation destroys the stale snapshot before creating a new one"
else
  bad "reconciliation destroys the stale snapshot before creating a new one" "$(cat "$log/zfs")"
fi
if grep -q 'destroy smortress/raw/photos@hdd\|destroy smortress/raw/books@ssd' "$log/zfs"; then
  bad "a job destroys only its own staging snapshot"
else
  ok "a job destroys only its own staging snapshot"
fi

# --- 2b. a staging failure says why -------------------------------------
# The 2026-11-22 hdd/photos failure recorded "snapshot-reconcile" and nothing
# else, because zfs's stderr went to /dev/null at every destroy site.
reset_state
export STUB_BACKUP_EXIT=0 STUB_BACKUP_ID="complete3" STUB_ZFS_LIST_EXIT=0 STUB_ZFS_DESTROY_EXIT=1
busy="cannot destroy 'smortress/raw/photos@ssd': dataset is busy"
export STUB_ZFS_STDERR=$busy
run scripts/smortress-restic-backup.sh ssd --unit photos --no-maintenance
if ((rc != 0)); then ok "a stale snapshot that will not destroy fails the job"; else bad "a stale snapshot that will not destroy fails the job"; fi
eq "$(state_json ssd-photos '.last_attempt.reason')" snapshot-reconcile "the failure reason stays symbolic"
if [[ $out == *"$busy"* ]]; then
  ok "a failed reconciliation records zfs's own message"
else
  bad "a failed reconciliation records zfs's own message" "$out"
fi
eq "$(grep -c '^destroy smortress/raw/photos@ssd' "$log/zfs")" 2 \
  "a busy destroy is retried once before the attempt fails"

reset_state
export STUB_BACKUP_EXIT=0 STUB_BACKUP_ID="complete4" STUB_ZFS_LIST_EXIT=1 STUB_ZFS_DESTROY_FAIL_LATE=1
export STUB_ZFS_STDERR=$busy
run scripts/smortress-restic-backup.sh ssd --unit photos --no-maintenance
eq "$rc" 0 "a staging snapshot that will not destroy does not fail a good backup"
if [[ $out == *"$busy"* ]]; then
  ok "a failed end-of-run cleanup names the zfs error"
else
  bad "a failed end-of-run cleanup names the zfs error" "$out"
fi
unset STUB_ZFS_DESTROY_FAIL_LATE STUB_ZFS_STDERR

# --- 3. readiness and mount gates ---------------------------------------
reset_state
export STUB_BACKUP_EXIT=0 STUB_BACKUP_ID="should-not-happen" STUB_READY_EXIT=1
run scripts/smortress-restic-backup.sh ssd --unit photos --no-maintenance
if ((rc != 0)); then ok "a failed readiness unit fails the job"; else bad "a failed readiness unit fails the job"; fi
eq "$(state_json ssd-photos '.last_attempt.reason')" readiness "readiness failure is recorded"
if grep -q 'zfs snapshot\|^backup ' "$log/zfs" "$log/restic"; then
  bad "no snapshot or backup happens before readiness"
else
  ok "no snapshot or backup happens before readiness"
fi

reset_state
sed -i "\|$repos/ssd|d" "$work/mountinfo"
export STUB_BACKUP_EXIT=0 STUB_BACKUP_ID="should-not-happen"
run scripts/smortress-restic-backup.sh ssd --unit photos --no-maintenance
if ((rc != 0)); then ok "an unmounted repository path fails the job"; else bad "an unmounted repository path fails the job"; fi
eq "$(state_json ssd-photos '.last_attempt.reason')" repo-not-mounted "unmounted repository is recorded"
if grep -q '^tag ' "$log/restic"; then bad "nothing is written to an unmounted repository"; else ok "nothing is written to an unmounted repository"; fi
printf '36 25 8:1 / %s rw,relatime - ext4 /dev/sdb1 rw\n' "$repos/ssd" >>"$work/mountinfo"

# --- 4. retention filter and deletion shape -----------------------------
joined=$(sed -e :a -e '/\\$/N; s/\\\n/ /; ta' scripts/smortress-restic-backup.sh)
retention_bad=""
while IFS= read -r line; do
  [[ $line == *--keep-* ]] || continue
  [[ $line == *'--tag "unit:'* && $line == *',verified'* ]] || retention_bad=$line
done <<<"$joined"
# Two --tag flags are OR in restic; only one comma-separated flag is AND, and a
# wrong form makes one unit's forget touch another unit's verified snapshots.
if grep -nE -- '--tag "unit:\$[a-z]+" --tag verified' scripts/smortress-restic-*.sh; then
  bad "unit and verified are matched with one AND tag"
else
  ok "unit and verified are matched with one AND tag"
fi

if [[ -z $retention_bad ]]; then
  ok "every retention command requires both unit and verified tags"
else
  bad "every retention command requires both unit and verified tags" "$retention_bad"
fi
if grep -qE -- '--keep-last|--keep-within|--keep-tag|unlock' scripts/smortress-restic-*.sh; then
  bad "retention uses no wildcard bucket and no routine unlock"
else
  ok "retention uses no wildcard bucket and no routine unlock"
fi
if grep -qE -- 'forget .*\*|rm -rf[^#]*(/var/lib/restic|/var/lib/homelab/restic)' scripts/smortress-restic-*.sh; then
  bad "no bulk deletion of snapshot sets or repository roots"
else
  ok "no bulk deletion of snapshot sets or repository roots"
fi

# --- 5. freshness verifier ----------------------------------------------
seed_state() {
  local backend=$1 unit=$2
  install -d -m 0700 "$state/state" "$state/journal"
  jq -n --arg b "$backend" --arg u "$unit" --argjson p "$(unit_paths_json "$unit" "$backend")" \
    --arg start "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg end "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg result "${3:-success}" --argjson exit "${4:-0}" --arg snap "${5:-strepo}" '
    {schema: 2, backend: $b, unit: $u, host: "smortress",
     repository: "stub", paths: $p,
     last_attempt: {n: 1, start: $start, end: $end, exit: $exit,
                    result: $result, reason: "", snapshot: $snap},
     last_success: {end: $end, snapshot: $snap},
     final: {end: $end, snapshot: $snap},
     pending_reap: []}' >"$state/state/$backend-$unit.json"
  jq -cn --arg result "${3:-success}" --arg snap "${5:-strepo}" \
    '{schema:2, attempt:1, result:$result, snapshot:$snap}' \
    >"$state/journal/$backend-$unit.jsonl"
}

seed_all_healthy() {
  for b in ssd hdd r2; do
    for g in "${units[@]}"; do seed_state "$b" "$g"; done
  done
}

reset_state
seed_all_healthy
export RESTIC_HEALTHCHECK_URL=https://hc.invalid/ping/abc
run scripts/smortress-restic-verify.sh
eq "$rc" 0 "a healthy plane verifies"
eq "$(wc -l <"$log/curl-urls" | tr -d ' ')" 1 "exactly one Healthchecks ping on success"
eq "$(cat "$log/curl-urls")" "$RESTIC_HEALTHCHECK_URL" "the ping goes to the configured check"

reset_state
seed_all_healthy
seed_state ssd photos failure 1 ""
export RESTIC_HEALTHCHECK_URL=https://hc.invalid/ping/abc
run scripts/smortress-restic-verify.sh
if ((rc != 0)); then ok "a newer failed run fails freshness even with a recent success"; else bad "a newer failed run fails freshness even with a recent success"; fi
if grep -qx "$RESTIC_HEALTHCHECK_URL" "$log/curl-urls"; then
  bad "no success ping while a destination is failing"
else
  ok "no success ping while a destination is failing"
fi
if grep -q '/fail$' "$log/curl-urls"; then ok "the failure is reported to the same check"; else bad "the failure is reported to the same check"; fi

reset_state
seed_all_healthy
jq '.last_attempt.n = 2 | .last_attempt.result = "running" | .last_attempt.start = "2000-01-01T00:00:00Z"' \
  "$state/state/hdd-books.json" >"$state/state/hdd-books.json.tmp" &&
  mv "$state/state/hdd-books.json.tmp" "$state/state/hdd-books.json"
run scripts/smortress-restic-verify.sh --no-ping
if ((rc != 0)); then ok "a run that died without completing expires"; else bad "a run that died without completing expires"; fi

# A unit that has never succeeded is uploading its first snapshot, which is
# bounded by the first-upload deadline; judging that run by the routine window
# would call a legitimate first upload dead and expire it.
first_running() { # <backend> <unit> <seconds ago>
  local start
  start=$(date -u -d "@$(($(date -u +%s) - $3))" +%Y-%m-%dT%H:%M:%SZ)
  jq --arg start "$start" '.last_success = null | .final = null
      | .last_attempt = {n: 2, start: $start, end: null, exit: null,
                         result: "running", reason: "", snapshot: null}' \
    "$state/state/$1-$2.json" >"$state/state/$1-$2.json.tmp" &&
    mv "$state/state/$1-$2.json.tmp" "$state/state/$1-$2.json"
  jq -cn '{schema: 2, attempt: 1, result: "failure", snapshot: null}' \
    >"$state/journal/$1-$2.jsonl"
}

reset_state
seed_all_healthy
first_running ssd photos 6000
run scripts/smortress-restic-verify.sh --no-ping
if grep -q 'never completed' <<<"$out"; then
  bad "a first upload inside its own window is not called dead" "$out"
else
  ok "a first upload inside its own window is not called dead"
fi

reset_state
seed_all_healthy
first_running ssd photos 20000
run scripts/smortress-restic-verify.sh --no-ping
if grep -q 'never completed' <<<"$out"; then
  ok "a first upload past its own window still expires"
else
  bad "a first upload past its own window still expires" "$out"
fi

reset_state
seed_all_healthy
rm -f "$state/state/r2-files.json"
run scripts/smortress-restic-verify.sh --no-ping
if ((rc != 0)); then ok "missing status state fails closed"; else bad "missing status state fails closed"; fi

reset_state
seed_all_healthy
STUB_SNAPSHOTS_JSON='[]'
export STUB_SNAPSHOTS_JSON
run scripts/smortress-restic-verify.sh --no-ping
if ((rc != 0)); then ok "a recorded snapshot missing from the repository fails"; else bad "a recorded snapshot missing from the repository fails"; fi

reset_state
seed_all_healthy
STUB_SNAPSHOTS_JSON=$(jq -cn '[{id: "strepo", time: "2026-01-01T00:00:00Z", hostname: "smortress", paths: ["x"], tags: ["group:photos", "host:smortress"]}]')
export STUB_SNAPSHOTS_JSON
run scripts/smortress-restic-verify.sh --no-ping
if ((rc != 0)); then ok "an unverified tag or wrong source path fails"; else bad "an unverified tag or wrong source path fails"; fi

reset_state
seed_all_healthy
unset RESTIC_HEALTHCHECK_URL
run scripts/smortress-restic-verify.sh
if ((rc != 0)); then ok "a missing Healthchecks URL refuses to claim freshness"; else bad "a missing Healthchecks URL refuses to claim freshness"; fi
if [[ -s $log/curl-urls ]]; then bad "no ping without a configured URL"; else ok "no ping without a configured URL"; fi
unset STUB_SNAPSHOTS_JSON

# --- 5b. the deploy gate's local query -----------------------------------
# `--local --json` is read-only and answers per restore unit, per local
# repository, because the caller owns the fallback: an unusable repository is a
# payload fact, freshness is a payload fact, and only a query that cannot run at
# all is an exit code. It never pings, so it works before the check exists.
reset_state
seed_all_healthy
export RESTIC_HEALTHCHECK_URL=https://hc.invalid/ping/abc
run scripts/smortress-restic-verify.sh --local --json
# A verdict that is not JSON makes every assertion below fail with the same
# message, so print what was actually returned once instead of hiding it.
if ! jq -e . >/dev/null 2>&1 <<<"$out"; then
  printf 'local verdict was not JSON: %s\n' "$out" >&2
fi
eq "$rc" 0 "a healthy plane answers the local query"
eq "$(jq -r '.ssd.usable' <<<"$out")" true "the SSD is reported usable"
eq "$(jq -r '.hdd.usable' <<<"$out")" true "the HDD is reported usable"
eq "$(jq -r '.ssd.units.photos.fresh' <<<"$out")" true "a fresh SSD unit is reported fresh"
eq "$(jq -r '.hdd.units["repo-archive"].fresh' <<<"$out")" true "a fresh HDD unit is reported fresh"
eq "$(jq -r '.ssd.units | length' <<<"$out")" "${#units[@]}" "every restore unit is reported"
eq "$(jq -r 'has("r2")' <<<"$out")" false "the local query covers only the two local repositories"
if [[ -s $log/curl-urls ]]; then
  bad "the local query never pings Healthchecks" "$(cat "$log/curl-urls")"
else
  ok "the local query never pings Healthchecks"
fi
unset RESTIC_HEALTHCHECK_URL
run scripts/smortress-restic-verify.sh --local --json
eq "$rc" 0 "the local query needs no Healthchecks URL"

# A verdict is freshness, not an exit code: the gate decides what a stale unit
# means (back it up, or hold the deploy).
reset_state
seed_all_healthy
stale_time=$(date -u -d "@$(($(date -u +%s) - 9000))" +%Y-%m-%dT%H:%M:%SZ)
STUB_SNAPSHOTS_JSON=$(jq -cn --arg t "$stale_time" --argjson p "$(unit_paths_json photos ssd)" \
  '[{id: "old1", time: $t, hostname: "smortress", paths: $p,
     tags: ["unit:photos", "host:smortress", "verified"]}]')
export STUB_SNAPSHOTS_JSON
run scripts/smortress-restic-verify.sh --local --json
eq "$rc" 0 "a stale snapshot is a verdict, not a failure of the query"
eq "$(jq -r '.ssd.units.photos.fresh' <<<"$out")" false "a snapshot past the max age is not fresh"
eq "$(jq -r '.ssd.units.photos.reason' <<<"$out")" stale "a stale snapshot says why"

STUB_SNAPSHOTS_JSON=$(jq -cn --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson p "$(unit_paths_json photos ssd)" \
  '[{id: "nv1", time: $t, hostname: "smortress", paths: $p,
     tags: ["unit:photos", "host:smortress"]}]')
export STUB_SNAPSHOTS_JSON
run scripts/smortress-restic-verify.sh --local --json
eq "$(jq -r '.ssd.units.photos.reason' <<<"$out")" unverified "an untagged snapshot is not fresh"
unset STUB_SNAPSHOTS_JSON

# The 970 is the preferred repository and the HDD is the fallback when it is
# absent, so "no SSD" must be a usable=false payload and not a broken query.
reset_state
seed_all_healthy
sed -i "\|$repos/ssd|d" "$work/mountinfo"
run scripts/smortress-restic-verify.sh --local --json
eq "$rc" 0 "an absent SSD does not break the local query"
eq "$(jq -r '.ssd.usable' <<<"$out")" false "an absent SSD is reported unusable"
eq "$(jq -r '.hdd.usable' <<<"$out")" true "the HDD stays usable"
eq "$(jq -r '.ssd.units.photos.fresh' <<<"$out")" false "no unit is fresh on an unusable repository"
printf '36 25 8:1 / %s rw,relatime - ext4 /dev/sdb1 rw\n' "$repos/ssd" >>"$work/mountinfo"

# A caller-named cache that cannot be created is a destination verdict, not a
# crash and not a warning on the stream a JSON consumer parses. This is what a
# GitHub runner exposed: /var/cache is unwritable there, and a stderr line merged
# into the output turned every assertion into a jq parse error.
reset_state
seed_all_healthy
out=$(env RESTIC_CACHE_DIR=/proc/smortress-restic-cache \
  scripts/smortress-restic-verify.sh --local --json 2>"$log/cache-stderr")
rc=$?
eq "$rc" 0 "an uncreatable cache is a verdict, not a crash"
if jq -e . >/dev/null 2>&1 <<<"$out"; then
  ok "the verdict stays JSON without a cache"
else
  bad "the verdict stays JSON without a cache" "$out"
fi
eq "$(jq -r '.ssd.usable' <<<"$out")" false "an uncreatable cache makes the repository unusable"
if grep -q 'cannot create the restic cache' "$log/cache-stderr"; then
  ok "the uncreatable cache is named on stderr"
else
  bad "the uncreatable cache is named on stderr" "$(cat "$log/cache-stderr")"
fi

# Nothing to join against is the one thing the query cannot answer.
reset_state
rm -rf "${state:?}"
run scripts/smortress-restic-verify.sh --local --json
if ((rc != 0)); then ok "missing plane state fails the local query"; else bad "missing plane state fails the local query"; fi

reset_state
seed_all_healthy
run scripts/smortress-restic-verify.sh --json
eq "$rc" 2 "the aggregate mode takes no --json"
run scripts/smortress-restic-verify.sh --local
eq "$rc" 2 "the local mode requires --json"

# --- 5b. a unit that gained a dataset reconciles its recorded paths --------
#
# The verifier reads .paths from the state the backup driver wrote, because that
# is the set actually archived. When a dataset joins a unit after it has run,
# the stored set is stale until the next successful run. Without the rewrite the
# verifier keeps comparing new snapshots against the old paths and the unit can
# never be fresh again, which holds every deploy.
reset_state
seed_state ssd music
jq --arg p "$(mountpoint_for raw/music)/.zfs/snapshot/ssd" '.paths = [$p]' \
  "$state/state/ssd-music.json" >"$state/state/ssd-music.json.tmp"
mv "$state/state/ssd-music.json.tmp" "$state/state/ssd-music.json"
export STUB_BACKUP_ID=reconcile1 STUB_BACKUP_TREE=treeR
run scripts/smortress-restic-backup.sh ssd --unit music --no-maintenance
eq "$rc" 0 "a unit whose dataset set changed still backs up"
eq "$(jq -c '.paths | sort' "$state/state/ssd-music.json")" \
  "$(unit_paths_json music ssd | jq -c 'sort')" \
  "a successful run records the path set it archived"
unset STUB_BACKUP_ID STUB_BACKUP_TREE

# --- 5c. a stale recorded path set is not called fresh ---------------------
#
# The local query prefers the state's recorded set while it still matches the
# table. After a dataset joins a unit and before its first new-family backup,
# the recorded set is stale; using it would report a pre-change snapshot as
# fresh while the new dataset has never been backed up.
reset_state
seed_state ssd music
jq --arg p "$(mountpoint_for raw/music)/.zfs/snapshot/ssd" '.paths = [$p]' \
  "$state/state/ssd-music.json" >"$state/state/ssd-music.json.tmp"
mv "$state/state/ssd-music.json.tmp" "$state/state/ssd-music.json"
STUB_SNAPSHOTS_JSON=$(jq -cn --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg p "$(mountpoint_for raw/music)/.zfs/snapshot/ssd" \
  '[{id: "oldfam", time: $t, hostname: "smortress", paths: [$p],
     tags: ["unit:music", "host:smortress", "verified"]}]')
export STUB_SNAPSHOTS_JSON
run scripts/smortress-restic-verify.sh --local --json
eq "$(jq -r '.ssd.units.music.fresh' <<<"$out")" false \
  "a snapshot from the old path family is not fresh"
unset STUB_SNAPSHOTS_JSON

# --- 6. repository init --------------------------------------------------
reset_state
install -d -m 0755 "$repos/ssd/restic"
export STUB_CAT_EXIT=0
run scripts/smortress-restic-init.sh ssd
eq "$rc" 0 "an existing repository is accepted"
if grep -q '^init' "$log/restic"; then bad "an existing repository is never re-initialised"; else ok "an existing repository is never re-initialised"; fi

reset_state
rm -rf "${repos:?}/ssd/restic"
export STUB_CAT_EXIT=10
run scripts/smortress-restic-init.sh ssd
eq "$rc" 0 "a missing repository is initialised"
if grep -q -- '-r .*/repos/ssd/restic init' "$log/restic"; then
  ok "init runs against the mounted repository path"
else
  bad "init runs against the mounted repository path" "$(cat "$log/restic")"
fi

reset_state
rm -rf "${repos:?}/ssd/restic"
sed -i "\|$repos/ssd|d" "$work/mountinfo"
export STUB_CAT_EXIT=10
run scripts/smortress-restic-init.sh ssd
if ((rc != 0)); then ok "init refuses an unmounted mountpoint"; else bad "init refuses an unmounted mountpoint"; fi
if grep -q '^init' "$log/restic"; then bad "nothing is initialised on the root filesystem"; else ok "nothing is initialised on the root filesystem"; fi
printf '36 25 8:1 / %s rw,relatime - ext4 /dev/sdb1 rw\n' "$repos/ssd" >>"$work/mountinfo"

reset_state
install -d -m 0755 "$repos/ssd/restic"
printf 'not a repo\n' >"$repos/ssd/restic/stray"
export STUB_CAT_EXIT=10
run scripts/smortress-restic-init.sh ssd
if ((rc != 0)); then ok "init refuses a non-empty non-repository directory"; else bad "init refuses a non-empty non-repository directory"; fi
rm -f "$repos/ssd/restic/stray"

# --- 7. sops-decrypt format column --------------------------------------
dec=$work/sops
install -d -m 0700 "$dec/src" "$dec/dst"
printf "AGE-SECRET-KEY-STUB\n" >"$dec/age"
printf 'canary: sops-decrypt-ok\n' >"$dec/src/canary.yaml"
printf 'password: hunter2\n' >"$dec/src/restic-password.yaml"
me=$(id -un)
mg=$(id -gn)
cat >"$dec/manifest" <<EOF
canary.yaml           $me $mg 0600
restic-password.yaml  $me $mg 0600 value
EOF
cat >"$bin/sops" <<'EOF'
#!/usr/bin/env bash
if [[ -n ${STUB_SOPS_PLAINTEXT:-} ]]; then
  printf '%s\n' "$STUB_SOPS_PLAINTEXT"
  exit 0
fi
file=""
for a in "$@"; do file=$a; done
if [[ $file == *restic-password.yaml ]]; then
  printf 'password: hunter2\n'
else
  printf 'canary: sops-decrypt-ok\n'
fi
EOF
chmod 0755 "$bin/sops"
export SOPS_BIN=$bin/sops
export SMORTRESS_SECRETS_SRC=$dec/src SMORTRESS_SECRETS_DST=$dec/dst
export SMORTRESS_SECRETS_MANIFEST=$dec/manifest SMORTRESS_AGE_KEY=$dec/age

run scripts/sops-decrypt.sh
eq "$rc" 0 "sops-decrypt writes a value secret"
eq "$(cat "$dec/dst/restic-password.yaml")" "hunter2" "format=value writes only the password"
eq "$(cat "$dec/dst/canary.yaml")" "canary: sops-decrypt-ok" "format=yaml stays verbatim"

mv "$dec/age" "$dec/age.missing"
run scripts/sops-decrypt.sh
if ((rc != 0)); then ok "a missing age identity fails closed"; else bad "a missing age identity fails closed"; fi
mv "$dec/age.missing" "$dec/age"

export STUB_SOPS_PLAINTEXT=$'first: one\nsecond: two\n'
export STUB_SOPS_PLAINTEXT
run scripts/sops-decrypt.sh
if ((rc != 0)); then ok "a multi-key secret cannot be written as value"; else bad "a multi-key secret cannot be written as value"; fi
unset STUB_SOPS_PLAINTEXT

printf 'extra.yaml\n' >"$dec/src/extra.yaml"
run scripts/sops-decrypt.sh
if ((rc != 0)); then ok "an unlisted ciphertext still fails closed"; else bad "an unlisted ciphertext still fails closed"; fi
rm -f "$dec/src/extra.yaml"

# --- 7b. the ciphertext seed that makes /var authoritative ----------------
# The decrypt reads /var now, and the image's baked set is only the seed for a
# host that has none. Nothing may overwrite a host copy: that is where a rotation
# lands, and reinstating the baked value would silently undo it.
#
# Both manifest paths are pointed into the work dir: the seed rewrites the host
# manifest, and a harness run must never touch the machine's /etc.
export SMORTRESS_SECRETS_IMAGE_MANIFEST=$work/seed/image.manifest
export SMORTRESS_SECRETS_MANIFEST=$work/seed/host.manifest
seed=$work/seed
install -d -m 0700 "$seed/baked"
printf 'canary: baked\n' >"$seed/baked/canary.yaml"
printf 'password: baked\n' >"$seed/baked/restic-password.yaml"
run env SMORTRESS_SECRETS_BAKED="$seed/baked" SMORTRESS_SECRETS_SRC="$seed/host" \
  scripts/smortress-secrets-seed.sh
eq "$rc" 0 "the seed copies the baked ciphertext"
eq "$(cat "$seed/host/canary.yaml" 2>/dev/null)" "canary: baked" "the ciphertext lands"
eq "$(stat -c %a "$seed/host/canary.yaml" 2>/dev/null)" 600 "the ciphertext is root-only"
eq "$(stat -c %a "$seed/host" 2>/dev/null)" 700 "the host directory is root-only"

printf 'canary: rotated\n' >"$seed/host/canary.yaml"
run env SMORTRESS_SECRETS_BAKED="$seed/baked" SMORTRESS_SECRETS_SRC="$seed/host" \
  scripts/smortress-secrets-seed.sh
eq "$(cat "$seed/host/canary.yaml")" "canary: rotated" "a host copy is never overwritten"

# A secret the image added after the host's copy existed: the manifest names it,
# so leaving it out fails the decrypt's set check for every consumer.
rm -f "$seed/host/restic-password.yaml"
run env SMORTRESS_SECRETS_BAKED="$seed/baked" SMORTRESS_SECRETS_SRC="$seed/host" \
  scripts/smortress-secrets-seed.sh
eq "$rc" 0 "a missing ciphertext is seeded"
eq "$(cat "$seed/host/restic-password.yaml" 2>/dev/null)" "password: baked" \
  "the newly added secret lands"
eq "$(cat "$seed/host/canary.yaml")" "canary: rotated" \
  "the existing rotation is still untouched"

rm -f "$seed/baked"/*.yaml
rm -f "$seed/host"/*.yaml
run env SMORTRESS_SECRETS_BAKED="$seed/baked" SMORTRESS_SECRETS_SRC="$seed/host" \
  scripts/smortress-secrets-seed.sh
eq "$rc" 0 "nothing baked is not an error"
if [[ -e $seed/host/canary.yaml ]]; then bad "nothing baked copies nothing"; else
  ok "nothing baked copies nothing"
fi

# --- 7c. the manifest the image owns --------------------------------------
# The manifest is metadata (name, owner, group, mode, format), never a secret, so
# the image is authoritative for it. bootc merges /etc once per deployment and
# keeps whatever the host already had, so on 2026-11-22 the image added two lines
# and an existing host never saw them: the seed copied both ciphertexts, /etc
# still listed the old set, and every consumer died on "ciphertext set and
# manifest disagree" until an operator appended the lines by hand. The seed now
# replaces the host copy from the image on every run, so the case below is a boot
# and nothing else.
refresh=$work/refresh
install -d -m 0700 "$refresh/host"
install -d -m 0755 "$refresh/image" "$refresh/image/secrets"
printf 'canary: baked\n' >"$refresh/image/secrets/canary.yaml"
printf 'token: baked\n' >"$refresh/image/secrets/new-token.yaml"
cat >"$refresh/image/secrets.manifest" <<EOF
canary.yaml      $me $mg 0600
new-token.yaml   $me $mg 0600 value
EOF
# A host that predates the new image: the manifest it booted with, and one of the
# two ciphertexts already rotated in place under it.
printf 'canary.yaml  %s %s 0600\n' "$me" "$mg" >"$refresh/host/secrets.manifest"
printf 'canary: rotated\n' >"$refresh/host/canary.yaml"
run env SMORTRESS_SECRETS_BAKED="$refresh/image/secrets" \
  SMORTRESS_SECRETS_SRC="$refresh/host" \
  SMORTRESS_SECRETS_IMAGE_MANIFEST="$refresh/image/secrets.manifest" \
  SMORTRESS_SECRETS_MANIFEST="$refresh/host/secrets.manifest" \
  scripts/smortress-secrets-seed.sh
eq "$rc" 0 "the seed applies the image manifest over the host's stale copy"
if cmp -s "$refresh/image/secrets.manifest" "$refresh/host/secrets.manifest"; then
  ok "the host manifest becomes the image's, not the one bootc preserved"
else
  bad "the host manifest becomes the image's, not the one bootc preserved" \
    "$(cat "$refresh/host/secrets.manifest")"
fi
eq "$(stat -c %a "$refresh/host/secrets.manifest" 2>/dev/null)" 644 \
  "the replaced manifest stays readable metadata, not a secret"
# The mixed rotation the incident hit: one entry the host already rotated and one
# the image added. The manifest refresh must not touch the first, must seed the
# second, and the set has to match afterwards or every consumer fails.
eq "$(cat "$refresh/host/canary.yaml")" "canary: rotated" \
  "a rotated ciphertext survives the manifest refresh"
eq "$(cat "$refresh/host/new-token.yaml" 2>/dev/null)" "token: baked" \
  "the ciphertext the new manifest line names is seeded"

run env SMORTRESS_SECRETS_SRC="$refresh/host" SMORTRESS_SECRETS_DST="$refresh/run" \
  SMORTRESS_SECRETS_MANIFEST="$refresh/host/secrets.manifest" \
  SMORTRESS_AGE_KEY="$dec/age" scripts/sops-decrypt.sh
if ((rc != 0)); then
  bad "the decrypt succeeds on a host that only ran the seed" "$out"
else
  ok "the decrypt succeeds on a host that only ran the seed"
fi
eq "$(cat "$refresh/run/new-token.yaml" 2>/dev/null)" "sops-decrypt-ok" \
  "the newly seeded secret decrypts as the manifest's value"
if [[ -s $refresh/run/canary.yaml ]]; then
  ok "the rotated ciphertext decrypts too"
else
  bad "the rotated ciphertext decrypts too"
fi

# A second boot of the same image is a no-op, not a rewrite: the inode survives.
manifest_inode=$(stat -c %i "$refresh/host/secrets.manifest")
run env SMORTRESS_SECRETS_BAKED="$refresh/image/secrets" \
  SMORTRESS_SECRETS_SRC="$refresh/host" \
  SMORTRESS_SECRETS_IMAGE_MANIFEST="$refresh/image/secrets.manifest" \
  SMORTRESS_SECRETS_MANIFEST="$refresh/host/secrets.manifest" \
  scripts/smortress-secrets-seed.sh
eq "$rc" 0 "a second seed run is not an error"
eq "$(stat -c %i "$refresh/host/secrets.manifest")" "$manifest_inode" \
  "an unchanged manifest is not rewritten"

# An image that carries no manifest -- the release that drops the baked set, or a
# rollback to one that only ever had /etc -- must leave the host copy alone: the
# seed is not allowed to delete the only manifest a booting host has.
mv "$refresh/image/secrets.manifest" "$refresh/image/secrets.manifest.off"
printf 'canary.yaml  %s %s 0600\n' "$me" "$mg" >"$refresh/host/secrets.manifest"
run env SMORTRESS_SECRETS_BAKED="$refresh/image/secrets" \
  SMORTRESS_SECRETS_SRC="$refresh/host" \
  SMORTRESS_SECRETS_IMAGE_MANIFEST="$refresh/image/secrets.manifest" \
  SMORTRESS_SECRETS_MANIFEST="$refresh/host/secrets.manifest" \
  scripts/smortress-secrets-seed.sh
eq "$rc" 0 "an image without a manifest is not an error"
eq "$(cat "$refresh/host/secrets.manifest")" "canary.yaml  $me $mg 0600" \
  "an image without a manifest leaves the host copy alone"
mv "$refresh/image/secrets.manifest.off" "$refresh/image/secrets.manifest"

# --- 8. units cannot start before the dataset is ready ------------------
svc=units/systemd/smortress-restic-backup@.service
for key in "${dataset_order[@]}"; do
  instance=$(readiness_instance "$key")
  if grep -q "zfs-ready@$instance.service" "$svc"; then
    ok "the backup driver is ordered after zfs-ready@$instance"
  else
    bad "the backup driver is ordered after zfs-ready@$instance"
  fi
done
for unit in var-lib-restic-ssd.mount var-lib-restic-hdd.mount \
  smortress-restic-init.service smortress-restic-backup-ssd.timer \
  smortress-restic-backup-hdd.timer smortress-restic-backup-r2.timer \
  smortress-restic-verify.timer; do
  if grep -q "$unit" image/Containerfile; then
    ok "the image enables $unit"
  else
    bad "the image enables $unit"
  fi
done
if grep -q -- '--keep-daily 14 --keep-weekly 8 --keep-monthly 12' scripts/smortress-restic-backup.sh; then
  ok "retention keeps 14 daily, 8 weekly, 12 monthly"
else
  bad "retention keeps 14 daily, 8 weekly, 12 monthly"
fi

# --- 9. first-upload sizing ---------------------------------------------
# A unit's first upload has nothing deduplicated yet, so it is read, chunked and
# written in full: it gets its own deadline and a single attempt. A unit with a
# success already recorded against the repository it writes keeps the routine
# bound and its retries. The state file itself says which of the two it is.
reset_state
export STUB_BACKUP_EXIT=1 STUB_BACKUP_ID=""
run RESTIC_ATTEMPTS=2 RESTIC_ATTEMPTS_FIRST=1 \
  scripts/smortress-restic-backup.sh ssd --unit photos --no-maintenance
eq "$(grep -c ' backup --host' "$log/restic")" 1 \
  "a unit with no recorded success gets one first attempt"
eq "$(state_json ssd-photos '.last_attempt.result')" failure \
  "the single first attempt still records its failure"

reset_state
export STUB_BACKUP_EXIT=0 STUB_BACKUP_ID="first1" STUB_VERIFIED_ID="first1v"
run scripts/smortress-restic-backup.sh ssd --unit photos --no-maintenance
eq "$(state_json ssd-photos '.last_attempt.result')" success "the first upload can succeed"
: >"$log/restic"
export STUB_BACKUP_EXIT=1 STUB_BACKUP_ID=""
run RESTIC_ATTEMPTS=2 RESTIC_ATTEMPTS_FIRST=1 \
  scripts/smortress-restic-backup.sh ssd --unit photos --no-maintenance
eq "$(grep -c ' backup --host' "$log/restic")" 2 \
  "a unit with a recorded success keeps the routine retries"

# Same state, different repository: the recorded success proves nothing about
# the repository this run writes, so it is a first upload again.
: >"$log/restic"
jq '.repository = "s3:https://elsewhere.invalid/other"' \
  "$state/state/ssd-photos.json" >"$state/state/ssd-photos.json.tmp" &&
  mv "$state/state/ssd-photos.json.tmp" "$state/state/ssd-photos.json"
run RESTIC_ATTEMPTS=2 RESTIC_ATTEMPTS_FIRST=1 \
  scripts/smortress-restic-backup.sh ssd --unit photos --no-maintenance
eq "$(grep -c ' backup --host' "$log/restic")" 1 \
  "a success against another repository does not count as a success"

# The deadline varies per unit, which is what the run is actually given: the
# slow first upload outlives the routine deadline, the same slowness afterwards
# does not.
reset_state
export STUB_BACKUP_EXIT=0 STUB_BACKUP_ID="slow1" STUB_VERIFIED_ID="slow1v" STUB_BACKUP_SLEEP=3
run RESTIC_DEADLINE_LOCAL=2 RESTIC_DEADLINE_FIRST_LOCAL=15 \
  scripts/smortress-restic-backup.sh ssd --unit photos --no-maintenance
eq "$rc" 0 "a slow first upload is not killed by the routine deadline"
eq "$(state_json ssd-photos '.last_attempt.result')" success \
  "a slow first upload is not recorded as timeout"
: >"$log/restic"
run RESTIC_DEADLINE_LOCAL=2 scripts/smortress-restic-backup.sh ssd --unit photos --no-maintenance
eq "$(state_json ssd-photos '.last_attempt.reason')" timeout \
  "a slow routine run keeps the tighter deadline"

# The agent's local state outgrew the hourly window, so that unit alone gets the
# long local bound: a slow increment of it succeeds while every other unit still
# keeps the tight one.
reset_state
export STUB_BACKUP_EXIT=0 STUB_BACKUP_ID="slowagent" STUB_VERIFIED_ID="slowagentv"
run scripts/smortress-restic-backup.sh ssd --unit agent-local --no-maintenance
run scripts/smortress-restic-backup.sh ssd --unit photos --no-maintenance
: >"$log/restic"
export STUB_BACKUP_SLEEP=3
run RESTIC_DEADLINE_LOCAL=2 RESTIC_DEADLINE_LOCAL_LONG=15 \
  scripts/smortress-restic-backup.sh ssd --unit agent-local --no-maintenance
eq "$(state_json ssd-agent-local '.last_attempt.result')" success \
  "agent-local's routine run gets the long local deadline"
run RESTIC_DEADLINE_LOCAL=2 RESTIC_DEADLINE_LOCAL_LONG=15 \
  scripts/smortress-restic-backup.sh ssd --unit photos --no-maintenance
eq "$(state_json ssd-photos '.last_attempt.reason')" timeout \
  "the other units keep the hourly deadline"
unset STUB_BACKUP_SLEEP

# The freshness and expiry budgets are derived from the deadline the unit
# actually gets, so the long attempt is not called stale while it is still legal.
budgets=$(RESTIC_ATTEMPTS=2 RESTIC_RETRY_SLEEP_LOCAL=60 \
  RESTIC_DEADLINE_LOCAL=1800 RESTIC_DEADLINE_LOCAL_LONG=14400 bash -c '
  source scripts/restic-plane-common.sh
  printf "%s %s %s\n" "$(max_age_for ssd agent-local)" \
    "$(run_expiry_for ssd agent-local)" "$(max_age_for ssd photos)"')
eq "$budgets" "33600 29520 8400" "agent-local's budgets follow its deadline"

printf '\n%d checks, %d failed\n' "$pass" "$fail"
((fail == 0))
