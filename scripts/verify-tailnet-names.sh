#!/usr/bin/env bash
# Prove the tailnet name service (design #834) still works, before a person
# finds out that it does not.
#
# `assistant.sammohr.dev`, `agent.sammohr.dev` and `sync.sammohr.dev` are five
# promises stacked on one another: a grey-cloud `A` record pointing at the Service
# VIP (`tofu/dns.tf`), a Service the host still advertises
# (`scripts/tailscale-serve.sh`), Serve's forward to Caddy on loopback, a DNS-01
# certificate Caddy renews, and the GUI behind all of it. Each breaks on its own
# and a 200 proves none of them, so every probe below is one of the claims:
#
#   - each name resolves, and to the one Service VIP. With
#     TAILNET_NAMES_EXPECT_VIP unset every name must land on the *same*
#     100.64.0.0/10 address: one Service owns one VIP, so a second address would
#     mean one name answers through something else -- the wildcard, a stale edge
#     record, a second Service.
#   - the chain verifies against the public roots with the name in it. The VIP is
#     not publicly routable, so this is Caddy's DNS-01 certificate and not
#     something the tailnet minted.
#   - that certificate is not within TAILNET_NAMES_MIN_DAYS of expiry.
#   - the UI answers as the UI. The agent UIs redirect `GET /` with a 3xx whose
#     `Location` is the login route, with `/` as the page to return to; the vault
#     GUI answers `/rest/noauth/health` with a fixed body and Syncthing's own
#     device id header. A bare 200 says nothing, and the ways this path breaks do
#     not even share a status: with Caddy stopped the forward refuses the
#     connection or Serve answers 502, and with the Service drained there is no
#     route at all, so the request times out. The UI's own signature is what
#     proves a UI is behind the name.
#
# Exit 0 only when every probe passes. `.github/workflows/verify-tailnet-names.yml`
# runs it on a schedule from a `tag:deploy` node, which is the only place a
# genuine non-owner client exists; nothing here knows about that, so an operator
# can run it from any node on the tailnet:
#
#   scripts/verify-tailnet-names.sh
#
# Knobs: TAILNET_NAMES_TIMEOUT (10 s), TAILNET_NAMES_MIN_DAYS (14),
# TAILNET_NAMES_EXPECT_VIP, TAILNET_NAMES_CAFILE, CURL_BIN, OPENSSL_BIN and
# GETENT_BIN (tests/tailnet-names/check.sh drives the same code).
set -uo pipefail

names=(assistant.sammohr.dev agent.sammohr.dev sync.sammohr.dev)
# The vault GUI is the one name whose GUI is not an agent web UI.
sync_name=sync.sammohr.dev
# The redirect both agent UIs answer with, read off the live names on 2026-11-23:
# `GET /` is 302 and `Location: login?next=/`. Relative and without a leading
# slash, because that is what the application emits.
login_location='login?next=/'
# What the vault GUI answers, and why `/` cannot be the probe: the login page and
# the app are both a 200, and so is anything else listening on that port.
syncthing_health='{"status":"OK"}'
tailnet_range='100.64.0.0/10'

timeout_s=${TAILNET_NAMES_TIMEOUT:-10}
min_days=${TAILNET_NAMES_MIN_DAYS:-14}
expect_vip=${TAILNET_NAMES_EXPECT_VIP:-}
cafile=${TAILNET_NAMES_CAFILE:-/etc/ssl/certs/ca-certificates.crt}
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

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# <name> -> every address the resolver answers with, one per line. `ahostsv4`
# because the records are `A`: a name answered only over IPv6 cannot reach a
# Service VIP that has none.
addresses() {
  "$getent_bin" ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u
}

