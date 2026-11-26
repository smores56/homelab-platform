#!/usr/bin/env bats
# bats file_tags=edge
# Behavioural checks for scripts/verify-public-edge.sh (design #725).
#
# The probe cannot reach the VPS from CI, so the script's own contract is what
# is tested here: it fails when a name is down, when Immich's paths answer as
# anything but the app (a wallpaper listing, the agent gateway's 404), when
# OPDShelf's paths lose their auth challenge, when the recovery page is not
# Backrest's behind its guard, and when a certificate does not verify or is
# close to expiry.
#
#   bats tests/edge/check.bats
#
# The shell suite this replaced ran every case against one stub set in one
# process and kept a running count; here each case is its own test with its own
# scratch directory under $BATS_TEST_TMPDIR, and the stubs every case shares are
# installed once per file.
load ../helpers

script=scripts/verify-public-edge.sh
caa_script=scripts/verify-caa.sh

setup_file() {
    [ -r "$script" ] || {
        printf 'FAIL %s is missing\n' "$script" >&2
        return 1
    }
    install_stubs
}

setup() {
    work=$BATS_TEST_TMPDIR
    stubs=$BATS_FILE_TMPDIR/stubs
}

# --- the stubs ---------------------------------------------------------------
# The curl stub records argv, then writes the body and headers the script asks
# for and prints a status. STUB_MODE is the failure each case injects.
install_stubs() {
    local bin=$BATS_FILE_TMPDIR/stubs
    mkdir -p "$bin"
    cat >"$bin/curl" <<'EOF'
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
    cat >"$bin/openssl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_OSSL_LOG"
[[ ${STUB_CERT_FAIL:-0} == 1 ]] && exit 1
printf 'Verify return code: 0 (ok)\n'
EOF
    # The CAA scan's stubs: dig answers the fixture the case wrote, and openssl
    # prints the issuer the case states.
    cat >"$bin/dig" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_DIG_LOG"
cat "$STUB_CAA_FILE"
EOF
    cat >"$bin/caa-openssl" <<'EOF'
#!/usr/bin/env bash
case $1 in
    s_client) printf '%s' '-----BEGIN CERTIFICATE-----
stub
-----END CERTIFICATE-----
' ;;
    x509) printf 'issuer=%s\n' "$STUB_ISSUER" ;;
esac
EOF
    chmod +x "$bin/curl" "$bin/openssl" "$bin/dig" "$bin/caa-openssl"
}

# probe: run the verifier against the stubs. The caller states the failure it
# injects in its own environment (STUB_MODE, STUB_CERT_FAIL, EDGE_CERT_MIN_DAYS),
# which is where the defaults below apply.
probe() {
    rc=0
    : >"$work/curl.log"
    : >"$work/ossl.log"
    EDGE_CERT_MIN_DAYS=${EDGE_CERT_MIN_DAYS:-14} \
        STUB_MODE=${STUB_MODE:-} \
        STUB_CERT_FAIL=${STUB_CERT_FAIL:-0} \
        STUB_LOG=$work/curl.log STUB_OSSL_LOG=$work/ossl.log \
        CURL_BIN=$stubs/curl OPENSSL_BIN=$stubs/openssl \
        bash "$script" >"$work/out" 2>"$work/err" || rc=$?
}

out() { cat "$work/out"; }
ossl_log() { cat "$work/ossl.log"; }
curl_log() { cat "$work/curl.log"; }

# --- a healthy edge -----------------------------------------------------------

@test "a healthy edge exits 0" {
    probe
    assert_equal "$rc" 0
}

@test "three names, three certificates, three paths each and Backrest" {
    probe
    assert_equal "$(grep -c '^ok' "$work/out")" 13
}

@test "nothing fails on a healthy edge" {
    probe
    assert_equal "$(grep -c '^FAIL' "$work/out")" 0
}

@test "the recovery page answers as Backrest" {
    probe
    assert_contains "$(out)" 'ok   recovery.sammohr.dev answers as Backrest'
}

@test "the certificate is verified for the name, not just for any name" {
    probe
    assert_contains "$(ossl_log)" '-verify_hostname opds.sammohr.dev'
}

@test "the expiry check uses the default 14-day window" {
    probe
    assert_contains "$(ossl_log)" '-checkend 1209600'
}

