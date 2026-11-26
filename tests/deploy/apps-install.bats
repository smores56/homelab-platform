#!/usr/bin/env bats
# bats file_tags=deploy
# The apps apply and its revert: a first apply, the pulls, and the secret-only change (§1-§7).
#
# One file of the suite that was tests/deploy/apps.sh, split so bats can run the
# sections in parallel (a single file is one job). The fakes, the published
# commits, the fixture, the drivers and the assertions are in apps_lib.bash.
#
#   bats tests/deploy/apps-install.bats
load ../helpers
load ./apps_lib

setup_file() { apps_setup_file; }
setup() { apps_setup; }

# --- 1. the tarball still yields the tree §1-§4 read --------------------------
# One test per path the tarball must yield: the shell suite made the same five
# checks in its preamble, where each `ok` line was already a test like any other.
check_extracted() { # <path in the tree>
    assert [ -s "$extract_check/$1" ]
}

for path in .github/CODEOWNERS .github/workflows/ci.yml .github/workflows/deploy.yml \
    apps/alpha/app.toml apps/beta/app.toml; do
    register "the commit tarball extracts $path" check_extracted "$path"
done

# --- 1. a first apply installs the plan, the units, the secrets and Serve -----
# §1-§4 are one test because each carries the installed state forward with no
# `reset_case`: §2 proves a rejected definition leaves §1's install untouched, and
# §4 proves an empty tenant departs from it. Four tests would reinstall between
# the parts, which is a different thing to prove.
@test "a clean commit applies" {
    fixture
    run_apply "$c_v1"
    same "$rc" 0 "a clean commit applies"
    present "$APPS_PLAN" "the plan is installed"
    same "$(jq -r '.apps | keys | join(" ")' "$APPS_PLAN")" 'alpha beta' \
        "the plan names both apps"
    present "$APPS_UNIT_DIR/alpha.container" "alpha's unit is installed"
    present "$APPS_UNIT_DIR/beta.container" "beta's unit is installed"
    present "$APPS_UNIT_DIR/smortress-apps.network" \
        "the internal network is installed for egress none"
    in_file "$APPS_UNIT_DIR/alpha.container" '# Rendered from apps/alpha/app.toml' \
        "the installed unit is the rendered one"
    same "$(cat "$secret_store/app-alpha-api-key" 2>/dev/null)" one \
        "alpha's secret value is in the store"
    same "$(cat "$secret_store/app-beta-beta-key" 2>/dev/null)" beta-one \
        "beta's secret value is in the store"
    present "$state_dir/state.json" "the applied revision is recorded"
    same "$(jq -r '.repos["homelab-apps"].commit' "$state_dir/state.json")" "$c_v1" \
        "state records the applied commit"
    same "$(journal_field state-verified '.repo')" homelab-apps \
        "the commit is recorded through state_record_verified"
    same "$(jq -r '.apps.apps.alpha.unit' "$state_dir/state.json")" \
        "$(sha "$APPS_UNIT_DIR/alpha.container")" \
        "the recorded unit hash is the installed unit's"
    nonempty "$(jq -r '.apps.apps.alpha.secrets // ""' "$state_dir/state.json")" \
        "the recorded secret hash is present"
    same "$(jq -r '.apps.unitsHash | length' "$state_dir/state.json")" 64 \
        "the whole-set unit hash is recorded"
    absent "$state_dir/apply.json" "a committed apply clears the crash record"
    same "$(tail -n 1 "$log/notify-urls")" "$ping_url" \
        "a clean apply pings the deploy check"
    # The ping URL is the capability to keep the check green: it is handed to curl
    # as a config on stdin, so no local account can read it out of /proc.
    not_in_file "$log/curl-argv" "$ping_url" "the ping URL never reaches curl's argv"
    in_file "$log/curl-argv" '--config -' "the ping URL is a curl config on stdin"
    # The tarball is untrusted bytes extracted as root: tar must not take
    # ownership, modes or the tree's own directory mode from it.
    extract=$(grep -F -- '-xzf' "$log/tar-argv" | head -n 1)
    for flag in --no-same-owner --no-same-permissions --no-overwrite-dir; do
        in_text "$extract" "$flag" "the extraction passes $flag"
    done
    in_file "$log/actions" 'system start smortress-app-ingress@alpha' \
        "alpha's ingress is started"
    in_file "$log/actions" 'system start smortress-app-ingress@beta' \
        "beta's ingress is started"

    # The quota applier must have read the new plan before any container started.
    same "$(sha "$log/quota-plan" 2>/dev/null)" "$(sha "$APPS_PLAN")" \
        "the quota restart reads the new plan"
    plan_at=$(line_of "$state_dir/journal.jsonl" '"event":"apps-plan-installed"')
    quota_at=$(line_of "$state_dir/journal.jsonl" '"event":"apps-quota-applied"')
    assert_before "$plan_at" "$quota_at" "the plan is installed before the quota restart"

    # --- 2. a rejected definition changes nothing and is denylisted -----------
    plan_before=$(sha "$APPS_PLAN")
    unit_before=$(sha "$APPS_UNIT_DIR/alpha.container")
    secret_before=$(cat "$secret_store/app-alpha-api-key")
    : >"$log/pulls"
    : >"$log/actions"
    run_apply "$c_bad"
    same "$rc" 3 "a rejected definition exits 3"
    same "$(sha "$APPS_PLAN")" "$plan_before" \
        "a rejected definition leaves the plan untouched"
    same "$(sha "$APPS_UNIT_DIR/alpha.container")" "$unit_before" \
        "a rejected definition leaves the units untouched"
    same "$(cat "$secret_store/app-alpha-api-key")" "$secret_before" \
        "a rejected definition leaves the secrets untouched"
    absent "$state_dir/apply.json" "a rejected definition writes no crash record"
    same "$(jq -r ".commits[\"$c_bad\"].reason" \
        <<<"$(cat "$state_dir/denylist.json" 2>/dev/null || printf '{}')")" \
        apps:definition-rejected "a rejected commit is denylisted"
    same "$(journal_field apps-rejected '.commit')" "$c_bad" "the rejection is journaled"
    nothing_in "$log/pulls" "a rejected definition pulls nothing"
    nothing_in "$log/actions" "a rejected definition mutates nothing"
    same "$(tail -n 1 "$log/notify-urls")" "$ping_url/fail" \
        "a rejection pages the deploy check"

    # --- 3. an empty tenant is refused by the renderer alone -------------------
    empty_tree=$trees/$c_empty/homelab-apps-$c_empty
    render_rc=0
    "$repo_root/$schema" render --root "$empty_tree" --out "$work/empty-refused" \
        >"$log/empty.log" 2>&1 || render_rc=$?
    [[ $render_rc -ne 0 ]] || fail \
        "the renderer refuses an empty tenant without --allow-empty: $(cat "$log/empty.log")"
    absent "$work/empty-refused/plan.json" "the refused empty render writes no plan"

    # --- 4. an empty tenant applies with --allow-empty and empties Serve's routes
    run_apply "$c_empty"
    same "$rc" 0 "the deploy applies an empty tenant"
    same "$(jq -r '.apps | length' "$APPS_PLAN")" 0 "the empty plan has no app"
    [[ -z $(find "$APPS_UNIT_DIR" -maxdepth 1 -type f -name '*.container' -print -quit) ]] ||
        fail "the emptied tenant has no app unit: $(ls "$APPS_UNIT_DIR")"
    absent "$APPS_UNIT_DIR/smortress-apps.network" \
        "the internal network goes with the last egress-none app"
    nothing_in "$secret_store" "the emptied tenant has no secrets"
    in_file "$log/actions" 'user stop alpha.service' "a departed app is stopped"
    in_file "$log/actions" 'system stop smortress-app-ingress@alpha' \
        "a departed app's ingress is stopped"
    same "$(jq -r '.apps.apps | length' "$state_dir/state.json")" 0 \
        "the emptied tenant records no app"
    in_file "$log/actions" 'system restart smortress-tailscale-serve.service' \
        "Serve is regenerated so the removed route is pruned"
}

