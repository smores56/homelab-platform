#!/usr/bin/env bash
# Prove the fleet answers on every name it publishes, in one run and one verdict.
#
# Three checks, each of which breaks on its own and a 200 proves none of:
#
#   edge    -- `photos`, `opds` and `recovery` answer from the internet, through
#              the VPS's Caddy. Each answers over TLS with a certificate that
#              chains to a public root, carries the name and has life left, and
#              each answers as *its application*, not as anything else on 443.
#   tailnet -- the six Service names (`immich`, `navidrome`, `assistant`, `agent`,
#              `sync`, `opds` as `<app>.<tailnet>.ts.net`) answer from inside. A
#              Service the host still advertises, Serve's forward to the loopback
#              port, the certificate Tailscale mints for that exact name and the
#              application behind all of it stack per name, so each leg is a check
#              of its own.
#   caa     -- the zone's `CAA` records admit the CA the edge's certificate was
#              issued by, because a record that forbids it stops renewal quietly,
#              weeks before anyone notices.
#
# The checks used to be two scripts in two workflows, each with its own checkout,
# its own tailnet join and its own page; the bootstrap was the same twice and the
# operator read two verdicts. They are one run now: the entries below are the
# fleet, the class of an entry is the path a client takes to it, and the summary
# at the end is the whole answer.
#
# The edge's probes are the design's claims (design #725), not a smoke test: a
# status code cannot tell which handler answered, because Immich's SPA answers 200
# for any path and OPDShelf answers 401 for any path. The signatures are
#
#   Immich   -> 200 and its own HTML shell;
#   OPDShelf -> 401 with a WWW-Authenticate challenge;
#   Backrest -> 200, text/html and its <title> behind backrest-guard;
#
# and Serve's wallpaper tree (a bare <pre> listing) and the agent gateway's
# text/plain 404 satisfy neither, which is what makes the signature a check.
#
# The tailnet leg asserts what a user would notice rather than a status code:
# each name resolves into the tailnet's own range on a VIP of its own (six names,
# six addresses, or one of them is not talking to its own Service), the chain
# verifies for the name, the certificate is above FLEET_CERT_MIN_DAYS, and `GET /`
# answers the class the application owns. The classes are promises about what a
# stranger sees, not about how an application spells its redirect.
#
# The tailnet suffix is derived from this node's own FQDN (`tailscale status
# --json`, `.Self.DNSName`), so a renamed tailnet needs no edit here and no
# checkout has to know the name; FLEET_TAILNET_SUFFIX states it outright, for a
# node with no `tailscale` binary and for the tests.
#
# Exit 0 only when every check passes, 1 when a probe failed, 2 when this node
# cannot make the assertions at all (a missing tool, an unreadable suffix). No
# repository check can see the VPS or a tailnet VIP: this script and
# `.github/workflows/verify-fleet.yml` on its daily schedule are the outside-in
# gate. The image's own static halves are `bootc/edge/tests/check.sh` and the
# host's `hosts/*/tests/check.sh`.
#
#   scripts/verify-fleet.sh
#   scripts/verify-fleet.sh --dry-run   # the plan, offline: no name is contacted
#
# Knobs: FLEET_TIMEOUT (10 s), FLEET_CERT_MIN_DAYS (14), FLEET_TAILNET_SUFFIX,
# FLEET_CAFILE, TAILSCALE_BIN, GETENT_BIN, CURL_BIN and OPENSSL_BIN; the CAA check
# keeps its own and reads DIG_BIN and OPENSSL_BIN from here. tests/fleet/check.bats
# drives all of this code offline through stub binaries.
set -uo pipefail

photos=photos.sammohr.dev
opds=opds.sammohr.dev
recovery=recovery.sammohr.dev

# <app> -> the status class its `GET /` answers with, read off the live Services
# on 2026-11-27. The Workspace serves its shell (2); the general UI redirects (3);
# the catalogue refuses (4): the class is what the application promises a
# stranger, and an exact code would turn a login spelling change into a pager.
declare -A want=(
  [immich]=2
  [navidrome]=3
  [assistant]=2
  [agent]=3
  [sync]=2
  [opds]=4
)
# The tailnet's report order, not an assertion of its own.
tailnet_apps=(immich navidrome assistant agent sync opds)
tailnet_range='100.64.0.0/10'

timeout_s=${FLEET_TIMEOUT:-10}
min_days=${FLEET_CERT_MIN_DAYS:-14}
suffix=${FLEET_TAILNET_SUFFIX:-}
cafile=${FLEET_CAFILE:-/etc/ssl/certs/ca-certificates.crt}
tailscale_bin=${TAILSCALE_BIN:-tailscale}
getent_bin=${GETENT_BIN:-getent}
curl_bin=${CURL_BIN:-curl}
openssl_bin=${OPENSSL_BIN:-openssl}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
caa_script=$here/verify-caa.sh

