#!/usr/bin/env bats
# bats file_tags=deploy
# The apps apply and its revert: the drain, the work-tree sweep, forged names and the schema guards (§11-§16).
#
# One file of the suite that was tests/deploy/apps.sh, split so bats can run the
# sections in parallel (a single file is one job). The fakes, the published
# commits, the fixture, the drivers and the assertions are in apps_lib.bash.
#
#   bats tests/deploy/apps-guard.bats
load ../helpers
load ./apps_lib

setup_file() { apps_setup_file; }
setup() { apps_setup; }
# --- 11. an interrupted apply is reverted by the drain and by the boot gate ---
# The state a killed process leaves: apply.json, the new plan and units already
# installed, one secret already replaced, and the previous revision saved under
# work/render.prev. Both entry points must put all of it back, so the two trees
# stage the same crash state and stay one test: a replay per assertion would
# stage it again for a check that reads the other entry point's aftermath.
@test "the drain exits after reverting the interrupted apply (§11: drain and boot gate)" {
    fixture
    run_apply "$c_v1"
    plan_before=$(sha "$APPS_PLAN")
    unit_before=$(sha "$APPS_UNIT_DIR/alpha.container")
    state_before=$(sha "$state_dir/state.json")
    stage_interrupted "$c_v2" "$trees/$c_v2/homelab-apps-$c_v2"
    same "$(sha "$APPS_PLAN")" "$(sha "$state_dir/work/apps-$c_v2/render.next/plan.json")" \
        "the interrupted apply left the new plan installed"
    : >"$log/actions"
    run_drain
    same "$rc" 0 "the drain exits after reverting the interrupted apply"
    same "$(sha "$APPS_PLAN")" "$plan_before" "the drain restores the previous plan"
    same "$(sha "$APPS_UNIT_DIR/alpha.container")" "$unit_before" \
        "the drain restores the previous unit"
    same "$(cat "$secret_store/app-alpha-api-key")" one "the drain restores the previous secret"
    same "$(sha "$state_dir/state.json")" "$state_before" "the drain restores the previous state"
    absent "$state_dir/apply.json" "the drain clears the crash record"
    same "$(journal_field apply-reverted '.by')" drain "the drain journals the reverted apply"
    in_file "$log/actions" 'system restart smortress-tailscale-serve.service' \
        "the drain regenerates Serve after the revert"

    reset_case
    run_apply "$c_v1"
    plan_before=$(sha "$APPS_PLAN")
    unit_before=$(sha "$APPS_UNIT_DIR/alpha.container")
    state_before=$(sha "$state_dir/state.json")
    stage_interrupted "$c_v2" "$trees/$c_v2/homelab-apps-$c_v2"
    : >"$log/actions"
    : >"$log/bootc-calls"
    run_gate
    same "$rc" 0 "the boot gate passes on a boot with no pending deploy"
    same "$(sha "$APPS_PLAN")" "$plan_before" "the gate restores the previous plan"
    same "$(sha "$APPS_UNIT_DIR/alpha.container")" "$unit_before" \
        "the gate restores the previous unit"
    same "$(cat "$secret_store/app-alpha-api-key")" one "the gate restores the previous secret"
    same "$(sha "$state_dir/state.json")" "$state_before" "the gate restores the previous state"
    absent "$state_dir/apply.json" "the gate clears the crash record"
    same "$(journal_field apply-interrupted '.phase')" installing \
        "the gate journals the interrupted phase it found"
    same "$(journal_field apply-reverted '.by')" boot-gate \
        "the gate journals the reverted apply"
    # The gate reads the booted digest even here, so a boot state.json does not
    # name is noticed (tests/deploy/apps.bats owns that check); it must not switch
    # or roll back on a boot with no pending deployment.
    not_matching "$log/bootc-calls" '^(switch|rollback)' \
        "a boot with no pending deploy switches nothing"
}

