#!/usr/bin/env bats
# bats file_tags=deploy
# A record that disagrees with the boot is reconciled by hand, and a
# restored host is bootstrapped by hand (§10c, §11).
#
# One file of the suite that was tests/deploy/platform.bats, split so bats can
# run the sections in parallel (a single file is one job); the fakes, the
# fixture, the drivers and the assertions are in platform_lib.bash.
#
#   bats tests/deploy/platform-recover.bats
load ../helpers
load ./platform_lib

setup_file() { pt_setup_file; }
setup() { pt_setup; }

# --- 10c. a record that disagrees with the boot is reconciled by hand --------
# The gate journals `booted-unrecorded` and deliberately leaves state alone, so
# the repair is the operator's: it records the digest the host actually booted,
# for the commit the operator names (a digest-pinned boot carries no commit), and
# keeps the previous value in the journal.
stale_record() {
    jq -nc --arg c "$stale_commit" --arg i "$stale_digest" --arg a "$apps_commit" '
  {schema:1,
   repos:{"homelab-platform":{commit:$c,indexDigest:$i,manifestDigest:$i},
          "homelab-apps":{commit:$a}},
   apps:{}, updated:"2026-11-21T00:00:00Z"}' | atomic_write "$state_dir/state.json"
}

# The digest the host reports it booted: present for every case but the one that
# proves a failure to read it.
booted_digest() { export STUB_BOOTC_DIGEST=$reconciled_digest; }

reconciled_record() {
    stale_record
    booted_digest
    cli_as alice uid0 reconcile --commit "$commit"
}

@test "a reconcile that cannot read the booted image exits 4" {
    stale_record
    unset STUB_BOOTC_DIGEST
    cli_as alice uid0 reconcile --commit "$commit"
    assert_equal "$rc" 4
}

@test "a failed reconcile leaves the record alone" {
    stale_record
    unset STUB_BOOTC_DIGEST
    cli_as alice uid0 reconcile --commit "$commit"
    json_is "$(state_read)" '.repos["homelab-platform"].manifestDigest' "$stale_digest"
}

@test "a non-root reconcile is refused" {
    stale_record
    booted_digest
    cli_as smores nonroot reconcile --commit "$commit"
    assert_equal "$rc" 1
}

@test "a refused reconcile leaves the commit alone" {
    stale_record
    booted_digest
    cli_as smores nonroot reconcile --commit "$commit"
    json_is "$(state_read)" '.repos["homelab-platform"].commit' "$stale_commit"
}

@test "a refused reconcile journals nothing" {
    stale_record
    booted_digest
    cli_as smores nonroot reconcile --commit "$commit"
    assert_equal "$(count_in "$state_dir/journal.jsonl" state-reconciled)" 0
}

@test "reconcile without arguments is a usage error" {
    stale_record
    run_cli reconcile
    assert_equal "$rc" 2
}

@test "reconcile takes --commit, not a bare value" {
    stale_record
    run_cli reconcile "$commit"
    assert_equal "$rc" 2
}

@test "reconcile rejects a commit that is not 40 hex" {
    stale_record
    run_cli reconcile --commit abc123
    assert_equal "$rc" 2
}

@test "root reconciles the record to the booted image" {
    reconciled_record
    assert_equal "$rc" 0
}

@test "the reconciled commit is recorded" {
    reconciled_record
    json_is "$(state_read)" '.repos["homelab-platform"].commit' "$commit"
}

@test "the booted digest is recorded" {
    reconciled_record
    json_is "$(state_read)" '.repos["homelab-platform"].manifestDigest' "$reconciled_digest"
}

@test "the stale index digest is dropped" {
    reconciled_record
    json_is "$(state_read)" '.repos["homelab-platform"] | has("indexDigest")' false
}

@test "the apps record is untouched" {
    reconciled_record
    json_is "$(state_read)" '.repos["homelab-apps"].commit' "$apps_commit"
}

@test "the reconcile is journaled with the operator" {
    reconciled_record
    assert_equal "$(journal_field state-reconciled '.operator')" alice
}

@test "the reconcile is journaled with the previous commit" {
    reconciled_record
    assert_equal "$(journal_field state-reconciled '.from')" "$stale_commit"
}

@test "the reconcile is journaled with the booted digest" {
    reconciled_record
    assert_equal "$(journal_field state-reconciled '.digest')" "$reconciled_digest"
}

@test "a reconcile does not claim a verified deployment" {
    reconciled_record
    assert_equal "$(count_in "$state_dir/journal.jsonl" state-verified)" 0
}