dry_run=false
while (($#)); do
  case $1 in
    --dry-run) dry_run=true ;;
    -h | --help)
      printf 'usage: %s [--dry-run]\n' "${0##*/}"
      exit 0
      ;;
    *)
      printf 'verify-fleet: unknown argument %s\n' "$1" >&2
      exit 2
      ;;
  esac
  shift
done

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
    printf 'verify-fleet: %s is not installed\n' "$tool" >&2
    exit 2
  }
done

if [[ -z $suffix ]]; then
  command -v "$tailscale_bin" >/dev/null 2>&1 || {
    printf 'verify-fleet: %s is not installed, and FLEET_TAILNET_SUFFIX is unset\n' \
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
    printf 'verify-fleet: %s status reported no .Self.DNSName; set FLEET_TAILNET_SUFFIX\n' \
      "$tailscale_bin" >&2
    exit 2
  fi
  suffix=${dns#*.}
fi
suffix=${suffix%.}
if [[ $suffix != *.* ]]; then
  printf "verify-fleet: '%s' is not a tailnet suffix like <tailnet>.ts.net\n" "$suffix" >&2
  exit 2
fi

# The fleet's host entries: `<class> <name> <application>`, one row per name a
# host publishes. The class is the path a client takes to the name -- `edge` is
# the internet through the VPS's Caddy, `tailnet` is a Service VIP a member of the
# tailnet reaches directly -- and it decides which probes the row gets. A name the
# fleet starts publishing is one line here and nothing else.
hosts=(
  "edge $photos immich"
  "edge $opds opds"
  "edge $recovery backrest"
  "tailnet immich.$suffix immich"
  "tailnet navidrome.$suffix navidrome"
  "tailnet assistant.$suffix assistant"
  "tailnet agent.$suffix agent"
  "tailnet sync.$suffix sync"
  "tailnet opds.$suffix opds"
)

# --dry-run resolves the suffix and checks the tools like a real run, then prints
# what it would ask and contacts nothing: the offline answer to "what does this
# probe cover", and the reason the suite can assert the plan without a network.
if $dry_run; then
  printf 'dry run: no name is contacted\n'
  printf '  %-8s %-32s %-10s %s\n' class name app checks
  for entry in "${hosts[@]}"; do
    read -r class name app <<<"$entry"
    case $class in
      edge) checks='TLS, chain, expiry, application signature' ;;
      tailnet) checks='one tailnet VIP, chain, expiry, status class' ;;
      *) checks='' ;;
    esac
    printf '  %-8s %-32s %-10s %s\n' "$class" "$name" "$app" "$checks"
  done
  printf '  %-8s %-32s %-10s %s\n' caa "$photos" '-' "the zone's CAA admits the served CA"
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# <url> <body file> <header file> -> status code. The body and headers are what
# the signature checks read; the code alone says nothing about which handler
# answered.
fetch() {
  "$curl_bin" --silent --show-error --output "$2" --dump-header "$3" \
    --max-time "$timeout_s" --write-out '%{http_code}' "$1" 2>/dev/null
}

# <name> -> one chain check and one expiry check, the two ways a name's
# certificate fails on its own. `-checkend` is an `openssl x509` option, not an
# `s_client` one: s_client rejects it as an unknown option and exits 1, so the
# expiry probe reads the PEM s_client printed. Both classes run this.
check_certificate() { # <name>
  local name=$1 pem
  pem=$("$openssl_bin" s_client -connect "$name:443" -servername "$name" \
    -verify_hostname "$name" -CAfile "$cafile" </dev/null 2>/dev/null)
  if grep -q 'Verify return code: 0 (ok)' <<<"$pem"; then
    ok "$name presents a certificate that chains to a public root for $name"
  else
    bad "$name presents a certificate that chains to a public root for $name" \
      "s_client could not verify $name against $cafile"
    return 0
  fi
  if "$openssl_bin" x509 -noout -checkend "$((min_days * 86400))" <<<"$pem" >/dev/null 2>&1; then
    ok "$name's certificate is valid for $min_days more days"
  else
    bad "$name's certificate is valid for $min_days more days" \
      "the certificate expires within $min_days days"
  fi
}

# <name> -> every address the resolver answers with, one per line. `ahostsv4`
# because a Service VIP is IPv4-only: a name answered only over IPv6 cannot reach
# one.
addresses() {
  "$getent_bin" ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u
}

