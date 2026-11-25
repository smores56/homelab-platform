#!/usr/bin/env bash
# Assert that the certificate the public edge serves is one the zone's own CAA
# policy admits (design #842). The probe reads a name the edge actually serves
# (`photos.sammohr.dev`, Let's Encrypt) so a `CAA` record that forbids the
# issuing CA stops renewal weeks before anyone notices. `kanbei.sammohr.dev` used
# to be the proxied probe; #833 retired it with the wildcard record. The issuer organization is what maps to a CA
# domain, not the CN, because the CA rotates WE1/WE2/E1 between certificates.
#
# An empty CAA set is a notice, not a failure: with no record there is nothing to
# assert, and a check that is red because of a missing record teaches the
# operator to ignore it. `dig` ships with the runner image; a host without it
# fails loudly here rather than skipping the assertion.
#
#   scripts/verify-caa.sh
#
# `issue` governs ordinary names, `issuewild` wildcard orders only, so the tag
# the probe requires follows the name it probes: `issue` for the default
# non-wildcard name, `issuewild` when CAA_WILDCARD=1 says the caller is checking
# a wildcard. A set carrying only `issuewild` satisfies a wildcard order and
# leaves every ordinary order refused, which is a renewal outage weeks out.
#
# Knobs: CAA_ZONE (sammohr.dev), CAA_NAME (photos.sammohr.dev), CAA_WILDCARD (0),
# DIG_BIN and OPENSSL_BIN (tests/edge/check.sh drives the same code).
set -uo pipefail

zone=${CAA_ZONE:-sammohr.dev}
name=${CAA_NAME:-photos.sammohr.dev}
case ${CAA_WILDCARD:-0} in
  1) need=issuewild ;;
  *) need=issue ;;
esac
dig_bin=${DIG_BIN:-dig}
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
notice() { printf 'note %s\n' "$1"; }

for tool in "$dig_bin" "$openssl_bin"; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'verify-caa: %s is not installed (dnsutils, openssl)\n' "$tool" >&2
    exit 2
  }
done

pem=$("$openssl_bin" s_client -connect "$name:443" -servername "$name" \
  </dev/null 2>/dev/null) || pem=''
issuer=$("$openssl_bin" x509 -noout -issuer -nameopt RFC2253 <<<"$pem" 2>/dev/null) || issuer=''
org=''
IFS=, read -ra rdns <<<"${issuer#issuer=}"
for rdn in "${rdns[@]}"; do
  rdn=${rdn# }
  case $rdn in O=*) org=${rdn#O=} ;; esac
done

ca=''
case $org in
  'Google Trust Services'*) ca=pki.goog ;;
  "Let's Encrypt"* | ISRG*) ca=letsencrypt.org ;;
  DigiCert*) ca=digicert.com ;;
  Sectigo*) ca=sectigo.com ;;
  ZeroSSL*) ca=zerossl.com ;;
esac

if [[ -z $org ]]; then
  bad "$name serves no certificate whose issuer can be read" "'$openssl_bin s_client' printed nothing"
elif [[ -z $ca ]]; then
  bad "the issuer organization '$org' has no mapped CA domain" \
    'add it to the case statement here and to tests/edge/check.sh'
else
  ok "$name is issued by $org, whose CAA domain is $ca"
fi

# One query carries both the status and the records: `+short` alone cannot tell
# an empty set from a SERVFAIL, and the two mean opposite things here.
caa=$("$dig_bin" +noall +comments +answer CAA "$zone" 2>/dev/null) || caa=''
status=$(sed -n 's/.*status: \([A-Z]*\),.*/\1/p' <<<"$caa")
records=$(awk '$4 == "CAA" { print $5, $6, $7 }' <<<"$caa")

if [[ $status != NOERROR ]]; then
  bad "dig could not answer a CAA query for $zone" "status '${status:-none}'"
elif [[ -z ${records//[[:space:]]/} ]]; then
  notice "no CAA records for $zone yet, so the issuer $ca is unasserted"
else
  # The values can carry parameters (`pki.goog; accounturi=...`); the domain is
  # what the policy admits, so the scan compares only up to the first `;`.
  admitted=''
  matched=''
  while read -r _flags tag value; do
    [[ -n ${tag:-} ]] || continue
    case $tag in issue | issuewild) ;; *) continue ;; esac
    value=${value//\"/}
    value=${value%%;*}
    admitted+="${admitted:+, }$tag=$value"
    # Only the tag this name's orders read can admit it; the other one is
    # printed on failure but never satisfies the probe.
    [[ -z $matched && $tag == "$need" && $value == "$ca" ]] && matched=$tag
  done <<<"$records"
  if [[ -n $matched ]]; then
    ok "$zone's CAA $matched admits $ca, the CA behind $name's certificate"
  else
    bad "$zone's CAA $need does not admit $ca, the CA behind $name's certificate" \
      "issue/issuewild: ${admitted:-none}"
  fi
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
exit $((fail > 0))
