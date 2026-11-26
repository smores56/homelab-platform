#!/usr/bin/env bats
# bats file_tags=core
# Offline checks for the Restic plane (SDLC #706, T3): fail-closed freshness and
# the deploy gate's local query, the backup driver's exit codes, stale-staging
# reconciliation, the readiness and mount gates, the retention filter,
# first-upload sizing, progress publication, repository init, the sops-decrypt
# format column and the ciphertext seed, and the unit ordering that keeps a
# backup off a dataset that is not ready yet.
#
# The host half — real disks, real repositories, real Healthchecks — is in
# docs/manual-steps.md section 38. This proves the half that does not need root
# or a network. restic, zfs, curl and sops are stubs; the command lines and the
# durable state are real.
load ../helpers

driver=scripts/smortress-restic-backup.sh
init=scripts/smortress-restic-init.sh
decrypt=scripts/sops-decrypt.sh
seeder=scripts/smortress-secrets-seed.sh

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

    # The secret pipeline's decrypt: a fixed plaintext per bundle, except that
    # STUB_SOPS_PLAINTEXT makes it emit a document of the caller's choosing, which
    # is how the two-key value case is reached.
    cat >"$fx/bin/sops" <<'STUB'
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
        CURL_BIN=$fx/bin/curl SOPS_BIN=$fx/bin/sops
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

