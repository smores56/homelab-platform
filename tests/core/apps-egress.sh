#!/usr/bin/env bash
# Offline checks for the apps-tenant egress policy (SDLC #726, T7 of #701).
#
# `egress = "internet"` is a public network, not the host's networks. A
# tenant-wide nftables rule drops every destination that is not the public
# internet for the apps uid: LAN and link-local ranges, the Tailscale ranges,
# host loopback, and the cloud metadata address. This proves the rule set
# statically and, where the runner can, that nft itself parses it.
#
#   tests/core/apps-egress.sh
set -uo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root" || exit 1

rules=image/rootfs/etc/nftables/smortress-apps.nft
unit=units/systemd/smortress-apps-egress.service

pass=0
fail=0
ok() {
  pass=$((pass + 1))
  printf 'ok   %s\n' "$1"
}
bad() {
  fail=$((fail + 1))
  printf 'FAIL %s\n' "$1"
  [[ -n ${2:-} ]] && printf '     %s\n' "${2//$'\n'/$'\n'     }"
  return 0
}

if [[ -f $rules ]]; then ok 'the tenant egress ruleset exists'; else bad 'the tenant egress ruleset exists'; fi
if [[ -f $unit ]]; then ok 'the loader unit exists'; else bad 'the loader unit exists'; fi
[[ -f $rules && -f $unit ]] || {
  printf '\n%d passed, %d failed\n' "$pass" "$fail"
  exit 1
}

# The rule matches the tenant by account name, not by uid. nft resolves the
# name when it loads the ruleset, so the policy keeps following the tenant after
# systemd-sysusers silently allocates a different uid because 1001 was taken; a
# numeric rule would then match nobody and leave the chain's `policy accept` in
# force. Every skuid operand must be the name.
skuid_operands=$(grep -oE 'meta skuid [^[:space:]]+' "$rules" | awk '{print $3}' | sort -u)
if [[ $skuid_operands == apps ]]; then
  ok 'every skuid rule names the apps account'
else
  bad 'every skuid rule names the apps account' "$(printf '%s\n' "$skuid_operands")"
fi
# The class of bug, not the instance: no skuid rule may pin a number.
numeric_skuid=$(grep -E 'meta skuid [0-9]' "$rules" || true)
if [[ -z $numeric_skuid ]]; then
  ok 'no skuid rule pins a numeric uid'
else
  bad 'no skuid rule pins a numeric uid' "$numeric_skuid"
fi
if grep -qE 'hook output' "$rules"; then ok 'the rule is on the output path' ; else bad 'the rule is on the output path'; fi

required=(
  10.0.0.0/8
  172.16.0.0/12
  192.168.0.0/16
  169.254.0.0/16
  127.0.0.0/8
  100.64.0.0/10
)
missing=0
for cidr in "${required[@]}"; do
  grep -qF -- "$cidr" "$rules" || {
    missing=$((missing + 1))
    printf '     missing %s\n' "$cidr"
  }
done
if [[ $missing == 0 ]]; then
  ok 'every non-public destination is dropped'
else
  bad 'every non-public destination is dropped'
fi

# Everything this host answers on is local, including an address that is not in
# a private range; resolve it through fib instead of enumerating it.
if grep -qE 'meta skuid apps fib daddr type local drop' "$rules"; then
  ok 'every local address is dropped, not just the ranges'
else
  bad 'every local address is dropped, not just the ranges'
fi

# Pasta forwards the tenant's DNS to the host resolver as the tenant uid, so
# port 53 to a local address must stay open or no app can resolve a name.
if grep -qE 'meta skuid apps udp dport 53 accept' "$rules" &&
  grep -qE 'meta skuid apps tcp dport 53 accept' "$rules"; then
  ok 'DNS is reachable wherever the resolver lives'
else
  bad 'DNS is reachable wherever the resolver lives'
fi

if grep -qE 'meta skuid apps meta nfproto ipv6 drop' "$rules"; then
  ok 'IPv6 egress is dropped entirely'
else
  bad 'IPv6 egress is dropped entirely'
fi