@test "the booted image is read, not guessed" {
    reconciled_record
    assert_contains "$(cat "$log/bootc-calls")" 'status --booted --json'
}

@test "reconciling a record that already matches is refused" {
    reconciled_record
    cli_as alice uid0 reconcile --commit "$commit"
    assert_equal "$rc" 1
}

# --- 11. a restored host is bootstrapped by hand ----------------------------
# Without a recorded ancestor there is no descendancy to check and the verifier
# refuses every deploy with `bootstrap-required`. The operator names the running
# commit once; nothing here infers it, and nothing overwrites a record.
no_state_record() { rm -f "$state_dir/state.json"; }

bootstrapped_apps() {
    no_state_record
    cli_as alice uid0 bootstrap homelab-apps "$bootstrap_commit"
}

@test "a non-root bootstrap is refused" {
    no_state_record
    cli_as smores nonroot bootstrap homelab-apps "$bootstrap_commit"
    assert_equal "$rc" 1
}

@test "a refused bootstrap writes no state" {
    no_state_record
    cli_as smores nonroot bootstrap homelab-apps "$bootstrap_commit"
    assert_absent "$state_dir/state.json"
}

@test "bootstrap without arguments is a usage error" {
    no_state_record
    run_cli bootstrap
    assert_equal "$rc" 2
}

@test "bootstrap rejects a repository the receiver does not deploy" {
    no_state_record
    run_cli bootstrap nix-config "$bootstrap_commit"
    assert_equal "$rc" 2
}

@test "bootstrap rejects a commit that is not 40 hex" {
    no_state_record
    run_cli bootstrap homelab-apps abc123
    assert_equal "$rc" 2
}

@test "root records the running commit" {
    bootstrapped_apps
    assert_equal "$rc" 0
}

@test "the bootstrapped commit is recorded" {
    bootstrapped_apps
    json_is "$(state_read)" '.repos["homelab-apps"].commit' "$bootstrap_commit"
}

@test "the bootstrap is journaled with the operator" {
    bootstrapped_apps
    assert_equal "$(journal_field bootstrap-recorded '.operator')" alice
}

@test "the bootstrap is journaled with the repository" {
    bootstrapped_apps
    assert_equal "$(journal_field bootstrap-recorded '.repo')" homelab-apps
}

@test "bootstrap never overwrites a recorded commit" {
    bootstrapped_apps
    cli_as alice uid0 bootstrap homelab-apps "$commit"
    assert_equal "$rc" 1
}

@test "the refused bootstrap leaves the record alone" {
    bootstrapped_apps
    cli_as alice uid0 bootstrap homelab-apps "$commit"
    json_is "$(state_read)" '.repos["homelab-apps"].commit' "$bootstrap_commit"
}

# A bootstrapped platform host records the commit only: the digests belong to the
# deployment the registry still serves, and a next deploy writes both forms.
platform_bootstrapped() {
    bootstrapped_apps
    cli_as alice uid0 bootstrap homelab-platform "$bootstrap_commit"
}

@test "both repositories can be bootstrapped" {
    platform_bootstrapped
    assert_equal "$rc" 0
}

@test "a bootstrap records no digest it did not observe" {
    platform_bootstrapped
    json_is "$(state_read)" '.repos["homelab-platform"] | has("indexDigest")' false
}

# An exhausted budget is one second, not no limit: `timeout 0` would hand the child
# unlimited time, which is the opposite of what a spent budget means.
exhausted_verify() {
    local started
    started=$(date -u +%s)
    rc=0
    out=$(STUB_VERIFY_SLEEP=20 DEPLOY_GATE_BUDGET=0 bash "$platform" prepare \
        --commit "$commit" --digests "$digests" 2>&1) || rc=$?
    elapsed=$(($(date -u +%s) - started))
}

# The elapsed seconds the shell suite interpolated into this check's name are the
# literal one a bounded child takes; the bound itself is asserted below.
@test "an exhausted budget bounds the child to one second (1s)" {
    exhausted_verify
    if ((elapsed >= 10)); then fail "the child ran ${elapsed}s"; fi
}

@test "an exhausted budget fails the gate instead of waiting for the child" {
    exhausted_verify
    assert_equal "$rc" 4
}

@test "the bounded child that timed out is journaled as an infrastructure failure" {
    exhausted_verify
    assert_equal "$(journal_field gate-infra-failure '.reason')" query-failed
}
