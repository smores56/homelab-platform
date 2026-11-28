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
# the same quarter-hour cadence with no catch-up at boot, and the edge's own state
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

# --- the cadence is the server's, and never a boot -------------------------

# The edge publishes only on a dispatch, so the poll is the whole of the trigger
# for a release nobody dispatched: the cadence is the delay, and it is the server's
# quarter hour (#1014), not a window of the edge's own.
@test "the poll runs every fifteen minutes" {
    assert_equal "$(value "$timer" OnCalendar)" '*-*-* *:0/15:00'
    assert grep -qxF 'AccuracySec=1min' "$timer"
}

@test "a missed tick is not owed at boot" {
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
    # Both files carry the deploy tag, which is what the area job selects on;
    # the retired driver used to name them by path.
    assert grep -qxF '# bats file_tags=deploy' "$BATS_TEST_DIRNAME/edge-notify.bats"
    assert grep -qxF '# bats file_tags=deploy' "$BATS_TEST_DIRNAME/edge-triggers.bats"
}

@test "CI runs the deploy group" {
    assert grep -qE -- "--filter-tags 'deploy'" .github/workflows/ci.yml
}

# --- the receiver is reachable from the tailnet ------------------------------
#
# The receiver binds loopback, so without a forward the notify job's POST reaches
# a port that exists on this host and nowhere else. The forward is `tailscale
# serve`, which keeps its configuration in the node's own state, so the unit only
# has to assert it once per boot.

@test "the deploy forward ships and is enabled" {
    local unit=$units/smoresnet-deploy-forward.service
    [[ -f $unit ]] || fail 'smoresnet-deploy-forward.service is missing'
    assert grep -qxF 'ExecStart=/usr/bin/tailscale serve --bg --tcp=8484 tcp://127.0.0.1:8484' "$unit"
    assert grep -qxF 'WantedBy=multi-user.target' "$unit"
    assert grep -qxF '      smoresnet-deploy-forward.service \' "$containerfile"
}

@test "the forward waits for the join and repeats safely" {
    local unit=$units/smoresnet-deploy-forward.service
    assert grep -qxF 'ConditionPathExists=/var/lib/smoresnet/tailscale-enrolled' "$unit"
    assert grep -qE '^After=.*smoresnet-tailscale-up\.service' "$unit"
    # Type=oneshot with RemainAfterExit: `tailscale serve --bg` is idempotent, and a
    # unit that kept running would hold a socket it does not need.
    assert grep -qxF 'Type=oneshot' "$unit"
    assert grep -qxF 'RemainAfterExit=yes' "$unit"
}

@test "the forward advertises the port the receiver binds and the ACL admits" {
    local receiver=bootc/lib/deploy/deploy-receiver.py
    # 8484 in three places: the program's default, the forward's TCP port, and the
    # ACL grant that lets tag:deploy reach it.
    assert grep -qE '8484' "$receiver"
    assert grep -qF 'tag:vps:8484' tofu/tailscale.tf
    assert grep -qF 'src    = ["tag:deploy"]' tofu/tailscale.tf
}

# --- the public ssh window before the join ----------------------------------
#
# The image admits no ssh on the public zone, and that is right for a host with a
# tailnet. It is wrong for one without: before the join there is no other way in,
# and the key the join needs can only arrive over ssh. Design #939 section 3 step
# 5 states the window; the unit is its implementation.

@test "the pre-join window ships, runs the helper, and is decided by the marker" {
    local unit=$units/smoresnet-firewall-prejoin.service
    local helper=$rootfs/usr/libexec/smoresnet-firewall-prejoin
    [[ -f $unit ]] || fail 'smoresnet-firewall-prejoin.service is missing'
    [[ -x $helper ]] || fail 'smoresnet-firewall-prejoin is missing or not executable'
    assert grep -qxF 'ExecStart=/usr/libexec/smoresnet-firewall-prejoin' "$unit"
    assert grep -qxF '      smoresnet-firewall-prejoin.service \' "$containerfile"
    # The marker is the helper's own decision, so the unit carries no condition:
    # both states have work to do, and only one of them is "do nothing".
    refute grep -qE '^ConditionPathExists' "$unit"
    assert grep -qF '/var/lib/smoresnet/tailscale-enrolled' "$helper"
}

@test "the pre-join helper opens ssh on the public zone and closes it after" {
    local helper=$rootfs/usr/libexec/smoresnet-firewall-prejoin
    assert grep -qF -- '--add-service=ssh' "$helper"
    assert grep -qF -- '--remove-service=ssh' "$helper"
    # Runtime rules only: the shipped zone is the reviewed answer, and a second
    # copy of "which ports does the edge accept" is how the two drift apart.
    refute grep -qF 'firewall-cmd --permanent' "$helper"
    refute grep -qF -- '--permanent' "$helper"
}

@test "the pre-join window is the only place 22 reaches the public zone" {
    # The shipped zones are unchanged: ssh is in the tailscale zone and nowhere
    # else, so the runtime rule is the whole of the difference.
    local public=$rootfs/usr/share/smoresnet/firewalld/zones/public.xml
    local tailnet=$rootfs/usr/share/smoresnet/firewalld/zones/tailscale.xml
    refute grep -qE '<service name="ssh"/>|<port port="22"' "$public"
    assert grep -qxF '  <port port="22" protocol="tcp"/>' "$tailnet"
}
