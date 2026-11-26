#!/usr/bin/env bats
# bats file_tags=deploy
# Offline checks for the platform snapshot gate, the hold and the break-glass
# release (SDLC #798, T3).
#
# A platform deploy reboots the host, so the decisions the gate makes are driven
# here against a throwaway state directory: which restore unit is satisfied on
# which local repository, when a backup is written and under which bounds, when
# the deploy holds instead, when an operator release waives the gate, and what
# the operator CLI reports. The local verifier, the backup driver and curl are
# fakes on PATH; the command lines, the bounds and the durable records are real.
# No root, no restic, no network, no bootc.
#
#   bats tests/deploy/platform.bats
#
# The shell suite this replaced ran every check in one process against one
# growing fixture; here each check is its own test with its own state directory
# under $BATS_TEST_TMPDIR, and the fixture a check needs is rebuilt by a helper
# named for it.
load ../helpers

platform=scripts/deploy-platform.sh
cli=scripts/deploy-cli.sh
lib=scripts/deploy-state.sh
layout=scripts/storage-layout.sh

ping_url=https://hc.invalid/ping/abc
commit=9f2c0d3b1a4e5f60718293a4b5c6d7e8f9012345
digest_index="sha256:$(printf '1%.0s' {1..64})"
digest_manifest="sha256:$(printf '2%.0s' {1..64})"
other_index="sha256:$(printf '3%.0s' {1..64})"
reconciled_digest="sha256:$(printf '4%.0s' {1..64})"
stale_digest="sha256:$(printf '5%.0s' {1..64})"
stale_commit=$(printf '1%.0s' {1..40})
crashed=$(printf '2%.0s' {1..40})
apps_commit=$(printf '2%.0s' {1..40})
bootstrap_commit=0123456789abcdef0123456789abcdef01234567
digests=$(jq -nc --arg i "$digest_index" --arg m "$digest_manifest" '{index:$i,manifest:$m}')
other_digests=$(jq -nc --arg i "$other_index" --arg m "$other_index" '{index:$i,manifest:$m}')

# --- the fakes ---------------------------------------------------------------
# They are the same for every test, so they are written once per file under
# $BATS_FILE_TMPDIR; the state directory, the logs and the verdict document they
# read are per test.
setup_file() {
    local bin=$BATS_FILE_TMPDIR/bin

    install -d -m 0755 "$bin"

    # The verifier's answer is a file: a test writes the verdict it wants, and a
    # backup that succeeds edits it, which is what "re-verify after the backup"
    # means to the gate.
    cat >"$bin/smortress-restic-verify" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG/verify-calls"
# A verifier that outlives its bound: the gate's own deadline is what has to end it.
[[ -z ${STUB_VERIFY_SLEEP:-} ]] || sleep "$STUB_VERIFY_SLEEP"
if [[ -n ${STUB_VERIFY_EXIT:-} ]]; then
  printf '{"verdict":"infra-failure","reason":"stub"}\n'
  exit "$STUB_VERIFY_EXIT"
fi
cat "$STUB_VERIFY_DOC"
STUB

    cat >"$bin/smortress-restic-backup" <<'STUB'
#!/usr/bin/env bash
printf '%s|lock=%s|%s\n' "$1" "${RESTIC_LOCK_WAIT:-unset}" "$*" >>"$STUB_LOG/backup-calls"
backend=$1
shift
unit=""
while (($#)); do
  case $1 in
    --unit) unit=$2; shift 2 ;;
    *) shift ;;
  esac
done
if [[ -n ${STUB_BACKUP_SLEEP:-} ]] &&
  [[ -z ${STUB_BACKUP_SLEEP_UNIT:-} || ${STUB_BACKUP_SLEEP_UNIT:-} == "$unit" ]]; then
  sleep "$STUB_BACKUP_SLEEP"
fi
if [[ -n ${STUB_BACKUP_EXIT:-} ]]; then exit "$STUB_BACKUP_EXIT"; fi
jq --arg b "$backend" --arg u "$unit" \
  '.[$b].units[$u] = {fresh:true,reason:"ok",snapshot:"snap",age:1}' \
  "$STUB_VERIFY_DOC" >"$STUB_VERIFY_DOC.tmp" && mv "$STUB_VERIFY_DOC.tmp" "$STUB_VERIFY_DOC"
STUB

    # Every external command the gate starts runs under `timeout`. Recording the
    # bound it is handed is the only way to assert which deadline a unit got.
    cat >"$bin/timeout" <<'STUB'
#!/usr/bin/env bash
bound=""
for a in "$@"; do
  case $a in
    --signal=*|--kill-after=*|--foreground|--preserve-status|--verbose) ;;
    *) bound=$a; break ;;
  esac
done
printf '%s|%s\n' "$bound" "$*" >>"$STUB_LOG/timeouts"
exec "$REAL_TIMEOUT" "$@"
STUB

    # deploy_notify hands the URL over as a curl config on stdin, never in argv;
    # the fake reads it from there when no argument names one.
    install -m 0755 tests/deploy/fake-curl.sh "$bin/curl"

    # `bootc status --booted --json` is the only thing a reconcile reads from the
    # host, and a stub is the only way to present a boot the record disagrees with.
    cat >"$bin/bootc" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG/bootc-calls"
