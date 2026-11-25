#!/usr/bin/env bats
# Offline checks for the Restic plane (SDLC #706, T3): the backup driver's exit
# codes, stale-staging reconciliation, the readiness and mount gates, the
# retention filter, first-upload sizing, and progress publication.
#
# The host half — real disks, real repositories, real Healthchecks — is in
# docs/manual-steps.md section 38. This proves the half that does not need root
# or a network. restic, zfs, curl and sops are stubs; the command lines and the
# durable state are real. tests/core/restic-plane.sh still holds the freshness
# verifier, init and sops sections until they convert (#934, #924).
load ../helpers

driver=scripts/smortress-restic-backup.sh

# bats sources this file, and runs setup_file, inside a function, so the storage
# table's `declare -A` arrays are local to it and gone by the test body. The
# table is read once here and handed on as two plain strings, which also stops
# the stubs sourcing 550 lines on every call to derive paths this file already
# knows. Everything here is read-only for the rest of the run.
setup_file() {
    fx=$BATS_FILE_TMPDIR/fixture
    mkdir -p "$fx/bin" "$fx/repos/ssd" "$fx/repos/hdd" "$fx/secrets"

    printf 'hunter2\n' >"$fx/secrets/restic-password.yaml"
    chmod 0600 "$fx/secrets/restic-password.yaml"
    cat >"$fx/secrets/r2-credentials.yaml" <<'EOF'
r2_access_key_id: stub-id
r2_secret_access_key: stub-secret
EOF
    chmod 0600 "$fx/secrets/r2-credentials.yaml"

    cat >"$fx/bin/restic" <<'STUB'
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
# The storage table as the harness read it once: RP_UNIT_KEYS maps a unit to its
# dataset keys, RP_MOUNTS a key to its mountpoint, and STORAGE_MOUNT_ROOT is the
# scratch tree both are relative to. Sourcing storage-layout and
# restic-plane-common to derive the same list cost ~10ms per call.
unit_keys_of() {
  local e
  for e in $RP_UNIT_KEYS; do
    [[ ${e%%=*} == "$1" ]] && { printf '%s' "${e#*=}"; return 0; }
  done
  return 1
}
mount_of() {
  local e
  for e in $RP_MOUNTS; do
    [[ ${e%%=*} == "$1" ]] && { printf '%s' "${e#*=}"; return 0; }
  done
  return 1
}
case $cmd in
  backup)
    # A slow upload is the only way to prove which deadline a run was given.
    # With STUB_BACKUP_STATUS the slowness is spent emitting restic's own
    # records once a second, so the harness can sample the published stream
    # while the process is still running instead of after it exits.
    if [[ -n ${STUB_BACKUP_STATUS:-} ]]; then
      for ((i = ${STUB_BACKUP_SLEEP:-1}; i > 0; i--)); do
        printf '{"message_type":"status","percent_done":0.25,"total_bytes":4000,"bytes_done":1000,"total_files":10,"files_done":2,"seconds_remaining":120,"current_files":["/var/lib/agent/local/secret.txt"]}\n'
        printf '{"message_type":"error","error":{"message":"open /var/lib/agent/local/secret.txt: permission denied"},"item":"/var/lib/agent/local/secret.txt"}\n'
        sleep 1
      done
    else
      [[ -n ${STUB_BACKUP_SLEEP:-} ]] && sleep "$STUB_BACKUP_SLEEP"
    fi
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
    paths=()
    keys=$(unit_keys_of "$unit") || { printf 'restic stub: unknown unit %s\n' "$unit" >&2; exit 1; }
    for key in ${keys//,/ }; do
      mp=$(mount_of "$key") || { printf 'restic stub: unknown dataset %s\n' "$key" >&2; exit 1; }
      paths+=("$STORAGE_MOUNT_ROOT$mp/.zfs/snapshot/$backend")
    done
    # restic stores a multi-path snapshot with its paths sorted
    printf '[{"id":"%s","tree":"%s","time":"%s","hostname":"smortress","paths":%s,"tags":["unit:%s","host:smortress","verified"]}]\n' \
      "${STUB_VERIFIED_ID:-${STUB_BACKUP_ID:-strepo}}" \
      "${STUB_VERIFIED_TREE:-${STUB_BACKUP_TREE:-tree1}}" \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      "$(jq -cn --args '$ARGS.positional | sort' -- "${paths[@]}")" "$unit"
    exit 0
    ;;
  forget | prune | check) exit "${STUB_MAINT_EXIT:-0}" ;;
  init) exit "${STUB_INIT_EXIT:-0}" ;;
  restore) exit 0 ;;