# s_client has no -checkend: passing it there made every run fail on a healthy
# host. The option belongs on `openssl x509`, reading the PEM s_client printed.
@test "s_client is not passed -checkend" {
    probe
    assert_equal "$(grep -F -- 's_client' "$work/ossl.log" | grep -cF -- '-checkend')" 0
}

# The stub keys on the URL, so a regression to plain HTTP or a hardcoded port
# would still look healthy; the argv is the only witness.
@test "every probe uses https on the name" {
    probe
    assert_contains "$(curl_log)" 'https://photos.sammohr.dev/'
}

@test "no probe addresses port 80" {
    probe
    assert_equal "$(grep -cF -- ':80' "$work/curl.log")" 0
}

# --- the failures this script exists to catch ---------------------------------

@test "an origin returning 502 fails the run" {
    STUB_MODE=down
    probe
    assert_equal "$rc" 1
}

@test "the failure names the name that did not answer" {
    STUB_MODE=down
    probe
    assert_contains "$(out)" 'FAIL photos.sammohr.dev answers over TLS'
}

@test "a published wallpaper listing fails the run" {
    STUB_MODE=leak
    probe
    assert_equal "$rc" 1
}

@test "the leak names the path and the name it leaked on" {
    STUB_MODE=leak
    probe
    assert_contains "$(out)" 'FAIL /wallpapers/ answers as Immich on photos.sammohr.dev'
}

@test "OPDShelf answering without its challenge fails the run" {
    STUB_MODE=noauth
    probe
    assert_equal "$rc" 1
}

@test "the failure names the path and the name" {
    STUB_MODE=noauth
    probe
    assert_contains "$(out)" "FAIL /apps/agent-local/v1 answers as OPDShelf's auth"
}

@test "a recovery origin answering 502 fails the run" {
    STUB_MODE=down
    probe
    assert_equal "$rc" 1
}

@test "the recovery failure names the name that did not answer" {
    STUB_MODE=down
    probe
    assert_contains "$(out)" 'FAIL recovery.sammohr.dev answers over TLS'
}

@test "a page that is not Backrest fails the run" {
    STUB_MODE=wrongbody
    probe
    assert_equal "$rc" 1
}

# The stub answers 200 text/html, so only the signature can tell: the status
# probe stays green while the signature probe does not.
@test "the wrong page still looks healthy by status alone" {
    STUB_MODE=wrongbody
    probe
    assert_contains "$(out)" 'ok   recovery.sammohr.dev answers over TLS (200)'
}

@test "the signature failure names the page that was not Backrest" {
    STUB_MODE=wrongbody
    probe
    assert_contains "$(out)" 'FAIL recovery.sammohr.dev answers as Backrest'
}

@test "a page without the backrest-guard server fails the run" {
    STUB_MODE=noguard
    probe
    assert_equal "$rc" 1
}

@test "Backrest without its guard is not accepted as the recovery page" {
    STUB_MODE=noguard
    probe
    assert_contains "$(out)" 'FAIL recovery.sammohr.dev answers as Backrest'
}

@test "a certificate that fails verification fails the run" {
    STUB_CERT_FAIL=1
    probe
    assert_equal "$rc" 1
}

@test "the certificate failure names the name" {
    STUB_CERT_FAIL=1
    probe
    assert_contains "$(out)" 'FAIL photos.sammohr.dev presents a certificate'
}

@test "the expiry window is configurable" {
    EDGE_CERT_MIN_DAYS=3
    probe
    assert_contains "$(ossl_log)" '-checkend 259200'
}

# --- the CAA invariant (scripts/verify-caa.sh) --------------------------------
# The zone's CAA records and the CA behind the edge's certificate are two
# networks away, so the mapping and the scan are what is tested: a record set
# that omits the served CA must fail, an empty set must not, and every issuer
# organization the script knows must land on its CA domain.

gts_issuer='CN=WE1,O=Google Trust Services,C=US'

# caa_fixture <file> <record...>: a dig answer carrying the records given, one
# `0 issue "ca"`-shaped record per argument.
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

