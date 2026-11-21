#!/usr/bin/env bash
# Prove the public edge (design #725) answers for the two names and for nothing
# else. Runs from anywhere: before the DNS cutover, set EDGE_IP to the VPS
# address and every probe resolves the names to it; after the cutover, leave it
# unset and the probes use public DNS.
#
# The probes are the design's own claims, not a smoke test:
#
#   - both names answer over TLS, with a certificate valid for the name;
#   - that certificate is not within EDGE_CERT_MIN_DAYS of expiry;
#   - the agent gateway APIs and the wallpaper library are absent on both names,
#     because the edge proxies to dedicated Serve ports and never to 443.
#
# Exit 0 only when all of them pass. No repository check can see the VPS, so
# this script and provision/edge/verify.sh are the gate.
#
#   EDGE_IP=203.0.113.7 scripts/verify-public-edge.sh
#
# Knobs: EDGE_IP, EDGE_TIMEOUT (10 s), EDGE_CERT_MIN_DAYS (14), EDGE_CAFILE,
# CURL_BIN and OPENSSL_BIN (tests/edge/check.sh drives the same code).
set -uo pipefail

photos=photos.sammohr.dev
opds=opds.sammohr.dev
edge_ip=${EDGE_IP:-}
timeout_s=${EDGE_TIMEOUT:-10}
min_days=${EDGE_CERT_MIN_DAYS:-14}
cafile=${EDGE_CAFILE:-/etc/ssl/certs/ca-certificates.crt}
curl_bin=${CURL_BIN:-curl}
openssl_bin=${OPENSSL_BIN:-openssl}

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

for tool in "$curl_bin" "$openssl_bin"; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'verify-public-edge: %s is not installed\n' "$tool" >&2
    exit 2
  }
done

# The status code, or 000 when the connection never got an answer. A resolve
# override keeps the probe honest before the cutover: it proves the box answers
# for the name without touching the zone.
http_code() { # <name> <url>
  local args=(
    --silent --show-error --output /dev/null
    --max-time "$timeout_s" --write-out '%{http_code}'
  )
  if [[ -n $edge_ip ]]; then
    args+=(--resolve "$1:443:$edge_ip")
  fi
  "$curl_bin" "${args[@]}" "$2" 2>/dev/null
}

certificate_ok() { # <name>
  local name=$1 connect=$1 out
  if [[ -n $edge_ip ]]; then
    connect=$edge_ip
  fi
  out=$("$openssl_bin" s_client -connect "$connect:443" -servername "$name" \
    -verify_hostname "$name" -CAfile "$cafile" \
    -checkend "$((min_days * 86400))" </dev/null 2>/dev/null) || return 1
  grep -q 'Verify return code: 0 (ok)' <<<"$out"
}

for host in "$photos" "$opds"; do
  code=$(http_code "$host" "https://$host/")
  if [[ $code =~ ^(2|3)[0-9][0-9]$ || $code == 401 ]]; then
    ok "$host answers over TLS ($code)"
  else
    bad "$host answers over TLS" "got '$code'"
  fi
  if certificate_ok "$host"; then
    ok "$host presents a certificate valid for the name for $min_days more days"
  else
    bad "$host presents a certificate valid for the name for $min_days more days" \
      "s_client failed for $host"
  fi
done

# 443 on smortress also carries the agent gateway APIs and the wallpaper tree.
# A 404 here is the proof that the edge did not proxy that port.
for host in "$photos" "$opds"; do
  for path in /apps/agent-local/v1 /apps/agent-general/v1 /wallpapers/; do
    code=$(http_code "$host" "https://$host$path")
    if [[ $code == 404 ]]; then
      ok "$path is not published on $host"
    else
      bad "$path is not published on $host" "got '$code', want 404"
    fi
  done
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
exit $((fail > 0))