esac
exit 0
STUB

    cat >"$fx/bin/zfs" <<'STUB'
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
    # The mountpoint comes from the table the harness read once, rooted at the
    # per-test scratch tree.
    mp=""
    for e in $RP_MOUNTS; do
      [[ ${e%%=*} == "$key" ]] && { mp=${e#*=}; break; }
    done
    [[ -n $mp ]] || { printf 'zfs stub: unknown dataset %s\n' "$key" >&2; exit 1; }
    install -d -m 0755 "$STORAGE_MOUNT_ROOT$mp/.zfs/snapshot/$name"
    exit 0
    ;;
esac
exit 0
STUB

    cat >"$fx/bin/zfs-ready" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG/ready"
exit "${STUB_READY_EXIT:-0}"
STUB

    cat >"$fx/bin/curl" <<'STUB'
#!/usr/bin/env bash
url=""
for a in "$@"; do url=$a; done
printf '%s\n' "$url" >>"$STUB_LOG/curl-urls"
exit "${STUB_CURL_EXIT:-0}"
STUB
    chmod 0755 "$fx/bin"/*

    # The harness builds its stub tree from the real storage table: the verifier
    # fails closed on a unit with no state, so a hardcoded list would stop
    # testing whichever unit was added last without failing. The real roots, not
    # a scratch tree, so a test's work dir can be prefixed to them.
    unset STORAGE_MOUNT_ROOT
    # shellcheck source=/dev/null
    source scripts/storage-layout.sh
    mounts=''
    for key in "${dataset_order[@]}"; do mounts+=" $key=${dataset_mount[$key]}"; done
    unit_keys=''
    for unit in "${units[@]}"; do unit_keys+=" $unit=${unit_datasets[$unit]// /,}"; done
    export fx mounts unit_keys
}

# Every scratch tree is per test: each @test runs in its own process and the file
# may run under --jobs, so nothing may be left where a sibling test would race.
# The stubs, the repository roots and the secrets are the read-only fixture; the
# state, the log, the mountpoints and the progress tree are this test's alone.
setup() {
    work=$BATS_TEST_TMPDIR/work
    repos=$fx/repos
    log=$work/log
    mkdir -p "$log" "$work/cache"
    install -d -m 0700 "$work/state"
    for f in restic zfs curl-urls ready snapshots; do : >"$log/$f"; done

    # The driver touches every dataset's snapshot automount, and a stale staging
    # snapshot is one of them.
    local -a automounts=()
    local entry
    for entry in $mounts; do automounts+=("$work${entry#*=}/.zfs/snapshot"); done
    mkdir -p "${automounts[@]}"

    printf '36 25 8:1 / %s/ssd rw,relatime - ext4 /dev/sdb1 rw\n37 25 8:2 / %s/hdd rw,relatime - ext4 /dev/sda1 rw\n' \
        "$repos" "$repos" >"$work/mountinfo"

    export STUB_LOG=$log REPO_ROOT=$PWD
    export PATH="$fx/bin:$PATH"
    export RESTIC_BIN=$fx/bin/restic ZFS_BIN=$fx/bin/zfs ZFS_READY_BIN=$fx/bin/zfs-ready \
        CURL_BIN=$fx/bin/curl
    export RESTIC_BASE=$repos RESTIC_STATE_ROOT=$work/state \
        STORAGE_LAYOUT=$PWD/scripts/storage-layout.sh
    export RESTIC_PROGRESS_ROOT=$work/progress
    # The driver refuses to run without a cache it can create; the unit supplies
    # one via CacheDirectory, so the harness supplies its own instead of relying
    # on /var/cache being writable (it is not on a CI runner).
    export RESTIC_CACHE_DIR=$work/cache
    export SMORTRESS_SECRETS_DIR=$fx/secrets RESTIC_MOUNTINFO=$work/mountinfo
    export STORAGE_MOUNT_ROOT=$work
    export RP_MOUNTS="$mounts" RP_UNIT_KEYS="$unit_keys"
    export RESTIC_ATTEMPTS=1 RESTIC_RETRY_SLEEP_LOCAL=0 RESTIC_RETRY_SLEEP_R2=0
    export RESTIC_LOCK_WAIT=5 RESTIC_DEADLINE_LOCAL=20 RESTIC_DEADLINE_R2=20
    export RESTIC_DEADLINE_MAINTENANCE=20
}

# drive [<var=value>...] <command...>: the shell suite's `run`, except bats owns
# that name. The driver's output lands in `out`, its status in `rc`.
drive() {
    rc=0
    out=$(env "$@" 2>&1) || rc=$?
}

state_json() { jq -r "$2" "$work/state/state/$1.json" 2>/dev/null; }

# mount_for <dataset key>: this test's scratch mountpoint for a dataset.
mount_for() {
    local entry
    for entry in $mounts; do
        [[ ${entry%%=*} == "$1" ]] && { printf '%s\n' "$work${entry#*=}"; return 0; }
    done
    printf 'unknown dataset: %s\n' "$1" >&2
    return 1
}

# assert_logged <pattern> <file>: the run wrote a line matching it.
assert_logged() { grep -q -- "$1" "$2" || fail "$2 has no line matching: $1"; }

# refute_logged <pattern> <file...>: nothing in the run's logs matches it.
refute_logged() {
    local file
    for file in "${@:2}"; do
        if grep -q -- "$1" "$file"; then fail "$file matches: $1"; fi
    done
}

# pause: a 10ms pause that starts no process — `sleep` here would spend the
# suite's time on the clock rather than on the run it is watching.
pause() { read -r -t 0.01 </dev/zero || :; }

# --- 1. exit codes -------------------------------------------------------

# exit 1 is restic's generic failure: no snapshot id to reap, and nothing to tag.
backup_exit_1() {
    export STUB_BACKUP_EXIT=1 STUB_BACKUP_ID=""
    drive "$driver" ssd --unit photos --no-maintenance
}

@test "exit 1 is a failed run" {
    backup_exit_1
    assert_not_equal "$rc" 0
}

@test "failed run is recorded as failure" {
    backup_exit_1
    assert_equal "$(state_json ssd-photos '.last_attempt.result')" failure
}

@test "failure reason records the exit code" {
    backup_exit_1
    assert_equal "$(state_json ssd-photos '.last_attempt.reason')" exit-1
}

@test "no verified tag after exit 1" {
    backup_exit_1
    refute_logged '^tag ' "$log/restic"
}

# exit 3 is restic's incomplete-snapshot code: the snapshot exists in the
# repository, so its id is what a later reap has to remove.
backup_exit_3() {
    export STUB_BACKUP_EXIT=3 STUB_BACKUP_ID="incomplete1"
    drive "$driver" ssd --unit photos --no-maintenance
}

@test "exit 3 is a failed run" {
    backup_exit_3
    assert_not_equal "$rc" 0
}

@test "exit 3 keeps its own reason" {
    backup_exit_3
    assert_equal "$(state_json ssd-photos '.last_attempt.reason')" exit-3
}

@test "an incomplete snapshot ID is recorded for reaping" {
    backup_exit_3
    assert_equal "$(state_json ssd-photos '.pending_reap[0]')" incomplete1
}

@test "an exit-3 snapshot is never tagged verified" {
    backup_exit_3
    refute_logged '^tag ' "$log/restic"
}

backup_exit_0() {
    export STUB_BACKUP_EXIT=0 STUB_BACKUP_ID="complete1"
    drive "$driver" ssd --unit photos --no-maintenance
}

@test "exit 0 succeeds" {
    backup_exit_0
    assert_equal "$rc" 0
}

@test "success is recorded" {
    backup_exit_0
    assert_equal "$(state_json ssd-photos '.last_attempt.result')" success
}

@test "the final snapshot ID is persisted" {
    backup_exit_0
    assert_equal "$(state_json ssd-photos '.final.snapshot')" complete1
}

@test "the successful snapshot is tagged verified" {
    backup_exit_0
    assert_logged 'tag --add verified complete1' "$log/restic"
}

# A second verified snapshot for the same unit and path set is normal. The run
# must pick the one whose tree it just wrote, not whichever is newest by time.
backup_with_two_verified_snapshots() {
    export STUB_BACKUP_EXIT=0 STUB_BACKUP_ID=complete3 STUB_BACKUP_TREE=treeB
    STUB_SNAPSHOTS_JSON=$(cat <<'JSON'
[{"id":"older1","tree":"treeA","time":"2026-01-01T00:00:00Z","hostname":"smortress","paths":[],"tags":["unit:photos","host:smortress","verified"]},
{"id":"newer2","tree":"treeB","time":"2026-01-01T00:05:00Z","hostname":"smortress","paths":[],"tags":["unit:photos","host:smortress","verified"]}]
JSON
    )
    export STUB_SNAPSHOTS_JSON
    drive "$driver" ssd --unit photos --no-maintenance
}

@test "a run succeeds when an older verified snapshot has a different tree" {
    backup_with_two_verified_snapshots
    assert_equal "$rc" 0
}

@test "the tree selects the snapshot this attempt wrote" {
    backup_with_two_verified_snapshots
    assert_equal "$(state_json ssd-photos '.final.snapshot')" newer2
}

@test "the staging snapshot was destroyed" {
    backup_with_two_verified_snapshots
    staged=$(mount_for raw/photos)/.zfs/snapshot/ssd
    [[ ! -e $staged || -z $(ls -A "$staged" 2>/dev/null) ]] ||
        fail "the staging snapshot survived the run"
}

# restic tag rewrites the snapshot, so the id changes; recording the pre-tag id
# makes the freshness verifier report a snapshot that no longer exists.
backup_with_retagged_snapshot() {
    export STUB_BACKUP_EXIT=0 STUB_BACKUP_ID="pretag1" STUB_VERIFIED_ID="tagged1"
    drive "$driver" ssd --unit photos --no-maintenance
}

@test "a tagged snapshot succeeds" {
    backup_with_retagged_snapshot
    assert_equal "$rc" 0
}

@test "the post-tag snapshot ID is the one recorded" {
    backup_with_retagged_snapshot
    assert_equal "$(state_json ssd-photos .final.snapshot)" tagged1
}

@test "the tag is applied to the pre-tag snapshot" {
    backup_with_retagged_snapshot
    assert_logged 'tag --add verified pretag1' "$log/restic"
}

# A snapshot that was written but never tagged verified is not a recovery point,
# so the run has to reap it by the id it knows.
backup_with_failing_tag() {
    export STUB_BACKUP_EXIT=0 STUB_BACKUP_ID="complete2" STUB_TAG_EXIT=1
    drive "$driver" ssd --unit photos --no-maintenance
}

@test "tagging failure fails the run" {
    backup_with_failing_tag
    assert_not_equal "$rc" 0
}

@test "tagging failure is its own reason" {
    backup_with_failing_tag
    assert_equal "$(state_json ssd-photos '.last_attempt.reason')" tag-failed
}

@test "an untagged snapshot is reaped by recorded ID" {
    backup_with_failing_tag
    assert_equal "$(state_json ssd-photos '.pending_reap[0]')" complete2
}

# restic exit 11 is a lock failure: remove only stale locks, then retry once.
backup_with_stale_lock() {
    export STUB_BACKUP_EXIT=0 STUB_BACKUP_ID="lock1" STUB_VERIFIED_ID="lock1v" STUB_TAG_EXIT_ONCE=11
    drive "$driver" ssd --unit photos --no-maintenance
}

@test "a stale lock is retried after unlocking" {
    backup_with_stale_lock
    assert_equal "$rc" 0
}

@test "stale locks are removed before the retry" {
    backup_with_stale_lock
    assert_logged ' unlock' "$log/restic"
}

# --- 2. stale staging reconciliation ------------------------------------
# zfs lists a snapshot the previous run left behind, and it destroys cleanly.
run_with_stale_staging() {
    export STUB_BACKUP_EXIT=0 STUB_BACKUP_ID="complete3" STUB_ZFS_LIST_EXIT=0
    drive "$driver" ssd --unit photos --no-maintenance
}

@test "a stale staging snapshot does not block the run" {
    run_with_stale_staging
    assert_equal "$rc" 0
}

@test "reconciliation destroys the stale snapshot before creating a new one" {
    run_with_stale_staging
    destroy_line=$(grep -n '^destroy smortress/raw/photos@ssd' "$log/zfs" | head -n1 | cut -d: -f1)
    snapshot_line=$(grep -n '^snapshot smortress/raw/photos@ssd' "$log/zfs" | head -n1 | cut -d: -f1)
    [[ -n $destroy_line && -n $snapshot_line ]] ||
        fail "expected both a destroy and a snapshot: $(cat "$log/zfs")"
    assert_equal "$((destroy_line < snapshot_line))" 1
}

@test "a job destroys only its own staging snapshot" {
    run_with_stale_staging
    refute_logged 'destroy smortress/raw/photos@hdd\|destroy smortress/raw/books@ssd' "$log/zfs"
}

# --- 2b. a staging failure says why -------------------------------------
# The 2026-11-22 hdd/photos failure recorded "snapshot-reconcile" and nothing
# else, because zfs's stderr went to /dev/null at every destroy site.
run_with_busy_stale_snapshot() {
    export STUB_BACKUP_EXIT=0 STUB_BACKUP_ID="complete3" STUB_ZFS_LIST_EXIT=0 STUB_ZFS_DESTROY_EXIT=1
    busy="cannot destroy 'smortress/raw/photos@ssd': dataset is busy"
    export STUB_ZFS_STDERR=$busy
    drive "$driver" ssd --unit photos --no-maintenance
}

@test "a stale snapshot that will not destroy fails the job" {
    run_with_busy_stale_snapshot
    assert_not_equal "$rc" 0
}

@test "the failure reason stays symbolic" {
    run_with_busy_stale_snapshot
    assert_equal "$(state_json ssd-photos '.last_attempt.reason')" snapshot-reconcile
}

@test "a failed reconciliation records zfs's own message" {
    run_with_busy_stale_snapshot
    assert_contains "$out" "$busy"
}

@test "a busy destroy is retried once before the attempt fails" {
    run_with_busy_stale_snapshot
    assert_equal "$(grep -c '^destroy smortress/raw/photos@ssd' "$log/zfs" || true)" 2
}

# The staging snapshot this run created will not destroy either, but that is the
# end-of-run cleanup: the backup itself succeeded.
run_with_failing_cleanup() {
    export STUB_BACKUP_EXIT=0 STUB_BACKUP_ID="complete4" STUB_ZFS_LIST_EXIT=1 STUB_ZFS_DESTROY_FAIL_LATE=1
    busy="cannot destroy 'smortress/raw/photos@ssd': dataset is busy"
    export STUB_ZFS_STDERR=$busy
    drive "$driver" ssd --unit photos --no-maintenance
}

@test "a staging snapshot that will not destroy does not fail a good backup" {
    run_with_failing_cleanup
    assert_equal "$rc" 0
}

@test "a failed end-of-run cleanup names the zfs error" {
    run_with_failing_cleanup
    assert_contains "$out" "$busy"
}

# --- 3. readiness and mount gates ---------------------------------------
run_with_failing_readiness() {
    export STUB_BACKUP_EXIT=0 STUB_BACKUP_ID="should-not-happen" STUB_READY_EXIT=1
    drive "$driver" ssd --unit photos --no-maintenance
}

@test "a failed readiness unit fails the job" {
    run_with_failing_readiness
    assert_not_equal "$rc" 0
}

@test "readiness failure is recorded" {
    run_with_failing_readiness
    assert_equal "$(state_json ssd-photos '.last_attempt.reason')" readiness
}

@test "no snapshot or backup happens before readiness" {
    run_with_failing_readiness
    refute_logged 'zfs snapshot\|^backup ' "$log/zfs" "$log/restic"
}

run_with_unmounted_repository() {
    sed -i "\|$repos/ssd|d" "$work/mountinfo"
    export STUB_BACKUP_EXIT=0 STUB_BACKUP_ID="should-not-happen"
    drive "$driver" ssd --unit photos --no-maintenance
}

@test "an unmounted repository path fails the job" {
    run_with_unmounted_repository
    assert_not_equal "$rc" 0
}

@test "unmounted repository is recorded" {
    run_with_unmounted_repository
    assert_equal "$(state_json ssd-photos '.last_attempt.reason')" repo-not-mounted
}

@test "nothing is written to an unmounted repository" {
    run_with_unmounted_repository
    refute_logged '^tag ' "$log/restic"
}

# --- 4. retention filter and deletion shape -----------------------------

@test "unit and verified are matched with one AND tag" {
    # Two --tag flags are OR in restic; only one comma-separated flag is AND, and
    # a wrong form makes one unit's forget touch another unit's verified
    # snapshots.
    if grep -nE -- '--tag "unit:\$[a-z]+" --tag verified' scripts/smortress-restic-*.sh; then
        fail "a retention command matches unit and verified with two OR tags"
    fi
}

@test "every retention command requires both unit and verified tags" {
    joined=$(sed -e :a -e '/\\$/N; s/\\\n/ /; ta' "$driver")
    retention_bad=""
    while IFS= read -r line; do
        [[ $line == *--keep-* ]] || continue
        [[ $line == *'--tag "unit:'* && $line == *',verified'* ]] || retention_bad=$line
    done <<<"$joined"
    assert_equal "$retention_bad" ""
}

@test "retention uses no wildcard bucket and no routine unlock" {
    if grep -qE -- '--keep-last|--keep-within|--keep-tag|unlock' scripts/smortress-restic-*.sh; then
        fail "a retention command keeps a wildcard bucket or unlocks routinely"
    fi
}

@test "no bulk deletion of snapshot sets or repository roots" {
    if grep -qE -- 'forget .*\*|rm -rf[^#]*(/var/lib/restic|/var/lib/homelab/restic)' \
        scripts/smortress-restic-*.sh; then
        fail "something deletes snapshot sets or repository roots in bulk"
    fi
}

# --- 9. first-upload sizing ---------------------------------------------
# A unit's first upload has nothing deduplicated yet, so it is read, chunked and
# written in full: it gets its own deadline and a single attempt. A unit with a
# success already recorded against the repository it writes keeps the routine
# bound and its retries. The state file itself says which of the two it is.
first_upload_failing() {
    export STUB_BACKUP_EXIT=1 STUB_BACKUP_ID=""
    drive RESTIC_ATTEMPTS=2 RESTIC_ATTEMPTS_FIRST=1 \
        "$driver" ssd --unit photos --no-maintenance
}

@test "a unit with no recorded success gets one first attempt" {
    first_upload_failing
    assert_equal "$(grep -c ' backup --host' "$log/restic" || true)" 1
}

@test "the single first attempt still records its failure" {
    first_upload_failing
    assert_equal "$(state_json ssd-photos '.last_attempt.result')" failure
}

# A real success first, so the second run is a routine increment of a unit with
# a recovery point already recorded against this repository.
first_upload_then_failing_routine() {
    export STUB_BACKUP_EXIT=0 STUB_BACKUP_ID="first1" STUB_VERIFIED_ID="first1v"
    drive "$driver" ssd --unit photos --no-maintenance
    : >"$log/restic"
    export STUB_BACKUP_EXIT=1 STUB_BACKUP_ID=""
    drive RESTIC_ATTEMPTS=2 RESTIC_ATTEMPTS_FIRST=1 \
        "$driver" ssd --unit photos --no-maintenance
}

@test "the first upload can succeed" {
    export STUB_BACKUP_EXIT=0 STUB_BACKUP_ID="first1" STUB_VERIFIED_ID="first1v"
    drive "$driver" ssd --unit photos --no-maintenance
    assert_equal "$(state_json ssd-photos '.last_attempt.result')" success
}

@test "a unit with a recorded success keeps the routine retries" {
    first_upload_then_failing_routine
    assert_equal "$(grep -c ' backup --host' "$log/restic" || true)" 2
}

@test "a success against another repository does not count as a success" {
    export STUB_BACKUP_EXIT=0 STUB_BACKUP_ID="first1" STUB_VERIFIED_ID="first1v"
    drive "$driver" ssd --unit photos --no-maintenance
    # Same state, different repository: the recorded success proves nothing about
    # the repository this run writes, so it is a first upload again.
    : >"$log/restic"
    jq '.repository = "s3:https://elsewhere.invalid/other"' \
        "$work/state/state/ssd-photos.json" >"$work/state/state/ssd-photos.json.tmp" &&
        mv "$work/state/state/ssd-photos.json.tmp" "$work/state/state/ssd-photos.json"
    export STUB_BACKUP_EXIT=1 STUB_BACKUP_ID=""
    drive RESTIC_ATTEMPTS=2 RESTIC_ATTEMPTS_FIRST=1 \
        "$driver" ssd --unit photos --no-maintenance
    assert_equal "$(grep -c ' backup --host' "$log/restic" || true)" 1
}

# The deadline varies per unit, which is what the run is actually given: the
# slow first upload outlives the routine deadline, the same slowness afterwards
# does not.
slow_first_upload() {
    export STUB_BACKUP_EXIT=0 STUB_BACKUP_ID="slow1" STUB_VERIFIED_ID="slow1v" STUB_BACKUP_SLEEP=3
    drive RESTIC_DEADLINE_LOCAL=2 RESTIC_DEADLINE_FIRST_LOCAL=15 \
        "$driver" ssd --unit photos --no-maintenance
}

@test "a slow first upload is not killed by the routine deadline" {
    slow_first_upload
    assert_equal "$rc" 0
}

@test "a slow first upload is not recorded as timeout" {
    slow_first_upload
    assert_equal "$(state_json ssd-photos '.last_attempt.result')" success
}

@test "a slow routine run keeps the tighter deadline" {
    slow_first_upload
    : >"$log/restic"
    drive RESTIC_DEADLINE_LOCAL=2 "$driver" ssd --unit photos --no-maintenance
    assert_equal "$(state_json ssd-photos '.last_attempt.reason')" timeout
}

# The agent's local state outgrew the hourly window, so that unit alone gets the
# long local bound: a slow increment of it succeeds while every other unit still
# keeps the tight one. Both units start with a recorded success, so both runs
# below are routine increments.
long_local_unit_seeded() {
    export STUB_BACKUP_EXIT=0 STUB_BACKUP_ID="slowagent" STUB_VERIFIED_ID="slowagentv"
    drive "$driver" ssd --unit agent-local --no-maintenance
    drive "$driver" ssd --unit photos --no-maintenance
    : >"$log/restic"
    export STUB_BACKUP_SLEEP=3
}

@test "agent-local's routine run gets the long local deadline" {
    long_local_unit_seeded
    drive RESTIC_DEADLINE_LOCAL=2 RESTIC_DEADLINE_LOCAL_LONG=15 \
        "$driver" ssd --unit agent-local --no-maintenance
    assert_equal "$(state_json ssd-agent-local '.last_attempt.result')" success
}

@test "the other units keep the hourly deadline" {
    long_local_unit_seeded
    drive RESTIC_DEADLINE_LOCAL=2 RESTIC_DEADLINE_LOCAL_LONG=15 \
        "$driver" ssd --unit photos --no-maintenance
    assert_equal "$(state_json ssd-photos '.last_attempt.reason')" timeout
}

@test "agent-local's budgets follow its deadline" {
    # The freshness and expiry budgets are derived from the deadline the unit
    # actually gets, so the long attempt is not called stale while it is legal.
    budgets=$(RESTIC_ATTEMPTS=2 RESTIC_RETRY_SLEEP_LOCAL=60 \
        RESTIC_DEADLINE_LOCAL=1800 RESTIC_DEADLINE_LOCAL_LONG=14400 bash -c '
        source scripts/restic-plane-common.sh
        printf "%s %s %s\n" "$(max_age_for ssd agent-local)" \
          "$(run_expiry_for ssd agent-local)" "$(max_age_for ssd photos)"')
    assert_equal "$budgets" "33600 29520 8400"
}

# --- 9. progress publication ---------------------------------------------
# Watching a run is read-only and belongs to the operator, so the driver
# publishes restic's own status records and each unit's last result to a
# world-readable tree beside the durable state, which stays root-only.
live_env() {
    export STUB_BACKUP_ID="live1" STUB_VERIFIED_ID="live1v" \
        STUB_BACKUP_STATUS=1 STUB_BACKUP_SLEEP=1
}

# Sample the stream while restic is still uploading, keyed on the record itself:
# the file existing is not proof the status arrived yet. Bounded at 200 x 10ms,
# so a record that never arrives fails the test instead of hanging it.
start_live_run() {
    live_env
    "$driver" ssd --unit photos --no-maintenance >/dev/null 2>&1 &
    live_pid=$!
    sampled='' marker_mode='' stream_mode=''
    local i=0
    while ((i < 200)); do
        sampled=$(jq -c 'select(.percent_done == 0.25)' "$work/progress/ssd-photos.jsonl" 2>/dev/null | tail -n1)
        if [[ -n $sampled && -r $work/progress/current-ssd.json ]]; then
            marker_mode=$(stat -c %a "$work/progress/current-ssd.json" 2>/dev/null)
            stream_mode=$(stat -c %a "$work/progress/ssd-photos.jsonl" 2>/dev/null)
            return 0
        fi
        pause
        i=$((i + 1))
    done
    return 1
}

@test "a running unit is published as current" {
    start_live_run || fail "no status record was published while the run was live"
    assert_equal "$(jq -r '.backend + "/" + .unit' "$work/progress/current-ssd.json" 2>/dev/null)" ssd/photos
    wait "$live_pid"
}

@test "restic's status records reach the progress tree" {
    start_live_run || fail "no status record was published while the run was live"
    assert_equal "$(jq -r '.percent_done' <<<"$sampled")" 0.25
    wait "$live_pid"
}

@test "the current marker is world-readable" {
    start_live_run || fail "no status record was published while the run was live"
    assert_equal "$marker_mode" 644
    wait "$live_pid"
}

@test "the status stream is world-readable" {
    start_live_run || fail "no status record was published while the run was live"
    assert_equal "$stream_mode" 644
    wait "$live_pid"
}

@test "the world-readable stream does not name the files being read" {
    start_live_run || fail "no status record was published while the run was live"
    if [[ $sampled == *secret.txt* ]]; then
        fail "the published record names the file being read: $sampled"
    fi
    wait "$live_pid"
}

@test "error records, which name the failing file, are not published" {
    start_live_run || fail "no status record was published while the run was live"
    if [[ $sampled == *'"message_type":"error"'* ]]; then
        fail "the published record is an error record: $sampled"
    fi
    wait "$live_pid"
}

@test "current is cleared after the run" {
    live_env
    drive "$driver" ssd --unit photos --no-maintenance
    if [[ -e $work/progress/current-ssd.json ]]; then
        fail "current is still published: $(cat "$work/progress/current-ssd.json")"
    fi
}

@test "the last result is published for a reader without root" {
    live_env
    drive "$driver" ssd --unit photos --no-maintenance
    assert_equal "$(jq -r '.result' "$work/progress/last/ssd-photos.json" 2>/dev/null)" success
}

@test "the last result is world-readable" {
    live_env
    drive "$driver" ssd --unit photos --no-maintenance
    assert_equal "$(stat -c %a "$work/progress/last/ssd-photos.json" 2>/dev/null)" 644
}
