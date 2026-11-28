#!/usr/bin/env bats
# bats file_tags=image
# The laptop image's checker, and the wiring that publishes it (SDLC #1023).
#
# hosts/laptop/tests/check.sh carries the laptop's static invariants onto the
# image: the base-tag doctrine, the package set the session calls, the NymVPN
# vendoring, the display re-probe, the `login` and `sudo` PAM stacks with the
# FIDO2 mapping behind them, and `bootc container lint`. It runs in the `image`
# area beside the server's and the edge's checkers.
#
# The checker is a plain shell script that prints its own `ok`/`FAIL` rows and
# exits 0, so what this file adds is the verdict, the mode CI invokes it by, and
# the fact that the workflow publishing it still covers the tree it reads: the
# laptop is the one host whose publish lives in its own workflow, and a path
# filter that stopped covering hosts/laptop/** would leave the image stale with
# every check still green.
#
#   bats tests/image/laptop-image.bats
load ../helpers

checker=hosts/laptop/tests/check.sh
workflow=.github/workflows/publish-laptop-image.yml

# contains <text> <file>: a failure names the line that went missing instead of a
# bare status, because these assertions read files rather than run commands.
contains() {
    grep -qF -- "$1" "$2" || fail "missing '$1' in $2"
}

@test "the laptop checker passes on the tree as committed" {
    run bash "$checker"
    assert_success
    refute_output --partial 'FAIL'
    # The lint is the image's own analysis: outside the image the run proves the
    # assertions and says so, rather than skipping silently.
    assert_output --partial '0 failed'
}

# CI invokes it by path, so the mode is part of the contract.
@test "the laptop checker is tracked as an executable" {
    run git ls-files -s "$checker"
    assert_output --partial '100755'
}

# The workflow is the only thing that publishes this image, and the checker
# itself asserts the build arguments it passes; what it cannot assert is that it
# runs at all, because the same tree also carries the build-argument rows.
@test "the laptop publish workflow covers the tree it builds" {
    contains '- "hosts/laptop/**"' "$workflow"
    contains './hosts/laptop/tests/check.sh' "$workflow"
    contains '-f hosts/laptop/Containerfile' "$workflow"
    contains '. hosts/laptop/pins.env' "$workflow"
    # The build context is the repository root: the key, the policy and the
    # sudoers gate live in lib/ (SDLC #1024).
    contains 'lib/containers/cosign.pub' "$workflow"
    contains '- "lib/**"' "$workflow"
}

# The reminder's decision is rpm-ostree's own staged deployment, and its two
# outputs are a notification and a marker the prompt reads, so the suite runs the
# shipped script against a stub `rpm-ostree` and a stub `notify-send` instead of
# grepping it: a script that trusted a marker someone else wrote, or that told the
# session about a download that never staged, would pass a grep and lie to the
# person deciding when to reboot.
reminder=hosts/laptop/rootfs/usr/libexec/smorespro/bootc-update-reminder
marker_rel=.local/state/bootc-update-pending

# reminder_run <rpm-ostree status --json>: a private HOME, a stub PATH and a log
# of every stub call. `stubs`, `home` and `calls` stay visible to the test.
reminder_run() {
    stubs=$BATS_TEST_TMPDIR/stubs
    home=$BATS_TEST_TMPDIR/home
    calls=$BATS_TEST_TMPDIR/calls
    mkdir -p "$stubs" "$home"
    : >"$calls"
    cat >"$stubs/rpm-ostree" <<'EOS'
#!/bin/sh
printf 'rpm-ostree %s\n' "$*" >>"$STUB_CALLS"
printf '%s\n' "$STUB_STATUS_JSON"
EOS
    cat >"$stubs/notify-send" <<'EOS'
#!/bin/sh
printf 'notify-send %s\n' "$*" >>"$STUB_CALLS"
EOS
    chmod +x "$stubs/rpm-ostree" "$stubs/notify-send"
    run env -u XDG_STATE_HOME HOME="$home" STUB_CALLS="$calls" \
        STUB_STATUS_JSON="$1" PATH="$stubs:$PATH" bash "$reminder"
}

@test "the reminder announces the still-staged update a reboot would apply" {
    reminder_run '{"deployments":[{"booted":true,"staged":false,"version":"45.1.4"},{"booted":false,"staged":true,"version":"45.2.0"}]}'
    assert_success
    assert_equal "$(cat "$home/$marker_rel")" \
        "$(printf 'version=45.2.0\ncommand=sudo systemctl reboot')"
    assert_equal "$(grep -c '^notify-send ' "$calls")" 1
    assert_contains "$(cat "$calls")" '45.2.0'
    # The staged deployment is read from rpm-ostree, never inferred.
    assert_contains "$(cat "$calls")" 'rpm-ostree status --json'
}

@test "the reminder clears the marker when no deployment is staged" {
    mkdir -p "$BATS_TEST_TMPDIR/home/$(dirname "$marker_rel")"
    printf 'version=45.0\ncommand=sudo systemctl reboot\n' >"$BATS_TEST_TMPDIR/home/$marker_rel"
    reminder_run '{"deployments":[{"booted":true,"staged":false,"version":"45.1.4"},{"booted":false,"staged":false,"version":"45.1.3"}]}'
    assert_success
    [ -e "$BATS_TEST_TMPDIR/home/$marker_rel" ] \
        && fail "a stale marker survived: $(cat "$BATS_TEST_TMPDIR/home/$marker_rel")"
    ! grep -q '^notify-send ' "$calls" || fail "the session was told about an update that is not staged"
    return 0
}
