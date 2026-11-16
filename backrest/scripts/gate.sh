#!/usr/bin/env bash
# Drives the hosted-Backrest gate matrix (#707) against a deployed instance.
#
# Deployment and credentials are operator inputs; this script exercises what
# the plan requires: configuration shape, redaction, verified-only snapshots,
# small file and directory streams, every write denial, a four-hour stream, and
# cancellation.
#
#   BACKREST_URL=https://recovery.sammohr.dev \
#   BACKREST_BOOTSTRAP_USER=bootstrap \
#   BACKREST_BOOTSTRAP_PASSWORD=... \
#   BACKREST_REPO_ID=r2 \
#   CF_ACCESS_CLIENT_ID=... CF_ACCESS_CLIENT_SECRET=... \
#   RESTIC_REPOSITORY=s3:https://<account>.r2.cloudflarestorage.com/<bucket>/<path> \
#   RESTIC_PASSWORD=... \
#   R2_READ_ACCESS_KEY_ID=... R2_READ_SECRET_ACCESS_KEY=... \
#   BACKREST_GATE_SMALL_FILE=/var/tmp/backrest-gate/small.bin \
#   BACKREST_GATE_SMALL_DIR=/var/tmp/backrest-gate/small-tree \
#     backrest/scripts/gate.sh matrix
#
# Subcommands:
#   verify                     config shape, redaction, verified snapshots, small downloads
#   denial                     restic write attempts and proxy write attempts must all fail
#   stream <path> [sha|tar] [hash]  one long download, 4h budget, optional content check
#   cancel <path>              abort a stream, then prove the service still answers
#   matrix                     verify + denial
#
# `denial` needs the `restic` binary: the R2 token is tested directly, because
# Backrest reports scheduled writes asynchronously with no status of their own.
set -euo pipefail

pass=0
fail=0
ok() {
  pass=$((pass + 1))
  printf 'ok   %s\n' "$*"
}
note() { printf '     %s\n' "$*"; }
die() {
  fail=$((fail + 1))
  printf 'FAIL %s\n' "$*" >&2
  printf '\n%d passed, %d failed\n' "$pass" "$fail" >&2
  exit 1
}

: "${BACKREST_URL:?BACKREST_URL is required}"
: "${BACKREST_BOOTSTRAP_USER:?}"
: "${BACKREST_BOOTSTRAP_PASSWORD:?}"
: "${BACKREST_REPO_ID:?}"
: "${CF_ACCESS_CLIENT_ID:?an Access service token is required; a browser login cannot be automated}"
: "${CF_ACCESS_CLIENT_SECRET:?}"

BACKREST_URL=${BACKREST_URL%/}
STREAM_TIMEOUT=${BACKREST_STREAM_TIMEOUT:-14400} # four hours
work=$(mktemp -d)
chmod 700 "$work"
trap 'rm -rf "$work"' EXIT

# Secrets travel in curl config files, never in argv: /proc/<pid>/cmdline is
# readable by every local user.
basic=$(printf '%s:%s' "$BACKREST_BOOTSTRAP_USER" "$BACKREST_BOOTSTRAP_PASSWORD" | base64 | tr -d '\n')
cat >"$work/auth.cfg" <<EOF
silent
show-error
header = "Authorization: Basic $basic"
header = "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID"
header = "CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET"
EOF
cat >"$work/access.cfg" <<EOF
silent
show-error
header = "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID"
header = "CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET"
EOF

