#!/usr/bin/env bats
# bats file_tags=core
# The Restic plane, offline: a recorded path set that went stale.
#
# One file of the suite that was tests/core/restic-plane.bats, split so bats
# can run the sections as parallel files (a file is one job). The stubs, the
# storage table, the scratch tree, the drivers and the case helpers are in
# tests/core/restic-plane_lib.bash.
#
#   bats tests/core/restic-plane-paths.bats
load ../helpers
load ./restic-plane_lib

setup_file() { rp_setup_file; }
setup() { rp_setup; }

# --- 5b. a unit that gained a dataset reconciles its recorded paths --------
#
# The verifier reads .paths from the state the backup driver wrote, because that
# is the set actually archived. When a dataset joins a unit after it has run,
# the stored set is stale until the next successful run. Without the rewrite the
# verifier keeps comparing new snapshots against the old paths and the unit can
# never be fresh again, which holds every deploy.


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