# run_caa <fixture> <issuer> [CAA_WILDCARD]: the scan against those stubs.
run_caa() {
    rc=0
    STUB_DIG_LOG=$work/dig.log STUB_CAA_FILE=$1 STUB_ISSUER=$2 CAA_WILDCARD=${3:-0} \
        DIG_BIN=$stubs/dig OPENSSL_BIN=$stubs/caa-openssl \
        bash "$caa_script" >"$work/caa.out" 2>"$work/caa.err" || rc=$?
}

caa_out() { cat "$work/caa.out"; }

@test "scripts/verify-caa.sh is present" {
    [ -r "$caa_script" ]
}

@test "an empty CAA set passes" {
    caa_fixture "$work/caa-empty"
    run_caa "$work/caa-empty" "$gts_issuer"
    assert_equal "$rc" 0
}

@test "an empty CAA set fails nothing" {
    caa_fixture "$work/caa-empty"
    run_caa "$work/caa-empty" "$gts_issuer"
    assert_equal "$(grep -c '^FAIL' "$work/caa.out")" 0
}

@test "an empty CAA set says so instead of passing silently" {
    caa_fixture "$work/caa-empty"
    run_caa "$work/caa-empty" "$gts_issuer"
    assert_contains "$(caa_out)" 'note no CAA records for sammohr.dev'
}

@test "an empty CAA set still reports the served issuer" {
    caa_fixture "$work/caa-empty"
    run_caa "$work/caa-empty" "$gts_issuer"
    assert_equal "$(grep -c '^ok' "$work/caa.out")" 1
}

@test "a CAA issue naming the served CA passes" {
    caa_fixture "$work/caa-gts" '0 issue "pki.goog"' '0 issuewild "pki.goog"'
    run_caa "$work/caa-gts" "$gts_issuer"
    assert_equal "$rc" 0
}

@test "the pass names the record, the CA and the name" {
    caa_fixture "$work/caa-gts" '0 issue "pki.goog"' '0 issuewild "pki.goog"'
    run_caa "$work/caa-gts" "$gts_issuer"
    assert_contains "$(caa_out)" "ok   sammohr.dev's CAA issue admits pki.goog"
}

@test "a CAA issue that omits the served CA fails" {
    caa_fixture "$work/caa-le" '0 issue "letsencrypt.org"'
    run_caa "$work/caa-le" "$gts_issuer"
    assert_equal "$rc" 1
}

@test "the failure names the CA it expected and the issuer it saw" {
    caa_fixture "$work/caa-le" '0 issue "letsencrypt.org"'
    run_caa "$work/caa-le" "$gts_issuer"
    assert_contains "$(caa_out)" "FAIL sammohr.dev's CAA issue does not admit pki.goog"
}

@test "the failure prints the records it read" {
    caa_fixture "$work/caa-le" '0 issue "letsencrypt.org"'
    run_caa "$work/caa-le" "$gts_issuer"
    assert_contains "$(caa_out)" 'issue=letsencrypt.org'
}

@test "issuewild alone admits no non-wildcard order" {
    caa_fixture "$work/caa-onlywild" '0 issuewild "pki.goog"'
    run_caa "$work/caa-onlywild" "$gts_issuer"
    assert_equal "$rc" 1
}

@test "the wildcard-only failure prints the record it read" {
    caa_fixture "$work/caa-onlywild" '0 issuewild "pki.goog"'
    run_caa "$work/caa-onlywild" "$gts_issuer"
    assert_contains "$(caa_out)" 'issuewild=pki.goog'
}

# A wildcard order reads `issuewild` and never `issue`; the mode is one more run
# of the same script, not a second record in the same set.
@test "CAA_WILDCARD=1: issuewild admits the wildcard name" {
    caa_fixture "$work/caa-onlywild" '0 issuewild "pki.goog"'
    run_caa "$work/caa-onlywild" "$gts_issuer" 1
    assert_equal "$rc" 0
}

@test "the wildcard pass names issuewild rather than issue" {
    caa_fixture "$work/caa-onlywild" '0 issuewild "pki.goog"'
    run_caa "$work/caa-onlywild" "$gts_issuer" 1
    assert_contains "$(caa_out)" "ok   sammohr.dev's CAA issuewild admits pki.goog"
}

