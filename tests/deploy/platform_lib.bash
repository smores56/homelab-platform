# The shared half of the platform gate suite (SDLC #798, T3): the preamble
# variables, the fakes, the per-test fixture, the drivers and the assertions
# (§1a-§11 of the suite that was tests/deploy/platform.bats, split by section for
# parallel files).
#
# A platform deploy reboots the host, so the decisions the gate makes are driven
# against a throwaway state directory: which restore unit is satisfied on which
# local repository, when a backup is written and under which bounds, when the
# deploy holds instead, when an operator release waives the gate, and what the
# operator CLI reports. The local verifier, the backup driver and curl are fakes
# on PATH; the command lines, the bounds and the durable records are real.
#
# Sourced by tests/deploy/platform-*.bats through `load ./platform_lib`; bats
# sources it afresh for every test, so it only defines functions and the paths
# they read. `repo_root` comes from tests/helpers.bash, and the fixture and
# driver outputs here are read by the section files that source this one, so a
# check of this file alone sees them unassigned or unused.
# shellcheck disable=SC2154,SC2034

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
pt_setup_file() {
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

    # The gate's budget is wall clock (`date -u +%s`). A test that needs a
    # deadline to pass cannot wait for one, and cannot rely on small budgets
    # either: under load the pre-loop work alone outlives a 2 s budget, which is
    # #993. STUB_CLOCK_FILE makes `-u +%s` read a file the backup toy advances,
    # so a budget expires between two units on any host. Every other form is the
    # real date, because journal timestamps and --rfc-3339 must stay real.
    cat >"$bin/date" <<'STUB'
#!/usr/bin/env bash
if [[ -n ${STUB_CLOCK_FILE:-} && $# -eq 2 && $1 == -u && $2 == +%s ]]; then
  cat "$STUB_CLOCK_FILE"
  exit 0
fi
exec "$REAL_DATE" "$@"
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
# The virtual clock the budget tests read: advancing it stands in for a backup
# that outlived the gate's remaining budget, with no wall-clock wait.
if [[ -n ${STUB_BACKUP_ADVANCE:-} ]] &&
  [[ -z ${STUB_BACKUP_ADVANCE_UNIT:-} || ${STUB_BACKUP_ADVANCE_UNIT:-} == "$unit" ]]; then
  printf '%s\n' $(($(cat "$STUB_CLOCK_FILE") + STUB_BACKUP_ADVANCE)) >"$STUB_CLOCK_FILE"
fi
if [[ -n ${STUB_BACKUP_EXIT:-} ]] &&
  [[ -z ${STUB_BACKUP_EXIT_UNIT:-} || ${STUB_BACKUP_EXIT_UNIT:-} == "$unit" ]]; then
  exit "$STUB_BACKUP_EXIT"
fi
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

pt_setup() {
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
    # The fake `date` delegates to this, so it is resolved before $bin joins PATH.
    REAL_DATE=$(type -P date) || fail "no date on PATH"
    export REAL_DATE
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
