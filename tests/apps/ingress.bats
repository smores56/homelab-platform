#!/usr/bin/env bats
# bats file_tags=apps
# Offline checks for the root-owned app ingress (SDLC #726, T7 of #701).
#
# A rootless publish forwards as the tenant uid, and the tenant egress table
# drops tenant traffic, so the loopback port Serve proxies to is answered by
# this root-owned helper instead: a unix socket inside the container's network
# namespace, and a loopback listener in the host's. This drives the real script
# against stubs and asserts the two ends, the plan and name checks, and that
# nothing listens off loopback.
#
#   bats tests/apps/ingress.bats
#
# The stubs, the plan and the runtime directory are written per test, so the
# checks never share a log or a socket with another test.
load ../helpers

script=scripts/apps-ingress.sh

setup() {
    [ -r "$script" ]
    work=$BATS_TEST_TMPDIR
    mkdir -p "$work/bin" "$work/run"
    export FAKE_LOG=$work/log
    : >"$FAKE_LOG"

    # The fake commands record their argv and, where the script waits for a
    # socket, create one so the wait is bounded and the test stays offline.
    cat >"$work/bin/podman" <<'EOF'
#!/usr/bin/env bash
printf 'podman %s\n' "$*" >>"$FAKE_LOG"
[[ ${FAKE_PODMAN_EMPTY:-} == 1 ]] && exit 1
printf '1234\n'
EOF
    cat >"$work/bin/runuser" <<'EOF'
#!/usr/bin/env bash
while [[ ${1-} != -- ]]; do shift; done
shift
exec "$@"
EOF
    cat >"$work/bin/nsenter" <<'EOF'
#!/usr/bin/env bash
printf 'nsenter %s\n' "$*" >>"$FAKE_LOG"
for arg in "$@"; do
  case $arg in
    UNIX-LISTEN:*) path=${arg#UNIX-LISTEN:}; python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "${path%%,*}" ;;
  esac
done
# A real listener stays up; exiting immediately would let the supervisor see the
# namespace side die before the host side ever started.
sleep 2
EOF
    cat >"$work/bin/socat" <<'EOF'
#!/usr/bin/env bash
printf 'socat %s\n' "$*" >>"$FAKE_LOG"
EOF
    # The host has the tenant account; CI does not. Only the uid lookup needs it.
    cat >"$work/bin/id" <<'EOF'
#!/usr/bin/env bash
if [[ ${1-} == -u ]]; then printf '1000\n'; exit 0; fi
exec /usr/bin/id "$@"
EOF
    cat >"$work/bin/schema" <<'EOF'
#!/usr/bin/env bash
# Mimics the shipped CLI: verify-plan takes --plan, and anything else is a usage
# error. A stub that accepts any argv would let a wrong invocation ship.
printf 'schema %s\n' "$*" >>"$FAKE_LOG"
[[ ${1-} == verify-plan ]] || { echo "fake schema: unknown command ${1-}" >&2; exit 2; }
[[ ${2-} == --plan ]] || { echo 'usage: apps-schema verify-plan --plan PLAN' >&2; exit 2; }
[[ ${FAKE_SCHEMA_REJECT:-} == 1 ]] && { echo "plan: foreign path"; exit 1; }
exit 0
EOF
    chmod +x "$work/bin/"*

    cat >"$work/plan.json" <<'JSON'
{"version": 1, "apps": {"alpha": {"loopbackPort": 20007, "containerPort": 8080}}}
JSON
}

# ingress_run [args...]: one run of the real helper against the stubs, with the
# log cleared first. APPS_INGRESS_WAIT=1 (the missing-container case) and the
# stub switches are set by the caller as a command prefix.
ingress_run() {
    : >"$FAKE_LOG"
    APPS_SCHEMA=$work/bin/schema APPS_PLAN=$work/plan.json \
        SOCAT=$work/bin/socat NSENTER=$work/bin/nsenter PODMAN=$work/bin/podman \
        RUNUSER=$work/bin/runuser APPS_USER=apps APPS_INGRESS_RUNTIME=$work/run \
        APPS_INGRESS_WAIT=${APPS_INGRESS_WAIT:-2} APPS_INGRESS_SOCKET_WAIT=10 \
        PATH=$work/bin:$PATH \
        bash "$script" "$@" >"$work/out" 2>"$work/err"
}

# ingress_sock: the socket the plan's single app answers on.
ingress_sock() { printf '%s' "$work/run/alpha/ingress.sock"; }

@test "a run reaches both listeners" {
    ingress_run alpha >/dev/null 2>&1 || true
    local len
    len=$(grep -c . "$FAKE_LOG" || true)
    ((len >= 4))
}

@test "the namespace comes from the container pid" {
    ingress_run alpha >/dev/null 2>&1 || true
    local netns_line
    netns_line=$(grep '^nsenter ' "$FAKE_LOG" || true)
    assert_contains "$netns_line" '--target 1234'
}

@test "only the network namespace is entered" {
    ingress_run alpha >/dev/null 2>&1 || true
    local netns_line
    netns_line=$(grep '^nsenter ' "$FAKE_LOG" || true)
    assert_contains "$netns_line" '--net'
}

