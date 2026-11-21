#!/usr/bin/env bash
# Offline checks for the root-owned app ingress (SDLC #726, T7 of #701).
#
# A rootless publish forwards as the tenant uid, and the tenant egress table
# drops tenant traffic, so the loopback port Serve proxies to is answered by
# this root-owned helper instead: a unix socket inside the container's network
# namespace, and a loopback listener in the host's. This drives the real script
# against stubs and asserts the two ends, the plan and name checks, and that
# nothing listens off loopback.
#
#   tests/apps/ingress.sh
set -uo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root" || exit 1

script=scripts/apps-ingress.sh
[[ -r $script ]] || {
  printf 'FAIL %s is missing\n' "$script" >&2
  exit 1
}

pass=0
fail=0
ok() {
  pass=$((pass + 1))
  printf 'ok   %s\n' "$1"
}
bad() {
  fail=$((fail + 1))
  printf 'FAIL %s\n' "$1" >&2
  [[ -n ${2:-} ]] && printf '     %s\n' "${2//$'\n'/$'\n'     }" >&2
  return 0
}
contains() { # haystack needle label
  if [[ $1 == *"$2"* ]]; then ok "$3"; else bad "$3" "missing '$2' in '$1'"; fi
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/run"
export FAKE_LOG=$work/log
: >"$FAKE_LOG"

# The fake commands record their argv and, where the script waits for a socket,
# create one so the wait is bounded and the test stays offline.
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
printf 'schema %s\n' "$*" >>"$FAKE_LOG"
[[ ${FAKE_SCHEMA_REJECT:-} == 1 ]] && { echo "plan: foreign path"; exit 1; }
exit 0
EOF
chmod +x "$work/bin/"*

cat >"$work/plan.json" <<'JSON'
{"version": 1, "apps": {"alpha": {"loopbackPort": 20007, "containerPort": 8080}}}
JSON

run() {
  : >"$work/log"
  APPS_SCHEMA=$work/bin/schema APPS_PLAN=$work/plan.json \
    SOCAT=$work/bin/socat NSENTER=$work/bin/nsenter PODMAN=$work/bin/podman \
    RUNUSER=$work/bin/runuser APPS_USER=apps APPS_INGRESS_RUNTIME=$work/run \
    APPS_INGRESS_WAIT=2 APPS_INGRESS_SOCKET_WAIT=10 \
    PATH=$work/bin:$PATH \
    bash "$script" "$@" >"$work/out" 2>"$work/err"
}

sock=$work/run/alpha/ingress.sock
run alpha >/dev/null 2>&1 || true
cp "$work/log" "$work/first.log"
len=$(grep -c . "$work/first.log" || true)
if ((len >= 4)); then ok 'a run reaches both listeners'; else bad 'a run reaches both listeners' "$(cat "$work/first.log")
$(cat "$work/err")"; fi

netns_line=$(grep '^nsenter ' "$work/first.log" || true)
host_line=$(grep '^socat ' "$work/first.log" || true)
contains "$netns_line" '--target 1234' 'the namespace comes from the container pid'
contains "$netns_line" '--net' 'only the network namespace is entered'
contains "$netns_line" "UNIX-LISTEN:$sock" 'the namespace side answers on the shared socket'
contains "$netns_line" 'unlink-early' 'a stale socket is replaced, not inherited'
contains "$netns_line" 'TCP:127.0.0.1:8080' 'the namespace side reaches the container port'
contains "$host_line" 'TCP-LISTEN:20007,bind=127.0.0.1' 'the host side listens on the planned loopback port'
contains "$host_line" "UNIX-CONNECT:$sock" 'the host side forwards to the socket'
if [[ $host_line != *'0.0.0.0'* && $host_line != *'[::]'* ]]; then
  ok 'nothing listens off loopback'
else
  bad 'nothing listens off loopback' "$host_line"
fi
contains "$(cat "$work/first.log")" 'schema verify-plan ' 'the plan is verified before anything listens'

# The name becomes a path component, so only a schema-shaped name is accepted,
# and nothing is started for a name the plan does not carry.
for bad_name in '../alpha' 'Alpha' 'alpha/beta' ''; do
  if run "$bad_name" >/dev/null 2>&1; then
    bad "an invalid name is refused: '$bad_name'"
  else
    ok "an invalid name is refused: '$bad_name'"
  fi
done
if ! grep -q '^nsenter ' "$work/log"; then ok 'no listener is created for an invalid name'; else bad 'no listener is created for an invalid name'; fi

if run gamma >/dev/null 2>&1; then bad 'an app that is not in the plan is refused'; else ok 'an app that is not in the plan is refused'; fi
contains "$(cat "$work/err")" 'gamma is not in' 'the refusal names the app'
if ! grep -q '^nsenter ' "$work/log"; then ok 'no listener is created for an unknown app'; else bad 'no listener is created for an unknown app'; fi

# A plan the shipped verifier rejects must stop everything: an ingress whose
# ports came from an unverified plan is how a foreign path or a port outside the
# range would reach a listener.
: >"$work/log"
APPS_SCHEMA=$work/bin/schema APPS_PLAN=$work/plan.json SOCAT=$work/bin/socat \
  NSENTER=$work/bin/nsenter PODMAN=$work/bin/podman RUNUSER=$work/bin/runuser \
  APPS_USER=apps APPS_INGRESS_RUNTIME=$work/run APPS_INGRESS_WAIT=2 \
  PATH=$work/bin:$PATH FAKE_SCHEMA_REJECT=1 \
  bash "$script" alpha >/dev/null 2>"$work/err"
rc=$?
if ((rc != 0)); then ok 'a rejected plan stops the helper'; else bad 'a rejected plan stops the helper'; fi
contains "$(cat "$work/err")" 'is not accepted' 'the refusal says the plan was rejected'
if ! grep -qE '^(nsenter|socat) ' "$work/log"; then ok 'a rejected plan creates no listener'; else bad 'a rejected plan creates no listener'; fi

# A container that never appears must fail rather than listen into nothing.
: >"$work/log"
APPS_SCHEMA=$work/bin/schema APPS_PLAN=$work/plan.json SOCAT=$work/bin/socat \
  NSENTER=$work/bin/nsenter PODMAN=$work/bin/podman RUNUSER=$work/bin/runuser \
  APPS_USER=apps APPS_INGRESS_RUNTIME=$work/run APPS_INGRESS_WAIT=1 \
  PATH=$work/bin:$PATH FAKE_PODMAN_EMPTY=1 \
  bash "$script" alpha >/dev/null 2>"$work/err"
rc=$?
if ((rc != 0)); then ok 'a missing container fails the helper'; else bad 'a missing container fails the helper'; fi
contains "$(cat "$work/err")" 'did not appear' 'the failure says the container is missing'
if ! grep -q '^socat ' "$work/log"; then ok 'no host listener exists without a container'; else bad 'no host listener exists without a container'; fi

# A helper that is tested but never shipped is dead code, and a unit that is
# shipped but never tested is a listener nobody checked.
if grep -q 'scripts/apps-ingress.sh' image/Containerfile; then
  ok 'the image installs the ingress helper'
else
  bad 'the image installs the ingress helper'
fi
if grep -q 'ExecStart=/usr/libexec/apps-ingress %i' units/systemd/smortress-app-ingress@.service; then
  ok 'the unit runs the installed helper for its instance'
else
  bad 'the unit runs the installed helper for its instance'
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
((fail == 0))
