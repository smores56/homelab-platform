#!/usr/bin/env bats
# bats file_tags=deploy
# The edge's two deploy triggers and the queue they feed (design #939, T11).
#
# The server has three moving parts between a merge and a reboot: the notify job
# (its own suite, tests/deploy/edge-notify.bats), the poll on a timer
# (tests/deploy/poll.bats drives the program), and `smortress-deploy.path`, which
# turns a queue entry into a drain. The edge gets the same three with edge names,
# and what this suite asserts is the difference: no sops unit to wait for, the
# dead-man URL from `/etc/smoresnet`, the one repository the edge receiver admits,
# the same 03:00 local window with no catch-up at boot, and the edge's own state
# directory writable and nothing else.
#
# Nothing runs a real systemd here: the units are read, and the two cross-file
# invariants -- the writable path is the state directory the image creates, and the
# polled repository is the receiver's allowlist -- are compared against the files
# that own them.
#
#   bats tests/deploy/edge-triggers.bats
load ../helpers

rootfs=bootc/edge/rootfs
units=$rootfs/usr/lib/systemd/system
containerfile=bootc/edge/Containerfile
workflow=.github/workflows/publish-edge-image.yml
tmpfiles=$rootfs/usr/lib/tmpfiles.d/smoresnet-deploy.conf
decisions=bootc/lib/deploy/decisions.py

service=$units/smoresnet-deploy-poll.service
timer=$units/smoresnet-deploy-poll.timer
path_unit=$units/smoresnet-deploy.path
drain_unit=$units/smoresnet-deploy.service

# entries <file>: the unit's keys, comments and blank lines dropped.
entries() { grep -vE '^[[:space:]]*(#|$)' "$1"; }

# value <file> <key>: the one value of a key, or the empty string.
value() { sed -n "s/^$2=//p" "$1" | head -n1; }

# env_value <file> <name>: the value of one Environment= assignment.
env_value() { sed -n "s/^Environment=$2=//p" "$1" | head -n1; }

# --- the poll backstop ships and runs ----------------------------------------

@test "the poll service and its timer ship" {
    assert [ -s "$service" ]
    assert [ -s "$timer" ]
}

@test "the service runs the installed program" {
    assert_equal "$(value "$service" ExecStart)" /usr/libexec/deploy-poll
}

@test "the Containerfile installs the program at that path, executable" {
    assert grep -qxF 'COPY scripts/deploy-poll.sh /usr/libexec/deploy-poll' "$containerfile"
    assert grep -qF 'chmod 0755 /usr/libexec/deploy-heartbeat /usr/libexec/deploy-poll' "$containerfile"
}

@test "the image enables the timer" {
    assert grep -qE '^[[:space:]]+smoresnet-deploy-poll\.timer \\$' "$containerfile"
}

@test "the service is a oneshot that owns no install" {
    assert_equal "$(value "$service" Type)" oneshot
    refute grep -qxF '[Install]' "$service"
}

# --- the edge has no sops plane ---------------------------------------------

# The poll pages on a denylisted tip and on an exhausted budget, and the server's
# unit reaches that ping URL through sops-decrypt. The edge ships no such unit, so
# a `Requires=`/`Wants=` on it would retire the backstop silently -- the one
# failure a backstop cannot have.
@test "the poll depends on no sops unit" {
    refute grep -qE '^(Requires|Wants)=.*sops-decrypt' "$service"
}

@test "the poll reads the edge's own ping URL" {
    assert_equal "$(env_value "$service" DEPLOY_PING_SECRET)" /etc/smoresnet/deploy-ping-url
}

# --- the boot gate orders the poll, and does not gate it --------------------
# A run against a state.json the gate has not written yet would enqueue the
# deployment the host is already running; a gate that held must not stop the poll,
# because the day after a hold is when a fix has to arrive.
@test "the poll is ordered after the boot gate with After= alone" {
    assert grep -qxF 'After=edge-boot-gate.service' "$service"
    refute grep -qE '^Requires=edge-boot-gate\.service$' "$service"
}

@test "the poll is bounded" {
    assert grep -qE '^TimeoutStartSec=[0-9]+$' "$service"
}

# --- the window is the operator's, and never a boot -------------------------

@test "the window is 03:00 in the operator's time zone" {
    assert_equal "$(value "$timer" OnCalendar)" '*-*-* 03:00:00 America/New_York'
    assert grep -qxF 'AccuracySec=1min' "$timer"
}

@test "a missed window is not owed at boot" {
    assert grep -qxF 'Persistent=false' "$timer"
}

