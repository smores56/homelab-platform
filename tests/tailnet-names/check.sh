#!/usr/bin/env bash
# Behavioural checks for scripts/verify-tailnet-names.sh (task #848).
#
# The probe needs a tailnet node and a live Service VIP to say anything, so what
# is tested here is its contract: it fails when a name does not resolve, when a
# name resolves somewhere that is not the tailnet, when the two names disagree
# about the VIP, when the chain or the name in it is wrong, when a certificate is
# close to expiry, and when the UI answers with anything but its login redirect
# -- a 200, a 502 from a stopped Caddy, or the timeout a drained Service leaves.
#
#   tests/tailnet-names/check.sh
set -uo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root" || exit 1

script=scripts/verify-tailnet-names.sh
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

# The resolver stub answers the one VIP both names carry, and STUB_MODE replaces
# that with the failure a case injects.
cat >"$work/getent" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG"
name=${!#}
case ${STUB_MODE:-} in
    noresolve) exit 2 ;;
    separate)
        case $name in
            assistant.sammohr.dev) printf '100.122.108.221\n' ;;
            *) printf '100.122.108.222\n' ;;
        esac
        ;;
    public) printf '203.0.113.7\n' ;;
    wrongvip) printf '100.122.108.99\n' ;;
    *) printf '100.122.108.221\n100.122.108.221\n' ;;
esac
EOF
# The curl stub records argv, writes the body and headers the script asks for and
# prints a status. A stopped Caddy and a drained Service differ only in how the
# request ends: a 502 from Serve, or no answer at all (curl exit 28, code 000).
cat >"$work/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_CURL_LOG"
url= body=/dev/null hdr=/dev/null
while (($#)); do
    case $1 in
        --output) body=$2; shift ;;
        --dump-header) hdr=$2; shift ;;
        --max-time|--write-out) shift ;;
        --*) ;;
        *) url=$1 ;;
    esac
    shift
done
code=302
location='login?next=/'
: >"$body"
case ${STUB_MODE:-} in
    down) code=502; location='' ;;
    drained) printf '000'; exit 28 ;;
    nosig) code=200; location='' ;;
esac
printf 'HTTP/1.1 %s\r\n' "$code" >"$hdr"
[[ -n $location ]] && printf 'Location: %s\r\n' "$location" >>"$hdr"
printf '\r\n' >>"$hdr"
printf '%s' "$code"
EOF
# The openssl stub answers like a real pair: s_client prints the verify line, and
# `x509 -checkend <seconds>` succeeds only while that window still fits inside the
# certificate's remaining life (STUB_REMAINING_DAYS), which is the same arithmetic
# the real `-checkend` does.
cat >"$work/openssl" <<'EOF'
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
chmod +x "$work/getent" "$work/curl" "$work/openssl"

run() {
    : >"$work/getent.log"
    : >"$work/curl.log"
    : >"$work/ossl.log"
    TAILNET_NAMES_MIN_DAYS=${TAILNET_NAMES_MIN_DAYS:-14} \
        TAILNET_NAMES_EXPECT_VIP=${TAILNET_NAMES_EXPECT_VIP:-} \
        STUB_MODE=${STUB_MODE:-} \
        STUB_CHAIN_FAIL=${STUB_CHAIN_FAIL:-0} \
        STUB_REMAINING_DAYS=${STUB_REMAINING_DAYS:-120} \
        STUB_LOG=$work/getent.log STUB_CURL_LOG=$work/curl.log \
        STUB_OSSL_LOG=$work/ossl.log \
        GETENT_BIN=$work/getent CURL_BIN=$work/curl OPENSSL_BIN=$work/openssl \
        bash "$script" >"$work/out" 2>"$work/err"
}

# --- a healthy pair of names --------------------------------------------------

run
eq "$?" 0 'a healthy pair of names exits 0'
eq "$(grep -c '^ok' "$work/out")" 9 'two names, four probes each and the shared VIP'
eq "$(grep -c '^FAIL' "$work/out")" 0 'nothing fails on a healthy pair'
if grep -qE '^ahostsv4 assistant\.sammohr\.dev$' "$work/getent.log" &&
    grep -qE '^ahostsv4 agent\.sammohr\.dev$' "$work/getent.log"; then
    ok 'both names are resolved through the system resolver'
else
    bad 'both names are resolved through the system resolver' "$(cat "$work/getent.log")"
fi
if grep -qF -- '-verify_hostname agent.sammohr.dev' "$work/ossl.log"; then
    ok 'the chain is verified for the name, not just for any name'
else
    bad 'the chain is verified for the name, not just for any name' "$(cat "$work/ossl.log")"
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
for name in assistant.sammohr.dev agent.sammohr.dev; do
    if grep -qF -- "https://$name/" "$work/curl.log"; then
        ok "the probe of $name uses https on the name"
    else
        bad "the probe of $name uses https on the name" "$(cat "$work/curl.log")"
    fi
