#!/usr/bin/env bats
# bats file_tags=deploy
# An interrupted apply, work-tree lifetime and a no-op revert (§11-§12).
#
# One file of the suite that was tests/deploy/apps.sh, split so bats can run the
# sections in parallel (a single file is one job). The fakes, the published
# commits, the fixture, the drivers and the assertions are in apps_lib.bash.
#
#   bats tests/deploy/apps-guard-interrupted.bats
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
