#!/usr/bin/env bats
# bats file_tags=tailnet-names
# Behavioural checks for scripts/verify-tailnet-names.sh (task #848, the six
# Service names).
#
# The probe needs a tailnet node and six live Service VIPs to say anything, so
# what is tested here is its contract: it fails when a name does not resolve,
# when a name resolves somewhere that is not the tailnet, when two names share
# one address, when the chain or the name in it is wrong, when a certificate is
# close to expiry, and when an application answers outside the status class it
# owns -- a 502 from a stopped Serve rule, the timeout a drained Service leaves,
# or a 200 where a login redirect belongs. It also checks how the tailnet suffix
# is found when nobody states it: from the node's own FQDN, never a peer's.
#
#   bats tests/tailnet-names/check.bats
#
# The shell suite this replaced ran every case against one stub set in one
# process and kept a running count; here each case is its own test with its own
# scratch directory under $BATS_TEST_TMPDIR, and the stubs every case shares are
# installed once per file.
load ../helpers

script=scripts/verify-tailnet-names.sh

# The suffix every case below states unless it is testing the derivation, and one
# FQDN per application, so a case can name the line it expects.
suffix=tail1234.ts.net
apps='immich navidrome assistant agent sync opds'

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
install_stubs() {
    local bin=$BATS_FILE_TMPDIR/stubs
    mkdir -p "$bin"
    # The resolver stub answers one distinct VIP per name -- one Service, one
    # address -- and folds the failure a case injects on top.
    cat >"$bin/getent" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG"
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
    # The curl stub records argv and prints the status the application would
    # answer. The default is one code per name, so a case can knock a single name
    # out of its class.
    cat >"$bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_CURL_LOG"
url=
while (($#)); do
    case $1 in
        --output|--max-time|--write-out) shift ;;
        --*) ;;
        *) url=$1 ;;
    esac
    shift
done
case ${url#https://} in
    immich.*) code=200 ;;
    navidrome.*) code=302 ;;
    assistant.*) code=200 ;;
    agent.*) code=302 ;;
    sync.*) code=200 ;;
    opds.*) code=401 ;;
    *) code=302 ;;