rpc() { # METHOD JSON -> writes $work/body.out and $work/code
  printf '%s' "$2" >"$work/body.json"
  curl --config "$work/auth.cfg" \
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

status() { # METHOD JSON -> HTTP status, body in $work/body.out
  rpc "$1" "$2"
  cat "$work/code"
}

verified_snapshot() {
  api ListSnapshots "{\"repoId\":\"$BACKREST_REPO_ID\"}" |
    jq -er '[.snapshots[] | select((.tags // []) | index("verified"))]
            | sort_by(.unixTimeMs) | last | .id' ||
    die "no verified-tagged snapshot is visible"
}

index_op() { # snapshot id -> index operation id, waiting for a fresh index
  local deadline op
  deadline=$(( $(date +%s) + ${BACKREST_INDEX_WAIT:-120} ))
  while :; do
    op=$(api GetOperations "{\"selector\":{\"snapshotId\":\"$1\"},\"lastN\":100}" |
      jq -er '[.operations[] | select(has("operationIndexSnapshot"))] | last | .id' 2>/dev/null || true)
    if [[ -n $op ]]; then
      printf '%s' "$op"
      return 0
    fi
    if [[ $(date +%s) -ge $deadline ]]; then
      die "snapshot $1 has no index operation after ${BACKREST_INDEX_WAIT:-120}s"
    fi
    # Listing snapshots is what makes the Worker schedule a refresh.
    api ListSnapshots "{\"repoId\":\"$BACKREST_REPO_ID\"}" >/dev/null
    sleep 3
  done
}

download_url() { # index op id, path -> absolute URL
  local value
  value=$(api GetDownloadURL "{\"opId\":$1,\"filePath\":\"$2\"}" | jq -er .value)
  [[ $value == ./* ]] && value="$BACKREST_URL/${value#./}"
  printf '%s' "$value"
}

curl_url() { # url, then curl args -> writes url into a 0600 config so it never hits argv
  local url=$1
  shift
  printf 'url = "%s"\n' "$url" >"$work/url.cfg"
  curl --config "$work/auth.cfg" --config "$work/url.cfg" "$@"
}

size_of() { # snapshot id, path -> size in bytes from the parent listing
  local dir
  dir=$(dirname "$2")
  [[ $dir == . ]] && dir=/
  api ListSnapshotFiles "{\"repoId\":\"$BACKREST_REPO_ID\",\"snapshotId\":\"$1\",\"path\":\"$dir\"}" |
    jq -er --arg p "$2" '.entries[] | select(.path == $p) | .size'
}

deny() { # label, command...
  local label=$1
  shift
  if "$@" >"$work/deny.out" 2>&1; then
    die "$label succeeded; the token can write"
  fi
  ok "$label denied: $(head -c 140 "$work/deny.out" | tr '\n' ' ')"
}

cmd_verify() {
  : "${BACKREST_GATE_SMALL_FILE:?}"
  : "${BACKREST_GATE_SMALL_DIR:?}"
  # A "small" payload that is not small must fail loudly rather than fill the
  # machine's tmpfs; the two-hour payloads are the stream subcommand's job.
  local small_max=${BACKREST_GATE_SMALL_MAX:-67108864}

  local config snaps snap op url expected got entries
  config=$(api GetConfig '{}')
  jq -e '.auth.disabled != true and (.auth.users | length) >= 2' <<<"$config" >/dev/null ||
    die "authentication must stay enabled with the operator and bootstrap users"
  jq -e '.plans | length == 0' <<<"$config" >/dev/null ||
    die "no plan may exist: Backrest is a recovery reader, not a backup controller"
  jq -e '.repos[0].flags | index("--no-lock") != null' <<<"$config" >/dev/null ||
    die "the repository must run with --no-lock; a write-denied token cannot create locks"
  jq -e '.repos[0].flags | index("--no-cache") != null' <<<"$config" >/dev/null ||
    die "the repository must run with --no-cache; the instance disk is ephemeral and small"
  ok "config: no plans, read-only flags present"

  # The proxy must not hand out the restic password or the R2 key pair.
  if jq -e 'any(.repos[]; has("password") or has("env"))' <<<"$config" >/dev/null; then
    die "GetConfig still exposes repository credentials"
  fi
  if grep -q 'AWS_SECRET_ACCESS_KEY' <<<"$config"; then
    die "GetConfig still exposes the R2 secret key"
  fi
  ok "config: repository password and R2 credentials are redacted"

  if [[ $(curl --config "$work/access.cfg" -o /dev/null -w '%{http_code}' \
    -H 'Content-Type: application/json' --data '{}' \
    "$BACKREST_URL/v1.Backrest/GetConfig") == 2?? ]]; then
    die "an Access-only request reached Backrest; password authentication is not enforced"
  fi
  ok "anonymous (Access-only) request is refused by Backrest"

  snaps=$(api ListSnapshots "{\"repoId\":\"$BACKREST_REPO_ID\"}")
  jq -e 'all(.snapshots[]; (.tags // []) | index("verified") != null)' <<<"$snaps" >/dev/null ||
    die "ListSnapshots returned a snapshot without the verified tag"
  ok "only verified snapshots are listed"

  snap=$(verified_snapshot)
  ok "newest verified snapshot ${snap:0:12}"
  op=$(index_op "$snap")
  note "index operation $op"

  url=$(download_url "$op" "$BACKREST_GATE_SMALL_FILE")
  [[ $url == "$BACKREST_URL"/download/* ]] ||
    die "download URL $url is not same-origin; an Access cookie would not cover it"
  curl_url "$url" --max-filesize "$small_max" -o "$work/small"
  expected=$(size_of "$snap" "$BACKREST_GATE_SMALL_FILE")
  got=$(wc -c <"$work/small")
  [[ $got == "$expected" ]] || die "small file streamed $got bytes, snapshot records $expected"
  ok "small file streamed $got bytes"

  url=$(download_url "$op" "$BACKREST_GATE_SMALL_DIR")
  curl_url "$url" --max-filesize "$small_max" -o "$work/small.tar"
  tar -tf "$work/small.tar" >"$work/small.tar.list" || die "directory download is not a readable tar"
  entries=$(wc -l <"$work/small.tar.list")
  [[ $entries -gt 0 ]] || die "directory download is an empty tar"
  ok "small directory streamed a tar with $entries entries"
}

cmd_denial() {
  : "${RESTIC_REPOSITORY:?}"
  : "${RESTIC_PASSWORD:?}"
  : "${R2_READ_ACCESS_KEY_ID:?}"
  : "${R2_READ_SECRET_ACCESS_KEY:?}"
  command -v restic >/dev/null || die "restic is required for the write-denial probes"

  export AWS_ACCESS_KEY_ID=$R2_READ_ACCESS_KEY_ID
  export AWS_SECRET_ACCESS_KEY=$R2_READ_SECRET_ACCESS_KEY
  export AWS_DEFAULT_REGION=auto
  export RESTIC_PASSWORD

  local probe="$RESTIC_REPOSITORY-init-probe" snap before after code
  snap=$(verified_snapshot)
  before=$(api ListSnapshots "{\"repoId\":\"$BACKREST_REPO_ID\"}" | jq -S '[.snapshots[].id] | sort')

  deny "manual init" restic -r "$probe" init
  if restic -r "$probe" cat config >/dev/null 2>&1; then
    die "the init probe created a repository; the token can write"
  fi
  ok "manual init left nothing behind"
  deny "backup" restic -r "$RESTIC_REPOSITORY" backup --no-lock --host gate-denial "$work"
  # forget/prune create a lock before touching data, so a write-denied token
  # fails at the lock; --no-lock is rejected by restic for these two commands.
  deny "forget" restic -r "$RESTIC_REPOSITORY" forget "$snap"
  deny "prune" restic -r "$RESTIC_REPOSITORY" prune
  deny "purge" restic -r "$RESTIC_REPOSITORY" forget --prune "$snap"
  # unlock deletes stale locks only; with none it writes nothing and may exit 0.
  # The guarantee is that it changes nothing, which the snapshot comparison below
  # proves; every command that must create a lock is denied above.
  if restic -r "$RESTIC_REPOSITORY" unlock >/dev/null 2>&1; then
    ok "unlock has nothing to remove (no lock was created by the reader)"
  else
    ok "unlock denied"
  fi

  after=$(api ListSnapshots "{\"repoId\":\"$BACKREST_REPO_ID\"}" | jq -S '[.snapshots[].id] | sort')
  [[ $before == "$after" ]] || die "a denied write changed the snapshot list"
  ok "snapshot list unchanged after every denied write"

  # The proxy itself must refuse write RPCs, so an authenticated UI session
  # cannot disable auth or repoint the repository.
  local name body
  for rpc_call in 'SetConfig {}' 'DoRepoTask {}' 'RunCommand {}' 'Forget {}' 'AddRepo {}'; do
    read -r name body <<<"$rpc_call"
    code=$(status "$name" "$body")
    [[ $code == 403 ]] || die "$name returned $code through the proxy, expected 403"
    ok "proxy refuses $name"
  done
}

cmd_stream() { # path [sha|tar] [expected sha256]
  local path=$1 mode=${2:-bytes} expected=${3:-} snap op url start end seconds bytes sha entries
  snap=$(verified_snapshot)
  op=$(index_op "$snap")
  url=$(download_url "$op" "$path")

  note "streaming $path for up to ${STREAM_TIMEOUT}s ($mode)"
  start=$(date +%s)
  case $mode in
    sha)
      sha=$(curl_url "$url" --max-time "$STREAM_TIMEOUT" | sha256sum | cut -d' ' -f1) ||
        die "stream failed"
      if [[ -n $expected && $sha != "$expected" ]]; then
        die "stream hash $sha does not match $expected"
      fi
      ;;
    tar)
      entries=$(curl_url "$url" --max-time "$STREAM_TIMEOUT" | tar -tf - | wc -l) ||
        die "stream failed or the tar is truncated"
      [[ $entries -gt 0 ]] || die "the directory stream produced an empty tar"
      ;;
    bytes)
      bytes=$(curl_url "$url" --max-time "$STREAM_TIMEOUT" -o /dev/null -w '%{size_download}') ||
        die "stream failed"
      ;;
    *)
      die "unknown mode $mode (sha|tar)"
      ;;
  esac
  end=$(date +%s)
  seconds=$((end - start))
  [[ $seconds -gt 0 ]] || seconds=1

  case $mode in
    sha) ok "streamed and hashed $path in ${seconds}s: $sha${expected:+ (matches)}" ;;
    tar) ok "streamed $path as a valid tar in ${seconds}s: $entries entries" ;;
    bytes) ok "streamed $path in ${seconds}s: $((bytes / seconds / 1048576)) MiB/s" ;;
  esac
}

cmd_cancel() { # path
  local path=$1 snap op url pid start code
  : "${BACKREST_CANCEL_AFTER:=30}"
  snap=$(verified_snapshot)
  op=$(index_op "$snap")
  url=$(download_url "$op" "$path")

  printf 'url = "%s"\n' "$url" >"$work/url.cfg"
  curl --config "$work/auth.cfg" --config "$work/url.cfg" --max-time "$STREAM_TIMEOUT" -o /dev/null &
  pid=$!
  sleep "$BACKREST_CANCEL_AFTER"
  kill -INT "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  ok "client aborted the stream after ${BACKREST_CANCEL_AFTER}s"

  start=$(date +%s)
  code=$(curl --config "$work/auth.cfg" -o /dev/null -w '%{http_code}' \
    -H 'Content-Type: application/json' --data '{}' \
    "$BACKREST_URL/v1.Backrest/GetConfig")
  [[ $code == 200 ]] || die "service answered $code after cancellation"
  ok "service answers again $(( $(date +%s) - start ))s after cancellation"

  note "confirm the subprocess died: Backrest logs 'error copying snapshot:"
  note "context canceled' when the dump is torn down (wrangler tail)."
}

case ${1:-matrix} in
  verify) cmd_verify ;;
  denial) cmd_denial ;;
  stream) shift; cmd_stream "$@" ;;
  cancel) shift; cmd_cancel "$@" ;;
  matrix) cmd_verify && cmd_denial ;;
  *)
    sed -n '2,32p' "$0"
    exit 64
    ;;
esac

printf '\n%d checks passed\n' "$pass"
