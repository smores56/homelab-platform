#!/usr/bin/env bash
# Offline checks for the Restic plane (SDLC #706, T3).
#
# The host half — real disks, real repositories, real Healthchecks — is in
# docs/manual-steps.md section 38. This proves the half that does not need root
# or a network: repository init, the sops-decrypt format column, and that no
# unit starts before its dataset is ready. restic, zfs, curl and sops are stubs;
# the command lines and the durable state are real.
#
# Fail-closed freshness, the deploy gate's local query, and the backup driver's
# own half — exit codes, stale-staging reconciliation, the readiness and mount
# gates, retention, first-upload sizing and progress publication — are
# tests/core/restic-plane.bats.
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
export RESTIC_PROGRESS_ROOT=$work/progress
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
  rm -rf "$work/progress"
  unset STUB_BACKUP_EXIT STUB_BACKUP_ID STUB_BACKUP_SLEEP STUB_BACKUP_STATUS STUB_TAG_EXIT STUB_ZFS_LIST_EXIT \
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

printf '\n%d checks, %d failed\n' "$pass" "$fail"
((fail == 0))
