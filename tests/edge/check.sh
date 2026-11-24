#!/usr/bin/env bash
# Behavioural checks for scripts/verify-public-edge.sh (design #725).
#
# The probe cannot reach the VPS from CI, so the script's own contract is what
# is tested here: it fails when a name is down, when Immich's paths answer as
# anything but the app (a wallpaper listing, the agent gateway's 404), when
# OPDShelf's paths lose their auth challenge, when the recovery page is not
# Backrest's behind its guard, and when a certificate does not verify or is
# close to expiry.
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
        [[ $url == https://recovery.sammohr.dev/ ]] && code=502
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
    https://recovery.sammohr.dev/*)
        if [[ ${STUB_MODE:-} == wrongbody ]]; then
            printf '%s' '<!doctype html><pre><a href="Backrest/">x</a></pre>' >"$body"
            printf 'HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nServer: Caddy\r\nServer: backrest-guard\r\n\r\n' >"$hdr"
        elif [[ ${STUB_MODE:-} == noguard ]]; then
            printf '%s' '<!doctype html><html><head><title>Backrest</title></head></html>' >"$body"
            printf 'HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nServer: Caddy\r\n\r\n' >"$hdr"
        else
            printf '%s' '<!doctype html><html><head><title>Backrest</title></head></html>' >"$body"
            printf 'HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nServer: Caddy\r\nServer: backrest-guard\r\n\r\n' >"$hdr"
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
eq "$(grep -c '^ok' "$work/out")" 13 'three names, three certificates, three paths each and Backrest'
eq "$(grep -c '^FAIL' "$work/out")" 0 'nothing fails on a healthy edge'
if grep -qF 'ok   recovery.sammohr.dev answers as Backrest' "$work/out"; then
    ok 'the recovery page answers as Backrest'
else
    bad 'the recovery page answers as Backrest' "$(cat "$work/out")"
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
# s_client has no -checkend: passing it there made every run fail on a healthy
# host. The option belongs on `openssl x509`, reading the PEM s_client printed.
if grep -F -- 's_client' "$work/ossl.log" | grep -qF -- '-checkend'; then
    bad 's_client is not passed -checkend' "$(cat "$work/ossl.log")"
else
    ok 's_client is not passed -checkend'
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

STUB_MODE=down
run
eq "$?" 1 'a recovery origin answering 502 fails the run'
if grep -qF 'FAIL recovery.sammohr.dev answers over TLS' "$work/out"; then
    ok 'the recovery failure names the name that did not answer'
else
    bad 'the recovery failure names the name that did not answer' "$(cat "$work/out")"
fi

STUB_MODE=wrongbody
run
eq "$?" 1 'a page that is not Backrest fails the run'
# The stub answers 200 text/html, so only the signature can tell: the status
# probe stays green while the signature probe does not.
if grep -qF 'ok   recovery.sammohr.dev answers over TLS (200)' "$work/out"; then
    ok 'the wrong page still looks healthy by status alone'
else
    bad 'the wrong page still looks healthy by status alone' "$(cat "$work/out")"
fi
if grep -qF 'FAIL recovery.sammohr.dev answers as Backrest' "$work/out"; then
    ok 'the signature failure names the page that was not Backrest'
else
    bad 'the signature failure names the page that was not Backrest' "$(cat "$work/out")"
fi

STUB_MODE=noguard
run
eq "$?" 1 'a page without the backrest-guard server fails the run'
if grep -qF 'FAIL recovery.sammohr.dev answers as Backrest' "$work/out"; then
    ok 'Backrest without its guard is not accepted as the recovery page'
else
    bad 'Backrest without its guard is not accepted as the recovery page' "$(cat "$work/out")"
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

# --- the CAA invariant (scripts/verify-caa.sh) --------------------------------
# The zone's CAA records and the CA behind the edge's certificate are two
# networks away, so the mapping and the scan are what is tested: a record set
# that omits the served CA must fail, an empty set must not, and every issuer
# organization the script knows must land on its CA domain.
caa_script=scripts/verify-caa.sh
if [[ -r $caa_script ]]; then
    ok "$caa_script is present"
else
    bad "$caa_script is present"
fi

cat >"$work/dig" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_DIG_LOG"
cat "$STUB_CAA_FILE"
EOF
cat >"$work/caa-openssl" <<'EOF'
#!/usr/bin/env bash
case $1 in
    s_client) printf '%s' '-----BEGIN CERTIFICATE-----
stub
-----END CERTIFICATE-----
' ;;
    x509) printf 'issuer=%s\n' "$STUB_ISSUER" ;;
esac
EOF
chmod +x "$work/dig" "$work/caa-openssl"

gts_issuer='CN=WE1,O=Google Trust Services,C=US'

# <fixture file> then one `0 issue "ca"`-shaped record per argument.
caa_fixture() {
    local file=$1 record
    shift
    {
        printf ';; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1\n'
        for record in "$@"; do
            printf 'sammohr.dev.\t300\tIN\tCAA\t%s\n' "$record"
        done
    } >"$file"
}