# --- 5. a failed pull changes nothing and leaves no crash record -------------
# Every check in a section below reads one aftermath, so each of its tests
# replays the section's own sequence: the same drivers in the same order, with
# nothing between them that a check depends on.
apply_a_failed_pull() {
    fixture
    run_apply "$c_v1"
    plan_before=$(sha "$APPS_PLAN")
    unit_before=$(sha "$APPS_UNIT_DIR/alpha.container")
    secret_before=$(cat "$secret_store/app-alpha-api-key")
    : >"$log/pulls"
    : >"$log/actions"
    : >"$log/systemctl-calls"
    export FAKE_PULL_FAIL=$d_c
    run_apply "$c_pull"
    unset FAKE_PULL_FAIL
}

@test "a failed pull exits 4 for a retry" {
    apply_a_failed_pull
    assert_equal "$rc" 4
}

@test "a failed pull leaves the plan untouched" {
    apply_a_failed_pull
    assert_equal "$(sha "$APPS_PLAN")" "$plan_before"
}

@test "a failed pull leaves the units untouched" {
    apply_a_failed_pull
    assert_equal "$(sha "$APPS_UNIT_DIR/alpha.container")" "$unit_before"
}

@test "a failed pull leaves the secrets untouched" {
    apply_a_failed_pull
    assert_equal "$(cat "$secret_store/app-alpha-api-key")" "$secret_before"
}

