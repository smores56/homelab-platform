#!/usr/bin/env bash
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

# The suffix every case below states unless it is testing the derivation, and one
# FQDN per application, so a case can name the line it expects.
suffix=tail1234.ts.net

# The resolver stub answers one distinct VIP per name -- one Service, one address
# -- and folds the failure a case injects on top.
cat >"$work/getent" <<'EOF'
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
# The curl stub records argv and prints the status the application would answer.
# The default is one code per name, so a case can knock a single name out of its
# class.
cat >"$work/curl" <<'EOF'
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
    assistant.*) code=302 ;;
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
    redirect303) case ${url#https://} in immich.* | sync.* | opds.*) ;; *) code=303 ;; esac ;;
    # OPDShelf answering 200 instead of refusing: a page where the class says 4xx.
    swap) case ${url#https://} in opds.*) code=200 ;; esac ;;
esac
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
# The status stub answers the shape `tailscale status --json` has, with a peer's
# FQDN first on purpose: the probe must read `.Self`, not the first DNSName it
# finds, and it must take the leading label and the trailing dot off.
cat >"$work/tailscale" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_TS_LOG"
printf '{"Peer":{"laptop":{"DNSName":"laptop.tail9999.ts.net."}},"Self":{"DNSName":"smortress.tail1234.ts.net."}}\n'
EOF
chmod +x "$work/getent" "$work/curl" "$work/openssl" "$work/tailscale"

# TAILNET_NAMES_SUFFIX uses `-` and not `:-` in run(): an empty value is how a
# case asks for the derivation, and a default would quietly replace it.
run() {
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
        GETENT_BIN=$work/getent CURL_BIN=$work/curl OPENSSL_BIN=$work/openssl \
        TAILSCALE_BIN=${TAILSCALE_BIN-$work/tailscale} \
        bash "$script" >"$work/out" 2>"$work/err"
}

# --- six healthy names --------------------------------------------------------

run
eq "$?" 0 'six healthy names exit 0'
eq "$(grep -c '^ok' "$work/out")" 25 'six names, four probes each and the distinct addresses'
eq "$(grep -c '^FAIL' "$work/out")" 0 'nothing fails on six healthy names'
for app in immich navidrome assistant agent sync opds; do
    if grep -qxF "ahostsv4 $app.$suffix" "$work/getent.log"; then
        ok "$app.$suffix is resolved through the system resolver"
    else
        bad "$app.$suffix is resolved through the system resolver" "$(cat "$work/getent.log")"
    fi
done
if grep -qF -- "-verify_hostname opds.$suffix" "$work/ossl.log"; then
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
for app in immich navidrome assistant agent sync opds; do
    if grep -qF -- "https://$app.$suffix/" "$work/curl.log"; then
        ok "the probe of $app.$suffix uses https on the name"
    else
        bad "the probe of $app.$suffix uses https on the name" "$(cat "$work/curl.log")"
    fi
done
if grep -qF -- ':80' "$work/curl.log"; then
    bad 'no probe addresses port 80' "$(cat "$work/curl.log")"
else
    ok 'no probe addresses port 80'
fi

# --- where the suffix comes from ---------------------------------------------

# No override: the suffix is the node's own FQDN minus its leading label and
# trailing dot. The stub's peer FQDN would give a different tailnet, so a probe
# that read the first DNSName in the JSON fails here.
TAILNET_NAMES_SUFFIX=''
run
eq "$?" 0 'a run with no suffix stated exits 0'
if grep -qxF "ahostsv4 immich.$suffix" "$work/getent.log"; then
    ok 'the suffix is derived from the node FQDN, without its trailing dot'
else
    bad 'the suffix is derived from the node FQDN, without its trailing dot' \
        "$(cat "$work/getent.log")"
fi
if grep -qF 'tail9999' "$work/getent.log"; then
    bad 'the suffix comes from .Self, not from a peer' "$(cat "$work/getent.log")"
else
    ok 'the suffix comes from .Self, not from a peer'
fi
# A stated suffix carrying the dot it came with is still a suffix.
TAILNET_NAMES_SUFFIX="$suffix."
run
eq "$?" 0 'a suffix stated with its trailing dot exits 0'
if grep -qxF "ahostsv4 sync.$suffix" "$work/getent.log"; then
    ok 'the trailing dot is stripped from a stated suffix too'
else
    bad 'the trailing dot is stripped from a stated suffix too' "$(cat "$work/getent.log")"
fi
TAILNET_NAMES_SUFFIX=''
TAILSCALE_BIN=/nonexistent/tailscale
run
eq "$?" 2 'a node with no tailscale binary and no stated suffix is a setup error'
if grep -qF 'TAILNET_NAMES_SUFFIX is unset' "$work/err"; then
    ok 'the setup error names the knob that fixes it'
else
    bad 'the setup error names the knob that fixes it' "$(cat "$work/err")"
fi
unset TAILNET_NAMES_SUFFIX TAILSCALE_BIN

# --- resolution --------------------------------------------------------------

STUB_MODE=noresolve
run
eq "$?" 1 'a name with no A record fails the run'
if grep -qF "FAIL immich.$suffix resolves" "$work/out"; then
    ok 'the failure names the name that did not resolve'
else
    bad 'the failure names the name that did not resolve' "$(cat "$work/out")"
fi

STUB_MODE=public
run
eq "$?" 1 'a name pointing outside the tailnet fails the run'
if grep -qF "FAIL immich.$suffix resolves into the tailnet" "$work/out"; then
    ok 'the failure names the name and the address that is not the tailnet'
else
    bad 'the failure names the name and the address that is not the tailnet' "$(cat "$work/out")"
fi

# Six Services, six VIPs: two names on one address means one of them answers
# through something that is not its own Service.
STUB_MODE=shared
run
eq "$?" 1 'two names on one address fail the run'
eq "$(grep -c "^ok   .* resolves into the tailnet" "$work/out")" 6 \
    'every name still resolves into the tailnet'
if grep -qF 'FAIL all six names resolve to distinct tailnet addresses' "$work/out"; then
    ok 'the failure names the shared address'
else
    bad 'the failure names the shared address' "$(cat "$work/out")"
fi
STUB_MODE=

# --- the certificate --------------------------------------------------------

STUB_CHAIN_FAIL=1
run
eq "$?" 1 'a chain that does not verify fails the run'
if grep -qF "FAIL immich.$suffix presents a certificate" "$work/out"; then
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
if grep -qF "FAIL immich.$suffix's certificate is valid for 14 more days" "$work/out"; then
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

# --- the per-name status class ----------------------------------------------

# The classes are promises about what a stranger sees, not about how an
# application spells its redirect: a 303 with a different Location is still the
# 3xx the three UIs owe.
STUB_MODE=redirect303
run
eq "$?" 0 'a redirect spelled differently still lands in the 3xx class'
eq "$(grep -c '^ok' "$work/out")" 25 'the class, not the code, is what is asserted'

# A stopped Serve rule: 502 for the forward the host cannot make.
STUB_MODE=down
run
eq "$?" 1 'a 502 from a stopped Serve rule fails the run'
if grep -qF "FAIL navidrome.$suffix answers the 3xx class" "$work/out"; then
    ok 'the failure names the name and the class it owed'
else
    bad 'the failure names the name and the class it owed' "$(cat "$work/out")"
fi

# A drained Service: the route is gone, so nothing answers and curl gives up.
STUB_MODE=drained
run
eq "$?" 1 'a drained Service that times out fails the run'
if grep -qF '(curl exit 28)' "$work/out"; then
    ok 'the timeout is reported as the reason'
else
    bad 'the timeout is reported as the reason' "$(cat "$work/out")"
fi

# One name out of its class and the rest still in theirs: the catalogue answering
# a page where it owes a refusal is a failure nobody else shares.
STUB_MODE=swap
run
eq "$?" 1 'a catalogue that serves a page instead of refusing fails the run'
if grep -qF "FAIL opds.$suffix answers the 4xx class" "$work/out"; then
    ok 'the failure is the one name out of its class'
else
    bad 'the failure is the one name out of its class' "$(cat "$work/out")"
fi
if grep -qF "FAIL immich.$suffix answers" "$work/out"; then
    bad 'the other names are untouched' "$(cat "$work/out")"
else
    ok 'the other names are untouched'
fi
STUB_MODE=

printf '\n%d passed, %d failed\n' "$pass" "$fail"
exit $((fail > 0))
