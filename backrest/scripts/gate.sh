#!/usr/bin/env bash
# Drives the hosted-Backrest gate matrix (#707) against a deployed instance.
#
# The deployment and its credentials are operator inputs; this script only
# exercises what the plan requires: readiness after a cold start, authenticated
# snapshot selection, small file and directory streams, every attempted R2
# write denial, a long stream, and cancellation.
#
#   BACKREST_URL=https://backrest-gate.sammohr.dev \
#   BACKREST_BOOTSTRAP_USER=bootstrap \
#   BACKREST_BOOTSTRAP_PASSWORD=... \
#   BACKREST_REPO_ID=r2 \
#   CF_ACCESS_CLIENT_ID=... CF_ACCESS_CLIENT_SECRET=... \
#   BACKREST_GATE_SMALL_FILE=/gate/small.txt \
#   BACKREST_GATE_SMALL_DIR=/gate/small-tree \
#   BACKREST_GATE_BIG_FILE=/gate/100g.bin \
#   BACKREST_GATE_BIG_DIR=/gate/100g-tree \
#     backrest/scripts/gate.sh matrix
#
# Subcommands:
#   verify                configuration shape, verified snapshot, small downloads
#   denial                every write attempt must fail and leave snapshots alone
#   stream <path> [sha]   one long download, 4h budget, optional content check
#   cancel <path>         abort a stream, then prove the service still answers
#   matrix                verify + denial
set -euo pipefail

die() {
  printf 'FAIL %s\n' "$*" >&2
  exit 1
}
pass=0
ok() {
  pass=$((pass + 1))
  printf 'ok   %s\n' "$*"
}
note() { printf '     %s\n' "$*"; }

: "${BACKREST_URL:?BACKREST_URL is required}"
: "${BACKREST_BOOTSTRAP_USER:?}"
: "${BACKREST_BOOTSTRAP_PASSWORD:?}"
: "${BACKREST_REPO_ID:?}"
: "${CF_ACCESS_CLIENT_ID:?an Access service token is required; a browser login cannot be automated}"
: "${CF_ACCESS_CLIENT_SECRET:?}"

BACKREST_URL=${BACKREST_URL%/}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
umask 077

# Secrets travel in a curl config file, never in argv: /proc/<pid>/cmdline is
# readable by every user on a shared machine.
basic=$(printf '%s:%s' "$BACKREST_BOOTSTRAP_USER" "$BACKREST_BOOTSTRAP_PASSWORD" | base64 | tr -d '\n')
cat >"$work/curl.cfg" <<EOF
silent
show-error
header = "Authorization: Basic $basic"
header = "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID"
header = "CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET"
EOF

rpc() { # METHOD JSON -> writes $work/body.out and $work/code, no stdout
  printf '%s' "$2" >"$work/body.json"
  curl --config "$work/curl.cfg" \
    -H 'Content-Type: application/json' \
    --data-binary "@$work/body.json" \
    -o "$work/body.out" -w '%{http_code}' \
    "$BACKREST_URL/v1.Backrest/$1" >"$work/code"
}

api() { # METHOD JSON -> body; dies unless 2xx
  rpc "$1" "$2"
  local code
  code=$(cat "$work/code")
  case $code in
    2??) cat "$work/body.out" ;;
    *) die "$1 returned HTTP $code: $(head -c 400 "$work/body.out")" ;;
  esac
}

verified_snapshot() {
  api ListSnapshots "{\"repoId\":\"$BACKREST_REPO_ID\"}" |
    jq -er '[.snapshots[] | select((.tags // []) | index("verified"))]
            | sort_by(.unixTimeMs) | last | .id' ||
    die "no verified-tagged snapshot in the repository"
}

index_op() { # snapshot id -> index operation id
  api GetOperations "{\"selector\":{\"snapshotId\":\"$1\"},\"lastN\":100}" |
    jq -er '[.operations[] | select(has("operationIndexSnapshot"))] | last | .id' ||
    die "snapshot $1 has no index operation; a download URL can only be minted for one"
}

download_url() { # index op id, path
  api GetDownloadURL "{\"opId\":$1,\"filePath\":\"$2\"}" | jq -er .
}

size_of() { # snapshot id, path -> size in bytes, from its parent directory listing
  local dir
  dir=$(dirname "$2")
  [[ $dir == . ]] && dir=/
  api ListSnapshotFiles "{\"repoId\":\"$BACKREST_REPO_ID\",\"snapshotId\":\"$1\",\"path\":\"$dir\"}" |
    jq -er --arg p "$2" '.entries[] | select(.path == $p) | .size'
}

fetch_url() { # signed URL, output file
  curl --config "$work/curl.cfg" "$1" -o "$2"
}