esac
case ${STUB_MODE:-} in
    down) code=502 ;;
    # A drained Service: nothing answers, and curl gives up.
    drained) printf '000'; exit 28 ;;
    # A login redirect spelled differently than the one seen on the day the
    # classes were read: the class is the promise, the spelling is not.
    redirect303) case ${url#https://} in immich.* | sync.* | assistant.* | opds.*) ;; *) code=303 ;; esac ;;
    # OPDShelf answering 200 instead of refusing: a page where the class says 4xx.
    swap) case ${url#https://} in opds.*) code=200 ;; esac ;;
esac
printf '%s' "$code"
EOF
    # The openssl stub answers like a real pair: s_client prints the verify line,
    # and `x509 -checkend <seconds>` succeeds only while that window still fits
    # inside the certificate's remaining life (STUB_REMAINING_DAYS), which is the
    # same arithmetic the real `-checkend` does.
    cat >"$bin/openssl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_OSSL_LOG"
case $1 in
    s_client)
        if [[ ${STUB_CHAIN_FAIL:-0} == 1 ]]; then
            printf 'Verify return code: 20 (unable to get local issuer certificate)\n'
        else
            printf 'Verify return code: 0 (ok)\n'
        fi
        ;;
    x509)
        window=0
        while (($#)); do
            if [[ $1 == -checkend ]]; then shift; window=$1; fi
            shift
        done
        ((window < ${STUB_REMAINING_DAYS:-120} * 86400))
        ;;
esac
EOF
    # The status stub answers the shape `tailscale status --json` has, with a
    # peer's FQDN first on purpose: the probe must read `.Self`, not the first
    # DNSName it finds, and it must take the leading label and the trailing dot
    # off.
    cat >"$bin/tailscale" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_TS_LOG"
printf '{"Peer":{"laptop":{"DNSName":"laptop.tail9999.ts.net."}},"Self":{"DNSName":"smortress.tail1234.ts.net."}}\n'
EOF
    chmod +x "$bin/getent" "$bin/curl" "$bin/openssl" "$bin/tailscale"
}

# probe: run the verifier against the stubs. TAILNET_NAMES_SUFFIX uses `-` and
# not `:-`: an empty value is how a case asks for the derivation, and a default
# would quietly replace it.
probe() {
    rc=0
    : >"$work/getent.log"
    : >"$work/curl.log"
    : >"$work/ossl.log"
    : >"$work/ts.log"
    TAILNET_NAMES_MIN_DAYS=${TAILNET_NAMES_MIN_DAYS:-14} \
        TAILNET_NAMES_SUFFIX=${TAILNET_NAMES_SUFFIX-$suffix} \
        STUB_MODE=${STUB_MODE:-} \
        STUB_CHAIN_FAIL=${STUB_CHAIN_FAIL:-0} \
        STUB_REMAINING_DAYS=${STUB_REMAINING_DAYS:-120} \
        STUB_LOG=$work/getent.log STUB_CURL_LOG=$work/curl.log \
        STUB_OSSL_LOG=$work/ossl.log STUB_TS_LOG=$work/ts.log \
        GETENT_BIN=$stubs/getent CURL_BIN=$stubs/curl OPENSSL_BIN=$stubs/openssl \
        TAILSCALE_BIN=${TAILSCALE_BIN-$stubs/tailscale} \
        bash "$script" >"$work/out" 2>"$work/err" || rc=$?
}

out() { cat "$work/out"; }
getent_log() { cat "$work/getent.log"; }
curl_log() { cat "$work/curl.log"; }
ossl_log() { cat "$work/ossl.log"; }

# logged <file> <line>: the stub's log must carry the whole line.
logged() {
    grep -qxF -- "$2" "$1" && return 0
    printf 'missing %q in:\n%s\n' "$2" "$(cat "$1")" >&2
    return 1
}

# --- six healthy names --------------------------------------------------------

@test "six healthy names exit 0" {
    probe
    assert_equal "$rc" 0
}

@test "six names, four probes each and the distinct addresses" {
    probe
    assert_equal "$(grep -c '^ok' "$work/out")" 25
}

@test "nothing fails on six healthy names" {
    probe
    assert_equal "$(grep -c '^FAIL' "$work/out")" 0
}

resolves_through_resolver() { # app
    probe
    logged "$work/getent.log" "ahostsv4 $1.$suffix"
}

for app in $apps; do
    register "$app.$suffix is resolved through the system resolver" \
        resolves_through_resolver "$app"
done

@test "the chain is verified for the name, not just for any name" {
    probe
    assert_contains "$(ossl_log)" "-verify_hostname opds.$suffix"
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
probe_uses_https() { # app
    probe
    assert_contains "$(curl_log)" "https://$1.$suffix/"
}

for app in $apps; do
    register "the probe of $app.$suffix uses https on the name" probe_uses_https "$app"
done

@test "no probe addresses port 80" {
    probe
    assert_equal "$(grep -cF -- ':80' "$work/curl.log")" 0
}

# --- where the suffix comes from ---------------------------------------------

# No override: the suffix is the node's own FQDN minus its leading label and
# trailing dot. The stub's peer FQDN would give a different tailnet, so a probe
# that read the first DNSName in the JSON fails here.
@test "a run with no suffix stated exits 0" {
    TAILNET_NAMES_SUFFIX=''
    probe
    assert_equal "$rc" 0
}

@test "the suffix is derived from the node FQDN, without its trailing dot" {
    TAILNET_NAMES_SUFFIX=''
    probe
    logged "$work/getent.log" "ahostsv4 immich.$suffix"
}

@test "the suffix comes from .Self, not from a peer" {
    TAILNET_NAMES_SUFFIX=''
    probe
    assert_equal "$(grep -cF 'tail9999' "$work/getent.log")" 0
}

# A stated suffix carrying the dot it came with is still a suffix.
@test "a suffix stated with its trailing dot exits 0" {
    TAILNET_NAMES_SUFFIX="$suffix."
    probe
    assert_equal "$rc" 0
}

@test "the trailing dot is stripped from a stated suffix too" {
    TAILNET_NAMES_SUFFIX="$suffix."
    probe
    logged "$work/getent.log" "ahostsv4 sync.$suffix"
}

@test "a node with no tailscale binary and no stated suffix is a setup error" {
    TAILNET_NAMES_SUFFIX=''
    TAILSCALE_BIN=/nonexistent/tailscale
    probe
    assert_equal "$rc" 2
}

@test "the setup error names the knob that fixes it" {
    TAILNET_NAMES_SUFFIX=''
    TAILSCALE_BIN=/nonexistent/tailscale
    probe
    assert_contains "$(cat "$work/err")" 'TAILNET_NAMES_SUFFIX is unset'
}

# --- resolution --------------------------------------------------------------

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

# --- the certificate --------------------------------------------------------

@test "a chain that does not verify fails the run" {
    STUB_CHAIN_FAIL=1
    probe
    assert_equal "$rc" 1
}

@test "the chain failure names the name" {
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
    TAILNET_NAMES_MIN_DAYS=3
    STUB_REMAINING_DAYS=13
    probe
    assert_equal "$rc" 0
}

@test "the expiry window is configurable" {
    TAILNET_NAMES_MIN_DAYS=3
    probe
    assert_contains "$(ossl_log)" '-checkend 259200'
}

# --- the per-name status class ----------------------------------------------

# The classes are promises about what a stranger sees, not about how an
# application spells its redirect: a 303 with a different Location is still the
# 3xx the three UIs owe.
@test "a redirect spelled differently still lands in the 3xx class" {
    STUB_MODE=redirect303
    probe
    assert_equal "$rc" 0
}

@test "the class, not the code, is what is asserted" {
    STUB_MODE=redirect303
    probe
    assert_equal "$(grep -c '^ok' "$work/out")" 25
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

# One name out of its class and the rest still in theirs: the catalogue answering
# a page where it owes a refusal is a failure nobody else shares.
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
