#!/usr/bin/env bats
# bats file_tags=fleet
# Behavioural checks for scripts/verify-fleet.sh (task #1030, merging #725's public
# edge probe and #848's tailnet name probe into one run and one verdict).
#
# The probe needs the VPS, six live Service VIPs and a tailnet node to say
# anything, so what is tested here is its contract, offline: the three classes it
# checks and the legs each one carries, and the ways each leg fails. It fails when a
# public name is down, when Immich's paths answer as anything but the app (a
# wallpaper listing, the agent gateway's 404), when OPDShelf's paths lose their auth
# challenge, when the recovery page is not Backrest's behind its guard, when a
# certificate does not verify or is close to expiry, when a tailnet name does not
# resolve, resolves outside the tailnet or shares an address with another name, and
# when an application answers outside the status class it owns -- a 502 from a
# stopped Serve rule, the timeout a drained Service leaves, or a 200 where a login
# redirect belongs. It also checks how the tailnet suffix is found when nobody
# states it (from the node's own FQDN, never a peer's), that one run covers every
# class and prints one verdict, and that a failing CAA check reddens the whole run.
#
#   bats tests/fleet/check.bats
#
# The stubs every case shares are installed once per file; each case is its own
# test with its own scratch directory under $BATS_TEST_TMPDIR.
load ../helpers

script=scripts/verify-fleet.sh
caa_script=scripts/verify-caa.sh

# The suffix every case below states unless it is testing the derivation, one FQDN
# per tailnet application so a case can name the line it expects, and the three
# public names the edge class publishes.
suffix=tail1234.ts.net
apps='immich navidrome assistant agent sync opds'
photos=photos.sammohr.dev
opds=opds.sammohr.dev
recovery=recovery.sammohr.dev
gts_issuer='CN=WE1,O=Google Trust Services,C=US'

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
    # The zone's CAA set every case starts from: it admits the CA the edge is
    # issued by, so the third check is green unless the case says otherwise.
    caa_fixture "$work/caa-gts" '0 issue "pki.goog"'
}

# --- the stubs ---------------------------------------------------------------
# One set for both classes, because one script checks both: the resolver answers one
# distinct VIP per tailnet name and folds the failure a case injects on top; the
# curl stub records argv and answers the status, body and headers each class reads;
# the openssl stub answers like a real pair (s_client prints the verify line, `x509
# -checkend` succeeds only while the window still fits inside the certificate's
# remaining life, and `x509 -issuer` prints the issuer the case states, which is
# what scripts/verify-caa.sh reads).
install_stubs() {
    local bin=$BATS_FILE_TMPDIR/stubs
    mkdir -p "$bin"
    cat >"$bin/getent" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_GETENT_LOG"
name=${!#}
vipof() {
    case ${1%%.*} in
        immich) printf '100.122.108.221' ;;
        navidrome) printf '100.122.108.222' ;;
        assistant) printf '100.122.108.223' ;;
        agent) printf '100.122.108.224' ;;
        sync) printf '100.122.108.225' ;;
        opds) printf '100.122.108.226' ;;
    esac
}
addr=$(vipof "$name")
case ${STUB_MODE:-} in
    noresolve) exit 2 ;;
    # Two names on one address: what a name pointing at another Service, at the
    # retired agent-ui VIP or at the device itself looks like.
    shared) [[ $name == opds.* ]] && addr=$(vipof immich) ;;
    public) addr=203.0.113.7 ;;