# <address> -> the address is in the tailnet's own range (100.64.0.0/10 is a
# carrier-grade NAT block; Tailscale holds it, no public route does).
in_tailnet() {
  [[ $1 =~ ^100\.([0-9]{1,3})\. ]] || return 1
  ((10#${BASH_REMATCH[1]} >= 64 && 10#${BASH_REMATCH[1]} <= 127))
}

# The public edge, from the internet. Every leg runs even when an earlier one
# failed: a name whose certificate is wrong still has an application to check, and
# one run should say everything that is broken.
probe_edge() { # <name> <app>
  local name=$1 app=$2 code path
  code=$(fetch "https://$name/" "$work/body" "$work/hdr")
  if [[ $code =~ ^(2|3)[0-9][0-9]$ || $code == 401 ]]; then
    ok "$name answers over TLS ($code)"
  else
    bad "$name answers over TLS" "got '$code'"
  fi
  check_certificate "$name"

  case $app in
    immich)
      # Immich: any path is the app's own shell, never the wallpaper tree (a
      # <pre> listing) and never the agent gateway (a text/plain 404 on 443).
      for path in /apps/agent-local/v1 /apps/agent-general/v1 /wallpapers/; do
        code=$(fetch "https://$name$path" "$work/body" "$work/hdr")
        if [[ $code == 200 ]] && grep -q '<html' "$work/body"; then
          ok "$path answers as Immich on $name"
        else
          bad "$path answers as Immich on $name" \
            "got '$code' and '$(head -c 60 "$work/body" 2>/dev/null | tr -d '\n')'"
        fi
      done
      ;;
    opds)
      # OPDShelf: its own auth challenge, never a status page or a listing.
      for path in /apps/agent-local/v1 /apps/agent-general/v1 /wallpapers/; do
        code=$(fetch "https://$name$path" "$work/body" "$work/hdr")
        if [[ $code == 401 ]] && grep -qi '^www-authenticate:' "$work/hdr"; then
          ok "$path answers as OPDShelf's auth on $name"
        else
          bad "$path answers as OPDShelf's auth on $name" "got '$code'"
        fi
      done
      ;;
    backrest)
      # Backrest: its own title behind the guard. A bare 200 cannot tell it apart
      # from Caddy's own pages, which answer text/html too. The body and headers
      # are the ones the status probe just fetched: same request, same answer.
      if [[ $code == 200 ]] && grep -qi '^content-type: text/html' "$work/hdr" &&
        grep -qi '^server: backrest-guard' "$work/hdr" &&
        grep -q '<title>Backrest</title>' "$work/body"; then
        ok "$name answers as Backrest"
      else
        bad "$name answers as Backrest" \
          "got '$code' and '$(head -c 60 "$work/body" 2>/dev/null | tr -d '\n')'"
      fi
      ;;
  esac
}

# The tailnet, from inside. A name that does not resolve to exactly one address
# ends its row there: every leg below would be a guess about which address
# answered.
probe_tailnet() { # <name> <app>
  local name=$1 app=$2 code rc
  local -a addrs=()
  mapfile -t addrs < <(addresses "$name")
  if ((${#addrs[@]} == 0)); then
    bad "$name resolves" "no A record for $name"
    return 0
  fi
  if ((${#addrs[@]} > 1)); then
    bad "$name resolves to one address" "got ${addrs[*]}"
    return 0
  fi
  vip[$name]=${addrs[0]}

  if in_tailnet "${vip[$name]}"; then
    ok "$name resolves into the tailnet (${vip[$name]})"
  else
    bad "$name resolves into the tailnet" \
      "got '${vip[$name]}', which is not in $tailnet_range"
  fi
  check_certificate "$name"

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
}

declare -A vip=()
for entry in "${hosts[@]}"; do
  read -r class name app <<<"$entry"
  case $class in
    edge) probe_edge "$name" "$app" ;;
    tailnet) probe_tailnet "$name" "$app" ;;
    *) printf 'verify-fleet: unknown class %s\n' "$class" >&2; exit 2 ;;
  esac
done

# Six Services, six VIPs. The per-name legs place each address in the tailnet; this
# is the property that ties a name to *its own* Service, because nothing else would
# notice two names sharing one VIP: two Services are two advertisements, and a name
# that answers on another's address is a record pointing at the wrong place.
if ((${#vip[@]} != ${#tailnet_apps[@]})); then
  bad "all six names resolve to distinct tailnet addresses" \
    "only ${#vip[@]} of ${#tailnet_apps[@]} names resolved"
else
  distinct=$(printf '%s\n' "${vip[@]}" | sort -u | wc -l)
  if ((${#tailnet_apps[@]} == distinct)); then
    ok "all six names resolve to distinct tailnet addresses"
  else
    bad "all six names resolve to distinct tailnet addresses" \
      "$(for app in "${tailnet_apps[@]}"; do printf '%s=%s ' "$app.$suffix" "${vip[$app.$suffix]}"; done)"
  fi
fi

# The zone's CAA records and the certificate the edge serves are two networks
# apart, and `scripts/verify-caa.sh` already owns that comparison: this run calls it
# and folds its exit status into the verdict, so one checkout, one tailnet join and
# one page cover the whole fleet. Its notices pass through here and its report is
# echoed when it fails; a standalone run is still the way to ask it a question.
caa_report=$("$caa_script" 2>&1)
caa_rc=$?
if ((caa_rc == 0)); then
  grep '^note ' <<<"$caa_report" || true
  ok "the zone's CAA policy admits the CA behind $photos's certificate"
else
  printf '%s\n' "$caa_report"
  bad "the zone's CAA policy admits the CA behind $photos's certificate" \
    "$(grep -m1 '^FAIL ' <<<"$caa_report" | sed 's/^FAIL //')"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
exit $((fail > 0))
