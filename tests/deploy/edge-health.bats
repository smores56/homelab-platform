#!/usr/bin/env bats
# bats file_tags=deploy
# The edge's greenboot check (SDLC #939): what "this deployment works" means.
#
# This is the successor to `edge-boot-gate`'s verdict. greenboot rolls a
# deployment back when a required check exits non-zero, so the two properties
# that matter are that it fails when the edge is not serving, and that it does
# not fail on a merely slow boot -- a check that gives up early is a rollback
# loop that punishes a healthy host.
#
#   bats tests/deploy/edge-health.bats
load ../helpers

check=bootc/edge/rootfs/etc/greenboot/check/required.d/10-edge-health.sh

setup() {
    bin=$BATS_TEST_TMPDIR/bin
    rm -rf "$bin"
    mkdir -p "$bin"
    export GREENBOOT_EDGE_BUDGET=0
    # curl: 200 for the served page, 401 for opds, or $STUB_CURL_STATUS when set.
    cat >"$bin/curl" <<'STUB'
#!/usr/bin/env bash
for argument; do
    case $argument in
        https://*) url=$argument ;;
    esac
done
status=${STUB_CURL_STATUS:-}
if [[ -z $status ]]; then
    case $url in
        *opds*) status=401 ;;
        *) status=200 ;;
    esac
fi
printf '%s\n' "$url" >>"$STUB_LOG"
printf '%s' "$status"
exit "${STUB_CURL_EXIT:-0}"
STUB
    cat >"$bin/systemctl" <<'STUB'
#!/usr/bin/env bash
for argument; do last=$argument; done
[[ $last == "${STUB_INACTIVE:-none}" ]] && exit 3
exit 0
STUB
    cat >"$bin/tailscale" <<'STUB'
#!/usr/bin/env bash
exit "${STUB_TAILSCALE_EXIT:-0}"
STUB
    chmod 0755 "$bin"/*
    export STUB_LOG=$BATS_TEST_TMPDIR/probes
    : >"$STUB_LOG"
    export PATH=$bin:$PATH
}

@test "a serving edge passes" {
    run "$check"
    assert_success
    assert_equal "$(wc -l <"$STUB_LOG")" 2
}

@test "a name that answers the wrong status fails the deployment" {
    STUB_CURL_STATUS=500 run "$check"
    assert_failure
    assert_contains "$output" "expected 200"
}

@test "caddy being down fails the deployment" {
    STUB_INACTIVE=caddy run "$check"
    assert_failure
    assert_contains "$output" "caddy: not active"
}

@test "an unjoined tailnet fails the deployment" {
    STUB_TAILSCALE_EXIT=1 run "$check"
    assert_failure
    assert_contains "$output" "not joined"
}

@test "the check ships executable, which is what makes greenboot run it" {
    [[ -x $check ]] || fail "$check is not executable: greenboot would skip it silently"
}

@test "the budget stays inside greenboot's oneshot timeout" {
    # systemd's default TimeoutStartSec is 90 s; a check that waits longer is
    # killed and reads as a failure, which rolls back a healthy host.
    local budget
    budget=$(grep -o 'GREENBOOT_EDGE_BUDGET:-[0-9]*' "$check" | grep -o '[0-9]*$')
    [[ -n $budget ]] || fail "the budget is not a literal"
    ((budget < 90)) || fail "a ${budget}s budget outlives the unit's 90s start limit"
}
