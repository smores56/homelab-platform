#!/usr/bin/env bats
# bats file_tags=deploy
# The denylist is cleared by hand, and a crashing commit is blocked by
# hand (§10, §10b).
#
# One file of the suite that was tests/deploy/platform.bats, split so bats can
# run the sections in parallel (a single file is one job); the fakes, the
# fixture, the drivers and the assertions are in platform_lib.bash.
#
#   bats tests/deploy/platform-denylist.bats
load ../helpers
load ./platform_lib

setup_file() { pt_setup_file; }
setup() { pt_setup; }

# --- 10. the denylist is cleared by hand ------------------------------------
# A denylisted tip stops the hourly poll and refuses every event, so the clear is
# the operator's own act: the CLI owns it, records who did it, and removes one
# entry from one table -- never the whole list.
both_denylisted() {
    jq -nc --arg d "$other_index" --arg c "$commit" '
  {schema:1,
   commits:{($c):{reason:"apps-schema",at:"2026-11-20T01:00:00Z"}},
   digests:{($d):{reason:"boot-gate",at:"2026-11-20T01:00:00Z"}}}' |
        atomic_write "$state_dir/denylist.json"
}

cleared_digest() {
    both_denylisted
    cli_as alice uid0 unblock digest "$other_index"
}

@test "a non-root unblock is refused" {
    both_denylisted
    cli_as smores nonroot unblock digest "$other_index"
    assert_equal "$rc" 1
}

@test "a refused unblock leaves the entry in place" {
    both_denylisted
    cli_as smores nonroot unblock digest "$other_index"
    run denylist_has digest "$other_index"
    assert_success
}

@test "a refused unblock journals nothing" {
    both_denylisted
    cli_as smores nonroot unblock digest "$other_index"
    assert_equal "$(count_in "$state_dir/journal.jsonl" denylist-cleared)" 0
}

@test "unblock without arguments is a usage error" {
    both_denylisted
    run_cli unblock
    assert_equal "$rc" 2
}

@test "unblock rejects an unknown table" {
    both_denylisted
    run_cli unblock tag "$commit"
    assert_equal "$rc" 2
}

@test "unblock rejects a digest where a commit belongs" {
    both_denylisted
    run_cli unblock commit "$other_index"
    assert_equal "$rc" 2
}

@test "unblock rejects a commit where a digest belongs" {
    both_denylisted
    run_cli unblock digest "$commit"
    assert_equal "$rc" 2
}

@test "root clears a denylisted digest" {
    cleared_digest
    assert_equal "$rc" 0
}

@test "the cleared digest is gone" {
    cleared_digest
    run denylist_has digest "$other_index"
    assert_failure
}

@test "clearing one table keeps the other" {
    cleared_digest
    run denylist_has commit "$commit"
    assert_success
}

@test "the clear is journaled with the operator" {
    cleared_digest
    assert_equal "$(journal_field denylist-cleared '.operator')" alice
}

@test "the clear is journaled with the table" {
    cleared_digest
    assert_equal "$(journal_field denylist-cleared '.kind')" digest
}

@test "the clear is journaled with the value" {
    cleared_digest
    assert_equal "$(journal_field denylist-cleared '.value')" "$other_index"
}

@test "clearing an entry that is not listed is refused" {
    cleared_digest
    cli_as alice uid0 unblock digest "$other_index"
    assert_equal "$rc" 1
}

# --- 10b. a crashing commit is denylisted by hand ---------------------------
# The drain retries a failed apps apply every 300 s, and an app that starts and
# then crash-loops fails every time: the verifier's refusal is what makes the
# block final, so the operator needs a way to place it -- one value, one table,
# journaled with who did it, exactly like the clear.
crashed_denylisted() {
    jq -nc --arg c "$crashed" '
  {schema:1,
   commits:{($c):{reason:"app-unhealthy",at:"2026-11-21T00:00:00Z"}},
   digests:{}}' | atomic_write "$state_dir/denylist.json"
}

blocked_commit() {
    crashed_denylisted
    cli_as alice uid0 block commit "$commit"
}

@test "a non-root block is refused" {
    crashed_denylisted
    cli_as smores nonroot block commit "$commit"
    assert_equal "$rc" 1
}

@test "a refused block denylists nothing" {
    crashed_denylisted
    cli_as smores nonroot block commit "$commit"
    run denylist_has commit "$commit"
    assert_failure
}

@test "block without arguments is a usage error" {
    crashed_denylisted
    run_cli block
    assert_equal "$rc" 2
}

@test "block rejects an unknown table" {
    crashed_denylisted
    run_cli block tag "$commit"
    assert_equal "$rc" 2
}

@test "block rejects a digest where a commit belongs" {
    crashed_denylisted
    run_cli block commit "$digest_index"
    assert_equal "$rc" 2
}

@test "block rejects a commit where a digest belongs" {
    crashed_denylisted
    run_cli block digest "$commit"
    assert_equal "$rc" 2
}

@test "root denylists a commit" {
    blocked_commit
    assert_equal "$rc" 0
}

@test "the blocked commit is listed" {
    blocked_commit
    run denylist_has commit "$commit"
    assert_success
}

@test "the block is journaled with the operator" {
    blocked_commit
    assert_equal "$(journal_field denylist-added '.operator')" alice
}

@test "the block is journaled with the table" {
    blocked_commit
    assert_equal "$(journal_field denylist-added '.kind')" commit
}

@test "the block is journaled with the value" {
    blocked_commit
    assert_equal "$(journal_field denylist-added '.value')" "$commit"
}

@test "blocking one commit keeps the others" {
    blocked_commit
    run denylist_has commit "$crashed"
    assert_success
}

@test "blocking a commit that is already listed is refused" {
    blocked_commit
    cli_as alice uid0 block commit "$commit"
    assert_equal "$rc" 1
}
