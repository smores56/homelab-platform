#!/usr/bin/env bash
# Prove the six tailnet Service names still work, before a person finds out that
# they do not.
#
# Each application answers on a name of its own -- `immich`, `navidrome`,
# `assistant`, `agent`, `sync` and `opds`, as `<app>.<tailnet>.ts.net` -- behind
# its own Tailscale Service (`tofu/tailscale.tf`). The `sammohr.dev` aliases that
# rode one Service and one Caddy are being retired, so this probe watches the
# names that outlive them. Four promises stack on one another per name: a Service
# the host still advertises (`scripts/tailscale-serve.sh`), Serve's forward to
# the application on loopback, a certificate Tailscale mints for that exact name,
# and the application behind all of it. Each breaks on its own and a 200 proves
# none of them, so every probe below is one of the claims:
#
#   - the name resolves, and into the tailnet's own range. Each Service owns its
#     own VIP, so the addresses must also be pairwise distinct: one address
#     answering two names means one of them is not talking to its own Service --
#     a stale record, another Service's VIP, the retired agent-ui one, or the
#     device itself. Six names, six addresses, or this fails.
#   - the chain verifies against the public roots with the name in it. The VIP is
#     not publicly routable, and Tailscale issues the certificate for the Service
#     FQDN, so a name answered by something else presents a certificate that does
#     not carry it and fails here.
#   - that certificate is not within TAILNET_NAMES_MIN_DAYS of expiry.
#   - the application answers `GET /` with the status class it owns: 2xx for
#     Immich and the Syncthing GUI, which serve a page, 3xx for the three that
#     redirect a stranger to a login, 4xx for OPDShelf, whose catalogue refuses an
#     unauthenticated reader. A class, not a code, because the redirect an
#     application spells is its own business; a 502 from a stopped Serve rule, the
#     timeout a drained Service leaves and a 200 from whatever else holds the port
#     all fall outside it.
#
# The tailnet suffix is derived from this node's own FQDN (`tailscale status
# --json`, `.Self.DNSName`), so a renamed tailnet needs no edit here and no
# checkout has to know the name; TAILNET_NAMES_SUFFIX states it outright, for a
# node with no `tailscale` binary and for the tests.
#
# Exit 0 only when every probe passes. `.github/workflows/verify-tailnet-names.yml`
# runs it on a schedule from a `tag:deploy` node, which is the only place a
# genuine non-owner client exists; nothing here knows about that, so an operator
# can run it from any node on the tailnet:
#
#   scripts/verify-tailnet-names.sh
#
# Knobs: TAILNET_NAMES_TIMEOUT (10 s), TAILNET_NAMES_MIN_DAYS (14),
# TAILNET_NAMES_SUFFIX, TAILNET_NAMES_CAFILE, TAILSCALE_BIN, CURL_BIN,
# OPENSSL_BIN and GETENT_BIN (tests/tailnet-names/check.sh drives the same code).
set -uo pipefail

# <app> -> the status class its `GET /` answers with, read off the live Services
# on 2026-11-25. Three UIs redirect, two serve, the catalogue refuses: the class
# is what the application promises a stranger, and an exact code would turn a
# login spelling change into a pager.
declare -A want=(
  [immich]=2
  [navidrome]=3
  [assistant]=3
  [agent]=3
  [sync]=2
  [opds]=4
)
# The report's order, not an assertion of its own.
apps=(immich navidrome assistant agent sync opds)
tailnet_range='100.64.0.0/10'

timeout_s=${TAILNET_NAMES_TIMEOUT:-10}
min_days=${TAILNET_NAMES_MIN_DAYS:-14}
suffix=${TAILNET_NAMES_SUFFIX:-}
cafile=${TAILNET_NAMES_CAFILE:-/etc/ssl/certs/ca-certificates.crt}
tailscale_bin=${TAILSCALE_BIN:-tailscale}
curl_bin=${CURL_BIN:-curl}
openssl_bin=${OPENSSL_BIN:-openssl}
getent_bin=${GETENT_BIN:-getent}

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

for tool in "$getent_bin" "$curl_bin" "$openssl_bin"; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'verify-tailnet-names: %s is not installed\n' "$tool" >&2
    exit 2
  }
done

