#!/usr/bin/env bash
# Behavioural checks for scripts/verify-public-edge.sh (design #725).
#
# The probe cannot reach the VPS from CI, so the script's own contract is what
# is tested here: it fails when a name is down, when Immich's paths answer as
# anything but the app (a wallpaper listing, the agent gateway's 404), when
# OPDShelf's paths lose their auth challenge, and when a certificate does not
# verify or is close to expiry.
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

# The curl stub records argv, then writes the body and headers the script asks
# for and prints a status. STUB_MODE is the failure each case injects.
cat >"$work/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG"
url= body=/dev/null hdr=/dev/null
while (($#)); do
    case $1 in
        --output) body=$2; shift ;;
        --dump-header) hdr=$2; shift ;;
        --*) ;;
        *) url=$1 ;;
    esac
    shift
done
code=200
printf '%s' '<!doctype html><html class="dark"></html>' >"$body"
printf 'HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n' >"$hdr"
case $STUB_MODE in
    down)
        [[ $url == https://photos.sammohr.dev/ ]] && code=502
        ;;
    leak)
        if [[ $url == https://photos.sammohr.dev/wallpapers/ ]]; then
            printf '%s' '<!doctype html><pre><a href="Reddit-Wallpapers/">x</a></pre>' >"$body"
        fi
        ;;
    noauth)
        ;;
esac
case $url in
    https://opds.sammohr.dev/*)
        if [[ ${STUB_MODE:-} == noauth ]]; then
            printf '%s' '<!doctype html><html></html>' >"$body"
            printf 'HTTP/1.1 200 OK\r\n\r\n' >"$hdr"
        else
            code=401
            : >"$body"
            printf 'HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm="opdshelf"\r\n\r\n' >"$hdr"
        fi
        ;;
esac
printf '%s' "$code"
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
    EDGE_CERT_MIN_DAYS=${EDGE_CERT_MIN_DAYS:-14} \
        STUB_MODE=${STUB_MODE:-} \
        STUB_CERT_FAIL=${STUB_CERT_FAIL:-0} \
        STUB_LOG=$work/curl.log STUB_OSSL_LOG=$work/ossl.log \
        CURL_BIN=$work/curl OPENSSL_BIN=$work/openssl \
        bash "$script" >"$work/out" 2>"$work/err"
}

# --- a healthy edge -----------------------------------------------------------

run
eq "$?" 0 'a healthy edge exits 0'
eq "$(grep -c '^ok' "$work/out")" 10 'two names, two certificates and three paths each'
eq "$(grep -c '^FAIL' "$work/out")" 0 'nothing fails on a healthy edge'
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
# The stub keys on the URL, so a regression to plain HTTP or a hardcoded port
# would still look healthy; the argv is the only witness.
if grep -qF -- 'https://photos.sammohr.dev/' "$work/curl.log"; then
    ok 'every probe uses https on the name'
else
    bad 'every probe uses https on the name' "$(cat "$work/curl.log")"
fi
if grep -qF -- ':80' "$work/curl.log"; then
    bad 'no probe addresses port 80' "$(cat "$work/curl.log")"
else
    ok 'no probe addresses port 80'
fi

# --- the failures this script exists to catch ---------------------------------

STUB_MODE=down
run
eq "$?" 1 'an origin returning 502 fails the run'
if grep -qF 'FAIL photos.sammohr.dev answers over TLS' "$work/out"; then
    ok 'the failure names the name that did not answer'
else
    bad 'the failure names the name that did not answer' "$(cat "$work/out")"
fi

STUB_MODE=leak
run
eq "$?" 1 'a published wallpaper listing fails the run'
if grep -qF 'FAIL /wallpapers/ answers as Immich on photos.sammohr.dev' "$work/out"; then
    ok 'the leak names the path and the name it leaked on'
else
    bad 'the leak names the path and the name it leaked on' "$(cat "$work/out")"
fi

STUB_MODE=noauth
run
eq "$?" 1 'OPDShelf answering without its challenge fails the run'
if grep -qF "FAIL /apps/agent-local/v1 answers as OPDShelf's auth" "$work/out"; then
    ok 'the failure names the path and the name'
else
    bad 'the failure names the path and the name' "$(cat "$work/out")"
fi

STUB_MODE=
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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
exit $((fail > 0))
