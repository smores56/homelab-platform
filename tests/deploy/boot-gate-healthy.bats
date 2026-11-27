#!/usr/bin/env bats
# bats file_tags=deploy
# The gate on a boot that is the staged deployment: the landed record and the released holds (§3).
#
# One file of the suite that was tests/deploy/boot.bats, split so bats can run
# the sections in parallel; the fakes, the fixture, the drivers and the
# assertions are in boot_lib.bash.
#
#   bats tests/deploy/boot-gate-healthy.bats
load ../helpers
load ./boot_lib

setup_file() { bt_setup_file; }
setup() { bt_setup; }

# --- 3. the gate on a boot that is the staged deployment --------------------
gate_on_staged_deployment() {
    seed_pending "$digest_index" "$digest_manifest" "$commit" "$digest_manifest"
    run_gate
}

@test "a healthy host on the staged deployment passes the gate" {
    gate_on_staged_deployment
    assert_equal "$rc" 0
}

@test "the gate journals the landed commit" {
    gate_on_staged_deployment
    assert_equal "$(journal_field boot-gate-green '.commit')" "$commit"
}

@test "the gate records the deployed commit" {
    gate_on_staged_deployment
    assert_equal "$(jq -r '.repos["homelab-platform"].commit' <<<"$(state_json)")" "$commit"
}

@test "the gate records the index digest" {
    gate_on_staged_deployment
    assert_equal "$(jq -r '.repos["homelab-platform"].indexDigest' <<<"$(state_json)")" "$digest_index"
}

@test "the gate records the manifest digest" {
    gate_on_staged_deployment
    assert_equal "$(jq -r '.repos["homelab-platform"].manifestDigest' <<<"$(state_json)")" "$digest_manifest"
}

@test "success sets boot_success" {
    gate_on_staged_deployment
    assert_equal "$(grub_flags '.boot_success')" 1
}

@test "success resets the boot counter" {
    gate_on_staged_deployment
    assert_equal "$(grub_flags '.boot_counter')" 3
}

@test "success clears the pending record" {
    gate_on_staged_deployment
    assert [ ! -e "$state_dir/pending.json" ]
}

@test "success pings the deploy check" {
    gate_on_staged_deployment
    assert_equal "$(cat "$log/curl-urls")" "$ping_url"
}

@test "a healthy boot rolls nothing back" {
    gate_on_staged_deployment
    refute grep -qF -- 'rollback' "$log/bootc-calls"
}

# The gate judges the host, and the plan's app is not part of that: the port
# below nothing listens on and a Serve query it never makes are the prober's
# business (tests/deploy/apps-health.bats).
@test "the gate probes no tenant unit" {
    gate_on_staged_deployment
    refute grep -qF -- 'demo.service' "$log/systemctl-calls"
}

@test "the gate asks no user manager anything" {
    gate_on_staged_deployment
    refute grep -qF -- '--user' "$log/systemctl-calls"
}

@test "the gate reads no Serve status" {
    gate_on_staged_deployment
    assert [ ! -s "$log/tailscale-calls" ]
}

@test "a healthy boot denylists nothing" {
    gate_on_staged_deployment
    assert_equal "$(jq -r '.digests | length' <<<"$(denylist_json)")" 0
}

# A signed release that the operator had held is cleared once it lands, so
# `status` stops reporting a hold that no longer exists.
gate_clears_released_hold() {
    seed_pending "$digest_index" "$digest_manifest" "$commit" "$digest_index"
    jq -nc --arg d "$digest_index" --arg c "$commit" \
        '{schema:1,digest:$d,commit:$c,digests:{index:$d,manifest:$d},missingUnits:[],reason:"x",
        heldAt:"2026-11-20T00:00:00Z",released:true,releasedBy:"alice"}' | held_write
    run_gate
}

@test "a booted index digest matches the pending record and passes" {
    gate_clears_released_hold
    assert_equal "$rc" 0
}

@test "a landed released hold is cleared by the gate" {
    gate_clears_released_hold
    assert [ ! -e "$state_dir/held.json" ]
}
