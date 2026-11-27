#!/usr/bin/env bats
# bats file_tags=deploy
# A forged app name never reaches a unit instance (§13).
#
# One file of the suite that was tests/deploy/apps.sh, split so bats can run the
# sections in parallel (a single file is one job). The fakes, the published
# commits, the fixture, the drivers and the assertions are in apps_lib.bash.
#
#   bats tests/deploy/apps-guard-forged.bats
load ../helpers
load ./apps_lib

setup_file() { apps_setup_file; }
setup() { apps_setup; }
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
