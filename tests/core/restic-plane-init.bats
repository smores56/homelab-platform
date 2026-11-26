#!/usr/bin/env bats
# bats file_tags=core
# The Restic plane, offline: repository init, the sops-decrypt column, the seed and the image manifest.
#
# One file of the suite that was tests/core/restic-plane.bats, split so bats
# can run the sections as parallel files (a file is one job). The stubs, the
# storage table, the scratch tree, the drivers and the case helpers are in
# tests/core/restic-plane_lib.bash.
#
#   bats tests/core/restic-plane-init.bats
load ../helpers
load ./restic-plane_lib

setup_file() { rp_setup_file; }
setup() { rp_setup; }

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


for _key in "${dataset_order[@]}"; do
    _instance=$(readiness_instance "$_key")
    register "the backup driver is ordered after zfs-ready@$_instance" \
        ordered_after_zfs_ready "$_instance"
done
unset _key _instance


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


@test "a unit with no recorded success gets one first attempt" {
    first_upload_failing
    assert_equal "$(grep -c ' backup --host' "$log/restic" || true)" 1
}

@test "the single first attempt still records its failure" {
    first_upload_failing
    assert_equal "$(state_json ssd-photos '.last_attempt.result')" failure
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