# --- 11b. work trees do not outlive their apply ----------------------------
# A work tree holds the decrypted tenant secrets, so an exit that is not the
# revert path has to take it with it -- including the exits nobody wrote a branch
# for, which is what the trap on the way out is for. The three blocks below stay
# one test: each reads only the tree and the sweep journal it just wrote, and a
# replay per text would lay down the same plaintext work trees again.
@test "a failed apply takes its work tree with it (§11b: work-tree lifetime)" {
    fixture
    mkdir -p "$state_dir/work/apps-$c_v1/tree"
    printf '{"apps":{}}\n' >"$state_dir/work/apps-$c_v1/tree/secrets.json"
    printf 'plaintext\n' >"$state_dir/work/apps-$c_v1/secrets.json"
    # A journal that cannot be appended stops the apply before its first mutation.
    rm -f "$state_dir/journal.jsonl"
    mkdir -p "$state_dir/journal.jsonl"
    run_apply "$c_v1"
    rmdir "$state_dir/journal.jsonl"
    same "$rc" 4 "an exit before the first mutation exits 4"
    absent "$state_dir/work/apps-$c_v1" "a failed apply takes its work tree with it"

    # A tree an interrupted apply left behind is plaintext nothing will clean up, and
    # an unbounded state directory is a leak that grows with every failed deploy.
    reset_case
    run_apply "$c_v1"
    mkdir -p "$state_dir/work/apps-$c_pull/tree"
    printf '{"apps":{}}\n' >"$state_dir/work/apps-$c_pull/tree/secrets.json"
    printf 'plaintext\n' >"$state_dir/work/apps-$c_pull/secrets.json"
    touch -d '3 days ago' "$state_dir/work/apps-$c_pull"
    # The tree apply.json still names is the crash state a revert restores from: it
    # stays, however old it is.
    mkdir -p "$state_dir/work/apps-$c_v2/render.prev"
    jq -nc --arg work "$state_dir/work/apps-$c_v2" \
        '{schema:1,phase:"installing",commit:"'"$c_v2"'",work:$work,
          previousUnits:[],intendedUnits:[],previousPlan:true,previousState:true,
          previousSecrets:{},intendedSecrets:[],startedAt:"2026-11-21T00:00:00Z"}' | apply_write
    touch -d '3 days ago' "$state_dir/work/apps-$c_v2"
    run_sweep
    same "$rc" 0 "the sweep succeeds"
    absent "$state_dir/work/apps-$c_pull" "a stale work tree is swept"
    [[ -d $state_dir/work/apps-$c_v2/render.prev ]] ||
        fail "the tree apply.json names survives the sweep: $(find "$state_dir/work")"
    same "$(journal_field apps-work-swept '.removed')" 1 "the swept tree is journaled"

    # A tree younger than the grace period is a deploy that may still be in flight.
    reset_case
    run_apply "$c_v1"
    mkdir -p "$state_dir/work/apps-$c_changed"
    printf 'plaintext\n' >"$state_dir/work/apps-$c_changed/secrets.json"
    run_sweep
    [[ -d $state_dir/work/apps-$c_changed ]] || fail "a young work tree is left alone"
}

# --- 12. a revert with no record is a no-op ---------------------------------
revert_with_no_record() {
    fixture
    : >"$log/actions"
    run_revert
}

@test "a revert with no record is a no-op" {
    revert_with_no_record
    assert_equal "$rc" 0
}

@test "a no-op revert touches nothing" {
    revert_with_no_record
    assert [ ! -s "$log/actions" ]
}

# --- 13. a forged app name never reaches a unit instance ---------------------
# The tenant's own unit directory is not a trusted source of names: a file with
# the render marker in it is taken as an installed app, so a forged one lands in
# the departed set. It must be refused and journaled, never spelled into a root
# `systemctl` line or a path under the tenant's home.
apply_a_forged_unit_name() {
    fixture
    run_apply "$c_v1"
    same "$rc" 0 "the base revision applies before the forged unit"
    forged='x;reboot'
    printf '# Rendered from apps/forged/app.toml\n[Container]\nImage=ghcr.io/example/alpha@%s\n' "$d_a" \
        >"$APPS_UNIT_DIR/$forged.container"
    : >"$log/actions"
    : >"$state_dir/journal.jsonl"
    run_apply "$c_empty"
}

@test "an apply that meets a forged unit name rolls back" {
    apply_a_forged_unit_name
    assert_equal "$rc" 5
}

