#!/usr/bin/env bash
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
#   tests/deploy/platform.sh
# shellcheck disable=SC2154  # the storage table and its helpers are sourced below
set -uo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root" || exit 1

platform=scripts/deploy-platform.sh
cli=scripts/deploy-cli.sh
lib=scripts/deploy-state.sh
for file in "$platform" "$cli" "$lib"; do
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
check_json() { # doc filter want label
  local got
  got=$(jq -r "$2" <<<"$1" 2>/dev/null)
  check_eq "$got" "$3" "$4"
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

bin=$work/bin
log=$work/log
state_dir=$work/state
install -d -m 0755 "$bin" "$log"

# The restore-unit table is the gate's own list: a hardcoded one here could
# disagree with the host and leave a unit ungated.
# shellcheck source=/dev/null
source scripts/storage-layout.sh

ping_url=https://hc.invalid/ping/abc
export DEPLOY_STATE_DIR=$state_dir
export DEPLOY_LOCK_FILE=$work/deploy.lock
export DEPLOY_PING_SECRET=$work/deploy-ping-url.yaml
export STUB_LOG=$log
export STUB_VERIFY_DOC=$work/verdict.json
export PATH="$bin:$PATH"
# shellcheck source=/dev/null
source "$lib"
deploy_state_init || exit 1

digest_index=sha256:1111111111111111111111111111111111111111111111111111111111111111
digest_manifest=sha256:2222222222222222222222222222222222222222222222222222222222222222
other_index=sha256:3333333333333333333333333333333333333333333333333333333333333333
commit=9f2c0d3b1a4e5f60718293a4b5c6d7e8f9012345
digests=$(jq -nc --arg i "$digest_index" --arg m "$digest_manifest" '{index:$i,manifest:$m}')
other_digests=$(jq -nc --arg i "$other_index" --arg m "$other_index" '{index:$i,manifest:$m}')

: >"$log/verify-calls"
: >"$log/backup-calls"
: >"$log/curl-urls"

# --- the fakes ---------------------------------------------------------------
# The verifier's answer is a file: a test writes the verdict it wants, and a
# backup that succeeds edits it, which is what "re-verify after the backup"
# means to the gate.
cat >"$bin/smortress-restic-verify" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG/verify-calls"
if [[ -n ${STUB_VERIFY_EXIT:-} ]]; then
  printf '{"verdict":"infra-failure","reason":"stub"}\n'
  exit "$STUB_VERIFY_EXIT"
fi
cat "$STUB_VERIFY_DOC"
EOF

cat >"$bin/smortress-restic-backup" <<'EOF'
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
EOF

cat >"$bin/curl" <<'EOF'
#!/usr/bin/env bash
url=""
for a in "$@"; do url=$a; done
printf '%s\n' "$url" >>"$STUB_LOG/curl-urls"
exit "${STUB_CURL_EXIT:-0}"
EOF

# `release --force` is a root action; the uid is faked so the test does not need
# to be root to prove the refusal.
install -d -m 0755 "$work/nonroot" "$work/uid0"
printf '#!/usr/bin/env bash\nprintf "1000\\n"\n' >"$work/nonroot/id"
printf '#!/usr/bin/env bash\nprintf "0\\n"\n' >"$work/uid0/id"
chmod 0755 "$bin"/* "$work/nonroot/id" "$work/uid0/id"

# --- the scenario ------------------------------------------------------------
all_fresh=$(for u in "${units[@]}"; do printf 'ssd:%s,hdd:%s,' "$u" "$u"; done)

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

reset_gate() {
  rm -f "$state_dir/held.json" "$state_dir/journal.jsonl" "$state_dir/pending.json"
  rm -f "$DEPLOY_PING_SECRET"
  : >"$log/verify-calls"
  : >"$log/backup-calls"
  : >"$log/curl-urls"
  unset STUB_VERIFY_EXIT STUB_BACKUP_EXIT STUB_BACKUP_SLEEP STUB_CURL_EXIT
  seed_doc true true "$all_fresh"
}

run_platform() {
  out=$(bash "$platform" "$@" 2>&1)
  rc=$?
}

run_cli() {
  out=$(bash "$cli" "$@" 2>&1)
  rc=$?
}

journal_field() { # <event> <jq path>
  jq -r "select(.event==\"$1\") | $2" "$state_dir/journal.jsonl" 2>/dev/null
}

seed_held() { # <digest> <released>
  jq -nc --arg d "$1" --arg c "$commit" --argjson rel "$2" \
    '{schema:1,digest:$d,commit:$c,digests:{index:$d,manifest:$d},
      missingUnits:["books"],reason:"no-usable-repository",
      heldAt:"2026-11-20T00:00:00Z",released:$rel}' | held_write
}

# --- 1. a fresh plane is green and writes nothing ----------------------------
reset_gate
run_platform prepare --commit "$commit" --digests "$digests"
check_eq "$rc" 0 "an entirely fresh plane passes the gate"
if [[ -s $log/backup-calls ]]; then
  bad "a fresh plane is not backed up again" "$(cat "$log/backup-calls")"
else
  ok "a fresh plane is not backed up again"
fi
check_eq "$(grep -c -- '--local --json' "$log/verify-calls")" 1 \
  "the gate asks the local verifier once"
check_eq "$(journal_field gate-green '.units.photos')" ssd "the green gate journals the per-unit backend"
check_eq "$(journal_field gate-green '.digest')" "$digest_index" "the green gate journals the digest"
check_eq "$(journal_field gate-green '.commit')" "$commit" "the green gate journals the commit"
if [[ -e $state_dir/held.json ]]; then bad "a green gate writes no hold"; else ok "a green gate writes no hold"; fi
if [[ -e $state_dir/pending.json ]]; then
  bad "the gate never stages, so it writes no pending record"
else
  ok "the gate never stages, so it writes no pending record"
fi
if [[ -s $log/curl-urls ]]; then bad "a green gate notifies nothing"; else ok "a green gate notifies nothing"; fi

# --- 2. one missing unit is backed up once, on the preferred backend --------
reset_gate
seed_doc true true "$(fresh_without books)"
printf '%s\n' "$ping_url" >"$DEPLOY_PING_SECRET"
run_platform prepare --commit "$commit" --digests "$digests"
check_eq "$rc" 0 "a backed-up unit passes the gate"
check_eq "$(wc -l <"$log/backup-calls" | tr -d ' ')" 1 "exactly one backup for one missing unit"
check_eq "$(cut -d'|' -f1 "$log/backup-calls")" ssd "the missing unit is backed up to the SSD first"
check_eq "$(cut -d'|' -f3 "$log/backup-calls")" "ssd --unit books --no-maintenance" \
  "the backup names the unit and skips maintenance"
check_eq "$(cut -d'|' -f2 "$log/backup-calls")" "lock=900" \
  "the backup waits at most 900s for a unit lock"
check_eq "$(journal_field gate-green '.units.books')" ssd "the gate is green on the backend it just wrote"
check_eq "$(grep -c -- '--local --json' "$log/verify-calls")" 2 "the gate re-verifies after the backups"

# --- 3. an absent SSD falls back to the HDD ---------------------------------
reset_gate
seed_doc false true ""
run_platform prepare --commit "$commit" --digests "$digests"
check_eq "$rc" 0 "an unusable SSD still passes on the HDD"
check_eq "$(grep -c '^hdd|' "$log/backup-calls")" "${#units[@]}" "every missing unit is backed up to the HDD"
if grep -q '^ssd|' "$log/backup-calls"; then
  bad "no backup is written to an unusable SSD" "$(cat "$log/backup-calls")"
else
  ok "no backup is written to an unusable SSD"
fi
check_eq "$(journal_field gate-green '.units.files')" hdd "the green gate names the HDD as the backend"

# --- 4. neither repository usable holds the deploy --------------------------
reset_gate
seed_doc false false ""
printf '%s\n' "$ping_url" >"$DEPLOY_PING_SECRET"
run_platform prepare --commit "$commit" --digests "$digests"
check_eq "$rc" 5 "a hold is exit 5"
if [[ -s $log/backup-calls ]]; then
  bad "a hold attempts no backup without a usable repository"
else
  ok "a hold attempts no backup without a usable repository"
fi
held=$(cat "$state_dir/held.json" 2>/dev/null) || held='{}'
check_json "$held" .digest "$digest_index" "the hold names the digest"
check_json "$held" .commit "$commit" "the hold names the commit"
check_json "$held" '.missingUnits | length' "${#units[@]}" "the hold lists every missing unit"
check_json "$held" .reason no-usable-repository "the hold names the reason"
check_json "$held" '.released' false "a new hold is not released"
check_json "$held" '.heldAt | type' string "the hold records when it was taken"
check_eq "$(journal_field deploy-held '.reason')" no-usable-repository "the hold is journaled with its reason"
check_eq "$(cat "$log/curl-urls")" "$ping_url/fail" "a hold reports the failure to the deploy check"

# --- 5. an exhausted budget holds instead of running on ---------------------
# The ping secret is deliberately absent here: a host mid-bootstrap has none, and
# a missing page must not turn a hold into a crash.
reset_gate
seed_doc true true "$(fresh_without files)"
jq -c '.ssd.units.books.fresh = false | .hdd.units.books.fresh = false' \
  "$STUB_VERIFY_DOC" >"$STUB_VERIFY_DOC.tmp" && mv "$STUB_VERIFY_DOC.tmp" "$STUB_VERIFY_DOC"
STUB_BACKUP_SLEEP=3 STUB_BACKUP_SLEEP_UNIT=books DEPLOY_GATE_BUDGET=2 bash "$platform" \
  prepare --commit "$commit" --digests "$digests" >"$work/budget.out" 2>&1
rc=$?
check_eq "$rc" 5 "an exhausted gate budget holds"
check_json "$(cat "$state_dir/held.json" 2>/dev/null || printf '{}')" .reason budget-exhausted \
  "the hold names the exhausted budget"
check_json "$(cat "$state_dir/held.json" 2>/dev/null || printf '{}')" \
  '.missingUnits | join(",")' books "the hold names the unit it could not back up"
if grep -q '^ssd|lock=900|ssd --unit files' "$log/backup-calls"; then
  ok "the first unit was backed up before the budget ran out"
else
  bad "the first unit was backed up before the budget ran out" "$(cat "$log/backup-calls")"
fi
check_eq "$(journal_field notify-skipped '.kind')" fail \
  "a hold with no ping secret is journaled as a skipped notification"
if [[ -s $log/curl-urls ]]; then
  bad "no notification is sent without a ping secret" "$(cat "$log/curl-urls")"
else
  ok "no notification is sent without a ping secret"
fi

# --- 6. an infrastructure failure leaves no hold ----------------------------
reset_gate
out=$(STUB_VERIFY_EXIT=4 bash "$platform" prepare --commit "$commit" --digests "$digests" 2>&1)
rc=$?
check_eq "$rc" 4 "a verifier that cannot run is an infrastructure failure"
if [[ -e $state_dir/held.json ]]; then
  bad "an infrastructure failure writes no hold"
else
  ok "an infrastructure failure writes no hold"
fi
if [[ -s $log/backup-calls ]]; then
  bad "an infrastructure failure attempts no backup"
else
  ok "an infrastructure failure attempts no backup"
fi
check_eq "$(journal_field gate-infra-failure '.commit')" "$commit" \
  "the infrastructure failure is journaled"
unset STUB_VERIFY_EXIT

# --- 7. break-glass --------------------------------------------------------
reset_gate
seed_held "$digest_index" false
out=$(SUDO_USER=smores PATH="$work/nonroot:$PATH" bash "$cli" release --force 2>&1)
rc=$?
if ((rc != 0)); then ok "a non-root release is refused"; else bad "a non-root release is refused" "$out"; fi
check_json "$(cat "$state_dir/held.json")" '.released' false "a refused release leaves the hold un-released"
if grep -q gate-released-by-operator "$state_dir/journal.jsonl" 2>/dev/null; then
  bad "a refused release journals nothing"
else
  ok "a refused release journals nothing"
fi

reset_gate
seed_held "$digest_index" false
out=$(SUDO_USER=alice PATH="$work/uid0:$PATH" bash "$cli" release --force 2>&1)
rc=$?
check_eq "$rc" 0 "root can release a held deploy"
held=$(cat "$state_dir/held.json")
check_json "$held" '.released' true "the release marks the hold released"
check_json "$held" .releasedBy alice "the release records the operator"
check_eq "$(journal_field gate-released-by-operator '.operator')" alice "the release is journaled with the operator"
check_eq "$(journal_field gate-released-by-operator '.digest')" "$digest_index" \
  "the release is journaled with the held digest"
check_eq "$(journal_field gate-released-by-operator '.missingUnits | join(",")')" books \
  "the release is journaled with the missing units"
if [[ -s $log/backup-calls ]]; then bad "the release stages nothing itself"; else ok "the release stages nothing itself"; fi

# --- 8. a released digest passes the gate without a backup ------------------
reset_gate
seed_held "$digest_index" true
out=$(PATH="$work/uid0:$PATH" SUDO_USER=alice bash "$cli" release --force 2>&1)
rc=$?
check_eq "$rc" 0 "releasing an already released hold is idempotent"
: >"$log/verify-calls"
: >"$log/backup-calls"
run_platform prepare --commit "$commit" --digests "$digests"
check_eq "$rc" 0 "a released hold passes the gate"
check_eq "$(journal_field gate-released '.digest')" "$digest_index" "the waive is journaled as gate-released"
if [[ -s $log/backup-calls ]]; then bad "a released hold writes no backup"; else ok "a released hold writes no backup"; fi
if [[ -s $log/verify-calls ]]; then bad "a released hold queries no repository"; else ok "a released hold queries no repository"; fi

# A release is good for one digest only: a different image must earn its own.
: >"$log/verify-calls"
: >"$state_dir/journal.jsonl"
out=$(bash "$platform" prepare --commit "$commit" --digests "$other_digests" 2>&1)
rc=$?
check_eq "$rc" 0 "a different digest runs the gate with a fresh plane"
if grep -q '"event":"gate-released"' "$state_dir/journal.jsonl"; then
  bad "a release is never reused for a different digest"
else
  ok "a release is never reused for a different digest"
fi
check_eq "$(journal_field gate-green '.digest')" "$other_index" \
  "the gate records the digest it actually cleared"
check_eq "$(grep -c -- '--local --json' "$log/verify-calls")" 1 \
  "the other digest is gated on its own"

# A hold the gate has now satisfied is cleared: leaving it would make `status`
# report a deploy that is no longer held.
reset_gate
seed_held "$digest_index" false
run_platform prepare --commit "$commit" --digests "$digests"
check_eq "$rc" 0 "a previously held digest passes once its units are fresh"
if [[ -e $state_dir/held.json ]]; then
  bad "a satisfied hold is cleared" "$(cat "$state_dir/held.json")"
else
  ok "a satisfied hold is cleared"
fi

# --- 9. the operator's status view -----------------------------------------
reset_gate
printf '%s' "$(jq -nc --arg c "$commit" --arg i "$digest_index" \
  '{schema:1,repos:{"homelab-platform":{commit:$c,indexDigest:$i}},apps:{},updated:"2026-11-20T00:00:00Z"}')" |
  atomic_write "$state_dir/state.json"
seed_held "$digest_index" true
jq -nc --arg d "$other_index" '{schema:1,commits:{},digests:{($d):{reason:"boot-gate",at:"2026-11-20T01:00:00Z"}}}' |
  atomic_write "$state_dir/denylist.json"
jq -nc --arg c "$commit" --arg i "$digest_index" \
  '{phase:"staged",commit:$c,digest:$i,budget:3}' | pending_write
run_cli status
check_eq "$rc" 0 "status runs"
status=$out
check_json "$status" '.repos["homelab-platform"].commit' "$commit" "status reports the deployed commit"
check_json "$status" '.held.digest' "$digest_index" "status reports the held record"
check_json "$status" '.pending.phase' staged "status reports the pending record"
check_json "$status" ".denylist.digests[\"$other_index\"].reason" boot-gate \
  "status reports the denylist"
check_json "$status" '.denylist.commits | type' object "status reports both denylist tables"
pending_clear

# --- 10. the denylist is cleared by hand ------------------------------------
# A denylisted tip stops the hourly poll and refuses every event, so the clear is
# the operator's own act: the CLI owns it, records who did it, and removes one
# entry from one table -- never the whole list.
reset_gate
jq -nc --arg d "$other_index" --arg c "$commit" '
  {schema:1,
   commits:{($c):{reason:"apps-schema",at:"2026-11-20T01:00:00Z"}},
   digests:{($d):{reason:"boot-gate",at:"2026-11-20T01:00:00Z"}}}' |
  atomic_write "$state_dir/denylist.json"

out=$(SUDO_USER=smores PATH="$work/nonroot:$PATH" bash "$cli" unblock digest "$other_index" 2>&1)
rc=$?
check_eq "$rc" 1 "a non-root unblock is refused"
if denylist_has digest "$other_index"; then ok "a refused unblock leaves the entry in place"; else
  bad "a refused unblock leaves the entry in place"
fi
if grep -q denylist-cleared "$state_dir/journal.jsonl" 2>/dev/null; then
  bad "a refused unblock journals nothing"
else
  ok "a refused unblock journals nothing"
fi

run_cli unblock
check_eq "$rc" 2 "unblock without arguments is a usage error"
run_cli unblock tag "$commit"
check_eq "$rc" 2 "unblock rejects an unknown table"
run_cli unblock commit "$other_index"
check_eq "$rc" 2 "unblock rejects a digest where a commit belongs"
run_cli unblock digest "$commit"
check_eq "$rc" 2 "unblock rejects a commit where a digest belongs"
out=$(PATH="$work/uid0:$PATH" SUDO_USER=alice bash "$cli" unblock digest "$other_index" 2>&1)
rc=$?
check_eq "$rc" 0 "root clears a denylisted digest"
if denylist_has digest "$other_index"; then bad "the cleared digest is gone"; else
  ok "the cleared digest is gone"
fi
if denylist_has commit "$commit"; then ok "clearing one table keeps the other"; else
  bad "clearing one table keeps the other"
fi
check_eq "$(journal_field denylist-cleared '.operator')" alice \
  "the clear is journaled with the operator"
check_eq "$(journal_field denylist-cleared '.kind')" digest "the clear is journaled with the table"
check_eq "$(journal_field denylist-cleared '.value')" "$other_index" \
  "the clear is journaled with the value"

out=$(PATH="$work/uid0:$PATH" SUDO_USER=alice bash "$cli" unblock digest "$other_index" 2>&1)
rc=$?
check_eq "$rc" 1 "clearing an entry that is not listed is refused"

# --- 11. a restored host is bootstrapped by hand ----------------------------
# Without a recorded ancestor there is no descendancy to check and the verifier
# refuses every deploy with `bootstrap-required`. The operator names the running
# commit once; nothing here infers it, and nothing overwrites a record.
reset_gate
rm -f "$state_dir/state.json"
bootstrap_commit=0123456789abcdef0123456789abcdef01234567

out=$(SUDO_USER=smores PATH="$work/nonroot:$PATH" bash "$cli" bootstrap homelab-apps \
  "$bootstrap_commit" 2>&1)
rc=$?
check_eq "$rc" 1 "a non-root bootstrap is refused"
if [[ -e $state_dir/state.json ]]; then bad "a refused bootstrap writes no state"; else
  ok "a refused bootstrap writes no state"
fi

run_cli bootstrap
check_eq "$rc" 2 "bootstrap without arguments is a usage error"
run_cli bootstrap nix-config "$bootstrap_commit"
check_eq "$rc" 2 "bootstrap rejects a repository the receiver does not deploy"
run_cli bootstrap homelab-apps abc123
check_eq "$rc" 2 "bootstrap rejects a commit that is not 40 hex"

out=$(PATH="$work/uid0:$PATH" SUDO_USER=alice bash "$cli" bootstrap homelab-apps \
  "$bootstrap_commit" 2>&1)
rc=$?
check_eq "$rc" 0 "root records the running commit"
check_json "$(state_read)" '.repos["homelab-apps"].commit' "$bootstrap_commit" \
  "the bootstrapped commit is recorded"
check_eq "$(journal_field bootstrap-recorded '.operator')" alice \
  "the bootstrap is journaled with the operator"
check_eq "$(journal_field bootstrap-recorded '.repo')" homelab-apps \
  "the bootstrap is journaled with the repository"

out=$(PATH="$work/uid0:$PATH" SUDO_USER=alice bash "$cli" bootstrap homelab-apps \
  "$commit" 2>&1)
rc=$?
check_eq "$rc" 1 "bootstrap never overwrites a recorded commit"
check_json "$(state_read)" '.repos["homelab-apps"].commit' "$bootstrap_commit" \
  "the refused bootstrap leaves the record alone"

# A bootstrapped platform host records the commit only: the digests belong to the
# deployment the registry still serves, and a next deploy writes both forms.
out=$(PATH="$work/uid0:$PATH" SUDO_USER=alice bash "$cli" bootstrap homelab-platform \
  "$bootstrap_commit" 2>&1)
rc=$?
check_eq "$rc" 0 "both repositories can be bootstrapped"
check_json "$(state_read)" '.repos["homelab-platform"] | has("indexDigest")' false \
  "a bootstrap records no digest it did not observe"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
