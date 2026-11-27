#!/usr/bin/env bats
# bats file_tags=deploy
# A departed app loses its unit, secret and Serve route (§8, tests 6-10).
#
# One file of the suite that was tests/deploy/apps.sh, split so bats can run the
# sections in parallel (a single file is one job). The fakes, the published
# commits, the fixture, the drivers and the assertions are in apps_lib.bash.
#
#   bats tests/deploy/apps-revert-depart2.bats
load ../helpers
load ./apps_lib

setup_file() { apps_setup_file; }
setup() { apps_setup; }
# --- 8. a departed app loses its unit, its secret and its Serve route --------
apply_a_departed_app() {
    fixture
    run_apply "$c_v1"
    : >"$log/actions"
    run_apply "$c_depart"
}

@test "the departed app is stopped" {
    apply_a_departed_app
    assert grep -qF 'user stop beta.service' "$log/actions"
}

@test "the departed app's ingress is stopped" {
    apply_a_departed_app
    assert grep -qF 'system stop smortress-app-ingress@beta' "$log/actions"
}

@test "Serve is regenerated so the departed route is pruned" {
    apply_a_departed_app
    assert grep -qF 'system restart smortress-tailscale-serve.service' "$log/actions"
}

@test "the plan keeps only the remaining app" {
    apply_a_departed_app
    assert_equal "$(jq -r '.apps | keys | join(" ")' "$APPS_PLAN")" alpha
}

@test "state keeps only the remaining app" {
    apply_a_departed_app
    assert_equal "$(jq -r '.apps.apps | keys | join(" ")' "$state_dir/state.json")" alpha
}