@test "the namespace side answers on the shared socket" {
    ingress_run alpha >/dev/null 2>&1 || true
    local netns_line
    netns_line=$(grep '^nsenter ' "$FAKE_LOG" || true)
    assert_contains "$netns_line" "UNIX-LISTEN:$(ingress_sock)"
}

@test "a stale socket is replaced, not inherited" {
    ingress_run alpha >/dev/null 2>&1 || true
    local netns_line
    netns_line=$(grep '^nsenter ' "$FAKE_LOG" || true)
    assert_contains "$netns_line" 'unlink-early'
}

@test "the namespace side reaches the container port" {
    ingress_run alpha >/dev/null 2>&1 || true
    local netns_line
    netns_line=$(grep '^nsenter ' "$FAKE_LOG" || true)
    assert_contains "$netns_line" 'TCP:127.0.0.1:8080'
}

@test "the host side listens on the planned loopback port" {
    ingress_run alpha >/dev/null 2>&1 || true
    local host_line
    host_line=$(grep '^socat ' "$FAKE_LOG" || true)
    assert_contains "$host_line" 'TCP-LISTEN:20007,bind=127.0.0.1'
}

@test "the host side forwards to the socket" {
    ingress_run alpha >/dev/null 2>&1 || true
    local host_line
    host_line=$(grep '^socat ' "$FAKE_LOG" || true)
    assert_contains "$host_line" "UNIX-CONNECT:$(ingress_sock)"
}

@test "nothing listens off loopback" {
    ingress_run alpha >/dev/null 2>&1 || true
    local host_line
    host_line=$(grep '^socat ' "$FAKE_LOG" || true)
    [[ $host_line != *'0.0.0.0'* && $host_line != *'[::]'* ]]
}

@test "the plan is verified before anything listens" {
    ingress_run alpha >/dev/null 2>&1 || true
    assert_contains "$(cat "$FAKE_LOG")" 'schema verify-plan --plan '
}

# The name becomes a path component, so only a schema-shaped name is accepted,
# and nothing is started for a name the plan does not carry.
invalid_name_is_refused() { # name
    local rc=0
    ingress_run "$1" >/dev/null 2>&1 || rc=$?
    assert_not_equal "$rc" 0
}

for bad_name in '../alpha' 'Alpha' 'alpha/beta' ''; do
    register "an invalid name is refused: '$bad_name'" invalid_name_is_refused "$bad_name"
done

@test "no listener is created for an invalid name" {
    ingress_run '' >/dev/null 2>&1 || true
    ! grep -q '^nsenter ' "$FAKE_LOG"
}

@test "an app that is not in the plan is refused" {
    local rc=0
    ingress_run gamma >/dev/null 2>&1 || rc=$?
    assert_not_equal "$rc" 0
}

@test "the refusal names the app" {
    ingress_run gamma >/dev/null 2>&1 || true
    assert_contains "$(cat "$work/err")" 'gamma is not in'
}

@test "no listener is created for an unknown app" {
    ingress_run gamma >/dev/null 2>&1 || true
    ! grep -q '^nsenter ' "$FAKE_LOG"
}

# A plan the shipped verifier rejects must stop everything: an ingress whose
# ports came from an unverified plan is how a foreign path or a port outside the
# range would reach a listener.
@test "a rejected plan stops the helper" {
    local rc=0
    FAKE_SCHEMA_REJECT=1 ingress_run alpha >/dev/null 2>&1 || rc=$?
    assert_not_equal "$rc" 0
}

@test "the refusal says the plan was rejected" {
    FAKE_SCHEMA_REJECT=1 ingress_run alpha >/dev/null 2>&1 || true
    assert_contains "$(cat "$work/err")" 'is not accepted'
}

@test "a rejected plan creates no listener" {
    FAKE_SCHEMA_REJECT=1 ingress_run alpha >/dev/null 2>&1 || true
    ! grep -qE '^(nsenter|socat) ' "$FAKE_LOG"
}

# A container that never appears must fail rather than listen into nothing.
@test "a missing container fails the helper" {
    local rc=0
    APPS_INGRESS_WAIT=1 FAKE_PODMAN_EMPTY=1 ingress_run alpha >/dev/null 2>&1 || rc=$?
    assert_not_equal "$rc" 0
}

@test "the failure says the container is missing" {
    APPS_INGRESS_WAIT=1 FAKE_PODMAN_EMPTY=1 ingress_run alpha >/dev/null 2>&1 || true
    assert_contains "$(cat "$work/err")" 'did not appear'
}

@test "no host listener exists without a container" {
    APPS_INGRESS_WAIT=1 FAKE_PODMAN_EMPTY=1 ingress_run alpha >/dev/null 2>&1 || true
    ! grep -q '^socat ' "$FAKE_LOG"
}

# A helper that is tested but never shipped is dead code, and a unit that is
# shipped but never tested is a listener nobody checked.
@test "the image installs the ingress helper" {
    grep -q 'scripts/apps-ingress.sh' image/Containerfile
}

@test "the unit runs the installed helper for its instance" {
    grep -q 'ExecStart=/usr/libexec/apps-ingress %i' units/systemd/smortress-app-ingress@.service
}