cmd_verify() {
  : "${BACKREST_GATE_SMALL_FILE:?}"
  : "${BACKREST_GATE_SMALL_DIR:?}"

  local config snap op url expected got
  config=$(api GetConfig '{}')
  jq -e '.auth.disabled == false and (.auth.users | length) >= 2' <<<"$config" >/dev/null ||
    die "authentication must stay enabled with the operator and bootstrap users"
  jq -e '.plans | length == 0' <<<"$config" >/dev/null ||
    die "no plan may exist: Backrest is a recovery reader, not a backup controller"
  jq -e '.repos[0].flags | index("--no-lock") != null' <<<"$config" >/dev/null ||
    die "the repository must run with --no-lock; a write-denied token cannot create locks"
  jq -e '.repos[0].flags | index("--no-cache") != null' <<<"$config" >/dev/null ||
    die "the repository must run with --no-cache; the container disk is ephemeral and small"
  ok "authenticated config: no plans, read-only flags present"

  snap=$(verified_snapshot)
  ok "newest verified snapshot ${snap:0:12}"
  op=$(index_op "$snap")
  note "index operation $op"

  url=$(download_url "$op" "$BACKREST_GATE_SMALL_FILE")
  [[ $url == "$BACKREST_URL"/* ]] ||
    die "download URL $url is not same-origin; an Access cookie would not cover it"
  fetch_url "$url" "$work/small"
  expected=$(size_of "$snap" "$BACKREST_GATE_SMALL_FILE")
  got=$(wc -c <"$work/small")
  [[ $got == "$expected" ]] ||
    die "small file streamed $got bytes, snapshot records $expected"
  ok "small file streamed $got bytes"

  url=$(download_url "$op" "$BACKREST_GATE_SMALL_DIR")
  fetch_url "$url" "$work/small.tar"
  tar -tf "$work/small.tar" >"$work/small.tar.list" ||
    die "directory download is not a readable tar archive"
  [[ -s $work/small.tar.list ]] || die "directory download is an empty tar archive"
  ok "small directory streamed a tar with $(wc -l <"$work/small.tar.list") entries"
}

snapshot_state() {
  api ListSnapshots "{\"repoId\":\"$BACKREST_REPO_ID\"}" |
    jq -S '[.snapshots[].id] | sort'
}

expect_denied() { # label, method, json
  local label=$1 method=$2 body=$3 code status message
  rpc "$method" "$body"
  code=$(cat "$work/code")
  body=$(cat "$work/body.out")
  if [[ $code == 2?? ]]; then
    status=$(jq -r '.status? // "STATUS_UNKNOWN"' <<<"$body")
  else
    status="HTTP$code"
  fi
  if [[ $status =~ ^(STATUS_SUCCESS|STATUS_WARNING)$ ]]; then
    die "$label succeeded; the R2 token is not read-only"
  fi
  message=$(jq -r '.displayMessage // .code // .message // empty' <<<"$body" 2>/dev/null | head -c 200 || true)
  ok "$label denied ($status${message:+: $message})"
}

cmd_denial() {
  local before after snap
  before=$(snapshot_state)
  snap=$(verified_snapshot)

  expect_denied "restic init" RunCommand \
    "{\"repoId\":\"$BACKREST_REPO_ID\",\"command\":\"init\"}"
  expect_denied "prune" DoRepoTask \
    "{\"repoId\":\"$BACKREST_REPO_ID\",\"task\":\"TASK_PRUNE\"}"
  expect_denied "unlock" DoRepoTask \
    "{\"repoId\":\"$BACKREST_REPO_ID\",\"task\":\"TASK_UNLOCK\"}"
  expect_denied "forget" Forget \
    "{\"repoId\":\"$BACKREST_REPO_ID\",\"planId\":\"gate\",\"snapshotId\":\"$snap\"}"

  after=$(snapshot_state)
  [[ $before == "$after" ]] || die "a denied write changed the snapshot list"
  ok "snapshot list unchanged after every denied write"
}

cmd_stream() { # path [expected sha256]
  local path=$1 expected=${2:--} snap op url start end seconds bytes sha
  : "${BACKREST_STREAM_TIMEOUT:=15000}"
  snap=$(verified_snapshot)
  op=$(index_op "$snap")
  url=$(download_url "$op" "$path")

  note "streaming $path for up to ${BACKREST_STREAM_TIMEOUT}s"
  start=$(date +%s)
  if [[ $expected == - ]]; then
    bytes=$(curl --config "$work/curl.cfg" --max-time "$BACKREST_STREAM_TIMEOUT" \
      "$url" -o /dev/null -w '%{size_download}')
  else
    sha=$(curl --config "$work/curl.cfg" --max-time "$BACKREST_STREAM_TIMEOUT" \
      "$url" | sha256sum | cut -d' ' -f1)
  fi
  end=$(date +%s)
  seconds=$((end - start))
  [[ $seconds -gt 0 ]] || seconds=1

  if [[ $expected != - ]]; then
    [[ $sha == "$expected" ]] || die "stream hash $sha != $expected"
    ok "streamed and hashed $path in ${seconds}s"
  else
    ok "streamed $path (${bytes} bytes in ${seconds}s, $((bytes / seconds / 1048576)) MiB/s)"
  fi
}

cmd_cancel() { # path
  local path=$1 snap op url pid start status
  : "${BACKREST_CANCEL_AFTER:=30}"
  snap=$(verified_snapshot)
  op=$(index_op "$snap")
  url=$(download_url "$op" "$path")

  curl --config "$work/curl.cfg" --max-time 3600 "$url" -o /dev/null &
  pid=$!
  sleep "$BACKREST_CANCEL_AFTER"
  kill -INT "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  ok "client aborted the stream after ${BACKREST_CANCEL_AFTER}s"

  start=$(date +%s)
  status=$(curl --config "$work/curl.cfg" -o /dev/null -w '%{http_code}' \
    -H 'Content-Type: application/json' --data '{}' \
    "$BACKREST_URL/v1.Backrest/GetConfig")
  [[ $status == 200 ]] || die "service answered $status after cancellation"
  ok "service answers again $(( $(date +%s) - start ))s after cancellation"

  note "confirm the subprocess died: in the worker log, Backrest logs"
  note "'error copying snapshot: context canceled' when the dump is torn down."
}

case ${1:-matrix} in
  verify) cmd_verify ;;
  denial) cmd_denial ;;
  stream) shift; cmd_stream "$@" ;;
  cancel) shift; cmd_cancel "$@" ;;
  matrix) cmd_verify && cmd_denial ;;
  *)
    sed -n '2,28p' "$0"
    exit 64
    ;;
esac

printf '\n%d checks passed\n' "$pass"