done
if grep -qF -- ':80' "$work/curl.log"; then
    bad 'no probe addresses port 80' "$(cat "$work/curl.log")"
else
    ok 'no probe addresses port 80'
fi

# --- resolution ---------------------------------------------------------------

STUB_MODE=noresolve
run
eq "$?" 1 'a name with no A record fails the run'
if grep -qF 'FAIL assistant.sammohr.dev resolves' "$work/out"; then
    ok 'the failure names the name that did not resolve'
else
    bad 'the failure names the name that did not resolve' "$(cat "$work/out")"
fi

STUB_MODE=public
run
eq "$?" 1 'a name pointing outside the tailnet fails the run'
if grep -qF 'FAIL assistant.sammohr.dev resolves into the tailnet' "$work/out"; then
    ok 'the failure names the name and the address that is not the tailnet'
else
    bad 'the failure names the name and the address that is not the tailnet' "$(cat "$work/out")"
fi

# The two names are one Service with one VIP: a split means one of them answers
# through something else, which is the failure the same-address rule exists for.
STUB_MODE=separate
run
eq "$?" 1 'two names on two addresses fail the run'
if grep -qF 'FAIL both names resolve to the same tailnet address' "$work/out"; then
    ok 'the failure names the split between the two names'
else
    bad 'the failure names the split between the two names' "$(cat "$work/out")"
fi

STUB_MODE=
TAILNET_NAMES_EXPECT_VIP=100.122.108.221
run
eq "$?" 0 'an expected VIP that matches exits 0'
eq "$(grep -c '^ok' "$work/out")" 8 'the pinned VIP replaces the shared-address probe'

STUB_MODE=wrongvip
run
eq "$?" 1 'a VIP that does not match the expected one fails the run'
if grep -qF 'FAIL assistant.sammohr.dev resolves to the Service VIP' "$work/out"; then
    ok 'the failure names the name whose VIP moved'
else
    bad 'the failure names the name whose VIP moved' "$(cat "$work/out")"
fi
TAILNET_NAMES_EXPECT_VIP=

# --- the certificate ----------------------------------------------------------

STUB_CHAIN_FAIL=1
run
eq "$?" 1 'a chain that does not verify fails the run'
if grep -qF 'FAIL assistant.sammohr.dev presents a certificate' "$work/out"; then
    ok 'the chain failure names the name'
else
    bad 'the chain failure names the name' "$(cat "$work/out")"
fi

# 13 days left is the case the task names: under the default 14-day window it is
# red, and with a 3-day window it is green, so the leg is the window and not the
# clock.
STUB_CHAIN_FAIL=0
STUB_REMAINING_DAYS=13
run
eq "$?" 1 'a certificate with 13 days left fails the default window'
if grep -qF "FAIL assistant.sammohr.dev's certificate is valid for 14 more days" "$work/out"; then
    ok 'the expiry failure names the window it needed'
else
    bad 'the expiry failure names the window it needed' "$(cat "$work/out")"
fi

TAILNET_NAMES_MIN_DAYS=3
run
eq "$?" 0 'the same certificate passes a 3-day window'
if grep -qF -- '-checkend 259200' "$work/ossl.log"; then
    ok 'the expiry window is configurable'
else
    bad 'the expiry window is configurable' "$(cat "$work/ossl.log")"
fi
TAILNET_NAMES_MIN_DAYS=
STUB_REMAINING_DAYS=

# --- the UI signature ---------------------------------------------------------

# A stopped Caddy: Serve answers 502 for the forward it cannot make.
STUB_MODE=down
run
eq "$?" 1 'a 502 from a stopped Caddy fails the run'
if grep -qF 'FAIL assistant.sammohr.dev answers the UI login redirect' "$work/out"; then
    ok 'the failure names the name that did not answer as the UI'
else
    bad 'the failure names the name that did not answer as the UI' "$(cat "$work/out")"
fi

# A drained Service: the route is gone, so nothing answers and curl gives up.
STUB_MODE=drained
run
eq "$?" 1 'a drained Service that times out fails the run'
if grep -qF "(curl exit 28)" "$work/out"; then
    ok 'the timeout is reported as the reason'
else
    bad 'the timeout is reported as the reason' "$(cat "$work/out")"
fi

# A bare 200 is what every other handler on the host answers, so it proves
# nothing; the redirect is the signature.
STUB_MODE=nosig
run
eq "$?" 1 'a 200 with no login redirect fails the run'
if grep -qF "location 'none'" "$work/out"; then
    ok 'the failure reports the missing Location'
else
    bad 'the failure reports the missing Location' "$(cat "$work/out")"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
exit $((fail > 0))
