#!/usr/bin/env bash
# Prove the public edge (design #725) answers for the two names and for nothing
# else. Run it after the DNS cutover; before that the names do not resolve here
# and no certificate can exist, so the pre-cutover proof is the box's own
# `provision/edge/verify.sh` with EXPECT_UPSTREAM=1.
#
# The probes are the design's claims, not a smoke test:
#
#   - both names answer over TLS, with a certificate valid for the name;
#   - that certificate is not within EDGE_CERT_MIN_DAYS of expiry;
#   - each name answers as *its application*, not as anything else that lives
#     on smortress's 443. That port carries the agent gateway APIs and
#     /wallpapers, and the edge proxies to dedicated ports so those never
#     appear here. A status code cannot prove it: Immich's SPA answers 200 for
#     any path and OPDShelf answers 401 for any path. The signatures are:
#       Immich  -> 200 and its own HTML shell;
#       OPDShelf-> 401 with a WWW-Authenticate challenge.
#     Serve's wallpaper tree is a bare <pre> listing and the agent gateway is a
#     text/plain 404, so neither can satisfy those.
#
# Exit 0 only when every probe passes. No repository check can see the VPS, so
# this script and `provision/edge/verify.sh` are the gate.
#
#   scripts/verify-public-edge.sh
#
# Knobs: EDGE_TIMEOUT (10 s), EDGE_CERT_MIN_DAYS (14), EDGE_CAFILE, CURL_BIN
# and OPENSSL_BIN (tests/edge/check.sh drives the same code).
set -uo pipefail

photos=photos.sammohr.dev
opds=opds.sammohr.dev
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

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# <url> <body file> <header file> -> status code. The body and headers are what
# the signature checks read; the code alone says nothing about which handler
# answered.
fetch() {
  "$curl_bin" --silent --show-error --output "$2" --dump-header "$3" \
    --max-time "$timeout_s" --write-out '%{http_code}' "$1" 2>/dev/null
}

certificate_ok() { # <name>
  local name=$1 pem
  # `-checkend` is an `openssl x509` option, not an `s_client` one: s_client
  # rejects it as an unknown option and exits 1, so this probe failed against
  # every host, healthy or not, until the check moved to a second invocation.
  pem=$("$openssl_bin" s_client -connect "$name:443" -servername "$name" \
    -verify_hostname "$name" -CAfile "$cafile" </dev/null 2>/dev/null) || return 1
  grep -q 'Verify return code: 0 (ok)' <<<"$pem" || return 1
  "$openssl_bin" x509 -noout -checkend "$((min_days * 86400))" <<<"$pem" >/dev/null 2>&1
}

for host in "$photos" "$opds"; do
  code=$(fetch "https://$host/" "$work/body" "$work/hdr")
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

# Immich: any path is the app's own shell, never the wallpaper tree (a <pre>
# listing) and never the agent gateway (text/plain 404 on 443).
for path in /apps/agent-local/v1 /apps/agent-general/v1 /wallpapers/; do
  code=$(fetch "https://$photos$path" "$work/body" "$work/hdr")
  if [[ $code == 200 ]] && grep -q '<html' "$work/body"; then
    ok "$path answers as Immich on $photos"
  else
    bad "$path answers as Immich on $photos" \
      "got '$code' and '$(head -c 60 "$work/body" 2>/dev/null | tr -d '\n')'"
  fi
done

# OPDShelf: its own auth challenge, never a status-page or a listing.
for path in /apps/agent-local/v1 /apps/agent-general/v1 /wallpapers/; do
  code=$(fetch "https://$opds$path" "$work/body" "$work/hdr")
  if [[ $code == 401 ]] && grep -qi '^www-authenticate:' "$work/hdr"; then
    ok "$path answers as OPDShelf's auth on $opds"
  else
    bad "$path answers as OPDShelf's auth on $opds" "got '$code'"
  fi
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
exit $((fail > 0))