run_caa() { # <fixture> <issuer>
    STUB_DIG_LOG=$work/dig.log STUB_CAA_FILE=$1 STUB_ISSUER=$2 \
        DIG_BIN=$work/dig OPENSSL_BIN=$work/caa-openssl \
        bash "$caa_script" >"$work/caa.out" 2>"$work/caa.err"
}

caa_fixture "$work/caa-empty"
run_caa "$work/caa-empty" "$gts_issuer"
eq "$?" 0 'an empty CAA set passes'
eq "$(grep -c '^FAIL' "$work/caa.out")" 0 'an empty CAA set fails nothing'
if grep -qF 'note no CAA records for sammohr.dev' "$work/caa.out"; then
    ok 'an empty CAA set says so instead of passing silently'
else
    bad 'an empty CAA set says so instead of passing silently' "$(cat "$work/caa.out")"
fi
eq "$(grep -c '^ok' "$work/caa.out")" 1 'an empty CAA set still reports the served issuer'

caa_fixture "$work/caa-gts" '0 issue "pki.goog"' '0 issuewild "pki.goog"'
run_caa "$work/caa-gts" "$gts_issuer"
eq "$?" 0 'a CAA issue naming the served CA passes'
if grep -qF "ok   sammohr.dev's CAA issue admits pki.goog" "$work/caa.out"; then
    ok 'the pass names the record, the CA and the name'
else
    bad 'the pass names the record, the CA and the name' "$(cat "$work/caa.out")"
fi

caa_fixture "$work/caa-le" '0 issue "letsencrypt.org"'
run_caa "$work/caa-le" "$gts_issuer"
eq "$?" 1 'a CAA issue that omits the served CA fails'
if grep -qF "FAIL sammohr.dev's CAA records do not admit pki.goog" "$work/caa.out"; then
    ok 'the failure names the CA it expected and the issuer it saw'
else
    bad 'the failure names the CA it expected and the issuer it saw' "$(cat "$work/caa.out")"
fi
if grep -qF 'issue=letsencrypt.org' "$work/caa.out"; then
    ok 'the failure prints the records it read'
else
    bad 'the failure prints the records it read' "$(cat "$work/caa.out")"
fi

caa_fixture "$work/caa-onlywild" '0 issuewild "pki.goog"'
run_caa "$work/caa-onlywild" "$gts_issuer"
eq "$?" 0 'issuewild alone admits the served CA'
if grep -qF "CAA issuewild admits pki.goog" "$work/caa.out"; then
    ok 'the pass reports which record admitted it'
else
    bad 'the pass reports which record admitted it' "$(cat "$work/caa.out")"
fi

caa_fixture "$work/caa-params" '0 issue "pki.goog; accounturi=https://acme.example/acct/1"'
run_caa "$work/caa-params" "$gts_issuer"
eq "$?" 0 'parameters after the domain are not read as part of it'

caa_fixture "$work/caa-lookalike" '0 issue "notpki.goog"'
run_caa "$work/caa-lookalike" "$gts_issuer"
eq "$?" 1 'a domain that merely ends in the CA domain does not admit it'

# Every organization the script maps, both ways: the CA domain it maps to is
# admitted, and a record naming a different CA is not.
while IFS='|' read -r org domain; do
    caa_fixture "$work/caa-map" "0 issue \"$domain\""
    run_caa "$work/caa-map" "CN=X,O=$org,C=US"
    eq "$?" 0 "'$org' maps to $domain"
done <<'EOF'
Google Trust Services|pki.goog
Google Trust Services LLC|pki.goog
Let's Encrypt|letsencrypt.org
DigiCert Inc|digicert.com
Sectigo Limited|sectigo.com
ZeroSSL|zerossl.com
EOF

run_caa "$work/caa-gts" 'CN=X,O=Some Other CA,C=US'
eq "$?" 1 'an unmapped issuer organization fails'

run_caa "$work/caa-gts" ''
eq "$?" 1 'a name that serves no readable certificate fails'
if grep -qF 'serves no certificate whose issuer can be read' "$work/caa.out"; then
    ok 'the certificate failure says what could not be read'
else
    bad 'the certificate failure says what could not be read' "$(cat "$work/caa.out")"
fi

printf ';; ->>HEADER<<- opcode: QUERY, status: SERVFAIL, id: 1\n' >"$work/caa-servfail"
run_caa "$work/caa-servfail" "$gts_issuer"
eq "$?" 1 'a SERVFAIL is not read as an empty CAA set'
if grep -qF "FAIL dig could not answer a CAA query for sammohr.dev" "$work/caa.out"; then
    ok 'the resolver failure is named rather than passed as empty'
else
    bad 'the resolver failure is named rather than passed as empty' "$(cat "$work/caa.out")"
fi

STUB_CAA_FILE=$work/caa-gts STUB_ISSUER=$gts_issuer \
    DIG_BIN=$work/no-such-dig OPENSSL_BIN=$work/caa-openssl \
    bash "$caa_script" >"$work/caa.out" 2>"$work/caa.err"
eq "$?" 2 'a host without dig fails instead of skipping the assertion'
if grep -qF 'verify-caa: ' "$work/caa.err"; then
    ok 'the missing tool is named'
else
    bad 'the missing tool is named' "$(cat "$work/caa.err")"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
exit $((fail > 0))
