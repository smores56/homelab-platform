#!/usr/bin/env bash
# Compare the Immich the cluster serves today with the copy on smortress.
#
# #709's gate and #725's cutover both need one fact first: the host copy is the
# authoritative library, not a partial or lagging replica. Comparing
# `/api/server/statistics` answers the countable half of that — assets, videos
# and bytes — and a mismatch means the cutover would serve a different library.
#
#   CLUSTER_URL=https://photos.sammohr.dev CLUSTER_API_KEY=… \
#   HOST_URL=https://smortress.<tailnet>.ts.net HOST_API_KEY=… \
#     scripts/compare-photos-origin.sh
#
# Exit 0 only when both copies report the same photos and videos, and their
# usage is within EDGE_USAGE_DELTA bytes (default 0).
#
# `--self-test` runs the parser and the verdict against fixtures, no network.
# Env: CURL_BIN (tests), EDGE_TIMEOUT (15).
set -uo pipefail

cluster_url=${CLUSTER_URL:-https://photos.sammohr.dev}
host_url=${HOST_URL:-}
cluster_key=${CLUSTER_API_KEY:-}
host_key=${HOST_API_KEY:-}
usage_delta=${EDGE_USAGE_DELTA:-0}
timeout_s=${EDGE_TIMEOUT:-15}
curl_bin=${CURL_BIN:-curl}
pass=0
fail=0

ok() {
  pass=$((pass + 1))
  printf 'ok   %s\n' "$1"
}
bad() {
  fail=$((fail + 1))
  printf 'FAIL %s\n' "$1"
  [[ -n ${2:-} ]] && printf '     %s\n' "$2"
  return 0
}

fetch() { # <url> <api key> -> statistics JSON
  "$curl_bin" --silent --show-error --fail --max-time "$timeout_s" \
    --header "x-api-key: $2" --header 'accept: application/json' \
    "$1/api/server/statistics" 2>"$work/err"
}

stats() { # <json> <field>
  jq -er --arg f "$2" '.[$f] | numbers' <<<"$1" 2>/dev/null
}

compare() { # <field> <tolerance>
  local field=$1 tolerance=${2:-0} left right delta
  left=$(stats "$cluster" "$field") || { bad "cluster reports $field" "$(head -c 120 "$work/err")"; return; }
  right=$(stats "$host" "$field") || { bad "host reports $field"; return; }
  delta=$((left - right))
  ((delta < 0)) && delta=$((-delta))
  if ((delta <= tolerance)); then
    ok "$field: cluster $left, host $right"
  else
    bad "$field: cluster $left, host $right" "delta $delta exceeds $tolerance"
  fi
}

run_self_test() {
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  cat >"$work/curl" <<'EOF'
#!/usr/bin/env bash
url=${!#}
cluster='{"photos":10,"videos":2,"usage":123456}'
host='{"photos":10,"videos":2,"usage":123456}'
case $url in
    *sammohr.dev*) printf '%s' "${STUB_CLUSTER:-$cluster}" ;;
    *) printf '%s' "${STUB_HOST:-$host}" ;;
esac
EOF
  chmod +x "$work/curl"
  local rc
  CURL_BIN=$work/curl HOST_URL=https://host CLUSTER_API_KEY=k HOST_API_KEY=k \
    bash "$0" >"$work/out" 2>&1
  rc=$?
  if [[ $rc == 0 ]] && grep -q '^ok   photos: cluster 10, host 10$' "$work/out"; then
    printf 'ok   equal copies pass\n'
  else
    printf 'FAIL equal copies pass\n'
    return 1
  fi
  STUB_HOST='{"photos":9,"videos":2,"usage":123456}' CURL_BIN=$work/curl HOST_URL=https://host \
    CLUSTER_API_KEY=k HOST_API_KEY=k bash "$0" >"$work/out" 2>&1
  rc=$?
  if [[ $rc == 1 ]] && grep -q '^FAIL photos' "$work/out"; then
    printf 'ok   a lagging host copy fails\n'
  else
    printf 'FAIL a lagging host copy fails\n'
    return 1
  fi
  STUB_HOST='{"photos":10,"videos":2,"usage":124456}' CURL_BIN=$work/curl HOST_URL=https://host \
    CLUSTER_API_KEY=k HOST_API_KEY=k EDGE_USAGE_DELTA=1000 bash "$0" >"$work/out" 2>&1
  rc=$?
  if [[ $rc == 0 ]]; then
    printf 'ok   the usage tolerance is honoured\n'
  else
    printf 'FAIL the usage tolerance is honoured\n'
    return 1
  fi
  return 0
}

if [[ ${1:-} == --self-test ]]; then
  run_self_test
  exit $?
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

[[ -n $host_url ]] || { printf 'compare-photos-origin: set HOST_URL\n' >&2; exit 2; }
[[ -n $cluster_key && -n $host_key ]] || {
  printf 'compare-photos-origin: set CLUSTER_API_KEY and HOST_API_KEY\n' >&2
  exit 2
}
command -v jq >/dev/null 2>&1 || { printf 'compare-photos-origin: jq is missing\n' >&2; exit 2; }

cluster=$(fetch "$cluster_url" "$cluster_key") || {
  printf 'compare-photos-origin: cannot read %s (status/curl error): %s\n' \
    "$cluster_url" "$(head -c 200 "$work/err")" >&2
  exit 2
}
host=$(fetch "$host_url" "$host_key") || {
  printf 'compare-photos-origin: cannot read %s (status/curl error): %s\n' \
    "$host_url" "$(head -c 200 "$work/err")" >&2
  exit 2
}

compare photos
compare videos
compare usage "$usage_delta"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
exit $((fail > 0))
