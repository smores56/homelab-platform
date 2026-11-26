# The shared half of the Restic plane suite (SDLC #706): the stubs, the storage
# table, the per-test scratch tree, the drivers and every case helper the
# section files call. Split out of tests/core/restic-plane.bats so the sections
# run as parallel files; sourced with `load ./restic-plane_lib`.
# `repo_root` comes from tests/helpers.bash; the storage table is read in
# setup_file into `mounts`/`unit_keys` and the case helpers below hand on
# fixtures the section files read, so a check of this file alone cannot see
# where they come from or who uses them.
# shellcheck disable=SC2154,SC2034

driver=scripts/smortress-restic-backup.sh
init=scripts/smortress-restic-init.sh
decrypt=scripts/sops-decrypt.sh
seeder=scripts/smortress-secrets-seed.sh

# bats sources this file, and runs setup_file, inside a function, so the storage
# table's `declare -A` arrays are local to it and gone by the test body. The
# table is read once here and handed on as two plain strings, which also stops
# the stubs sourcing 550 lines on every call to derive paths this file already
# knows. Everything here is read-only for the rest of the run.
rp_setup_file() {
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
rp_setup() {
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

# exit 1 is restic's generic failure: no snapshot id to reap, and nothing to tag.
backup_exit_1() {
    export STUB_BACKUP_EXIT=1 STUB_BACKUP_ID=""
    drive "$driver" ssd --unit photos --no-maintenance
}
# exit 3 is restic's incomplete-snapshot code: the snapshot exists in the
# repository, so its id is what a later reap has to remove.
backup_exit_3() {
    export STUB_BACKUP_EXIT=3 STUB_BACKUP_ID="incomplete1"
    drive "$driver" ssd --unit photos --no-maintenance
}
backup_exit_0() {
    export STUB_BACKUP_EXIT=0 STUB_BACKUP_ID="complete1"
    drive "$driver" ssd --unit photos --no-maintenance
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
# restic tag rewrites the snapshot, so the id changes; recording the pre-tag id
# makes the freshness verifier report a snapshot that no longer exists.
backup_with_retagged_snapshot() {
    export STUB_BACKUP_EXIT=0 STUB_BACKUP_ID="pretag1" STUB_VERIFIED_ID="tagged1"
    drive "$driver" ssd --unit photos --no-maintenance
}
# A snapshot that was written but never tagged verified is not a recovery point,
# so the run has to reap it by the id it knows.
backup_with_failing_tag() {
    export STUB_BACKUP_EXIT=0 STUB_BACKUP_ID="complete2" STUB_TAG_EXIT=1
    drive "$driver" ssd --unit photos --no-maintenance
}
# restic exit 11 is a lock failure: remove only stale locks, then retry once.
backup_with_stale_lock() {
    export STUB_BACKUP_EXIT=0 STUB_BACKUP_ID="lock1" STUB_VERIFIED_ID="lock1v" STUB_TAG_EXIT_ONCE=11
    drive "$driver" ssd --unit photos --no-maintenance
}
# --- 1b. maintenance is due once a day, not once a run -------------------
# The stamps are what make forget/prune daily and the data check weekly. An
# empty stamp read as "never ran", so every hourly run pruned and read 1/30 of
# the repository: on 2026-11-26 the host logged "maintenance ok" at 10:05, 11:05
# and 12:05.
maintenance_twice() {
    export STUB_BACKUP_EXIT=0 STUB_BACKUP_ID="maint1"
    drive "$driver" ssd --unit photos
    prunes_first=$(grep -c ' prune' "$log/restic")
    checks_first=$(grep -c ' check ' "$log/restic")
    drive "$driver" ssd --unit photos
}
# --- 2. stale staging reconciliation ------------------------------------
# zfs lists a snapshot the previous run left behind, and it destroys cleanly.
run_with_stale_staging() {
    export STUB_BACKUP_EXIT=0 STUB_BACKUP_ID="complete3" STUB_ZFS_LIST_EXIT=0
    drive "$driver" ssd --unit photos --no-maintenance
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
# The staging snapshot this run created will not destroy either, but that is the
# end-of-run cleanup: the backup itself succeeded.
run_with_failing_cleanup() {
    export STUB_BACKUP_EXIT=0 STUB_BACKUP_ID="complete4" STUB_ZFS_LIST_EXIT=1 STUB_ZFS_DESTROY_FAIL_LATE=1
    busy="cannot destroy 'smortress/raw/photos@ssd': dataset is busy"
    export STUB_ZFS_STDERR=$busy
    drive "$driver" ssd --unit photos --no-maintenance
}
# --- 3. readiness and mount gates ---------------------------------------
run_with_failing_readiness() {
    export STUB_BACKUP_EXIT=0 STUB_BACKUP_ID="should-not-happen" STUB_READY_EXIT=1
    drive "$driver" ssd --unit photos --no-maintenance
}
run_with_unmounted_repository() {
    sed -i "\|$repos/ssd|d" "$work/mountinfo"
    export STUB_BACKUP_EXIT=0 STUB_BACKUP_ID="should-not-happen"
    drive "$driver" ssd --unit photos --no-maintenance
}
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
# The 970 is the preferred repository and the HDD is the fallback when it is
# absent, so "no SSD" must be a usable=false payload and not a broken query. This
# test's mountinfo is its own, so the SSD line goes and nothing is put back.
absent_ssd() {
    seed_all_healthy
    sed -i "\|$repos/ssd|d" "$work/mountinfo"
    drive scripts/smortress-restic-verify.sh --local --json
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
# stale_recorded_path_set: music's state records only raw/music, the set it
# archived before state/navidrome joined the unit.
stale_recorded_path_set() {
    seed_state ssd music
    jq --arg p "$(mount_for raw/music)/.zfs/snapshot/ssd" '.paths = [$p]' \
        "$work/state/state/ssd-music.json" >"$work/state/state/ssd-music.json.tmp" &&
        mv "$work/state/state/ssd-music.json.tmp" "$work/state/state/ssd-music.json"
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
ordered_after_zfs_ready() { # instance
    grep -q "zfs-ready@$1.service" "$backup_service" ||
        fail "$backup_service does not order after zfs-ready@$1.service"
}
image_enables_unit() { # unit
    grep -q "$1" bootc/server/Containerfile || fail "bootc/server/Containerfile does not enable $1"
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
# The deadline varies per unit, which is what the run is actually given: the
# slow first upload outlives the routine deadline, the same slowness afterwards
# does not.
slow_first_upload() {
    export STUB_BACKUP_EXIT=0 STUB_BACKUP_ID="slow1" STUB_VERIFIED_ID="slow1v" STUB_BACKUP_SLEEP=3
    drive RESTIC_DEADLINE_LOCAL=2 RESTIC_DEADLINE_FIRST_LOCAL=15 \
        "$driver" ssd --unit photos --no-maintenance
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
