#!/usr/bin/env bash
# Functional tests for the read-only guard (#725 T2): the same refusals and
# rewrites the Cloudflare Worker performs, on a host that has no Worker.
#
#   tests/backrest/guard.sh
#
# A stub stands in for Backrest and the guard is pointed at it, so the test
# needs no repository, no restic and no network.
set -uo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root" || exit 1

guard=backrest/container/guard.py
pass=0
fail=0
ok() {
  pass=$((pass + 1))
  printf 'ok   %s\n' "$1"
}
bad() {
  fail=$((fail + 1))
  printf 'FAIL %s\n' "$1"
  [[ -n ${2:-} ]] && printf '     %s\n' "${2//$'\n'/$'\n'     }"
  return 0
}

if ! command -v python3 >/dev/null 2>&1; then
  echo "skip guard tests: python3 is not installed"
  exit 0
fi

work=$(mktemp -d)
stub_pid=''
guard_pid=''
cleanup() {
  [[ -n $guard_pid ]] && kill "$guard_pid" 2>/dev/null
  [[ -n $stub_pid ]] && kill "$stub_pid" 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

read -r stub_port guard_port < <(python3 - <<'PY'
import socket
def free():
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port
print(free(), free())
PY
)

cat >"$work/stub.py" <<'PY'
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


def varint(value):
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def ld(field, payload):
    return varint((field << 3) | 2) + varint(len(payload)) + payload


# Config.repos = 3, Repo.password = 3, Repo.env = 4
CONFIG_PROTO = ld(3, ld(3, b"SECRET-PW") + ld(4, b"AWS_ACCESS_KEY_ID=AKIA"))


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def send(self, code, body, ctype):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/metrics":
            return self.send(200, b"metrics", "text/plain")
        return self.send(200, b"<html>app</html>", "text/html")

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length)
        if self.path == "/v1.Backrest/GetConfig":
            if "proto" in (self.headers.get("Content-Type") or ""):
                return self.send(200, CONFIG_PROTO, "application/proto")
            return self.send(
                200,
                json.dumps(
                    {
                        "repos": [
                            {
                                "id": "r2",
                                "password": "SECRET-PW",
                                "env": ["AWS_ACCESS_KEY_ID=AKIA"],
                            }
                        ],
                        "auth": {"users": [{"name": "operator", "passwordBcrypt": "$2a$hash"}]},
                    }
                ).encode(),
                "application/json",
            )
        if self.path == "/v1.Backrest/ListSnapshots":
            return self.send(
                200,
                json.dumps(
                    {
                        "snapshots": [
                            {"id": "aaa", "tags": ["verified"]},
                            {"id": "bbb", "tags": ["unit:books"]},
                        ]
                    }
                ).encode(),
                "application/json",
            )
        if self.path == "/v1.Backrest/GetOperations":
            try:
                selector = json.loads(body or b"{}").get("selector") or {}
            except ValueError:
                selector = {}
            requested = selector.get("ids") or []
            if not requested:
                # No index operations until a reindex runs, which is the state a
                # freshly started reader is in.
                return self.send(200, json.dumps({"operations": []}).encode(), "application/json")
            snapshot = "bbb" if "2" in requested else "aaa"
            return self.send(
                200,
                json.dumps(
                    {
                        "operations": [
                            {
                                "id": str(requested[0]),
                                "snapshotId": snapshot,
                                "operationIndexSnapshot": {},
                            }
                        ]
                    }
                ).encode(),
                "application/json",
            )
        if self.path == "/v1.Backrest/DoRepoTask":
            with open(sys.argv[2], "a") as log:
                log.write("DoRepoTask %s\n" % body.decode())
            return self.send(200, b"{}", "application/json")
        if self.path == "/v1.Authentication/Login":
            return self.send(200, b'{"token":"t"}', "application/json")
        return self.send(200, b'{"ok":true}', "application/json")


HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
PY

python3 "$work/stub.py" "$stub_port" "$work/calls" &
stub_pid=$!

BACKREST_BIN='' BACKREST_REPO_ID=r2 \
  BACKREST_UPSTREAM_ADDR="127.0.0.1:$stub_port" \
  BACKREST_GUARD_ADDR="127.0.0.1:$guard_port" \
  python3 "$guard" 2>"$work/guard.log" &
guard_pid=$!

ready=0
for _ in $(seq 50); do
  if curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$guard_port/"; then
    ready=1
    break
  fi
  sleep 0.2
done
[[ $ready == 1 ]] || {
  bad "the guard starts" "$(cat "$work/guard.log")"
  printf '\n%d passed, %d failed\n' "$pass" "$fail"
  exit 1
}
ok "the guard starts"

req() { # <method> <path> [body] [content-type]
  local method=$1 path=$2 body=${3:-} ctype=${4:-application/json}
  if [[ -n $body ]]; then
    curl -s -o "$work/body" -w '%{http_code}' -X "$method" \
      -H "Content-Type: $ctype" --data-binary "$body" \
      "http://127.0.0.1:$guard_port$path"
  else
    curl -s -o "$work/body" -w '%{http_code}' -X "$method" \
      "http://127.0.0.1:$guard_port$path"
  fi
}

eq() { if [[ $1 == "$2" ]]; then ok "$3"; else bad "$3" "got '$1', want '$2'"; fi; }
hasnt() { if grep -qa -- "$2" "$work/body"; then bad "$1" "'$2' survived"; else ok "$1"; fi; }
has() { if grep -qa -- "$2" "$work/body"; then ok "$1"; else bad "$1" "'$2' missing"; fi; }

eq "$(req POST /v1.Backrest/SetConfig '{}')" 403 'SetConfig is refused'
eq "$(req POST /v1.Backrest/RunCommand '{}')" 403 'RunCommand is refused'
eq "$(req POST /v1.Authentication/Logout '{}')" 403 'a non-login auth call is refused'
eq "$(req GET /metrics)" 403 'metrics is refused'
eq "$(req PUT /)" 405 'a non-GET request outside the RPC surface is refused'
eq "$(req POST /v1.Authentication/Login '{"username":"operator"}')" 200 'login is proxied'

eq "$(req POST /v1.Backrest/GetConfig '{}')" 200 'GetConfig is served'
hasnt 'the repository password is redacted' 'SECRET-PW'
hasnt 'the restic environment is redacted' 'AKIA'
has 'the user hash is masked' '********'

eq "$(req POST /v1.Backrest/ListSnapshots '{"repoId":"r2"}')" 200 'ListSnapshots is served'
has 'the verified snapshot stays' '"aaa"'
hasnt 'the untagged snapshot is dropped' '"bbb"'

eq "$(req POST /v1.Backrest/GetDownloadURL '{"opId":"1"}')" 200 'download of a verified snapshot is allowed'
eq "$(req POST /v1.Backrest/GetDownloadURL '{"opId":"2"}')" 409 'download of an unverified snapshot is refused'

# A fresh reader has no index operations, so the guard must ask for one after a
# listing or GetDownloadURL can never mint a URL.
sleep 2
if grep -qa 'TASK_INDEX_SNAPSHOTS' "$work/calls"; then
  ok 'listing triggers a snapshot reindex'
else
  bad 'listing triggers a snapshot reindex' "$(cat "$work/calls" 2>/dev/null)"
fi

eq "$(req POST /v1.Backrest/GetConfig '{}' application/proto)" 200 'protobuf GetConfig is served'
hasnt 'protobuf redaction removes the password' 'SECRET-PW'
hasnt 'protobuf redaction removes the environment' 'AKIA'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