@test "the forged name is journaled" {
    apply_a_forged_unit_name
    assert_equal "$(journal_field apps-name-refused '.name' | head -n 1)" "$forged"
}

@test "the refusal names the sink it was refused at" {
    apply_a_forged_unit_name
    assert_equal "$(journal_field apps-name-refused '.sink' | head -n 1)" remove-departed-unit
}

@test "the forged name never reaches a unit command" {
    apply_a_forged_unit_name
    refute grep -qF -- "$forged" "$log/actions"
}

# The revert cannot restore a unit whose name this deploy would never write, so it
# says so and keeps the record instead of claiming the revision is back.
@test "the incomplete revert is journaled as such" {
    apply_a_forged_unit_name
    assert_equal "$(journal_field apps-revert-failed '.reason' | tail -n 1)" restore-incomplete
}

@test "an incomplete revert keeps the crash record" {
    apply_a_forged_unit_name
    assert [ -s "$state_dir/apply.json" ]
}

# --- 14. only this deploy's own work trees are removed ----------------------
# The path a sweep or a revert removes is named by `apply.json`, which an operator
# can edit, and by a glob over the work directory. The shape is checked on the
# canonical path: a symlink out of the tree, a name that is not a commit, and a
# traversal that resolves elsewhere all survive.
sweep_foreign_work_trees() {
    fixture
    run_apply "$c_v1"
    outside=$work/outside
    mkdir -p "$outside/render.prev" "$state_dir/work/apps-notacommit"
    printf 'keep\n' >"$outside/render.prev/plan.json"
    printf 'keep\n' >"$state_dir/work/apps-notacommit/keep"
    ln -s "$outside" "$state_dir/work/apps-$c_changed"
    touch -h -d '3 days ago' "$state_dir/work/apps-notacommit" "$state_dir/work/apps-$c_changed"
    run_sweep
}

@test "the sweep survives the trees it refuses" {
    sweep_foreign_work_trees
    assert_equal "$rc" 0
}

@test "a symlinked work tree is not followed out of the work directory" {
    sweep_foreign_work_trees
    assert [ -d "$outside/render.prev" ]
}

@test "the refused symlink itself stays" {
    sweep_foreign_work_trees
    assert [ -L "$state_dir/work/apps-$c_changed" ]
}

@test "a directory that is not a commit tree stays" {
    sweep_foreign_work_trees
    assert [ -d "$state_dir/work/apps-notacommit" ]
}

@test "the sweep removes nothing it refused" {
    sweep_foreign_work_trees
    assert_equal "$(journal_field apps-work-swept '.removed')" 0
}

@test "the sweep journals the trees it refused" {
    sweep_foreign_work_trees
    assert_equal "$(journal_field apps-work-kept '.dir' | wc -l)" 2
}

# The same check behind a traversal in the record: apply.json names a path that
# resolves outside the work directory, and the revert's own cleanup refuses it
# even after it has restored everything else.
revert_a_traversal_record() {
    sweep_foreign_work_trees
    traversal=$work/state/work/../../outside
    jq -nc --arg work "$traversal" \
        '{schema:1,phase:"installing",commit:"'"$c_v2"'",work:$work,
          previousUnits:[],intendedUnits:[],previousPlan:false,previousState:false,
          previousSecrets:{},intendedSecrets:[],startedAt:"2026-11-21T00:00:00Z"}' | apply_write
    run_revert
}

@test "a traversal in apply.json removes nothing outside the work directory" {
    revert_a_traversal_record
    assert [ -f "$outside/render.prev/plan.json" ]
}

# --- 15. a revert refuses a state document of another schema ----------------
# The saved state.json is what a revert puts back, and it comes from a snapshot of
# whatever revision was running: a document of another schema is not this
# library's truth, so the revert refuses it, journals, pages and keeps its record
# rather than silently rewriting what the host is recorded as running.
revert_a_foreign_schema_state() {
    fixture
    run_apply "$c_v1"
    stage_interrupted "$c_v2" "$trees/$c_v2/homelab-apps-$c_v2"
    state_staged=$(sha "$state_dir/state.json")
    jq -c '.schema = 2' "$state_dir/work/apps-$c_v2/render.prev/state.json" |
        atomic_write "$state_dir/work/apps-$c_v2/render.prev/state.json"
    : >"$log/notify-urls"
    run_revert
}