@test "CAA_WILDCARD=1: issue alone does not admit the wildcard name" {
    caa_fixture "$work/caa-onlyissue" '0 issue "pki.goog"'
    run_caa "$work/caa-onlyissue" "$gts_issuer" 1
    assert_equal "$rc" 1
}

@test "parameters after the domain are not read as part of it" {
    caa_fixture "$work/caa-params" '0 issue "pki.goog; accounturi=https://acme.example/acct/1"'
    run_caa "$work/caa-params" "$gts_issuer"
    assert_equal "$rc" 0
}

@test "a domain that merely ends in the CA domain does not admit it" {
    caa_fixture "$work/caa-lookalike" '0 issue "notpki.goog"'
    run_caa "$work/caa-lookalike" "$gts_issuer"
    assert_equal "$rc" 1
}

# Every organization the script maps, both ways: the CA domain it maps to is
# admitted, and a record naming a different CA is not.
caa_maps() { # org domain
    caa_fixture "$work/caa-map" "0 issue \"$2\""
    run_caa "$work/caa-map" "CN=X,O=$1,C=US"
    assert_equal "$rc" 0
}

# bats resolves a registered description with `eval`, so a value carrying a
# quote, a backslash or a backtick has to survive that round trip to keep the
# assertion text the shell suite printed.
registered() { # description command...
    local escaped=${1//\\/\\\\}
    escaped=${escaped//\"/\\\"}
    escaped=${escaped//\`/\\\`}
    escaped=${escaped//\$/\\\$}
    register "$escaped" "${@:2}"
}

while IFS='|' read -r org domain; do
    registered "'$org' maps to $domain" caa_maps "$org" "$domain"
done <<'EOF'
Google Trust Services|pki.goog
Google Trust Services LLC|pki.goog
Let's Encrypt|letsencrypt.org
DigiCert Inc|digicert.com
Sectigo Limited|sectigo.com
ZeroSSL|zerossl.com
EOF

@test "an unmapped issuer organization fails" {
    caa_fixture "$work/caa-gts" '0 issue "pki.goog"' '0 issuewild "pki.goog"'
    run_caa "$work/caa-gts" 'CN=X,O=Some Other CA,C=US'
    assert_equal "$rc" 1
}

@test "a name that serves no readable certificate fails" {
    caa_fixture "$work/caa-gts" '0 issue "pki.goog"' '0 issuewild "pki.goog"'
    run_caa "$work/caa-gts" ''
    assert_equal "$rc" 1
}

@test "the certificate failure says what could not be read" {
    caa_fixture "$work/caa-gts" '0 issue "pki.goog"' '0 issuewild "pki.goog"'
    run_caa "$work/caa-gts" ''
    assert_contains "$(caa_out)" 'serves no certificate whose issuer can be read'
}

@test "a SERVFAIL is not read as an empty CAA set" {
    printf ';; ->>HEADER<<- opcode: QUERY, status: SERVFAIL, id: 1\n' >"$work/caa-servfail"
    run_caa "$work/caa-servfail" "$gts_issuer"
    assert_equal "$rc" 1
}

@test "the resolver failure is named rather than passed as empty" {
    printf ';; ->>HEADER<<- opcode: QUERY, status: SERVFAIL, id: 1\n' >"$work/caa-servfail"
    run_caa "$work/caa-servfail" "$gts_issuer"
    assert_contains "$(caa_out)" 'FAIL dig could not answer a CAA query for sammohr.dev'
}

# A host without the resolver tool cannot make the assertion at all, so the scan
# exits 2 instead of passing on an absent binary.
caa_without_dig() {
    rc=0
    caa_fixture "$work/caa-gts" '0 issue "pki.goog"' '0 issuewild "pki.goog"'
    STUB_CAA_FILE=$work/caa-gts STUB_ISSUER=$gts_issuer \
        DIG_BIN=$work/no-such-dig OPENSSL_BIN=$stubs/caa-openssl \
        bash "$caa_script" >"$work/caa.out" 2>"$work/caa.err" || rc=$?
}

@test "a host without dig fails instead of skipping the assertion" {
    caa_without_dig
    assert_equal "$rc" 2
}

@test "the missing tool is named" {
    caa_without_dig
    assert_contains "$(cat "$work/caa.err")" 'verify-caa: '
}
