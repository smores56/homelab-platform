#!/usr/bin/env bash
# Behavioural checks for scripts/verify-public-edge.sh (design #725).
#
# The probe cannot reach the VPS from CI, so the script's own contract is what
# is tested here: it resolves the names to EDGE_IP when one is given, it fails
# when a public name is down, it fails when a path that must not be published
# answers anything but 404, and it fails when the certificate check fails.
#
#   tests/edge/check.sh
set -uo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root" || exit 1

script=scripts/verify-public-edge.sh
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
  printf 'FAIL %s\n' "$1"
  [[ -n ${2:-} ]] && printf '     %s\n' "$2"
  return 0
}
eq() {
  if [[ $1 == "$2" ]]; then ok "$3"; else bad "$3" "got '$1' want '$2'"; fi
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The stubs stand in for the two tools, so every case is offline. curl records
# its argv and answers from STUB_ROOT_CODE/STUB_LEAK_CODE; openssl records its
# argv and fails when STUB_CERT_FAIL is set.
cat >"$work/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG"
for last; do :; done
case $last in
    *'/apps/'*|*/wallpapers/) printf '%s' "${STUB_LEAK_CODE:-404}" ;;
    *) printf '%s' "${STUB_ROOT_CODE:-200}" ;;
esac
EOF
cat >"$work/openssl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_OSSL_LOG"
[[ ${STUB_CERT_FAIL:-0} == 1 ]] && exit 1
printf 'Verify return code: 0 (ok)\n'
EOF
chmod +x "$work/curl" "$work/openssl"

run() {
    : >"$work/curl.log"
    : >"$work/ossl.log"
    EDGE_IP=${EDGE_IP-203.0.113.7} \
        EDGE_CERT_MIN_DAYS=${EDGE_CERT_MIN_DAYS:-14} \
        STUB_ROOT_CODE=${STUB_ROOT_CODE:-} \
        STUB_LEAK_CODE=${STUB_LEAK_CODE:-} \
        STUB_CERT_FAIL=${STUB_CERT_FAIL:-0} \
        STUB_LOG=$work/curl.log STUB_OSSL_LOG=$work/ossl.log \
        CURL_BIN=$work/curl OPENSSL_BIN=$work/openssl \
        bash "$script" >"$work/out" 2>"$work/err"
}

# --- a healthy edge -----------------------------------------------------------

run
eq "$?" 0 'a healthy edge exits 0'
eq "$(grep -c '^ok' "$work/out")" 10 'both names are probed for reachability, certificate and three paths each'
eq "$(grep -c '^FAIL' "$work/out")" 0 'nothing fails on a healthy edge'
if grep -qF -- '--resolve photos.sammohr.dev:443:203.0.113.7' "$work/curl.log"; then
    ok 'EDGE_IP pins the photos name for the pre-cutover probe'
else
    bad 'EDGE_IP pins the photos name for the pre-cutover probe' "$(cat "$work/curl.log")"
fi
if grep -qF -- '--resolve opds.sammohr.dev:443:203.0.113.7' "$work/curl.log"; then
    ok 'EDGE_IP pins the opds name for the pre-cutover probe'
else
    bad 'EDGE_IP pins the opds name for the pre-cutover probe' "$(cat "$work/curl.log")"
fi
if grep -qF -- '-verify_hostname opds.sammohr.dev' "$work/ossl.log"; then
    ok 'the certificate is verified for the name, not just for any name'
else
    bad 'the certificate is verified for the name, not just for any name' "$(cat "$work/ossl.log")"
fi
if grep -qF -- '-checkend 1209600' "$work/ossl.log"; then
    ok 'the expiry check uses the default 14-day window'
else
    bad 'the expiry check uses the default 14-day window' "$(cat "$work/ossl.log")"
fi

# --- the failure this script exists to catch ----------------------------------

STUB_ROOT_CODE=502
run
eq "$?" 1 'an origin returning 502 fails the run'
if grep -qF 'FAIL photos.sammohr.dev answers over TLS' "$work/out"; then
    ok 'the failure names the name that did not answer'
else
    bad 'the failure names the name that did not answer' "$(cat "$work/out")"
fi

STUB_ROOT_CODE=
STUB_LEAK_CODE=200
run
eq "$?" 1 'a published /wallpapers fails the run'
if grep -qF 'FAIL /wallpapers/ is not published on opds.sammohr.dev' "$work/out"; then
    ok 'the leak names the path and the name it leaked on'
else
    bad 'the leak names the path and the name it leaked on' "$(cat "$work/out")"
fi

STUB_LEAK_CODE=
STUB_CERT_FAIL=1
run
eq "$?" 1 'a certificate that fails verification fails the run'
if grep -qF 'FAIL photos.sammohr.dev presents a certificate' "$work/out"; then
    ok 'the certificate failure names the name'
else
    bad 'the certificate failure names the name' "$(cat "$work/out")"
fi

STUB_CERT_FAIL=0
EDGE_CERT_MIN_DAYS=3
run
if grep -qF -- '-checkend 259200' "$work/ossl.log"; then
    ok 'the expiry window is configurable'
else
    bad 'the expiry window is configurable' "$(cat "$work/ossl.log")"
fi

# --- the cutover mode ---------------------------------------------------------

EDGE_CERT_MIN_DAYS=
EDGE_IP=
run
eq "$?" 0 'an unset EDGE_IP still probes through public DNS'
if grep -qF -- '--resolve' "$work/curl.log"; then
    bad 'an unset EDGE_IP adds no resolve override' "$(cat "$work/curl.log")"
else
    ok 'an unset EDGE_IP adds no resolve override'
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
exit $((fail > 0))