# A missing skuid on any drop rule would take out traffic for every user.
unbound=$(grep -E '[[:space:]]drop$' "$rules" | grep -v '^[[:space:]]*}' \
  | grep -vE 'meta skuid apps([[:space:]]|$)' || true)
if [[ -z $unbound ]]; then
  ok 'every drop rule is bound to the tenant account'
else
  bad 'every drop rule is bound to the tenant account' "$unbound"
fi

# The DNS accepts must precede the local-address drop or DNS dies again.
dns_line=$(grep -nE '(udp|tcp) dport 53 accept' "$rules" | head -1 | cut -d: -f1)
local_line=$(grep -nE 'fib daddr type local drop' "$rules" | cut -d: -f1)
if [[ -n $dns_line && -n $local_line ]] && ((dns_line < local_line)); then
  ok 'the DNS exception is evaluated before the drops'
else
  bad 'the DNS exception is evaluated before the drops' "dns=$dns_line local=$local_line"
fi

# The internet class keeps the public internet, so the policy must not accept
# everything and the drops must come before any accept.
if grep -qE '^\s*table' "$rules" && ! grep -qE '^\s*policy drop' "$rules"; then
  ok 'the tenant chain keeps the public internet reachable'
else
  bad 'the tenant chain keeps the public internet reachable'
fi
explicit=$(grep -E '(udp|tcp) dport 53 accept' "$rules" || true)
others=$(grep -E '\baccept\b' "$rules" | grep -v 'policy accept' \
  | grep -vE '(udp|tcp) dport 53 accept' || true)
if [[ $(printf '%s\n' "$explicit" | grep -c .) == 2 && -z $others ]]; then
  ok 'only the DNS exception is explicitly accepted'
else
  bad 'only the DNS exception is explicitly accepted' "$others"
fi

# Loading twice must be a no-op: a plain `delete` aborts a reload when the
# table is absent on the first boot.
if grep -qE '^destroy table' "$rules"; then
  ok 'the table is destroyed idempotently'
else
  bad 'the table is destroyed idempotently' "$(head -5 "$rules")"
fi

if grep -q 'smortress-apps-egress.service' image/Containerfile; then
  ok 'the image enables the loader'
else
  bad 'the image enables the loader'
fi
if grep -q 'nft -f /etc/nftables/smortress-apps.nft' "$unit"; then
  ok 'the unit loads the shipped ruleset'
else
  bad 'the unit loads the shipped ruleset' "$(cat "$unit")"
fi

# The ruleset names the account, so the account must exist when nft loads it;
# with DefaultDependencies=no nothing else orders this unit after sysusers.
if grep -q '^After=.*systemd-sysusers.service' "$unit"; then
  ok 'the account exists before the ruleset is loaded'
else
  bad 'the account exists before the ruleset is loaded' "$(cat "$unit")"
fi
# The rule set must be in force before a lingering user manager (and any
# tenant Quadlet it starts) can run.
if grep -q '^Before=.*systemd-logind.service' "$unit"; then
  ok 'the rule set is in force before a user manager can start'
else
  bad 'the rule set is in force before a user manager can start' "$(cat "$unit")"
fi

# A real parser is better than greps. A user + network namespace gives nft the
# capability it needs without root, and loading twice there proves the reload
# is a no-op; a runner without unprivileged namespaces says so instead.
if command -v nft >/dev/null 2>&1 && unshare -rn true 2>/dev/null; then
    if unshare -rn nft -c -f "$rules" >/dev/null 2>&1; then
        ok 'nft parses the ruleset'
    else
        bad 'nft parses the ruleset' "$(unshare -rn nft -c -f "$rules" 2>&1)"
    fi
    # shellcheck disable=SC2016  # $1 is the inner shell's argument
    if unshare -rn sh -c 'nft -f "$1" && nft -f "$1"' sh "$rules" >/dev/null 2>&1; then
        ok 'the ruleset loads twice without error'
    else
        bad 'the ruleset loads twice without error' \
            "$(unshare -rn sh -c 'nft -f "$1" && nft -f "$1"' sh "$rules" 2>&1)"
    fi
else
    printf 'skip nft parse (no unprivileged namespaces)\n'
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