# <address> -> the address is in the tailnet's own range (100.64.0.0/10 is a
# carrier-grade NAT block; Tailscale holds it, no public route does).
in_tailnet() {
  [[ $1 =~ ^100\.([0-9]{1,3})\. ]] || return 1
  ((10#${BASH_REMATCH[1]} >= 64 && 10#${BASH_REMATCH[1]} <= 127))
}

# <name> -> the agent UIs answer `GET /` with a 3xx to their login route.
probe_login() {
  local name=$1 code rc location
  code=$("$curl_bin" --silent --show-error --output "$work/body" \
    --dump-header "$work/hdr" --max-time "$timeout_s" \
    --write-out '%{http_code}' "https://$name/" 2>/dev/null)
  rc=$?
  location=$({ tr -d '\r' <"$work/hdr"; } 2>/dev/null \
    | sed -n 's/^[Ll]ocation:[[:space:]]*//p' | tail -n 1)
  if [[ $code =~ ^3[0-9][0-9]$ && $location =~ ^/?login\?next=/ ]]; then
    ok "$name answers the UI login redirect ('$location')"
  else
    bad "$name answers the UI login redirect ('$login_location')" \
      "got '$code' with location '${location:-none}' (curl exit $rc)"
  fi
}

# <name> -> the vault GUI answers as Syncthing. The device id is checked for
# shape, not pinned: the name is already tied to the Service VIP by the first
# probe, and a pinned id would turn a deliberately re-keyed identity into a red
# probe nobody acts on.
probe_syncthing() {
  local name=$1 code rc id body
  code=$("$curl_bin" --silent --show-error --output "$work/body" \
    --dump-header "$work/hdr" --max-time "$timeout_s" \
    --write-out '%{http_code}' "https://$name/rest/noauth/health" 2>/dev/null)
  rc=$?
  id=$({ tr -d '\r' <"$work/hdr"; } 2>/dev/null \
    | sed -n 's/^[Xx]-[Ss]yncthing-[Ii][Dd]:[[:space:]]*//p' | tail -n 1)
  body=$({ tr -d '[:space:]' <"$work/body"; } 2>/dev/null)
  if [[ $code == 200 && $body == "$syncthing_health" && $id =~ ^[A-Z2-7]{7}(-[A-Z2-7]{7}){7}$ ]]; then
    ok "$name answers as Syncthing ($id)"
  else
    bad "$name answers as Syncthing" \
      "got '$code' with body '${body:-none}' and id '${id:-none}' (curl exit $rc)"
  fi
}

declare -A vip=()
for name in "${names[@]}"; do
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

  if [[ -n $expect_vip ]]; then
    # The pinned form, for an operator who knows the VIP: it catches a Service
    # whose address changed underneath an unchanged record.
    if [[ ${vip[$name]} == "$expect_vip" ]]; then
      ok "$name resolves to the Service VIP (${vip[$name]})"
    else
      bad "$name resolves to the Service VIP" "got '${vip[$name]}' want '$expect_vip'"
    fi
  elif in_tailnet "${vip[$name]}"; then
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

  if [[ $name == "$sync_name" ]]; then
    probe_syncthing "$name"
  else
    probe_login "$name"
  fi
done

# One Service, one VIP. With no VIP given, the property that ties the names to
# that one Service is that they agree, and only a second record or a second
# Service could split them. Skipped when TAILNET_NAMES_EXPECT_VIP pins the
# address: the per-name lines above already made the stronger statement.
if [[ -z $expect_vip ]]; then
  if ((${#vip[@]} != ${#names[@]})); then
    bad "every name resolves to the same tailnet address" \
      "only ${#vip[@]} of ${#names[@]} names resolved"
  elif [[ $(printf '%s\n' "${vip[@]}" | sort -u | wc -l) == 1 ]]; then
    ok "every name resolves to the same tailnet address (${vip[${names[0]}]})"
  else
    bad "every name resolves to the same tailnet address" \
      "$(for n in "${names[@]}"; do printf '%s=%s ' "$n" "${vip[$n]}"; done)"
  fi
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
exit $((fail > 0))
