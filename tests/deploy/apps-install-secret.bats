#!/usr/bin/env bats
# bats file_tags=deploy
# A secret-only change restarts the app that mounts it (§7).
#
# One file of the suite that was tests/deploy/apps.sh, split so bats can run the
# sections in parallel (a single file is one job). The fakes, the published
# commits, the fixture, the drivers and the assertions are in apps_lib.bash.
#
#   bats tests/deploy/apps-install-secret.bats
load ../helpers
load ./apps_lib

setup_file() { apps_setup_file; }
setup() { apps_setup; }

# --- 7. a secret-only change restarts the app that mounts it -----------------
apply_a_secret_only_change() {
    fixture
    run_apply "$c_v1"
    : >"$log/pulls"
    : >"$log/actions"
    : >"$log/secret-creates"
    set_secrets "$secrets_v1b"
    run_apply "$c_secret"
}

@test "a secret-only change applies" {
    apply_a_secret_only_change
    assert_equal "$rc" 0
}

@test "the rotated value is in the store" {
    apply_a_secret_only_change
    assert_equal "$(cat "$secret_store/app-alpha-api-key")" two
}

@test "an unchanged secret keeps its value" {
    apply_a_secret_only_change
    assert_equal "$(cat "$secret_store/app-beta-beta-key")" beta-one
}

@test "a secret-only change pulls nothing" {
    apply_a_secret_only_change
    assert [ ! -s "$log/pulls" ]
}

@test "the app whose secret changed is restarted" {
    apply_a_secret_only_change
    assert grep -qF 'user restart alpha.service' "$log/actions"
}

@test "an app with no change is not restarted" {
    apply_a_secret_only_change
    refute grep -qF 'user restart beta.service' "$log/actions"
}

@test "the changed secret is replaced" {
    apply_a_secret_only_change
    assert grep -qF app-alpha-api-key "$log/secret-creates"
}

@test "a committed secret change clears the crash record" {
    apply_a_secret_only_change
    assert [ ! -e "$state_dir/apply.json" ]
}