esac
# Twice, on purpose: a record answered twice is one address, not a split.
printf '%s\n%s\n' "$addr" "$addr"
EOF
    cat >"$bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_CURL_LOG"
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
host=${url#https://}
host=${host%%/*}
code=200
printf '%s' '<!doctype html><html class="dark"></html>' >"$body"
printf 'HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n' >"$hdr"

# The tailnet names: one code per application, so a case can knock a single name
# out of its class.
case $host in
    immich.*) code=200 ;;
    navidrome.*) code=302 ;;
    assistant.*) code=200 ;;
    agent.*) code=302 ;;
    sync.*) code=200 ;;
    opds.*) code=401 ;;
esac

tailnet=false
case $host in
    photos.sammohr.dev | opds.sammohr.dev | recovery.sammohr.dev) ;;
    *) tailnet=true ;;
esac
case ${STUB_MODE:-} in
    # A stopped Serve rule or a dead origin: one 502 for the name that owns it. The
    # edge's catalogue keeps its challenge, which is its own answer.
    down)
        if $tailnet; then code=502; else
            case $host in photos.* | recovery.*) code=502 ;; esac
        fi
        ;;
    # A drained Service: nothing answers, and curl gives up.
    drained)
        if $tailnet; then
            printf '000'
            exit 28
        fi
        ;;
    # A login redirect spelled differently than the one seen on the day the classes
    # were read: the class is the promise, the spelling is not.
    redirect303)
        if $tailnet; then
            case $host in immich.* | sync.* | assistant.* | opds.*) ;; *) code=303 ;; esac
        fi
        ;;
    # OPDShelf answering 200 instead of refusing: a page where the class says 4xx.
    swap)
        if $tailnet; then case $host in opds.*) code=200 ;; esac; fi
        ;;
    # A published wallpaper listing instead of Immich's shell.
    leak)
        if [[ $url == "https://photos.sammohr.dev/wallpapers/" ]]; then
            printf '%s' '<!doctype html><pre><a href="Reddit-Wallpapers/">x</a></pre>' >"$body"
        fi
        ;;
esac

# The public names: OPDShelf's own challenge, and Backrest's page behind its guard.
case $host in
    opds.sammohr.dev)
        if [[ ${STUB_MODE:-} == noauth ]]; then
            printf '%s' '<!doctype html><html></html>' >"$body"
            printf 'HTTP/1.1 200 OK\r\n\r\n' >"$hdr"
        else
            code=401
            : >"$body"
            printf 'HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm="opdshelf"\r\n\r\n' >"$hdr"
        fi
        ;;
    recovery.sammohr.dev)
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
case $1 in
    s_client)
        if [[ ${STUB_CHAIN_FAIL:-0} == 1 ]]; then
            printf 'Verify return code: 20 (unable to get local issuer certificate)\n'
        else
            printf 'Verify return code: 0 (ok)\n-----BEGIN CERTIFICATE-----\nstub\n-----END CERTIFICATE-----\n'
        fi
        ;;
    x509)
        window= checkend=false issuer=false
        while (($#)); do
            case $1 in
                -checkend) checkend=true; shift; window=$1 ;;
                -issuer) issuer=true ;;
            esac
            shift
        done
        if $issuer; then
            printf 'issuer=%s\n' "$STUB_ISSUER"
        elif $checkend; then
            ((window < ${STUB_REMAINING_DAYS:-120} * 86400))
        fi
        ;;
esac
EOF
    # The CAA scan's dig stub answers the fixture the case wrote, and its openssl
    # answers the issuer the case states -- through the same binary above, which is
    # what makes one stub set serve both scripts.
    cat >"$bin/dig" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_DIG_LOG"
cat "$STUB_CAA_FILE"
EOF
    # The status stub answers the shape `tailscale status --json` has, with a peer's
    # FQDN first on purpose: the probe must read `.Self`, not the first DNSName it
    # finds, and it must take the leading label and the trailing dot off.
    cat >"$bin/tailscale" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_TS_LOG"
printf '{"Peer":{"laptop":{"DNSName":"laptop.tail9999.ts.net."}},"Self":{"DNSName":"smortress.tail1234.ts.net."}}\n'
EOF
    chmod +x "$bin/getent" "$bin/curl" "$bin/openssl" "$bin/dig" "$bin/tailscale"
}

# --- driving the probe -------------------------------------------------------
# probe: run the verifier against the stubs. The caller states the failure it
# injects in its own environment (STUB_MODE, STUB_CHAIN_FAIL, FLEET_CERT_MIN_DAYS...),
# which is where the defaults below apply. FLEET_TAILNET_SUFFIX uses `-` and not
# `:-`: an empty value is how a case asks for the derivation, and a default would
# quietly replace it.
probe() {
    rc=0
    : >"$work/getent.log"
    : >"$work/curl.log"
    : >"$work/ossl.log"
    : >"$work/dig.log"
    : >"$work/ts.log"
    FLEET_CERT_MIN_DAYS=${FLEET_CERT_MIN_DAYS:-14} \
        FLEET_TAILNET_SUFFIX=${FLEET_TAILNET_SUFFIX-$suffix} \
        STUB_MODE=${STUB_MODE:-} \
        STUB_CHAIN_FAIL=${STUB_CHAIN_FAIL:-0} \
        STUB_REMAINING_DAYS=${STUB_REMAINING_DAYS:-120} \
        STUB_CAA_FILE=${STUB_CAA_FILE:-$work/caa-gts} \
        STUB_ISSUER=${STUB_ISSUER:-$gts_issuer} \
        CAA_WILDCARD=${CAA_WILDCARD:-0} \
        STUB_GETENT_LOG=$work/getent.log STUB_CURL_LOG=$work/curl.log \
        STUB_OSSL_LOG=$work/ossl.log STUB_DIG_LOG=$work/dig.log \
        STUB_TS_LOG=$work/ts.log \
        GETENT_BIN=$stubs/getent CURL_BIN=$stubs/curl OPENSSL_BIN=$stubs/openssl \
        DIG_BIN=$stubs/dig \
        TAILSCALE_BIN=${TAILSCALE_BIN-$stubs/tailscale} \
        bash "$script" >"$work/out" 2>"$work/err" || rc=$?
}

out() { cat "$work/out"; }
err() { cat "$work/err"; }
getent_log() { cat "$work/getent.log"; }
curl_log() { cat "$work/curl.log"; }
ossl_log() { cat "$work/ossl.log"; }

# logged <file> <line>: the stub's log must carry the whole line.
logged() {
    grep -qxF -- "$2" "$1" && return 0
    printf 'missing %q in:\n%s\n' "$2" "$(cat "$1")" >&2
    return 1
}

# --- a healthy fleet ---------------------------------------------------------

@test "a healthy fleet exits 0" {
    probe
    assert_equal "$rc" 0
}

# Sixteen edge legs (three names with a status, a chain and an expiry each, three
# Immich paths, three OPDShelf paths and Backrest's signature), twenty-five tailnet
# legs (four per name and the distinct-VIP property) and the CAA check.
@test "every check of both classes and the CAA scan runs and passes" {
    probe
    assert_equal "$(grep -c '^ok' "$work/out")" 42
}

@test "nothing fails on a healthy fleet" {
    probe
    assert_equal "$(grep -c '^FAIL' "$work/out")" 0
}

@test "one run prints one verdict" {
    probe
    assert_equal "$(grep -c ' passed, .* failed$' "$work/out")" 1
}

@test "the verdict covers every class in the run" {
    probe
    assert_contains "$(out)" 'ok   photos.sammohr.dev answers over TLS (200)'
    assert_contains "$(out)" "ok   immich.$suffix resolves into the tailnet"
    assert_contains "$(out)" "ok   the zone's CAA policy admits the CA behind $photos's certificate"
}

@test "the recovery page answers as Backrest" {
    probe
    assert_contains "$(out)" "ok   $recovery answers as Backrest"
}

@test "the certificate is verified for the name, not just for any name" {
    probe
    assert_contains "$(ossl_log)" "-verify_hostname opds.$suffix"
}

@test "the edge names are verified the same way" {
    probe
    assert_contains "$(ossl_log)" "-verify_hostname $recovery"
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

# The stub keys on the URL, so a regression to plain HTTP or a hardcoded port would
# still look healthy; the argv is the only witness.
@test "every probe uses https on the name" {
    probe
    assert_contains "$(curl_log)" "https://$photos/"
    assert_contains "$(curl_log)" "https://opds.$suffix/"
}

@test "no probe addresses port 80" {
    probe
    assert_equal "$(grep -cF -- ':80' "$work/curl.log")" 0
}

@test "every tailnet name is resolved through the system resolver" {
    probe
    for app in $apps; do
        logged "$work/getent.log" "ahostsv4 $app.$suffix" || return 1
    done
}

@test "no two tailnet names share an address" {
    probe
    assert_contains "$(out)" 'ok   all six names resolve to distinct tailnet addresses'
}

# --- the failures this script exists to catch: the public edge -----------------

@test "an origin returning 502 fails the run" {
    STUB_MODE=down
    probe
    assert_equal "$rc" 1
}

@test "the failure names the name that did not answer" {
    STUB_MODE=down
    probe
    assert_contains "$(out)" "FAIL $photos answers over TLS"
}

@test "a published wallpaper listing fails the run" {
    STUB_MODE=leak
    probe
    assert_equal "$rc" 1
}

@test "the leak names the path and the name it leaked on" {
    STUB_MODE=leak
    probe
    assert_contains "$(out)" "FAIL /wallpapers/ answers as Immich on $photos"
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

@test "the recovery failure names the name that did not answer" {
    STUB_MODE=down
    probe
    assert_contains "$(out)" "FAIL $recovery answers over TLS"
}

@test "a page that is not Backrest fails the run" {
    STUB_MODE=wrongbody
    probe
    assert_equal "$rc" 1
}

# The stub answers 200 text/html, so only the signature can tell: the status probe
# stays green while the signature probe does not.
@test "the wrong page still looks healthy by status alone" {
    STUB_MODE=wrongbody
    probe
    assert_contains "$(out)" "ok   $recovery answers over TLS (200)"
}

@test "the signature failure names the page that was not Backrest" {
    STUB_MODE=wrongbody
    probe
    assert_contains "$(out)" "FAIL $recovery answers as Backrest"
}

@test "a page without the backrest-guard server fails the run" {
    STUB_MODE=noguard
    probe
    assert_equal "$rc" 1
}

@test "Backrest without its guard is not accepted as the recovery page" {
    STUB_MODE=noguard
    probe
    assert_contains "$(out)" "FAIL $recovery answers as Backrest"
}

@test "a certificate that fails verification fails the run" {
    STUB_CHAIN_FAIL=1
    probe
    assert_equal "$rc" 1
}

@test "the certificate failure names the name" {
    STUB_CHAIN_FAIL=1
    probe
    assert_contains "$(out)" "FAIL $photos presents a certificate"
}

# 13 days left of an edge certificate is red under the default window: the leg is
# the window and not the clock.
@test "an edge certificate with 13 days left fails the default window" {
    STUB_REMAINING_DAYS=13
    probe
    assert_equal "$rc" 1
}

@test "the edge expiry failure names the window it needed" {
    STUB_REMAINING_DAYS=13
    probe
    assert_contains "$(out)" "FAIL $photos's certificate is valid for 14 more days"
}

@test "the expiry window is configurable" {
    FLEET_CERT_MIN_DAYS=3
    probe
    assert_contains "$(ossl_log)" '-checkend 259200'
}

# --- where the suffix comes from ---------------------------------------------

# No override: the suffix is the node's own FQDN minus its leading label and
# trailing dot. The stub's peer FQDN would give a different tailnet, so a probe that
# read the first DNSName in the JSON fails here.
@test "a run with no suffix stated exits 0" {
    FLEET_TAILNET_SUFFIX=''
    probe
    assert_equal "$rc" 0
}

@test "the suffix is derived from the node FQDN, without its trailing dot" {
    FLEET_TAILNET_SUFFIX=''
    probe
    logged "$work/getent.log" "ahostsv4 immich.$suffix"
}

@test "the suffix comes from .Self, not from a peer" {
    FLEET_TAILNET_SUFFIX=''
    probe
    assert_equal "$(grep -cF 'tail9999' "$work/getent.log")" 0
}

# A stated suffix carrying the dot it came with is still a suffix.
@test "a suffix stated with its trailing dot exits 0" {
    FLEET_TAILNET_SUFFIX="$suffix."
    probe
    assert_equal "$rc" 0
}

@test "the trailing dot is stripped from a stated suffix too" {
    FLEET_TAILNET_SUFFIX="$suffix."
    probe
    logged "$work/getent.log" "ahostsv4 sync.$suffix"
}

@test "a node with no tailscale binary and no stated suffix is a setup error" {
    FLEET_TAILNET_SUFFIX=''
    TAILSCALE_BIN=/nonexistent/tailscale
    probe
    assert_equal "$rc" 2
}

@test "the setup error names the knob that fixes it" {
    FLEET_TAILNET_SUFFIX=''
    TAILSCALE_BIN=/nonexistent/tailscale
    probe
    assert_contains "$(err)" 'FLEET_TAILNET_SUFFIX is unset'
}

# --- the failures this script exists to catch: the tailnet --------------------

@test "a name with no A record fails the run" {
    STUB_MODE=noresolve
    probe
    assert_equal "$rc" 1
}

@test "the failure names the name that did not resolve" {
    STUB_MODE=noresolve
    probe
    assert_contains "$(out)" "FAIL immich.$suffix resolves"
}

@test "a name pointing outside the tailnet fails the run" {
    STUB_MODE=public
    probe
    assert_equal "$rc" 1
}

@test "the failure names the name and the address that is not the tailnet" {
    STUB_MODE=public
    probe
    assert_contains "$(out)" "FAIL immich.$suffix resolves into the tailnet"
}

# Six Services, six VIPs: two names on one address means one of them answers
# through something that is not its own Service.
@test "two names on one address fail the run" {
    STUB_MODE=shared
    probe
    assert_equal "$rc" 1
}

@test "every name still resolves into the tailnet" {
    STUB_MODE=shared
    probe
    assert_equal "$(grep -c "^ok   .* resolves into the tailnet" "$work/out")" 6
}

@test "the failure names the shared address" {
    STUB_MODE=shared
    probe
    assert_contains "$(out)" 'FAIL all six names resolve to distinct tailnet addresses'
}

@test "the chain failure names the tailnet name" {
    STUB_CHAIN_FAIL=1
    probe
    assert_contains "$(out)" "FAIL immich.$suffix presents a certificate"
}

# 13 days left is the case the task names: under the default 14-day window it is
# red, and with a 3-day window it is green, so the leg is the window and not the
# clock.
@test "a certificate with 13 days left fails the default window" {
    STUB_REMAINING_DAYS=13
    probe
    assert_equal "$rc" 1
}

@test "the expiry failure names the window it needed" {
    STUB_REMAINING_DAYS=13
    probe
    assert_contains "$(out)" "FAIL immich.$suffix's certificate is valid for 14 more days"
}

@test "the same certificate passes a 3-day window" {
    FLEET_CERT_MIN_DAYS=3
    STUB_REMAINING_DAYS=13
    probe
    assert_equal "$rc" 0
}

# The classes are promises about what a stranger sees, not about how an
# application spells its redirect: a 303 with a different Location is still the 3xx
# the three UIs owe.
@test "a redirect spelled differently still lands in the 3xx class" {
    STUB_MODE=redirect303
    probe
    assert_equal "$rc" 0
}

@test "the class, not the code, is what is asserted" {
    STUB_MODE=redirect303
    probe
    assert_equal "$(grep -c '^ok' "$work/out")" 42
}

# A stopped Serve rule: 502 for the forward the host cannot make.
@test "a 502 from a stopped Serve rule fails the run" {
    STUB_MODE=down
    probe
    assert_equal "$rc" 1
}

@test "the failure names the name and the class it owed" {
    STUB_MODE=down
    probe
    assert_contains "$(out)" "FAIL navidrome.$suffix answers the 3xx class"
}

# A drained Service: the route is gone, so nothing answers and curl gives up.
@test "a drained Service that times out fails the run" {
    STUB_MODE=drained
    probe
    assert_equal "$rc" 1
}

@test "the timeout is reported as the reason" {
    STUB_MODE=drained
    probe
    assert_contains "$(out)" '(curl exit 28)'
}

# One name out of its class and the rest still in theirs: the catalogue answering a
# page where it owes a refusal is a failure nobody else shares.
@test "a catalogue that serves a page instead of refusing fails the run" {
    STUB_MODE=swap
    probe
    assert_equal "$rc" 1
}

@test "the failure is the one name out of its class" {
    STUB_MODE=swap
    probe
    assert_contains "$(out)" "FAIL opds.$suffix answers the 4xx class"
}

@test "the other names are untouched" {
    STUB_MODE=swap
    probe
    assert_equal "$(grep -c "FAIL immich.$suffix answers" "$work/out")" 0
}

# The classes are checked in one run, so one class failing must not swallow the
# other: the operator reads what is broken everywhere, not the first thing.
@test "a failing edge class still checks the tailnet class" {
    STUB_MODE=leak
    probe
    assert_contains "$(out)" "ok   immich.$suffix answers the 2xx class"
}

@test "a failing edge class still reports the tailnet's checks" {
    STUB_MODE=leak
    probe
    assert_contains "$(out)" 'ok   all six names resolve to distinct tailnet addresses'
}

@test "a failing tailnet class still checks the edge class" {
    STUB_MODE=swap
    probe
    assert_contains "$(out)" "ok   $photos answers over TLS (200)"
}

@test "both classes' failures land in the one verdict" {
    STUB_MODE=leak
    probe
    assert_equal "$rc" 1
    assert_contains "$(out)" "FAIL /wallpapers/ answers as Immich on $photos"
    assert_contains "$(out)" "ok   $recovery answers as Backrest"
}

# --- the third check: the zone's CAA policy ----------------------------------

@test "a CAA set that omits the served CA fails the whole run" {
    caa_fixture "$work/caa-le" '0 issue "letsencrypt.org"'
    STUB_CAA_FILE=$work/caa-le
    probe
    assert_equal "$rc" 1
}

@test "the CAA failure is named in the run's verdict" {
    caa_fixture "$work/caa-le" '0 issue "letsencrypt.org"'
    STUB_CAA_FILE=$work/caa-le
    probe
    assert_contains "$(out)" "FAIL the zone's CAA policy admits the CA behind $photos's certificate"
}

@test "the CAA failure carries the scan's own reason" {
    caa_fixture "$work/caa-le" '0 issue "letsencrypt.org"'
    STUB_CAA_FILE=$work/caa-le
    probe
    assert_contains "$(out)" "does not admit pki.goog"
}

@test "a zone with no CAA records still passes and says so" {
    caa_fixture "$work/caa-empty"
    STUB_CAA_FILE=$work/caa-empty
    probe
    assert_equal "$rc" 0
    assert_contains "$(out)" 'note no CAA records for sammohr.dev'
}

# --- the offline plan --------------------------------------------------------

# --dry-run is the offline half: it resolves the suffix, checks the tools and says
# what a run would ask, so a reviewer can read the coverage without a network.
@test "a dry run exits 0" {
    rc=0
    FLEET_TAILNET_SUFFIX=$suffix CURL_BIN=$stubs/curl OPENSSL_BIN=$stubs/openssl \
        GETENT_BIN=$stubs/getent STUB_CURL_LOG=$work/curl.log \
        bash "$script" --dry-run >"$work/out" 2>"$work/err" || rc=$?
    assert_equal "$rc" 0
}

@test "a dry run lists every public name" {
    rc=0
    FLEET_TAILNET_SUFFIX=$suffix CURL_BIN=$stubs/curl OPENSSL_BIN=$stubs/openssl \
        GETENT_BIN=$stubs/getent STUB_CURL_LOG=$work/curl.log \
        bash "$script" --dry-run >"$work/out" 2>"$work/err" || rc=$?
    assert_contains "$(out)" "$photos"
    assert_contains "$(out)" "$opds"
    assert_contains "$(out)" "$recovery"
}

@test "a dry run lists every tailnet name and the CAA check" {
    rc=0
    FLEET_TAILNET_SUFFIX=$suffix CURL_BIN=$stubs/curl OPENSSL_BIN=$stubs/openssl \
        GETENT_BIN=$stubs/getent STUB_CURL_LOG=$work/curl.log \
        bash "$script" --dry-run >"$work/out" 2>"$work/err" || rc=$?
    for app in $apps; do
        assert_contains "$(out)" "$app.$suffix" || return 1
    done
    assert_contains "$(out)" "the zone's CAA admits the served CA"
}

@test "a dry run contacts nothing" {
    : >"$work/curl.log"
    rc=0
    FLEET_TAILNET_SUFFIX=$suffix CURL_BIN=$stubs/curl OPENSSL_BIN=$stubs/openssl \
        GETENT_BIN=$stubs/getent STUB_CURL_LOG=$work/curl.log \
        bash "$script" --dry-run >"$work/out" 2>"$work/err" || rc=$?
    assert_equal "$(wc -l <"$work/curl.log")" 0
}

@test "a dry run on a host without the tools is a setup error" {
    rc=0
    FLEET_TAILNET_SUFFIX=$suffix CURL_BIN=/nonexistent/curl OPENSSL_BIN=$stubs/openssl \
        GETENT_BIN=$stubs/getent bash "$script" --dry-run >"$work/out" 2>"$work/err" || rc=$?
    assert_equal "$rc" 2
}

@test "the setup error names the tool that is missing" {
    rc=0
    FLEET_TAILNET_SUFFIX=$suffix CURL_BIN=/nonexistent/curl OPENSSL_BIN=$stubs/openssl \
        GETENT_BIN=$stubs/getent bash "$script" --dry-run >"$work/out" 2>"$work/err" || rc=$?
    assert_contains "$(err)" '/nonexistent/curl is not installed'
}

@test "an unknown argument is refused instead of being ignored" {
    rc=0
    bash "$script" --nonsense >"$work/out" 2>"$work/err" || rc=$?
    assert_equal "$rc" 2
    assert_contains "$(err)" 'unknown argument --nonsense'
}

# --- the CAA invariant (scripts/verify-caa.sh) --------------------------------
# The zone's CAA records and the CA behind the edge's certificate are two networks
# away, so the mapping and the scan are what is tested: a record set that omits the
# served CA must fail, an empty set must not, and every issuer organization the
# script knows must land on its CA domain. The script keeps its own entry point,
# and the run above drives it through the same stubs.

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
        DIG_BIN=$stubs/dig OPENSSL_BIN=$stubs/openssl \
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
    caa_fixture "$work/caa-gts2" '0 issue "pki.goog"' '0 issuewild "pki.goog"'
    run_caa "$work/caa-gts2" "$gts_issuer"
    assert_equal "$rc" 0
}

@test "the pass names the record, the CA and the name" {
    caa_fixture "$work/caa-gts2" '0 issue "pki.goog"' '0 issuewild "pki.goog"'
    run_caa "$work/caa-gts2" "$gts_issuer"
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
# admitted, and a record naming a different CA's record set is not.
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
    caa_fixture "$work/caa-gts2" '0 issue "pki.goog"' '0 issuewild "pki.goog"'
    run_caa "$work/caa-gts2" 'CN=X,O=Some Other CA,C=US'
    assert_equal "$rc" 1
}

@test "a name that serves no readable certificate fails" {
    caa_fixture "$work/caa-gts2" '0 issue "pki.goog"' '0 issuewild "pki.goog"'
    run_caa "$work/caa-gts2" ''
    assert_equal "$rc" 1
}

@test "the certificate failure says what could not be read" {
    caa_fixture "$work/caa-gts2" '0 issue "pki.goog"' '0 issuewild "pki.goog"'
    run_caa "$work/caa-gts2" ''
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
    caa_fixture "$work/caa-gts2" '0 issue "pki.goog"' '0 issuewild "pki.goog"'
    STUB_CAA_FILE=$work/caa-gts2 STUB_ISSUER=$gts_issuer \
        DIG_BIN=$work/no-such-dig OPENSSL_BIN=$stubs/openssl \
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