@test "a failed pull leaves no crash record" {
    apply_a_failed_pull
    assert [ ! -e "$state_dir/apply.json" ]
}

@test "a failed pull removes its work tree" {
    apply_a_failed_pull
    assert [ ! -e "$state_dir/work/apps-$c_pull" ]
}

@test "the failed pull is journaled" {
    apply_a_failed_pull
    assert_equal "$(journal_field apps-pull-failed '.commit')" "$c_pull"
}

@test "the changed image is the one pulled" {
    apply_a_failed_pull
    assert grep -qF -- "ghcr.io/example/alpha@$d_c" "$log/pulls"
}

@test "a failed pull happens before any mutation" {
    apply_a_failed_pull
    assert [ ! -s "$log/actions" ]
}

@test "a failed pull pages the deploy check" {
    apply_a_failed_pull
    assert_equal "$(tail -n 1 "$log/notify-urls")" "$ping_url/fail"
}

# --- 6. pull-all-then-change, and the plan before the quota restart ----------
apply_a_changed_commit() {
    fixture
    run_apply "$c_v1"
    : >"$state_dir/journal.jsonl"
    : >"$log/pulls"
    : >"$log/actions"
    : >"$log/sequence"
    run_apply "$c_changed"
    last_pull=$(grep -n 'apps-pulled' "$state_dir/journal.jsonl" | tail -n 1 | cut -d: -f1)
    plan_at=$(line_of "$state_dir/journal.jsonl" '"event":"apps-plan-installed"')
    quota_at=$(line_of "$state_dir/journal.jsonl" '"event":"apps-quota-applied"')
    # The command log's own order: every pull is a child of this apply, and the
    # first thing it changes is the plan's consumer.
    last_pull_cmd=$(grep -n '^pull ' "$log/sequence" | tail -n 1 | cut -d: -f1)
    quota_cmd=$(line_of "$log/sequence" 'restart smortress-apps-quota.service')
}

@test "a changed commit applies" {
    apply_a_changed_commit
    assert_equal "$rc" 0
}

@test "the changed image is pulled" {
    apply_a_changed_commit
    assert [ -s "$log/pulls" ]
}

@test "every pull completes before the first mutation" {
    apply_a_changed_commit
    assert_before "$last_pull" "$plan_at" "every pull completes before the first mutation"
}

@test "the plan is installed before the quota reads it" {
    apply_a_changed_commit
    assert_before "$plan_at" "$quota_at" "the plan is installed before the quota reads it"
}

@test "the quota applier reads the new plan" {
    apply_a_changed_commit
    assert_equal "$(sha "$log/quota-plan" 2>/dev/null)" "$(sha "$APPS_PLAN")"
}

@test "the command log shows every pull before the quota restart" {
    apply_a_changed_commit
    assert_before "$last_pull_cmd" "$quota_cmd" \
        "the command log shows every pull before the quota restart"
}

@test "Serve is regenerated from the new plan" {
    apply_a_changed_commit
    assert_equal "$(sha "$log/serve-plan" 2>/dev/null)" "$(sha "$APPS_PLAN")"
}

@test "a changed unit is restarted" {
    apply_a_changed_commit
    assert grep -qF 'user restart alpha.service' "$log/actions"
}

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