@test "a revert refuses a state document of another schema" {
    revert_a_foreign_schema_state
    assert_equal "$rc" 1
}

@test "the refused restore leaves the state alone" {
    revert_a_foreign_schema_state
    assert_equal "$(sha "$state_dir/state.json")" "$state_staged"
}

@test "the refused restore is journaled with its reason" {
    revert_a_foreign_schema_state
    assert_equal "$(journal_field apps-revert-failed '.reason' | head -n 1)" state-schema-mismatch
}

@test "the refused restore pages the deploy check" {
    revert_a_foreign_schema_state
    assert_equal "$(tail -n 1 "$log/notify-urls")" "$ping_url/fail"
}

@test "the refused revert keeps the record" {
    revert_a_foreign_schema_state
    assert [ -s "$state_dir/apply.json" ]
}

# --- 16. state.json keeps a top-level key it does not know -------------------
# state.json has three writers -- the library's state_record_verified, the apps
# apply's state_apps_write and the revert restore -- and four readers. A field a
# newer writer added must survive a round trip through each, or a downgrade
# silently drops it while the readers still expect it.
apply_through_an_unknown_key() {
    fixture
    run_apply "$c_v1"
    jq -c '.future = {added: "by-a-newer-writer"}' "$state_dir/state.json" |
        atomic_write "$state_dir/state.json"
    run_apply "$c_v2"
    kept_rc=$rc
    kept_after_apply=$(jq -r '.future.added' "$state_dir/state.json")
    set_secrets "$secrets_v1b"
    export FAKE_SYSTEMCTL_FAIL_ONCE='restart alpha.service'
    run_apply "$c_v1"
    unset FAKE_SYSTEMCTL_FAIL_ONCE
}

@test "the apply after the unknown key succeeds" {
    apply_through_an_unknown_key
    assert_equal "$kept_rc" 0
}

@test "the apps writer and state_record_verified keep an unknown top-level key" {
    apply_through_an_unknown_key
    assert_equal "$kept_after_apply" by-a-newer-writer
}

@test "the failing apply reverts" {
    apply_through_an_unknown_key
    assert_equal "$rc" 5
}

@test "the revert restore keeps an unknown top-level key" {
    apply_through_an_unknown_key
    assert_equal "$(jq -r '.future.added' "$state_dir/state.json")" by-a-newer-writer
}

# An immutable image root is not a place an apply writes: `df /` there is its own
# 8 MB size, always 0 available, and treating that as a full disk refused every
# apply on a host whose /var had 63G free.
apply_on_a_root() { # <filesystem type> [<mount options>]
    fixture
    printf '/ 0\n' >"$FAKE_DF_MAP"
    printf '/ %s\n' "$1" >"$FAKE_FSTYPE_MAP"
    if [[ -n ${2:-} ]]; then export FAKE_MOUNT_OPTS=$2; fi
    export APPS_FREE_ROOT_PATH=/ APPS_FREE_VAR_PATH=/
    run_apply "$c_v1"
    unset FAKE_MOUNT_OPTS
}

@test "an immutable root is not a space floor" {
    apply_on_a_root composefs
    refute grep -q 'below the' <<<"$out"
}

# On this host `findmnt` reports `overlay` for the composefs root; it is not a
# writable disk and must not refuse an apply.
@test "an overlay root is not a space floor" {
    apply_on_a_root overlay
    refute grep -q 'below the' <<<"$out"
}

# A writable overlay is an ordinary disk; the zero-free floor still applies.
@test "a writable overlay root still refuses the apply" {
    apply_on_a_root overlay rw
    assert grep -q 'below the' <<<"$out"
}

# The same zero free on an ordinary root is still refused.
@test "a full ordinary root refuses the apply" {
    apply_on_a_root ext4
    assert_equal "$rc" 4
}

@test "the refusal names the space floor" {
    apply_on_a_root ext4
    assert grep -q 'below the' <<<"$out"
}
