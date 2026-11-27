#!/usr/bin/env bats
# bats file_tags=deploy
# Neither repository usable holds the deploy (§4).
#
# One file of the suite that was tests/deploy/platform.bats, split so bats can
# run the sections in parallel (a single file is one job); the fakes, the
# fixture, the drivers and the assertions are in platform_lib.bash.
#
#   bats tests/deploy/platform-hold.bats
load ../helpers
load ./platform_lib

setup_file() { pt_setup_file; }
setup() { pt_setup; }

# --- 4. neither repository usable holds the deploy --------------------------
held_deploy() {
    seed_doc false false ""
    printf '%s\n' "$ping_url" >"$DEPLOY_PING_SECRET"
    run_platform prepare --commit "$commit" --digests "$digests"
    held=$(cat "$state_dir/held.json" 2>/dev/null) || held='{}'
}

@test "a hold is exit 5" {
    held_deploy
    assert_equal "$rc" 5
}

@test "a hold attempts no backup without a usable repository" {
    held_deploy
    assert_empty "$log/backup-calls"
}

@test "the hold names the digest" {
    held_deploy
    json_is "$held" .digest "$digest_index"
}

@test "the hold names the commit" {
    held_deploy
    json_is "$held" .commit "$commit"
}

@test "the hold lists every missing unit" {
    held_deploy
    json_is "$held" '.missingUnits | length' "${#units[@]}"
}

@test "the hold names the reason" {
    held_deploy
    json_is "$held" .reason no-usable-repository
}

@test "a new hold is not released" {
    held_deploy
    json_is "$held" '.released' false
}

@test "the hold records when it was taken" {
    held_deploy
    json_is "$held" '.heldAt | type' string
}

@test "the hold is journaled with its reason" {
    held_deploy
    assert_equal "$(journal_field deploy-held '.reason')" no-usable-repository
}

@test "a hold reports the failure to the deploy check" {
    held_deploy
    assert_equal "$(cat "$log/curl-urls")" "$ping_url/fail"
}