if [[ ${1-} == status && -n ${STUB_BOOTC_DIGEST:-} ]]; then
  jq -nc --arg d "$STUB_BOOTC_DIGEST" '{status:{booted:{image:{imageDigest:$d}}}}'
  exit 0
fi
exit 1
STUB

    # `release --force` is a root action; the uid is faked so the test does not
    # need to be root to prove the refusal.
    install -d -m 0755 "$BATS_FILE_TMPDIR/nonroot" "$BATS_FILE_TMPDIR/uid0"
    printf '#!/usr/bin/env bash\nprintf "1000\\n"\n' >"$BATS_FILE_TMPDIR/nonroot/id"
    printf '#!/usr/bin/env bash\nprintf "0\\n"\n' >"$BATS_FILE_TMPDIR/uid0/id"
    chmod 0755 "$bin"/* "$BATS_FILE_TMPDIR/nonroot/id" "$BATS_FILE_TMPDIR/uid0/id"
}

setup() {
    local file tool name bin=$BATS_FILE_TMPDIR/bin

    work=$BATS_TEST_TMPDIR
    log=$work/log
    state_dir=$work/state
    install -d -m 0755 "$log"
    # The fakes append to these, and a test that asserts "nothing was called"
    # must find the log rather than a reader error.
    for name in verify-calls backup-calls curl-urls timeouts bootc-calls; do
        : >"$log/$name"
    done

    for file in "$platform" "$cli" "$lib" "$layout"; do
        [[ -r $file ]] || fail "$file is missing"
    done
    for tool in jq timeout; do
        command -v "$tool" >/dev/null || fail "$tool is required"
    done

    # The restore-unit table is the gate's own list: a hardcoded one here could
    # disagree with the host and leave a unit ungated.
    # shellcheck source=/dev/null
    source "$layout"

    # The fake `timeout` execs the real one, so its path is resolved before the
    # fake's directory joins PATH.
    REAL_TIMEOUT=$(type -P timeout) || fail "no timeout on PATH"
    export REAL_TIMEOUT
    export DEPLOY_STATE_DIR=$state_dir
    export DEPLOY_LOCK_FILE=$work/deploy.lock
    export DEPLOY_PING_SECRET=$work/deploy-ping-url.yaml
    # The drift check reads a glob; a test that wants drift creates the directory
    # under $work, so no check ever looks at the runner's own /etc.
    export DEPLOY_MANAGER_DROPINS="$work/etc/user@*.service.d"
    export STUB_LOG=$log
    export STUB_VERIFY_DOC=$work/verdict.json
    export FAKE_PING_LOG=$log/curl-urls
    export PATH="$bin:$PATH"
    # shellcheck source=/dev/null
    source "$lib"
    deploy_state_init || fail "deploy_state_init failed"

    reset_gate
}

# --- the fixture -------------------------------------------------------------
# Every test starts on a plane where every unit is fresh on both backends, with
# no hold, no journal and no ping secret; a check that needs anything else
# rebuilds that part of the world itself.
reset_gate() {
    local name unit
    rm -f "$state_dir/held.json" "$state_dir/journal.jsonl" "$state_dir/pending.json"
    rm -f "$DEPLOY_PING_SECRET"
    for name in verify-calls backup-calls curl-urls timeouts bootc-calls; do
        : >"$log/$name"
    done
    all_fresh=$(for unit in "${units[@]}"; do printf 'ssd:%s,hdd:%s,' "$unit" "$unit"; done)
    seed_doc true true "$all_fresh"
}

fresh_without() { # <unit>...
    local skip=$1 unit
    for unit in "${units[@]}"; do
        [[ $unit == "$skip" ]] && continue
        printf 'ssd:%s,hdd:%s,' "$unit" "$unit"
    done
}

# seed_doc <ssd-usable> <hdd-usable> <fresh-unit-list>
seed_doc() {
    jq -nc --argjson ssd "$1" --argjson hdd "$2" --arg units "${units[*]}" --arg fresh "$3" '
    def unitdoc($b):
      reduce ($units | split(" ")[]) as $u ({};
        .[$u] = (if (($fresh | split(",")) | index($b + ":" + $u)) != null
                 then {fresh: true, reason: "ok", snapshot: "snap", age: 120}
                 else {fresh: false, reason: "stale", snapshot: "snap", age: 9000} end));
    {ssd: {units: unitdoc("ssd"), usable: $ssd},
     hdd: {units: unitdoc("hdd"), usable: $hdd}}' >"$STUB_VERIFY_DOC"
}

# The gate's own record of a decision, read the way the shell suite's
# journal_field read it.
journal_field() { # <event> <jq-path>
    jq -r "select(.event==\"$1\") | $2" "$state_dir/journal.jsonl" 2>/dev/null
}

run_platform() {
    rc=0
    out=$(bash "$platform" "$@" 2>&1) || rc=$?
}

run_cli() {
    rc=0
    out=$(bash "$cli" "$@" 2>&1) || rc=$?
}

# The CLI as an operator: the faked `id` on PATH is what the CLI reads the uid
# from, and SUDO_USER is who it records.
cli_as() { # <user> <fake-id-dir> <args...>
    local user=$1 ids=$2
    shift 2
    rc=0
    out=$(SUDO_USER="$user" PATH="$BATS_FILE_TMPDIR/$ids:$PATH" bash "$cli" "$@" 2>&1) || rc=$?
}

seed_held() { # <digest> <released>
    jq -nc --arg d "$1" --arg c "$commit" --argjson rel "$2" \
        '{schema:1,digest:$d,commit:$c,digests:{index:$d,manifest:$d},
      missingUnits:["books"],reason:"no-usable-repository",
      heldAt:"2026-11-20T00:00:00Z",released:$rel}' | held_write
}

# --- the assertions ----------------------------------------------------------
# check_json's: the filter over the document a test already holds.
json_is() { # <doc> <jq-filter> <expected>
    assert_equal "$(jq -r "$2" <<<"$1" 2>/dev/null)" "$3"
}

# A file the subject never wrote is zero calls, not a reader error.
count_in() { # <file> <pattern>
    local n
    n=$(grep -c -- "$2" "$1" 2>/dev/null) || n=${n:-0}
    printf '%s\n' "${n:-0}"
}

assert_absent() { # <path>
    if [[ -e $1 ]]; then fail "$1 exists: $(cat "$1" 2>/dev/null)"; fi
}

# A log the subject must not have written to; it is the call that fails, so it is
# the call that is printed.
assert_empty() { # <path>
    assert_equal "$(cat "$1" 2>/dev/null)" ""
}

# check_match's: an ERE over text the test already holds.
assert_matches() { # <text> <ere>
    if ! grep -qE -- "$2" <<<"$1"; then fail "no /$2/ in: $1"; fi
}

# The old suite's `((rc != 0))` with the run's own output as the detail.
assert_not_green() {
    if ((rc == 0)); then fail "$out"; fi
}

# --- 1a. a host-local manager drop-in refuses the stage ----------------------
# The image ships none, and one carrying `Requires=` stops the tenant manager
# whenever the apps apply restarts the quota applier, which is how six applies
# reverted (#152). Nothing else inspects the host, so the gate does.
drifted_host() {
    install -d -m 0755 "$work/etc/user@972.service.d"
    printf '[Unit]\nRequires=smortress-apps-quota.service\n' \
        >"$work/etc/user@972.service.d/50-smortress-apps.conf"
    run_platform prepare --commit "$commit" --digests "$digests"
}

@test "a host manager drop-in refuses the deploy" {
    drifted_host
    assert_equal "$rc" 6
}

@test "the refusal names the file" {
    drifted_host
    assert_contains "$out" "user@972.service.d"
}

@test "the drift is journaled with its path" {
    drifted_host
    assert_matches "$(jq -c 'select(.event == "deploy-drift")' "$state_dir/journal.jsonl")" \
        'user@972\.service\.d'
}

@test "a drifted host is never queried for snapshots" {
    drifted_host
    assert_empty "$log/verify-calls"
}

@test "a drifted host stages nothing" {
    drifted_host
    assert_absent "$state_dir/pending.json"
}

# --- 1. a fresh plane is green and writes nothing ----------------------------
fresh_plane() {
    run_platform prepare --commit "$commit" --digests "$digests"
}

@test "an entirely fresh plane passes the gate" {
    fresh_plane
    assert_equal "$rc" 0
}

@test "a fresh plane is not backed up again" {
    fresh_plane
    assert_empty "$log/backup-calls"
}

@test "the gate asks the local verifier once" {
    fresh_plane
    assert_equal "$(count_in "$log/verify-calls" '--local --json')" 1
}

@test "the green gate journals the per-unit backend" {
    fresh_plane
    assert_equal "$(journal_field gate-green '.units.photos')" ssd
}

@test "the green gate journals the digest" {
    fresh_plane
    assert_equal "$(journal_field gate-green '.digest')" "$digest_index"
}

@test "the green gate journals the commit" {
    fresh_plane
    assert_equal "$(journal_field gate-green '.commit')" "$commit"
}

@test "a green gate writes no hold" {
    fresh_plane
    assert_absent "$state_dir/held.json"
}

@test "the gate never stages, so it writes no pending record" {
    fresh_plane
    assert_absent "$state_dir/pending.json"
}

@test "a green gate notifies nothing" {
    fresh_plane
    assert_empty "$log/curl-urls"
}

# --- 2. one missing unit is backed up once, on the preferred backend --------
# books is stale on both backends and the ping secret is present: the gate has
# exactly one unit to back up, and it must take the SSD.
one_missing_unit() {
    seed_doc true true "$(fresh_without books)"
    printf '%s\n' "$ping_url" >"$DEPLOY_PING_SECRET"
    run_platform prepare --commit "$commit" --digests "$digests"
}

@test "a backed-up unit passes the gate" {
    one_missing_unit
    assert_equal "$rc" 0
}

@test "exactly one backup for one missing unit" {
    one_missing_unit
    assert_equal "$(wc -l <"$log/backup-calls" | tr -d ' ')" 1
}

@test "the missing unit is backed up to the SSD first" {
    one_missing_unit
    assert_equal "$(cut -d'|' -f1 "$log/backup-calls")" ssd
}

@test "the backup names the unit and skips maintenance" {
    one_missing_unit
    assert_equal "$(cut -d'|' -f3 "$log/backup-calls")" "ssd --unit books --no-maintenance"
}

@test "the backup waits at most 900s for a unit lock" {
    one_missing_unit
    assert_equal "$(cut -d'|' -f2 "$log/backup-calls")" "lock=900"
}

@test "the gate is green on the backend it just wrote" {
    one_missing_unit
    assert_equal "$(journal_field gate-green '.units.books')" ssd
}

@test "the gate re-verifies after the backups" {
    one_missing_unit
    assert_equal "$(count_in "$log/verify-calls" '--local --json')" 2
}

# --- 3. an absent SSD falls back to the HDD ---------------------------------
# Neither unit is fresh and the SSD is unusable: every backup lands on the HDD.
no_usable_ssd() {
    seed_doc false true ""
    run_platform prepare --commit "$commit" --digests "$digests"
}

@test "an unusable SSD still passes on the HDD" {
    no_usable_ssd
    assert_equal "$rc" 0
}

@test "every missing unit is backed up to the HDD" {
    no_usable_ssd
    assert_equal "$(grep -c '^hdd|' "$log/backup-calls" || true)" "${#units[@]}"
}

@test "no backup is written to an unusable SSD" {
    no_usable_ssd
    assert_equal "$(grep -c '^ssd|' "$log/backup-calls" || true)" 0
}

@test "the green gate names the HDD as the backend" {
    no_usable_ssd
    assert_equal "$(journal_field gate-green '.units.files')" hdd
}

# --- 4. neither repository usable holds the deploy --------------------------
held_deploy() {
    seed_doc false false ""
    printf '%s\n' "$ping_url" >"$DEPLOY_PING_SECRET"
    run_platform prepare --commit "$commit" --digests "$digests"
    held=$(cat "$state_dir/held.json" 2>/dev/null) || held='{}'
}

@test "a hold is exit 5" {
    held_deploy
    assert_equal "$rc" 5
}

@test "a hold attempts no backup without a usable repository" {
    held_deploy
    assert_empty "$log/backup-calls"
}

@test "the hold names the digest" {
    held_deploy
    json_is "$held" .digest "$digest_index"
}

@test "the hold names the commit" {
    held_deploy
    json_is "$held" .commit "$commit"
}

@test "the hold lists every missing unit" {
    held_deploy
    json_is "$held" '.missingUnits | length' "${#units[@]}"
}

@test "the hold names the reason" {
    held_deploy
    json_is "$held" .reason no-usable-repository
}

@test "a new hold is not released" {
    held_deploy
    json_is "$held" '.released' false
}

@test "the hold records when it was taken" {
    held_deploy
    json_is "$held" '.heldAt | type' string
}

@test "the hold is journaled with its reason" {
    held_deploy
    assert_equal "$(journal_field deploy-held '.reason')" no-usable-repository
}

@test "a hold reports the failure to the deploy check" {
    held_deploy
    assert_equal "$(cat "$log/curl-urls")" "$ping_url/fail"
}

# --- 5. an exhausted budget holds instead of running on ---------------------
# The ping secret is deliberately absent here: a host mid-bootstrap has none, and
# a missing page must not turn a hold into a crash. files and books are stale and
# a backup of books outlives the 2 s budget the gate is given.
exhausted_budget() {
    seed_doc true true "$(fresh_without files)"
    jq -c '.ssd.units.books.fresh = false | .hdd.units.books.fresh = false' \
        "$STUB_VERIFY_DOC" >"$STUB_VERIFY_DOC.tmp" && mv "$STUB_VERIFY_DOC.tmp" "$STUB_VERIFY_DOC"
    rc=0
    out=$(STUB_BACKUP_SLEEP=3 STUB_BACKUP_SLEEP_UNIT=books DEPLOY_GATE_BUDGET=2 bash "$platform" \
        prepare --commit "$commit" --digests "$digests" 2>&1) || rc=$?
    held=$(cat "$state_dir/held.json" 2>/dev/null) || held='{}'
}

@test "an exhausted gate budget holds" {
    exhausted_budget
    assert_equal "$rc" 5
}

@test "the hold names the exhausted budget" {
    exhausted_budget
    json_is "$held" .reason budget-exhausted
}

@test "the hold names the unit it could not back up" {
    exhausted_budget
    json_is "$held" '.missingUnits | join(",")' books
}

@test "the first unit was backed up before the budget ran out" {
    exhausted_budget
    assert_matches "$(cat "$log/backup-calls")" '^ssd\|lock=900\|ssd --unit files'
}

@test "a hold with no ping secret is journaled as a skipped notification" {
    exhausted_budget
    assert_equal "$(journal_field notify-skipped '.kind')" fail
}

@test "no notification is sent without a ping secret" {
    exhausted_budget
    assert_empty "$log/curl-urls"
}

# --- 5b. a backup is bounded by the unit's own deadline ---------------------
# A unit that legitimately needs hours must not be cut at a flat 1800 s: the
# gate hands each backup the deadline the plane gives that unit.
per_unit_deadlines() {
    seed_doc true true "$(fresh_without books)"
    jq -c '.ssd.units["agent-local"].fresh = false
      | .hdd.units["agent-local"].fresh = false' "$STUB_VERIFY_DOC" >"$STUB_VERIFY_DOC.tmp" &&
        mv "$STUB_VERIFY_DOC.tmp" "$STUB_VERIFY_DOC"
    : >"$log/timeouts"
    rc=0
    out=$(RESTIC_DEADLINE_LOCAL_LONG=40 bash "$platform" prepare \
        --commit "$commit" --digests "$digests" 2>&1) || rc=$?
    timeouts=$(cat "$log/timeouts")
}

@test "the gate is green after backing up both units" {
    per_unit_deadlines
    assert_equal "$rc" 0
}

@test "an ordinary unit keeps the 1800 s deadline" {
    per_unit_deadlines
    assert_matches "$timeouts" '^1860\|.*--unit books'
}

@test "agent-local gets its long local deadline" {
    per_unit_deadlines
    assert_matches "$timeouts" '^100\|.*--unit agent-local'
}

# --- 6. an infrastructure failure leaves no hold ----------------------------
verifier_cannot_run() {
    rc=0
    out=$(STUB_VERIFY_EXIT=4 bash "$platform" prepare --commit "$commit" --digests "$digests" 2>&1) || rc=$?
}

@test "a verifier that cannot run is an infrastructure failure" {
    verifier_cannot_run
    assert_equal "$rc" 4
}

@test "an infrastructure failure writes no hold" {
    verifier_cannot_run
    assert_absent "$state_dir/held.json"
}

@test "an infrastructure failure attempts no backup" {
    verifier_cannot_run
    assert_empty "$log/backup-calls"
}

@test "the infrastructure failure is journaled" {
    verifier_cannot_run
    assert_equal "$(journal_field gate-infra-failure '.commit')" "$commit"
}

# --- 7. break-glass --------------------------------------------------------
# `release --force` is a root action; the uid is faked (a 1000-only `id` on PATH)
# so the test does not need to be root to prove the refusal.
refused_release() {
    seed_held "$digest_index" false
    cli_as smores nonroot release --force
    held=$(cat "$state_dir/held.json")
}

@test "a non-root release is refused" {
    refused_release
    assert_not_green
}

@test "a refused release leaves the hold un-released" {
    refused_release
    json_is "$held" '.released' false
}

@test "a refused release journals nothing" {
    refused_release
    assert_equal "$(count_in "$state_dir/journal.jsonl" gate-released-by-operator)" 0
}

root_release() {
    seed_held "$digest_index" false
    cli_as alice uid0 release --force
    held=$(cat "$state_dir/held.json" 2>/dev/null) || held='{}'
}

@test "root can release a held deploy" {
    root_release
    assert_equal "$rc" 0
}

@test "the release marks the hold released" {
    root_release
    json_is "$held" '.released' true
}

@test "the release records the operator" {
    root_release
    json_is "$held" .releasedBy alice
}

@test "the release is journaled with the operator" {
    root_release
    assert_equal "$(journal_field gate-released-by-operator '.operator')" alice
}

@test "the release is journaled with the held digest" {
    root_release
    assert_equal "$(journal_field gate-released-by-operator '.digest')" "$digest_index"
}

@test "the release is journaled with the missing units" {
    root_release
    assert_equal "$(journal_field gate-released-by-operator '.missingUnits | join(",")')" books
}

@test "the release stages nothing itself" {
    root_release
    assert_empty "$log/backup-calls"
}

# --- 8. a released digest passes the gate without a backup ------------------
release_already_released() {
    seed_held "$digest_index" true
    cli_as alice uid0 release --force
}

released_hold_gated() {
    release_already_released
    : >"$log/verify-calls"
    : >"$log/backup-calls"
    run_platform prepare --commit "$commit" --digests "$digests"
}

@test "releasing an already released hold is idempotent" {
    release_already_released
    assert_equal "$rc" 0
}

@test "a released hold passes the gate" {
    released_hold_gated
    assert_equal "$rc" 0
}

@test "the waive is journaled as gate-released" {
    released_hold_gated
    assert_equal "$(journal_field gate-released '.digest')" "$digest_index"
}

@test "a released hold writes no backup" {
    released_hold_gated
    assert_empty "$log/backup-calls"
}

@test "a released hold queries no repository" {
    released_hold_gated
    assert_empty "$log/verify-calls"
}

# A release is good for one digest only: a different image must earn its own.
other_digest_gated() {
    release_already_released
    : >"$log/verify-calls"
    : >"$state_dir/journal.jsonl"
    run_platform prepare --commit "$commit" --digests "$other_digests"
}

@test "a different digest runs the gate with a fresh plane" {
    other_digest_gated
    assert_equal "$rc" 0
}

@test "a release is never reused for a different digest" {
    other_digest_gated
    assert_equal "$(count_in "$state_dir/journal.jsonl" gate-released)" 0
}

@test "the gate records the digest it actually cleared" {
    other_digest_gated
    assert_equal "$(journal_field gate-green '.digest')" "$other_index"
}

@test "the other digest is gated on its own" {
    other_digest_gated
    assert_equal "$(count_in "$log/verify-calls" '--local --json')" 1
}

# A hold the gate has now satisfied is cleared: leaving it would make `status`
# report a deploy that is no longer held.
satisfied_hold() {
    seed_held "$digest_index" false
    run_platform prepare --commit "$commit" --digests "$digests"
}

@test "a previously held digest passes once its units are fresh" {
    satisfied_hold
    assert_equal "$rc" 0
}

@test "a satisfied hold is cleared" {
    satisfied_hold
    assert_absent "$state_dir/held.json"
}

# --- 9. the operator's status view -----------------------------------------
# One of each document `status` reads: the record, a released hold, a denylisted
# digest and a staged request.
status_view() {
    printf '%s' "$(jq -nc --arg c "$commit" --arg i "$digest_index" \
        '{schema:1,
    repos:{"homelab-platform":{commit:$c,indexDigest:$i}},
    apps:{unitsHash:"u",secretsHash:"s",apps:{alpha:{unit:"unit-hash",secrets:"secret-hash"}}},
    updated:"2026-11-20T00:00:00Z"}')" |
        atomic_write "$state_dir/state.json"
    seed_held "$digest_index" true
    jq -nc --arg d "$other_index" '{schema:1,commits:{},digests:{($d):{reason:"boot-gate",at:"2026-11-20T01:00:00Z"}}}' |
        atomic_write "$state_dir/denylist.json"
    jq -nc --arg c "$commit" --arg i "$digest_index" \
        '{phase:"staged",commit:$c,digest:$i}' | pending_write
    run_cli status
    status=$out
}

@test "status runs" {
    status_view
    assert_equal "$rc" 0
}

@test "status reports the deployed commit" {
    status_view
    json_is "$status" '.repos["homelab-platform"].commit' "$commit"
}

@test "status reports the held record" {
    status_view
    json_is "$status" '.held.digest' "$digest_index"
}

@test "status reports the pending record" {
    status_view
    json_is "$status" '.pending.phase' staged
}

@test "status reports the denylist" {
    status_view
    json_is "$status" ".denylist.digests[\"$other_index\"].reason" boot-gate
}

@test "status reports both denylist tables" {
    status_view
    json_is "$status" '.denylist.commits | type' object
}

# The apps table is what the next apply diffs against and what an operator reads
# to see which app runs which unit and secret revision; a status without it hides
# the half of the host an apps deploy owns.
@test "status reports the apps table" {
    status_view
    json_is "$status" '.apps.apps.alpha.unit' unit-hash
}

@test "status reports the whole-set unit hash" {
    status_view
    json_is "$status" '.apps.unitsHash' u
}

# --- 10. the denylist is cleared by hand ------------------------------------
# A denylisted tip stops the hourly poll and refuses every event, so the clear is
# the operator's own act: the CLI owns it, records who did it, and removes one
# entry from one table -- never the whole list.
both_denylisted() {
    jq -nc --arg d "$other_index" --arg c "$commit" '
  {schema:1,
   commits:{($c):{reason:"apps-schema",at:"2026-11-20T01:00:00Z"}},
   digests:{($d):{reason:"boot-gate",at:"2026-11-20T01:00:00Z"}}}' |
        atomic_write "$state_dir/denylist.json"
}

cleared_digest() {
    both_denylisted
    cli_as alice uid0 unblock digest "$other_index"
}

@test "a non-root unblock is refused" {
    both_denylisted
    cli_as smores nonroot unblock digest "$other_index"
    assert_equal "$rc" 1
}

@test "a refused unblock leaves the entry in place" {
    both_denylisted
    cli_as smores nonroot unblock digest "$other_index"
    run denylist_has digest "$other_index"
    assert_success
}

@test "a refused unblock journals nothing" {
    both_denylisted
    cli_as smores nonroot unblock digest "$other_index"
    assert_equal "$(count_in "$state_dir/journal.jsonl" denylist-cleared)" 0
}

@test "unblock without arguments is a usage error" {
    both_denylisted
    run_cli unblock
    assert_equal "$rc" 2
}

@test "unblock rejects an unknown table" {
    both_denylisted
    run_cli unblock tag "$commit"
    assert_equal "$rc" 2
}

@test "unblock rejects a digest where a commit belongs" {
    both_denylisted
    run_cli unblock commit "$other_index"
    assert_equal "$rc" 2
}

@test "unblock rejects a commit where a digest belongs" {
    both_denylisted
    run_cli unblock digest "$commit"
    assert_equal "$rc" 2
}

@test "root clears a denylisted digest" {
    cleared_digest
    assert_equal "$rc" 0
}

@test "the cleared digest is gone" {
    cleared_digest
    run denylist_has digest "$other_index"
    assert_failure
}

@test "clearing one table keeps the other" {
    cleared_digest
    run denylist_has commit "$commit"
    assert_success
}

@test "the clear is journaled with the operator" {
    cleared_digest
    assert_equal "$(journal_field denylist-cleared '.operator')" alice
}

@test "the clear is journaled with the table" {
    cleared_digest
    assert_equal "$(journal_field denylist-cleared '.kind')" digest
}

@test "the clear is journaled with the value" {
    cleared_digest
    assert_equal "$(journal_field denylist-cleared '.value')" "$other_index"
}

@test "clearing an entry that is not listed is refused" {
    cleared_digest
    cli_as alice uid0 unblock digest "$other_index"
    assert_equal "$rc" 1
}

# --- 10b. a crashing commit is denylisted by hand ---------------------------
# The drain retries a failed apps apply every 300 s, and an app that starts and
# then crash-loops fails every time: the verifier's refusal is what makes the
# block final, so the operator needs a way to place it -- one value, one table,
# journaled with who did it, exactly like the clear.
crashed_denylisted() {
    jq -nc --arg c "$crashed" '
  {schema:1,
   commits:{($c):{reason:"app-unhealthy",at:"2026-11-21T00:00:00Z"}},
   digests:{}}' | atomic_write "$state_dir/denylist.json"
}

blocked_commit() {
    crashed_denylisted
    cli_as alice uid0 block commit "$commit"
}

@test "a non-root block is refused" {
    crashed_denylisted
    cli_as smores nonroot block commit "$commit"
    assert_equal "$rc" 1
}

@test "a refused block denylists nothing" {
    crashed_denylisted
    cli_as smores nonroot block commit "$commit"
    run denylist_has commit "$commit"
    assert_failure
}

@test "block without arguments is a usage error" {
    crashed_denylisted
    run_cli block
    assert_equal "$rc" 2
}

@test "block rejects an unknown table" {
    crashed_denylisted
    run_cli block tag "$commit"
    assert_equal "$rc" 2
}

@test "block rejects a digest where a commit belongs" {
    crashed_denylisted
    run_cli block commit "$digest_index"
    assert_equal "$rc" 2
}

@test "block rejects a commit where a digest belongs" {
    crashed_denylisted
    run_cli block digest "$commit"
    assert_equal "$rc" 2
}

@test "root denylists a commit" {
    blocked_commit
    assert_equal "$rc" 0
}

@test "the blocked commit is listed" {
    blocked_commit
    run denylist_has commit "$commit"
    assert_success
}

@test "the block is journaled with the operator" {
    blocked_commit
    assert_equal "$(journal_field denylist-added '.operator')" alice
}

@test "the block is journaled with the table" {
    blocked_commit
    assert_equal "$(journal_field denylist-added '.kind')" commit
}

@test "the block is journaled with the value" {
    blocked_commit
    assert_equal "$(journal_field denylist-added '.value')" "$commit"
}

@test "blocking one commit keeps the others" {
    blocked_commit
    run denylist_has commit "$crashed"
    assert_success
}

@test "blocking a commit that is already listed is refused" {
    blocked_commit
    cli_as alice uid0 block commit "$commit"
    assert_equal "$rc" 1
}

# --- 10c. a record that disagrees with the boot is reconciled by hand --------
# The gate journals `booted-unrecorded` and deliberately leaves state alone, so
# the repair is the operator's: it records the digest the host actually booted,
# for the commit the operator names (a digest-pinned boot carries no commit), and
# keeps the previous value in the journal.
stale_record() {
    jq -nc --arg c "$stale_commit" --arg i "$stale_digest" --arg a "$apps_commit" '
  {schema:1,
   repos:{"homelab-platform":{commit:$c,indexDigest:$i,manifestDigest:$i},
          "homelab-apps":{commit:$a}},
   apps:{}, updated:"2026-11-21T00:00:00Z"}' | atomic_write "$state_dir/state.json"
}

# The digest the host reports it booted: present for every case but the one that
# proves a failure to read it.
booted_digest() { export STUB_BOOTC_DIGEST=$reconciled_digest; }

reconciled_record() {
    stale_record
    booted_digest
    cli_as alice uid0 reconcile --commit "$commit"
}

@test "a reconcile that cannot read the booted image exits 4" {
    stale_record
    unset STUB_BOOTC_DIGEST
    cli_as alice uid0 reconcile --commit "$commit"
    assert_equal "$rc" 4
}

@test "a failed reconcile leaves the record alone" {
    stale_record
    unset STUB_BOOTC_DIGEST
    cli_as alice uid0 reconcile --commit "$commit"
    json_is "$(state_read)" '.repos["homelab-platform"].manifestDigest' "$stale_digest"
}

@test "a non-root reconcile is refused" {
    stale_record
    booted_digest
    cli_as smores nonroot reconcile --commit "$commit"
    assert_equal "$rc" 1
}

@test "a refused reconcile leaves the commit alone" {
    stale_record
    booted_digest
    cli_as smores nonroot reconcile --commit "$commit"
    json_is "$(state_read)" '.repos["homelab-platform"].commit' "$stale_commit"
}

@test "a refused reconcile journals nothing" {
    stale_record
    booted_digest
    cli_as smores nonroot reconcile --commit "$commit"
    assert_equal "$(count_in "$state_dir/journal.jsonl" state-reconciled)" 0
}

@test "reconcile without arguments is a usage error" {
    stale_record
    run_cli reconcile
    assert_equal "$rc" 2
}

@test "reconcile takes --commit, not a bare value" {
    stale_record
    run_cli reconcile "$commit"
    assert_equal "$rc" 2
}

@test "reconcile rejects a commit that is not 40 hex" {
    stale_record
    run_cli reconcile --commit abc123
    assert_equal "$rc" 2
}

@test "root reconciles the record to the booted image" {
    reconciled_record
    assert_equal "$rc" 0
}

@test "the reconciled commit is recorded" {
    reconciled_record
    json_is "$(state_read)" '.repos["homelab-platform"].commit' "$commit"
}

@test "the booted digest is recorded" {
    reconciled_record
    json_is "$(state_read)" '.repos["homelab-platform"].manifestDigest' "$reconciled_digest"
}

@test "the stale index digest is dropped" {
    reconciled_record
    json_is "$(state_read)" '.repos["homelab-platform"] | has("indexDigest")' false
}

@test "the apps record is untouched" {
    reconciled_record
    json_is "$(state_read)" '.repos["homelab-apps"].commit' "$apps_commit"
}

@test "the reconcile is journaled with the operator" {
    reconciled_record
    assert_equal "$(journal_field state-reconciled '.operator')" alice
}

@test "the reconcile is journaled with the previous commit" {
    reconciled_record
    assert_equal "$(journal_field state-reconciled '.from')" "$stale_commit"
}

@test "the reconcile is journaled with the booted digest" {
    reconciled_record
    assert_equal "$(journal_field state-reconciled '.digest')" "$reconciled_digest"
}

@test "a reconcile does not claim a verified deployment" {
    reconciled_record
    assert_equal "$(count_in "$state_dir/journal.jsonl" state-verified)" 0
}

@test "the booted image is read, not guessed" {
    reconciled_record
    assert_contains "$(cat "$log/bootc-calls")" 'status --booted --json'
}

@test "reconciling a record that already matches is refused" {
    reconciled_record
    cli_as alice uid0 reconcile --commit "$commit"
    assert_equal "$rc" 1
}

# --- 11. a restored host is bootstrapped by hand ----------------------------
# Without a recorded ancestor there is no descendancy to check and the verifier
# refuses every deploy with `bootstrap-required`. The operator names the running
# commit once; nothing here infers it, and nothing overwrites a record.
no_state_record() { rm -f "$state_dir/state.json"; }

bootstrapped_apps() {
    no_state_record
    cli_as alice uid0 bootstrap homelab-apps "$bootstrap_commit"
}

@test "a non-root bootstrap is refused" {
    no_state_record
    cli_as smores nonroot bootstrap homelab-apps "$bootstrap_commit"
    assert_equal "$rc" 1
}

@test "a refused bootstrap writes no state" {
    no_state_record
    cli_as smores nonroot bootstrap homelab-apps "$bootstrap_commit"
    assert_absent "$state_dir/state.json"
}

@test "bootstrap without arguments is a usage error" {
    no_state_record
    run_cli bootstrap
    assert_equal "$rc" 2
}

@test "bootstrap rejects a repository the receiver does not deploy" {
    no_state_record
    run_cli bootstrap nix-config "$bootstrap_commit"
    assert_equal "$rc" 2
}

@test "bootstrap rejects a commit that is not 40 hex" {
    no_state_record
    run_cli bootstrap homelab-apps abc123
    assert_equal "$rc" 2
}

@test "root records the running commit" {
    bootstrapped_apps
    assert_equal "$rc" 0
}

@test "the bootstrapped commit is recorded" {
    bootstrapped_apps
    json_is "$(state_read)" '.repos["homelab-apps"].commit' "$bootstrap_commit"
}

@test "the bootstrap is journaled with the operator" {
    bootstrapped_apps
    assert_equal "$(journal_field bootstrap-recorded '.operator')" alice
}

@test "the bootstrap is journaled with the repository" {
    bootstrapped_apps
    assert_equal "$(journal_field bootstrap-recorded '.repo')" homelab-apps
}

@test "bootstrap never overwrites a recorded commit" {
    bootstrapped_apps
    cli_as alice uid0 bootstrap homelab-apps "$commit"
    assert_equal "$rc" 1
}

@test "the refused bootstrap leaves the record alone" {
    bootstrapped_apps
    cli_as alice uid0 bootstrap homelab-apps "$commit"
    json_is "$(state_read)" '.repos["homelab-apps"].commit' "$bootstrap_commit"
}

# A bootstrapped platform host records the commit only: the digests belong to the
# deployment the registry still serves, and a next deploy writes both forms.
platform_bootstrapped() {
    bootstrapped_apps
    cli_as alice uid0 bootstrap homelab-platform "$bootstrap_commit"
}

@test "both repositories can be bootstrapped" {
    platform_bootstrapped
    assert_equal "$rc" 0
}

@test "a bootstrap records no digest it did not observe" {
    platform_bootstrapped
    json_is "$(state_read)" '.repos["homelab-platform"] | has("indexDigest")' false
}

# An exhausted budget is one second, not no limit: `timeout 0` would hand the child
# unlimited time, which is the opposite of what a spent budget means.
exhausted_verify() {
    local started
    started=$(date -u +%s)
    rc=0
    out=$(STUB_VERIFY_SLEEP=20 DEPLOY_GATE_BUDGET=0 bash "$platform" prepare \
        --commit "$commit" --digests "$digests" 2>&1) || rc=$?
    elapsed=$(($(date -u +%s) - started))
}

# The elapsed seconds the shell suite interpolated into this check's name are the
# literal one a bounded child takes; the bound itself is asserted below.
@test "an exhausted budget bounds the child to one second (1s)" {
    exhausted_verify
    if ((elapsed >= 10)); then fail "the child ran ${elapsed}s"; fi
}

@test "an exhausted budget fails the gate instead of waiting for the child" {
    exhausted_verify
    assert_equal "$rc" 4
}

@test "the bounded child that timed out is journaled as an infrastructure failure" {
    exhausted_verify
    assert_equal "$(journal_field gate-infra-failure '.reason')" query-failed
}