@test "the timer starts the service and is enabled at boot" {
    assert grep -qxF 'Unit=smoresnet-deploy-poll.service' "$timer"
    assert grep -qxF 'WantedBy=timers.target' "$timer"
}

# --- the state tree is the edge's own ---------------------------------------

# The server's units write /var/lib/homelab/deploy; the edge's tmpfiles line
# creates the same tree (one state library, one layout), so this is a comparison
# and not a hardcoded path: a unit pointing at a directory the image does not
# create would fail with a read-only filesystem, not with a clear message.
@test "the poll writes the state directory the image creates" {
    state=$(sed -n 's|^d \([^ ]*\) 0*700 root root -$|\1|p' "$tmpfiles" | grep 'deploy$' | head -n1)
    assert [ -n "$state" ]
    assert_equal "$(value "$service" ReadWritePaths)" "$state"
}

@test "the poll is confined to it" {
    assert grep -qxF 'ProtectSystem=strict' "$service"
    assert grep -qxF 'ProtectHome=yes' "$service"
    assert grep -qxF 'PrivateTmp=yes' "$service"
    assert grep -qxF 'NoNewPrivileges=yes' "$service"
    assert grep -qxF 'UMask=0077' "$service"
    assert grep -qE '^RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX$' "$service"
}

# --- the poll asks for what the receiver admits -----------------------------

# The poll writes straight into the queue, so it bypasses the receiver's allowlist;
# polling homelab-apps would spend one of the 32 slots on a request the drain then
# refuses. The allowlist is read from the shared decision rather than trusted to
# match by hand.
@test "the poll asks for exactly the repositories the edge receiver admits" {
    run python3 - "$decisions" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("decisions", sys.argv[1])
module = importlib.util.module_from_spec(spec)
sys.modules["decisions"] = module
spec.loader.exec_module(module)
print(" ".join(sorted(module.ROLES[module.EDGE].repos)))
PY
    assert_success
    admitted=$output
    assert_equal "$(env_value "$service" DEPLOY_POLL_REPOS)" "$admitted"
}

# --- a request in the queue is what starts the drain ------------------------

@test "the queue path unit ships" {
    assert [ -s "$path_unit" ]
}

@test "the path unit watches the state queue" {
    state=$(sed -n 's|^d \([^ ]*\) 0*700 root root -$|\1|p' "$tmpfiles" | grep '/queue$' | head -n1)
    assert [ -n "$state" ]
    assert_equal "$(value "$path_unit" DirectoryNotEmpty)" "$state"
}

@test "the path unit starts the edge's drain" {
    assert_equal "$(value "$path_unit" Unit)" smoresnet-deploy.service
    assert grep -qxF 'WantedBy=paths.target' "$path_unit"
}

# The drain itself installs nothing: a unit that also started at boot would drain a
# queue nobody had filled, which on this host is a reboot with no trigger and the
# least rollback in the fleet.
@test "the drain has no install of its own" {
    refute grep -qxF '[Install]' "$drain_unit"
    assert_equal "$(value "$drain_unit" ExecStart)" /usr/libexec/deploy-drain-edge
    assert grep -qxF 'After=edge-boot-gate.service' "$drain_unit"
}

@test "the image enables the path unit" {
    assert grep -qE '^[[:space:]]+smoresnet-deploy\.path \\$' "$containerfile"
}

# --- the release trigger is a dispatch, and the poll is its backstop --------

@test "the publish workflow deploys only from a main dispatch" {
    assert grep -qxF "    if: github.event_name == 'workflow_dispatch' && github.ref == 'refs/heads/main'" "$workflow"
    assert_equal "$(grep -cF 'tags: tag:deploy' "$workflow")" 1
}

@test "the poll is the only thing that deploys without a dispatch" {
    # The notify job is gated on the event; the timer is not gated on anything, and
    # that asymmetry is the design: a release is deliberate, and a release nobody
    # made deliberate still has to arrive.
    assert grep -qxF 'Persistent=false' "$timer"
    refute grep -qE 'ConditionACPower|ConditionPathExists' "$service"
}

# --- the suite runs where the other deploy suites do -----------------------

@test "the deploy group runs this suite and the notify suite" {
    assert grep -qE 'tests/deploy/edge-notify\.bats' scripts/check-all.sh
    assert grep -qE 'tests/deploy/edge-triggers\.bats' scripts/check-all.sh
}

@test "CI runs the deploy group" {
    assert grep -qE -- "--filter-tags 'deploy'" .github/workflows/ci.yml
}