# The wait is the other half: a lock a stopped or still-running writer holds is
# waited on, not failed on, so a stop does not make the repository unusable for
# the next attempt (#138).
@test "a write waits for a live lock instead of failing on it" {
    export STUB_BACKUP_EXIT=0 STUB_BACKUP_ID="waits1"
    drive "$driver" ssd --unit photos --no-maintenance
    assert_logged '--retry-lock 2m backup' "$log/restic"
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

@test "no restic write bypasses the lock wait" {
    # restic_with_lock is the only place --retry-lock is passed; a write called
    # straight through "$restic_bin" would fail on a lock instead of waiting it
    # out, which is the window that blocked forget and prune on 2026-11-25 (#138).
    if grep -nE -- '"\$(\{restic_bin\}|restic_bin)" (backup|forget|prune|tag|check)\b' \
        scripts/smortress-restic-*.sh; then
        fail "a restic write runs without the lock wait"
    fi
}

@test "no bulk deletion of snapshot sets or repository roots" {
    if grep -qE -- 'forget .*\*|rm -rf[^#]*(/var/lib/restic|/var/lib/homelab/restic)' \
        scripts/smortress-restic-*.sh; then
        fail "something deletes snapshot sets or repository roots in bulk"
    fi
}

# --- 5. freshness verifier -----------------------------------------------
# The hourly verifier joins the durable state to what the repositories actually
# contain, and pings one Healthchecks check only when every destination is
# current. Each case below seeds the plane it needs: the shell suite seeded it
# nine times for assertions that shared eleven runs, so the slowest area of the
# file ran as one serial pass.

# unit_paths <unit> <backend>: the storage table's path set for a unit on a
# backend, as a JSON array. The same list unit_paths_json builds, from the two
# strings setup_file handed on: the arrays it needs are gone by the test body.
unit_paths() {
    local entry keys='' key
    local -a paths=()
    for entry in $unit_keys; do
        [[ ${entry%%=*} == "$1" ]] && { keys=${entry#*=}; break; }
    done
    [[ -n $keys ]] || {
        printf 'unknown unit: %s\n' "$1" >&2
        return 1
    }
    for key in ${keys//,/ }; do
        paths+=("$(mount_for "$key")/.zfs/snapshot/$2")
    done
    jq -cn --args '$ARGS.positional' -- "${paths[@]}"
}

# unit_count: how many restore units the table names.
unit_count() {
    local entry n=0
    for entry in $unit_keys; do n=$((n + 1)); done
    printf '%s\n' "$n"
}

# seed_state <backend> <unit> [<result>] [<exit>] [<snapshot>]: one unit's status
# file and journal, as a run with that result leaves them.
seed_state() {
    local backend=$1 unit=$2 now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    install -d -m 0700 "$work/state/state" "$work/state/journal"
    jq -n --arg b "$backend" --arg u "$unit" --argjson p "$(unit_paths "$unit" "$backend")" \
        --arg start "$now" --arg end "$now" \
        --arg result "${3:-success}" --argjson exit "${4:-0}" --arg snap "${5:-strepo}" '
        {schema: 2, backend: $b, unit: $u, host: "smortress",
         repository: "stub", paths: $p,
         last_attempt: {n: 1, start: $start, end: $end, exit: $exit,
                        result: $result, reason: "", snapshot: $snap},
         last_success: {end: $end, snapshot: $snap},
         final: {end: $end, snapshot: $snap},
         pending_reap: []}' >"$work/state/state/$backend-$unit.json"
    jq -cn --arg result "${3:-success}" --arg snap "${5:-strepo}" \
        '{schema:2, attempt:1, result:$result, snapshot:$snap}' \
        >"$work/state/journal/$backend-$unit.jsonl"
}

# Every healthy unit of every backend in one jq, then one write per file: 27
# units x 3 backends through seed_state would be 54 jq processes, and nearly
# every freshness case seeds the plane before its assertion.
seed_all_healthy() {
    local now entry
    local -a table=()
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    install -d -m 0700 "$work/state/state" "$work/state/journal"
    # The storage table as setup_file read it: one key=<mountpoint> per dataset
    # and one unit:<unit>=<keys> per unit, so jq can build each unit's snapshot
    # paths without calling unit_paths per unit. The mountpoints are the real
    # ones, so this test's scratch tree is prefixed here.
    for entry in $mounts; do table+=("${entry%%=*}=$work${entry#*=}"); done
    for entry in $unit_keys; do table+=("unit:${entry%%=*}=${entry#*=}"); done
    while IFS=$'\t' read -r file doc; do
        printf '%s\n' "$doc" >"$work/state/$file"
    done < <(jq -rn --arg now "$now" --args '
    def kv: (index("=")) as $i | {(.[0:$i]): .[$i+1:]};
    ($ARGS.positional | map(kv) | add) as $t
    | ($t | to_entries) as $rows
    | [ $rows[] | select(.key | startswith("unit:")) as $u
        | ["ssd", "hdd", "r2"][] as $b
        | {file: "state/\($b)-\($u.key[5:]).json",
           doc: {schema: 2, backend: $b, unit: ($u.key[5:]), host: "smortress",
                 repository: "stub",
                 paths: [($u.value | split(",")[]) as $k
                         | ($rows[] | select(.key == $k) | .value)
                           + "/.zfs/snapshot/" + $b],
                 last_attempt: {n: 1, start: $now, end: $now, exit: 0,
                                result: "success", reason: "", snapshot: "strepo"},
                 last_success: {end: $now, snapshot: "strepo"},
                 final: {end: $now, snapshot: "strepo"},
                 pending_reap: []}},
          {file: "journal/\($b)-\($u.key[5:]).jsonl",
           doc: {schema: 2, attempt: 1, result: "success", snapshot: "strepo"}} ]
    | .[] | "\(.file)\t\(.doc | tojson)"' -- "${table[@]}")
}

# first_running <backend> <unit> <seconds ago>: the unit's second attempt is in
# flight and nothing has ever succeeded. A unit that has never succeeded is
# uploading its first snapshot, which is bounded by the first-upload deadline;
# judging that run by the routine window would call a legitimate first upload
# dead and expire it.
first_running() {
    local start
    start=$(date -u -d "@$(($(date -u +%s) - $3))" +%Y-%m-%dT%H:%M:%SZ)
    jq --arg start "$start" '.last_success = null | .final = null
        | .last_attempt = {n: 2, start: $start, end: null, exit: null,
                           result: "running", reason: "", snapshot: null}' \
        "$work/state/state/$1-$2.json" >"$work/state/state/$1-$2.json.tmp" &&
        mv "$work/state/state/$1-$2.json.tmp" "$work/state/state/$1-$2.json"
    jq -cn '{schema: 2, attempt: 1, result: "failure", snapshot: null}' \
        >"$work/state/journal/$1-$2.jsonl"
}

# healthy_plane: a fully seeded plane with its Healthchecks check configured, as
# the hourly verifier sees it.
healthy_plane() {
    seed_all_healthy
    export RESTIC_HEALTHCHECK_URL=https://hc.invalid/ping/abc
}

# failing_destination: one unit's newest attempt failed after a recent success.
failing_destination() {
    healthy_plane
    seed_state ssd photos failure 1 ""
}

@test "a healthy plane verifies" {
    healthy_plane
    drive scripts/smortress-restic-verify.sh
    assert_equal "$rc" 0
}

@test "exactly one Healthchecks ping on success" {
    healthy_plane
    drive scripts/smortress-restic-verify.sh
    assert_equal "$(wc -l <"$log/curl-urls" | tr -d ' ')" 1
}

@test "the ping goes to the configured check" {
    healthy_plane
    drive scripts/smortress-restic-verify.sh
    assert_equal "$(cat "$log/curl-urls")" "$RESTIC_HEALTHCHECK_URL"
}

@test "a newer failed run fails freshness even with a recent success" {
    failing_destination
    drive scripts/smortress-restic-verify.sh
    assert_not_equal "$rc" 0
}

@test "no success ping while a destination is failing" {
    failing_destination
    drive scripts/smortress-restic-verify.sh
    if grep -qx "$RESTIC_HEALTHCHECK_URL" "$log/curl-urls"; then
        fail "the success check was pinged while a destination is failing"
    fi
}

@test "the failure is reported to the same check" {
    failing_destination
    drive scripts/smortress-restic-verify.sh
    assert_logged '/fail$' "$log/curl-urls"
}

@test "a run that died without completing expires" {
    seed_all_healthy
    jq '.last_attempt.n = 2 | .last_attempt.result = "running" | .last_attempt.start = "2000-01-01T00:00:00Z"' \
        "$work/state/state/hdd-books.json" >"$work/state/state/hdd-books.json.tmp" &&
        mv "$work/state/state/hdd-books.json.tmp" "$work/state/state/hdd-books.json"
    drive scripts/smortress-restic-verify.sh --no-ping
    assert_not_equal "$rc" 0
}

@test "a first upload inside its own window is not called dead" {
    seed_all_healthy
    first_running ssd photos 6000
    drive scripts/smortress-restic-verify.sh --no-ping
    if grep -q 'never completed' <<<"$out"; then
        fail "a legal first upload was called dead" "$out"
    fi
}

@test "a first upload past its own window still expires" {
    seed_all_healthy
    first_running ssd photos 20000
    drive scripts/smortress-restic-verify.sh --no-ping
    assert_contains "$out" 'never completed'
}

@test "missing status state fails closed" {
    seed_all_healthy
    rm -f "$work/state/state/r2-files.json"
    drive scripts/smortress-restic-verify.sh --no-ping
    assert_not_equal "$rc" 0
}

@test "a recorded snapshot missing from the repository fails" {
    seed_all_healthy
    export STUB_SNAPSHOTS_JSON='[]'
    drive scripts/smortress-restic-verify.sh --no-ping
    assert_not_equal "$rc" 0
}

@test "an unverified tag or wrong source path fails" {
    seed_all_healthy
    STUB_SNAPSHOTS_JSON=$(jq -cn '[{id: "strepo", time: "2026-01-01T00:00:00Z", hostname: "smortress", paths: ["x"], tags: ["group:photos", "host:smortress"]}]')
    export STUB_SNAPSHOTS_JSON
    drive scripts/smortress-restic-verify.sh --no-ping
    assert_not_equal "$rc" 0
}

@test "a missing Healthchecks URL refuses to claim freshness" {
    seed_all_healthy
    unset RESTIC_HEALTHCHECK_URL
    drive scripts/smortress-restic-verify.sh
    assert_not_equal "$rc" 0
}

@test "no ping without a configured URL" {
    seed_all_healthy
    unset RESTIC_HEALTHCHECK_URL
    drive scripts/smortress-restic-verify.sh
    if [[ -s $log/curl-urls ]]; then
        fail "a ping was sent without a configured URL" "$(cat "$log/curl-urls")"
    fi
}

# --- 5b. the deploy gate's local query -----------------------------------
# `--local --json` is read-only and answers per restore unit, per local
# repository, because the caller owns the fallback: an unusable repository is a
# payload fact, freshness is a payload fact, and only a query that cannot run at
# all is an exit code. It never pings, so it works before the check exists.

# local_query: the gate's question about a healthy plane, with a Healthchecks URL
# configured to prove the query never uses it.
local_query() {
    healthy_plane
    drive scripts/smortress-restic-verify.sh --local --json
    # A verdict that is not JSON makes every assertion below fail with the same
    # message, so print what was actually returned instead of hiding it.
    if ! jq -e . >/dev/null 2>&1 <<<"$out"; then
        printf 'local verdict was not JSON: %s\n' "$out" >&2
    fi
}

@test "a healthy plane answers the local query" {
    local_query
    assert_equal "$rc" 0
}

@test "the SSD is reported usable" {
    local_query
    assert_equal "$(jq -r '.ssd.usable' <<<"$out")" true
}

@test "the HDD is reported usable" {
    local_query
    assert_equal "$(jq -r '.hdd.usable' <<<"$out")" true
}

@test "a fresh SSD unit is reported fresh" {
    local_query
    assert_equal "$(jq -r '.ssd.units.photos.fresh' <<<"$out")" true
}

@test "a fresh HDD unit is reported fresh" {
    local_query
    assert_equal "$(jq -r '.hdd.units["repo-archive"].fresh' <<<"$out")" true
}

@test "every restore unit is reported" {
    local_query
    assert_equal "$(jq -r '.ssd.units | length' <<<"$out")" "$(unit_count)"
}

@test "the local query covers only the two local repositories" {
    local_query
    assert_equal "$(jq -r 'has("r2")' <<<"$out")" false
}

@test "the local query never pings Healthchecks" {
    local_query
    if [[ -s $log/curl-urls ]]; then
        fail "the local query pinged Healthchecks" "$(cat "$log/curl-urls")"
    fi
}

@test "the local query needs no Healthchecks URL" {
    seed_all_healthy
    unset RESTIC_HEALTHCHECK_URL
    drive scripts/smortress-restic-verify.sh --local --json
    assert_equal "$rc" 0
}

# A verdict is freshness, not an exit code: the gate decides what a stale unit
# means (back it up, or hold the deploy).

# stale_snapshot: photos' only snapshot is verified but 9000s old, past its max
# age.
stale_snapshot() {
    seed_all_healthy
    local stale_time
    stale_time=$(date -u -d "@$(($(date -u +%s) - 9000))" +%Y-%m-%dT%H:%M:%SZ)
    STUB_SNAPSHOTS_JSON=$(jq -cn --arg t "$stale_time" --argjson p "$(unit_paths photos ssd)" '
        [{id: "old1", time: $t, hostname: "smortress", paths: $p,
          tags: ["unit:photos", "host:smortress", "verified"]}]')
    export STUB_SNAPSHOTS_JSON
    drive scripts/smortress-restic-verify.sh --local --json
}

@test "a stale snapshot is a verdict, not a failure of the query" {
    stale_snapshot
    assert_equal "$rc" 0
}

@test "a snapshot past the max age is not fresh" {
    stale_snapshot
    assert_equal "$(jq -r '.ssd.units.photos.fresh' <<<"$out")" false
}

@test "a stale snapshot says why" {
    stale_snapshot
    assert_equal "$(jq -r '.ssd.units.photos.reason' <<<"$out")" stale
}

# unverified_snapshot: photos' only snapshot is current but never tagged
# verified, so it is not a recovery point.
unverified_snapshot() {
    seed_all_healthy
    STUB_SNAPSHOTS_JSON=$(jq -cn --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson p "$(unit_paths photos ssd)" '
        [{id: "nv1", time: $t, hostname: "smortress", paths: $p,
          tags: ["unit:photos", "host:smortress"]}]')
    export STUB_SNAPSHOTS_JSON
    drive scripts/smortress-restic-verify.sh --local --json
}

@test "an untagged snapshot is not fresh" {
    unverified_snapshot
    assert_equal "$(jq -r '.ssd.units.photos.reason' <<<"$out")" unverified
}

# The 970 is the preferred repository and the HDD is the fallback when it is
# absent, so "no SSD" must be a usable=false payload and not a broken query. This
# test's mountinfo is its own, so the SSD line goes and nothing is put back.
absent_ssd() {
    seed_all_healthy
    sed -i "\|$repos/ssd|d" "$work/mountinfo"
    drive scripts/smortress-restic-verify.sh --local --json
}

@test "an absent SSD does not break the local query" {
    absent_ssd
    assert_equal "$rc" 0
}

@test "an absent SSD is reported unusable" {
    absent_ssd
    assert_equal "$(jq -r '.ssd.usable' <<<"$out")" false
}

@test "the HDD stays usable" {
    absent_ssd
    assert_equal "$(jq -r '.hdd.usable' <<<"$out")" true
}

@test "no unit is fresh on an unusable repository" {
    absent_ssd
    assert_equal "$(jq -r '.ssd.units.photos.fresh' <<<"$out")" false
}

# A caller-named cache that cannot be created is a destination verdict, not a
# crash and not a warning on the stream a JSON consumer parses. This is what a
# GitHub runner exposed: /var/cache is unwritable there, and a stderr line merged
# into the output turned every assertion into a jq parse error.
uncreatable_cache() {
    seed_all_healthy
    rc=0
    out=$(env RESTIC_CACHE_DIR=/proc/smortress-restic-cache \
        scripts/smortress-restic-verify.sh --local --json 2>"$log/cache-stderr") || rc=$?
}

@test "an uncreatable cache is a verdict, not a crash" {
    uncreatable_cache
    assert_equal "$rc" 0
}

@test "the verdict stays JSON without a cache" {
    uncreatable_cache
    if ! jq -e . >/dev/null 2>&1 <<<"$out"; then
        fail "the verdict was not JSON" "$out"
    fi
}

@test "an uncreatable cache makes the repository unusable" {
    uncreatable_cache
    assert_equal "$(jq -r '.ssd.usable' <<<"$out")" false
}

@test "the uncreatable cache is named on stderr" {
    uncreatable_cache
    assert_logged 'cannot create the restic cache' "$log/cache-stderr"
}

# Nothing to join against is the one thing the query cannot answer.
@test "missing plane state fails the local query" {
    rm -rf "${work:?}/state"
    drive scripts/smortress-restic-verify.sh --local --json
    assert_not_equal "$rc" 0
}

@test "the aggregate mode takes no --json" {
    seed_all_healthy
    drive scripts/smortress-restic-verify.sh --json
    assert_equal "$rc" 2
}

@test "the local mode requires --json" {
    seed_all_healthy
    drive scripts/smortress-restic-verify.sh --local
    assert_equal "$rc" 2
}

# --- 5b. a unit that gained a dataset reconciles its recorded paths --------
#
# The verifier reads .paths from the state the backup driver wrote, because that
# is the set actually archived. When a dataset joins a unit after it has run,
# the stored set is stale until the next successful run. Without the rewrite the
# verifier keeps comparing new snapshots against the old paths and the unit can
# never be fresh again, which holds every deploy.

# stale_recorded_path_set: music's state records only raw/music, the set it
# archived before state/navidrome joined the unit.
stale_recorded_path_set() {
    seed_state ssd music
    jq --arg p "$(mount_for raw/music)/.zfs/snapshot/ssd" '.paths = [$p]' \
        "$work/state/state/ssd-music.json" >"$work/state/state/ssd-music.json.tmp" &&
        mv "$work/state/state/ssd-music.json.tmp" "$work/state/state/ssd-music.json"
}

@test "a unit whose dataset set changed still backs up" {
    stale_recorded_path_set
    export STUB_BACKUP_ID=reconcile1 STUB_BACKUP_TREE=treeR
    drive "$driver" ssd --unit music --no-maintenance
    assert_equal "$rc" 0
}

@test "a successful run records the path set it archived" {
    stale_recorded_path_set
    export STUB_BACKUP_ID=reconcile1 STUB_BACKUP_TREE=treeR
    drive "$driver" ssd --unit music --no-maintenance
    assert_equal "$(jq -c '.paths | sort' "$work/state/state/ssd-music.json")" \
        "$(unit_paths music ssd | jq -c 'sort')"
}

# --- 5c. a stale recorded path set is not called fresh ---------------------
#
# The local query prefers the state's recorded set while it still matches the
# table. After a dataset joins a unit and before its first new-family backup,
# the recorded set is stale; using it would report a pre-change snapshot as
# fresh while the new dataset has never been backed up.
@test "a snapshot from the old path family is not fresh" {
    stale_recorded_path_set
    STUB_SNAPSHOTS_JSON=$(jq -cn --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg p "$(mount_for raw/music)/.zfs/snapshot/ssd" '
        [{id: "oldfam", time: $t, hostname: "smortress", paths: [$p],
          tags: ["unit:music", "host:smortress", "verified"]}]')
    export STUB_SNAPSHOTS_JSON
    drive scripts/smortress-restic-verify.sh --local --json
    assert_equal "$(jq -r '.ssd.units.music.fresh' <<<"$out")" false
}

# --- 6. repository init --------------------------------------------------
# A repository is created once. init has to tell an existing repository from an
# absent one (restic exits 10) from a directory that holds files and is not a
# repository, and it must refuse a local backend whose disk is not mounted:
# a repository written under an unmounted mountpoint looks like a backup
# destination and is not one.
#
# The init checks create and delete repositories, so each test builds its own
# root and mountinfo: this file's fixture is shared by every sibling test under
# --jobs, and a half-built repository is exactly what they must not see.
init_fixture() {
    repos=$work/repos
    install -d -m 0755 "$repos/ssd" "$repos/hdd"
    printf '36 25 8:1 / %s/ssd rw,relatime - ext4 /dev/sdb1 rw\n37 25 8:2 / %s/hdd rw,relatime - ext4 /dev/sda1 rw\n' \
        "$repos" "$repos" >"$work/mountinfo"
    export RESTIC_BASE=$repos
}

init_existing_repository() {
    init_fixture
    install -d -m 0755 "$repos/ssd/restic"
    drive STUB_CAT_EXIT=0 "$init" ssd
}

init_missing_repository() {
    init_fixture
    drive STUB_CAT_EXIT=10 "$init" ssd
}

init_unmounted_mountpoint() {
    init_fixture
    sed -i "\|$repos/ssd|d" "$work/mountinfo"
    drive STUB_CAT_EXIT=10 "$init" ssd
}

init_non_repository_directory() {
    init_fixture
    install -d -m 0755 "$repos/ssd/restic"
    printf 'not a repo\n' >"$repos/ssd/restic/stray"
    drive STUB_CAT_EXIT=10 "$init" ssd
}

@test "an existing repository is accepted" {
    init_existing_repository
    assert_equal "$rc" 0
}

@test "an existing repository is never re-initialised" {
    init_existing_repository
    refute_logged '^init' "$log/restic"
}

@test "a missing repository is initialised" {
    init_missing_repository
    assert_equal "$rc" 0
}

@test "init runs against the mounted repository path" {
    init_missing_repository
    assert_logged '-r .*/repos/ssd/restic init' "$log/restic"
}

@test "init refuses an unmounted mountpoint" {
    init_unmounted_mountpoint
    assert_not_equal "$rc" 0
}

@test "nothing is initialised on the root filesystem" {
    init_unmounted_mountpoint
    refute_logged '^init' "$log/restic"
}

@test "init refuses a non-empty non-repository directory" {
    init_non_repository_directory
    assert_not_equal "$rc" 0
}

# --- 7. sops-decrypt format column ---------------------------------------
# The decrypt writes /run from a manifest whose last column decides how a
# secret is written: `value` takes the one scalar (what a restic password file
# must be), `yaml` keeps the document verbatim. The fixture is the age identity,
# the ciphertext set and that manifest, per test because every scenario breaks
# one of them.
sops_fixture() {
    dec=$work/sops
    install -d -m 0700 "$dec/src" "$dec/dst"
    printf 'AGE-SECRET-KEY-STUB\n' >"$dec/age"
    printf 'canary: sops-decrypt-ok\n' >"$dec/src/canary.yaml"
    printf 'password: hunter2\n' >"$dec/src/restic-password.yaml"
    me=$(id -un)
    mg=$(id -gn)
    cat >"$dec/manifest" <<EOF
canary.yaml           $me $mg 0600
restic-password.yaml  $me $mg 0600 value
EOF
    export SMORTRESS_SECRETS_SRC=$dec/src SMORTRESS_SECRETS_DST=$dec/dst \
        SMORTRESS_SECRETS_MANIFEST=$dec/manifest SMORTRESS_AGE_KEY=$dec/age
}

decrypt_listed_set() {
    sops_fixture
    drive "$decrypt"
}

decrypt_without_identity() {
    sops_fixture
    mv "$dec/age" "$dec/age.missing"
    drive "$decrypt"
}

decrypt_multi_key_value() {
    sops_fixture
    export STUB_SOPS_PLAINTEXT=$'first: one\nsecond: two\n'
    drive "$decrypt"
}

decrypt_unlisted_ciphertext() {
    sops_fixture
    printf 'extra.yaml\n' >"$dec/src/extra.yaml"
    drive "$decrypt"
}

@test "sops-decrypt writes a value secret" {
    decrypt_listed_set
    assert_equal "$rc" 0
}

@test "format=value writes only the password" {
    decrypt_listed_set
    assert_equal "$(cat "$dec/dst/restic-password.yaml")" "hunter2"
}

@test "format=yaml stays verbatim" {
    decrypt_listed_set
    assert_equal "$(cat "$dec/dst/canary.yaml")" "canary: sops-decrypt-ok"
}

@test "a missing age identity fails closed" {
    decrypt_without_identity
    assert_not_equal "$rc" 0
}

@test "a multi-key secret cannot be written as value" {
    decrypt_multi_key_value
    assert_not_equal "$rc" 0
}

@test "an unlisted ciphertext still fails closed" {
    decrypt_unlisted_ciphertext
    assert_not_equal "$rc" 0
}

# --- 7b. the ciphertext seed that makes /var authoritative ----------------
# The decrypt reads /var now, and the image's baked set is only the seed for a
# host that has none. Nothing may overwrite a host copy: that is where a rotation
# lands, and reinstating the baked value would silently undo it.
#
# Both manifest paths are pointed into the work dir: the seed rewrites the host
# manifest, and a harness run must never touch the machine's /etc.
seed_fixture() {
    seed=$work/seed
    install -d -m 0700 "$seed/baked"
    printf 'canary: baked\n' >"$seed/baked/canary.yaml"
    printf 'password: baked\n' >"$seed/baked/restic-password.yaml"
    export SMORTRESS_SECRETS_BAKED=$seed/baked SMORTRESS_SECRETS_SRC=$seed/host \
        SMORTRESS_SECRETS_IMAGE_MANIFEST=$seed/image.manifest \
        SMORTRESS_SECRETS_MANIFEST=$seed/host.manifest
}

seed_run() { drive "$seeder"; }

seeded_host() {
    seed_fixture
    seed_run
}

seeded_then_rotated() {
    seeded_host
    printf 'canary: rotated\n' >"$seed/host/canary.yaml"
    seed_run
}

# A secret the image added after the host's copy existed: the manifest names it,
# so leaving it out fails the decrypt's set check for every consumer.
seeded_after_image_addition() {
    seeded_then_rotated
    rm -f "$seed/host/restic-password.yaml"
    seed_run
}

seeded_from_nothing() {
    seed_fixture
    rm -f "$seed/baked"/*.yaml
    seed_run
}

@test "the seed copies the baked ciphertext" {
    seeded_host
    assert_equal "$rc" 0
}

@test "the ciphertext lands" {
    seeded_host
    assert_equal "$(cat "$seed/host/canary.yaml" 2>/dev/null)" "canary: baked"
}

@test "the ciphertext is root-only" {
    seeded_host
    assert_equal "$(stat -c %a "$seed/host/canary.yaml" 2>/dev/null)" 600
}

@test "the host directory is root-only" {
    seeded_host
    assert_equal "$(stat -c %a "$seed/host" 2>/dev/null)" 700
}

@test "a host copy is never overwritten" {
    seeded_then_rotated
    assert_equal "$(cat "$seed/host/canary.yaml")" "canary: rotated"
}

@test "a missing ciphertext is seeded" {
    seeded_after_image_addition
    assert_equal "$rc" 0
}

@test "the newly added secret lands" {
    seeded_after_image_addition
    assert_equal "$(cat "$seed/host/restic-password.yaml" 2>/dev/null)" "password: baked"
}

@test "the existing rotation is still untouched" {
    seeded_after_image_addition
    assert_equal "$(cat "$seed/host/canary.yaml")" "canary: rotated"
}

@test "nothing baked is not an error" {
    seeded_from_nothing
    assert_equal "$rc" 0
}

@test "nothing baked copies nothing" {
    seeded_from_nothing
    if [[ -e $seed/host/canary.yaml ]]; then
        fail "the seed copied a ciphertext with nothing baked: $(cat "$seed/host/canary.yaml")"
    fi
}

# --- 7c. the manifest the image owns --------------------------------------
# The manifest is metadata (name, owner, group, mode, format), never a secret, so
# the image is authoritative for it. bootc merges /etc once per deployment and
# keeps whatever the host already had, so on 2026-11-22 the image added two lines
# and an existing host never saw them: the seed copied both ciphertexts, /etc
# still listed the old set, and every consumer died on "ciphertext set and
# manifest disagree" until an operator appended the lines by hand. The seed now
# replaces the host copy from the image on every run, so the case below is a boot
# and nothing else.
#
# The age identity is §7's, and the last assertions decrypt what the seed left
# behind through the same sops stub, so one fixture carries the chain.
refresh_fixture() {
    dec=$work/sops
    install -d -m 0700 "$dec"
    printf 'AGE-SECRET-KEY-STUB\n' >"$dec/age"
    me=$(id -un)
    mg=$(id -gn)
    refresh=$work/refresh
    install -d -m 0700 "$refresh/host"
    install -d -m 0755 "$refresh/image" "$refresh/bootc/server/secrets"
    printf 'canary: baked\n' >"$refresh/bootc/server/secrets/canary.yaml"
    printf 'token: baked\n' >"$refresh/bootc/server/secrets/new-token.yaml"
    cat >"$refresh/bootc/server/secrets.manifest" <<EOF
canary.yaml      $me $mg 0600
new-token.yaml   $me $mg 0600 value
EOF
    # A host that predates the new image: the manifest it booted with, and one of
    # the two ciphertexts already rotated in place under it.
    printf 'canary.yaml  %s %s 0600\n' "$me" "$mg" >"$refresh/host/secrets.manifest"
    printf 'canary: rotated\n' >"$refresh/host/canary.yaml"
    export SMORTRESS_SECRETS_BAKED=$refresh/bootc/server/secrets \
        SMORTRESS_SECRETS_SRC=$refresh/host \
        SMORTRESS_SECRETS_IMAGE_MANIFEST=$refresh/bootc/server/secrets.manifest \
        SMORTRESS_SECRETS_MANIFEST=$refresh/host/secrets.manifest
}

refresh_seeded() {
    refresh_fixture
    drive "$seeder"
}

refresh_decrypted() {
    refresh_seeded
    drive SMORTRESS_SECRETS_SRC="$refresh/host" SMORTRESS_SECRETS_DST="$refresh/run" \
        SMORTRESS_SECRETS_MANIFEST="$refresh/host/secrets.manifest" \
        SMORTRESS_AGE_KEY="$dec/age" "$decrypt"
}

# A second boot of the same image is a no-op, not a rewrite: the inode survives.
refresh_reseeded() {
    refresh_seeded
    manifest_inode=$(stat -c %i "$refresh/host/secrets.manifest")
    drive "$seeder"
}

# An image that carries no manifest -- the release that drops the baked set, or a
# rollback to one that only ever had /etc -- must leave the host copy alone: the
# seed is not allowed to delete the only manifest a booting host has.
refresh_without_image_manifest() {
    refresh_fixture
    mv "$refresh/bootc/server/secrets.manifest" "$refresh/bootc/server/secrets.manifest.off"
    printf 'canary.yaml  %s %s 0600\n' "$me" "$mg" >"$refresh/host/secrets.manifest"
    drive "$seeder"
}

@test "the seed applies the image manifest over the host's stale copy" {
    refresh_seeded
    assert_equal "$rc" 0
}

@test "the host manifest becomes the image's, not the one bootc preserved" {
    refresh_seeded
    if ! cmp -s "$refresh/bootc/server/secrets.manifest" "$refresh/host/secrets.manifest"; then
        fail "the host manifest is not the image's: $(cat "$refresh/host/secrets.manifest")"
    fi
}

@test "the replaced manifest stays readable metadata, not a secret" {
    refresh_seeded
    assert_equal "$(stat -c %a "$refresh/host/secrets.manifest" 2>/dev/null)" 644
}

# The mixed rotation the incident hit: one entry the host already rotated and one
# the image added. The manifest refresh must not touch the first, must seed the
# second, and the set has to match afterwards or every consumer fails.
@test "a rotated ciphertext survives the manifest refresh" {
    refresh_seeded
    assert_equal "$(cat "$refresh/host/canary.yaml")" "canary: rotated"
}

@test "the ciphertext the new manifest line names is seeded" {
    refresh_seeded
    assert_equal "$(cat "$refresh/host/new-token.yaml" 2>/dev/null)" "token: baked"
}

@test "the decrypt succeeds on a host that only ran the seed" {
    refresh_decrypted
    assert_equal "$rc" 0
}

@test "the newly seeded secret decrypts as the manifest's value" {
    refresh_decrypted
    assert_equal "$(cat "$refresh/run/new-token.yaml" 2>/dev/null)" "sops-decrypt-ok"
}

@test "the rotated ciphertext decrypts too" {
    refresh_decrypted
    if [[ ! -s $refresh/run/canary.yaml ]]; then
        fail "the rotated ciphertext did not decrypt"
    fi
}

@test "a second seed run is not an error" {
    refresh_reseeded
    assert_equal "$rc" 0
}

@test "an unchanged manifest is not rewritten" {
    refresh_reseeded
    assert_equal "$(stat -c %i "$refresh/host/secrets.manifest")" "$manifest_inode"
}

@test "an image without a manifest is not an error" {
    refresh_without_image_manifest
    assert_equal "$rc" 0
}

@test "an image without a manifest leaves the host copy alone" {
    refresh_without_image_manifest
    assert_equal "$(cat "$refresh/host/secrets.manifest")" "canary.yaml  $me $mg 0600"
}

# --- 8. units cannot start before the dataset is ready ------------------
# The ordering is one check per dataset in the storage table, so the table is
# read here, where bats sources this file, and not inside a test body.
# shellcheck source=/dev/null
source scripts/storage-layout.sh

backup_service=units/systemd/smortress-restic-backup@.service

ordered_after_zfs_ready() { # instance
    grep -q "zfs-ready@$1.service" "$backup_service" ||
        fail "$backup_service does not order after zfs-ready@$1.service"
}

for _key in "${dataset_order[@]}"; do
    _instance=$(readiness_instance "$_key")
    register "the backup driver is ordered after zfs-ready@$_instance" \
        ordered_after_zfs_ready "$_instance"
done
unset _key _instance

image_enables_unit() { # unit
    grep -q "$1" bootc/server/Containerfile || fail "bootc/server/Containerfile does not enable $1"
}

for _unit in var-lib-restic-ssd.mount var-lib-restic-hdd.mount \
    smortress-restic-init.service smortress-restic-backup-ssd.timer \
    smortress-restic-backup-hdd.timer smortress-restic-backup-r2.timer \
    smortress-restic-verify.timer; do
    register "the image enables $_unit" image_enables_unit "$_unit"
done
unset _unit

@test "retention keeps 14 daily, 8 weekly, 12 monthly" {
    assert_logged '--keep-daily 14 --keep-weekly 8 --keep-monthly 12' "$driver"
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