if [[ -z $suffix ]]; then
  command -v "$tailscale_bin" >/dev/null 2>&1 || {
    printf 'verify-tailnet-names: %s is not installed, and TAILNET_NAMES_SUFFIX is unset\n' \
      "$tailscale_bin" >&2
    exit 2
  }
  # `.Self.DNSName` is this node's own FQDN with a trailing dot; every peer
  # carries one too, so the anchor matters. The first label is the device, so
  # what is left is the tailnet's suffix, and the dot goes with it: the names
  # below are built as `<app>.<suffix>`, and a trailing dot on the suffix would
  # make every one of them a name that does not resolve.
  status=$("$tailscale_bin" status --json 2>/dev/null)
  dns=$(printf '%s' "${status#*\"Self\":}" |
    grep -o '"DNSName":[[:space:]]*"[^"]*"' | head -n 1 | cut -d'"' -f4)
  if [[ -z $dns ]]; then
    printf 'verify-tailnet-names: %s status reported no .Self.DNSName; set TAILNET_NAMES_SUFFIX\n' \
      "$tailscale_bin" >&2
    exit 2
  fi
  suffix=${dns#*.}
fi
suffix=${suffix%.}
if [[ $suffix != *.* ]]; then
  printf "verify-tailnet-names: '%s' is not a tailnet suffix like <tailnet>.ts.net\n" \
    "$suffix" >&2
  exit 2
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# <name> -> every address the resolver answers with, one per line. `ahostsv4`
# because a Service VIP is IPv4-only: a name answered only over IPv6 cannot
# reach one.
addresses() {
  "$getent_bin" ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u
}

# <address> -> the address is in the tailnet's own range (100.64.0.0/10 is a
# carrier-grade NAT block; Tailscale holds it, no public route does).
in_tailnet() {
  [[ $1 =~ ^100\.([0-9]{1,3})\. ]] || return 1
  ((10#${BASH_REMATCH[1]} >= 64 && 10#${BASH_REMATCH[1]} <= 127))
}

declare -A vip=()
for app in "${apps[@]}"; do
  name=$app.$suffix

  mapfile -t addrs < <(addresses "$name")
  if ((${#addrs[@]} == 0)); then
    bad "$name resolves" "no A record for $name"
    continue
  fi
  if ((${#addrs[@]} > 1)); then
    bad "$name resolves to one address" "got ${addrs[*]}"
    continue
  fi
  vip[$name]=${addrs[0]}

  if in_tailnet "${vip[$name]}"; then
    ok "$name resolves into the tailnet (${vip[$name]})"
  else
    bad "$name resolves into the tailnet" \
      "got '${vip[$name]}', which is not in $tailnet_range"
  fi

  # `-checkend` is an `openssl x509` option, not an `s_client` one: s_client
  # rejects it as an unknown option and exits 1, so the expiry probe failed
  # against every host, healthy or not, until it moved to a second invocation
  # reading the PEM s_client printed.
  pem=$("$openssl_bin" s_client -connect "$name:443" -servername "$name" \
    -verify_hostname "$name" -CAfile "$cafile" </dev/null 2>/dev/null)
  if grep -q 'Verify return code: 0 (ok)' <<<"$pem"; then
    ok "$name presents a certificate that chains to a public root for $name"
  else
    bad "$name presents a certificate that chains to a public root for $name" \
      "s_client could not verify $name against $cafile"
  fi
  if "$openssl_bin" x509 -noout -checkend "$((min_days * 86400))" <<<"$pem" >/dev/null 2>&1; then
    ok "$name's certificate is valid for $min_days more days"
  else
    bad "$name's certificate is valid for $min_days more days" \
      "the certificate expires within $min_days days, or s_client returned nothing"
  fi

  # The body is discarded: what the name promises a stranger is a status class,
  # and downloading an application's first page proves nothing more.
  code=$("$curl_bin" --silent --show-error --output /dev/null \
    --max-time "$timeout_s" --write-out '%{http_code}' "https://$name/" 2>/dev/null)
  rc=$?
  if [[ $code =~ ^${want[$app]}[0-9][0-9]$ ]]; then
    ok "$name answers the ${want[$app]}xx class ('$code')"
  else
    bad "$name answers the ${want[$app]}xx class" \
      "got '$code' (curl exit $rc) -- the name did not reach the application, or the application did not answer as itself"
  fi
done

# Six Services, six VIPs. The per-name legs above place each address in the
# tailnet; this is the property that ties a name to *its own* Service, because
# nothing else would notice two names sharing one VIP: two Services are two
# advertisements, and a name that answers on another's address is a record
# pointing at the wrong place.
if ((${#vip[@]} != ${#apps[@]})); then
  bad "all six names resolve to distinct tailnet addresses" \
    "only ${#vip[@]} of ${#apps[@]} names resolved"
else
  distinct=$(printf '%s\n' "${vip[@]}" | sort -u | wc -l)
  if ((${#apps[@]} == distinct)); then
    ok "all six names resolve to distinct tailnet addresses"
  else
    bad "all six names resolve to distinct tailnet addresses" \
      "$(for app in "${apps[@]}"; do printf '%s=%s ' "$app.$suffix" "${vip[$app.$suffix]}"; done)"
  fi
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
exit $((fail > 0))
