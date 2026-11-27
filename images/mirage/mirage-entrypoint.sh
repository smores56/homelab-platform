#!/bin/bash
# Bring up one Mirage daemon and the workspace it serves, inside a container.
#
# Mirage has no server command and no container story: `mirage daemon` is a
# supervisor that starts on demand and exits after its last workspace stops, and
# the documented long-lived form is the ASGI app at `mirage.server.daemon:app`.
# So the daemon is uvicorn here, in the foreground, and the workspace is created
# once the daemon answers.
#
# The daemon binds 127.0.0.1 only and no config key moves it, which is why socat
# sits in front: the personal gateway and anything else on agent-local.network
# reach this container by name on $MIRAGE_PROXY_PORT, and socat forwards to the
# loopback daemon. The forwarder carries the MCP route and nothing else needs a
# second one, because no machine is attached to this instance yet (T1 pins Mirage
# and leaves real binaries in the workspace shell; see the issue).
#
# The token is required, not optional: an instance with no bearer auth answers
# anyone who can reach it, and the only thing in front of it is a bridge network.
set -euo pipefail

: "${MIRAGE_AUTH_TOKEN:?MIRAGE_AUTH_TOKEN is required; the unit passes it from mirage.env}"
: "${MIRAGE_DAEMON_PORT:=8765}"
: "${MIRAGE_PROXY_PORT:=18010}"
: "${MIRAGE_WORKSPACE_ID:=personal}"
: "${MIRAGE_WORKSPACE_CONFIG:=/etc/mirage/workspace.yaml}"

socat "TCP-LISTEN:${MIRAGE_PROXY_PORT},fork,reuseaddr,bind=0.0.0.0" \
  "TCP:127.0.0.1:${MIRAGE_DAEMON_PORT}" &
proxy_pid=$!

python3 -m uvicorn mirage.server.daemon:app \
  --host 127.0.0.1 --port "$MIRAGE_DAEMON_PORT" --log-level warning &
daemon_pid=$!

cleanup() {
  kill "$proxy_pid" "$daemon_pid" 2>/dev/null || true
  wait "$proxy_pid" "$daemon_pid" 2>/dev/null || true
}
trap cleanup EXIT

# The CLI is a client, not the server: it sends a context's token and nothing
# else, so the token has to be logged in once before any command works. `--token
# -` reads it off stdin, which keeps it out of argv, the process table and this
# script's own history.
#
# The same loop is the readiness wait: a login that lands before the daemon
# listens fails, and the retry is cheap. /v1/health is unauthenticated, but
# parsing its JSON in shell is noise next to asking the question we care about.
attempt=0
until printf '%s\n' "$MIRAGE_AUTH_TOKEN" |
  mirage login "http://127.0.0.1:${MIRAGE_DAEMON_PORT}" --token - >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  if ((attempt > 60)); then
    echo "mirage: the daemon did not accept the login in 60s" >&2
    exit 1
  fi
  sleep 1
done

# The workspace is created once; from then on it is the same id, and a boot finds
# it already stored. A stored workspace comes back stopped, because the daemon
# that ran it is gone with the last container: `start` is what makes a restart the
# same workspace rather than a second one.
if mirage workspace get "$MIRAGE_WORKSPACE_ID" >/dev/null 2>&1; then
  mirage workspace start "$MIRAGE_WORKSPACE_ID" >/dev/null 2>&1 || true
else
  attempt=0
  until mirage workspace create "$MIRAGE_WORKSPACE_CONFIG" -w "$MIRAGE_WORKSPACE_ID" >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    if ((attempt > 60)); then
      echo "mirage: the daemon did not accept workspace $MIRAGE_WORKSPACE_ID in 60s" >&2
      exit 1
    fi
    sleep 1
  done
fi

wait "$daemon_pid"
