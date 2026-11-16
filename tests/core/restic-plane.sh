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

# The harness builds its stub tree from the real group list: the verifier
# fails closed on a group with no state, so a hardcoded list here would stop
# testing whichever group was added last without failing.
mapfile -t groups < <(grep -oP '^groups=\(\K[^)]+' scripts/restic-plane-common.sh | tr ' ' '\n')

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

bin=$work/bin
install -d -m 0755 "$bin"
state=$work/state
src=$work/tank
repos=$work/repos
secrets=$work/secrets
install -d -m 0700 "$state" "$src" "$repos/ssd" "$repos/hdd" "$secrets"
for g in "${groups[@]}"; do
  install -d -m 0755 "$src/$g/.zfs/snapshot"
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
    -r|--retry-lock) i=$((i + 2)); continue ;;
    -*) i=$((i + 1)); continue ;;
    *) cmd=${args[i]}; break ;;
  esac
done
case $cmd in
  backup)
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
    path=""
    for ((j = 0; j < ${#args[@]}; j++)); do
      [[ ${args[j]} == --path ]] && path=${args[j + 1]}
    done
    rest=${path#*/tank/}
    group=${rest%%/*}
    printf '[{"id":"%s","tree":"%s","time":"%s","hostname":"smortress","paths":["%s"],"tags":["group:%s","host:smortress","verified"]}]\n' \
      "${STUB_VERIFIED_ID:-${STUB_BACKUP_ID:-strepo}}" \
      "${STUB_VERIFIED_TREE:-${STUB_BACKUP_TREE:-tree1}}" \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$path" "$group"
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
  destroy) exit "${STUB_ZFS_DESTROY_EXIT:-0}" ;;
  snapshot)
    name=${2##*@}
    ds=${2%@*}
    printf '%s\n' "$name" >>"$STUB_LOG/snapshots"
    install -d -m 0755 "$RESTIC_SOURCE_ROOT/${ds##*/}/.zfs/snapshot/$name"
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

export STUB_LOG=$log
export PATH="$bin:$PATH"
export RESTIC_BIN=$bin/restic ZFS_BIN=$bin/zfs ZFS_READY_BIN=$bin/zfs-ready CURL_BIN=$bin/curl
export RESTIC_BASE=$repos RESTIC_SOURCE_ROOT=$src RESTIC_STATE_ROOT=$state
export SMORTRESS_SECRETS_DIR=$secrets RESTIC_MOUNTINFO=$work/mountinfo
export RESTIC_ATTEMPTS=1 RESTIC_RETRY_SLEEP_LOCAL=0 RESTIC_RETRY_SLEEP_R2=0
export RESTIC_LOCK_WAIT=5 RESTIC_DEADLINE_LOCAL=20 RESTIC_DEADLINE_R2=20
export RESTIC_DEADLINE_MAINTENANCE=20

reset_state() {
  rm -rf "$state"
  install -d -m 0700 "$state"
  : >"$log/restic"; : >"$log/zfs"; : >"$log/curl-urls"; : >"$log/ready"
  unset STUB_BACKUP_EXIT STUB_BACKUP_ID STUB_TAG_EXIT STUB_ZFS_LIST_EXIT \
    STUB_SNAPSHOTS_JSON STUB_SNAPSHOTS_EXIT STUB_READY_EXIT STUB_CAT_EXIT \
    STUB_MAINT_EXIT STUB_INIT_EXIT STUB_CURL_EXIT RESTIC_HEALTHCHECK_URL
  for g in "${groups[@]}"; do
    rm -rf "$src/$g/.zfs/snapshot"/*
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
run scripts/smortress-restic-backup.sh ssd --group photos --no-maintenance
if ((rc != 0)); then ok "exit 1 is a failed run"; else bad "exit 1 is a failed run" "rc=$rc"; fi
eq "$(state_json ssd-photos '.last_attempt.result')" failure "failed run is recorded as failure"
eq "$(state_json ssd-photos '.last_attempt.reason')" exit-1 "failure reason records the exit code"
if grep -q '^tag ' "$log/restic"; then bad "no verified tag after exit 1"; else ok "no verified tag after exit 1"; fi

reset_state
export STUB_BACKUP_EXIT=3 STUB_BACKUP_ID="incomplete1"
run scripts/smortress-restic-backup.sh ssd --group photos --no-maintenance
if ((rc != 0)); then ok "exit 3 is a failed run"; else bad "exit 3 is a failed run"; fi
eq "$(state_json ssd-photos '.last_attempt.reason')" exit-3 "exit 3 keeps its own reason"
eq "$(state_json ssd-photos '.pending_reap[0]')" incomplete1 "an incomplete snapshot ID is recorded for reaping"
if grep -q '^tag ' "$log/restic"; then bad "an exit-3 snapshot is never tagged verified"; else ok "an exit-3 snapshot is never tagged verified"; fi

reset_state
export STUB_BACKUP_EXIT=0 STUB_BACKUP_ID="complete1"
run scripts/smortress-restic-backup.sh ssd --group photos --no-maintenance
eq "$rc" 0 "exit 0 succeeds"
eq "$(state_json ssd-photos '.last_attempt.result')" success "success is recorded"
eq "$(state_json ssd-photos '.final.snapshot')" complete1 "the final snapshot ID is persisted"
if grep -q -- 'tag --add verified complete1' "$log/restic"; then
  ok "the successful snapshot is tagged verified"
else
  bad "the successful snapshot is tagged verified" "$(cat "$log/restic")"
fi
if [[ ! -e $src/photos/.zfs/snapshot/ssd ]] || [[ -z $(ls -A "$src/photos/.zfs/snapshot/ssd" 2>/dev/null) ]]; then
  ok "the staging snapshot was destroyed"
else
  bad "the staging snapshot was destroyed"
fi

# restic tag rewrites the snapshot, so the id changes; recording the pre-tag id
# makes the freshness verifier report a snapshot that no longer exists.
reset_state
export STUB_BACKUP_EXIT=0 STUB_BACKUP_ID="pretag1" STUB_VERIFIED_ID="tagged1"
run scripts/smortress-restic-backup.sh ssd --group photos --no-maintenance
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
run scripts/smortress-restic-backup.sh ssd --group photos --no-maintenance
if ((rc != 0)); then ok "tagging failure fails the run"; else bad "tagging failure fails the run"; fi
eq "$(state_json ssd-photos '.last_attempt.reason')" tag-failed "tagging failure is its own reason"
eq "$(state_json ssd-photos '.pending_reap[0]')" complete2 "an untagged snapshot is reaped by recorded ID"

# restic exit 11 is a lock failure: remove only stale locks, then retry once.
reset_state
export STUB_BACKUP_EXIT=0 STUB_BACKUP_ID="lock1" STUB_VERIFIED_ID="lock1v" STUB_TAG_EXIT_ONCE=11
run scripts/smortress-restic-backup.sh ssd --group photos --no-maintenance
eq "$rc" 0 "a stale lock is retried after unlocking"
if grep -q ' unlock' "$log/restic"; then ok "stale locks are removed before the retry"; else bad "stale locks are removed before the retry"; fi
export STUB_TAG_EXIT_ONCE=""
reset_state
export STUB_BACKUP_ID="" STUB_VERIFIED_ID=""

# --- 2. stale staging reconciliation ------------------------------------
reset_state
export STUB_BACKUP_EXIT=0 STUB_BACKUP_ID="complete3" STUB_ZFS_LIST_EXIT=0
run scripts/smortress-restic-backup.sh ssd --group photos --no-maintenance
eq "$rc" 0 "a stale staging snapshot does not block the run"
if [[ $(grep -n '^destroy tank/photos@ssd' "$log/zfs" | head -n1 | cut -d: -f1) -lt \
  $(grep -n '^snapshot tank/photos@ssd' "$log/zfs" | head -n1 | cut -d: -f1) ]]; then
  ok "reconciliation destroys the stale snapshot before creating a new one"
else
  bad "reconciliation destroys the stale snapshot before creating a new one" "$(cat "$log/zfs")"
fi
if grep -q 'destroy tank/photos@hdd\|destroy tank/books@ssd' "$log/zfs"; then
  bad "a job destroys only its own staging snapshot"
else
  ok "a job destroys only its own staging snapshot"
fi

# --- 3. readiness and mount gates ---------------------------------------
reset_state
export STUB_BACKUP_EXIT=0 STUB_BACKUP_ID="should-not-happen" STUB_READY_EXIT=1
run scripts/smortress-restic-backup.sh ssd --group photos --no-maintenance
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
run scripts/smortress-restic-backup.sh ssd --group photos --no-maintenance
if ((rc != 0)); then ok "an unmounted repository path fails the job"; else bad "an unmounted repository path fails the job"; fi
eq "$(state_json ssd-photos '.last_attempt.reason')" repo-not-mounted "unmounted repository is recorded"
if grep -q '^tag ' "$log/restic"; then bad "nothing is written to an unmounted repository"; else ok "nothing is written to an unmounted repository"; fi
printf '36 25 8:1 / %s rw,relatime - ext4 /dev/sdb1 rw\n' "$repos/ssd" >>"$work/mountinfo"

# --- 4. retention filter and deletion shape -----------------------------
joined=$(sed -e :a -e '/\\$/N; s/\\\n/ /; ta' scripts/smortress-restic-backup.sh)
retention_bad=""
while IFS= read -r line; do
  [[ $line == *--keep-* ]] || continue
  [[ $line == *'--tag "group:'* || $line == *'--tag group:'* ]] || retention_bad=$line
  [[ $line == *'--tag verified'* ]] || retention_bad=$line
done <<<"$joined"
if [[ -z $retention_bad ]]; then
  ok "every retention command requires both group and verified tags"
else
  bad "every retention command requires both group and verified tags" "$retention_bad"
fi
if grep -qE -- '--keep-last|--keep-within|--keep-tag|unlock' scripts/smortress-restic-*.sh; then
  bad "retention uses no wildcard bucket and no routine unlock"
else
  ok "retention uses no wildcard bucket and no routine unlock"
fi
if grep -qE -- 'forget .*\*|rm -rf[^#]*(/var/lib/restic|/var/lib/smortress/restic)' scripts/smortress-restic-*.sh; then
  bad "no bulk deletion of snapshot sets or repository roots"
else
  ok "no bulk deletion of snapshot sets or repository roots"
fi

# --- 5. freshness verifier ----------------------------------------------
seed_state() {
  local backend=$1 group=$2
  install -d -m 0700 "$state/state" "$state/journal"
  jq -n --arg b "$backend" --arg g "$group" --arg p "$src/$group/.zfs/snapshot/$backend" \
    --arg start "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg end "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg result "${3:-success}" --argjson exit "${4:-0}" --arg snap "${5:-strepo}" '
    {schema: 1, backend: $b, group: $g, host: "smortress",
     repository: "stub", path: $p,
     last_attempt: {n: 1, start: $start, end: $end, exit: $exit,
                    result: $result, reason: "", snapshot: $snap},
     last_success: {end: $end, snapshot: $snap},
     final: {end: $end, snapshot: $snap},
     pending_reap: []}' >"$state/state/$backend-$group.json"
  jq -cn --arg result "${3:-success}" --arg snap "${5:-strepo}" \
    '{schema:1, attempt:1, result:$result, snapshot:$snap}' \
    >"$state/journal/$backend-$group.jsonl"
}

seed_all_healthy() {
  for b in ssd hdd r2; do
    for g in "${groups[@]}"; do seed_state "$b" "$g"; done
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

reset_state
seed_all_healthy
rm -f "$state/state/r2-notes.json"
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

export STUB_SOPS_PLAINTEXT=$'first: one\nsecond: two\n'
export STUB_SOPS_PLAINTEXT
run scripts/sops-decrypt.sh
if ((rc != 0)); then ok "a multi-key secret cannot be written as value"; else bad "a multi-key secret cannot be written as value"; fi

printf 'extra.yaml\n' >"$dec/src/extra.yaml"
run scripts/sops-decrypt.sh
if ((rc != 0)); then ok "an unlisted ciphertext still fails closed"; else bad "an unlisted ciphertext still fails closed"; fi
rm -f "$dec/src/extra.yaml"

# --- 8. units cannot start before the dataset is ready ------------------
svc=units/systemd/smortress-restic-backup@.service
for g in "${groups[@]}"; do
  if grep -q "zfs-ready@$g.service" "$svc"; then
    ok "the backup driver is ordered after zfs-ready@$g"
  else
    bad "the backup driver is ordered after zfs-ready@$g"
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

printf '\n%d checks, %d failed\n' "$pass" "$fail"
((fail == 0))
