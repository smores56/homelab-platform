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
net=$(grep -E 'ip daddr 10\.89\.0\.0/24 accept' "$rules" || true)
others=$(grep -E '\baccept\b' "$rules" | grep -v 'policy accept' \
  | grep -vE '(udp|tcp) dport 53 accept' \
  | grep -vE 'ip daddr 10\.89\.0\.0/24 accept' || true)
if [[ $(printf '%s\n' "$explicit" | grep -c .) == 2 &&
  $(printf '%s\n' "$net" | grep -c .) == 1 && -z $others ]]; then
  ok 'only the DNS and tenant-network exceptions are explicitly accepted'
else
  bad 'only the DNS and tenant-network exceptions are explicitly accepted' "$others"
fi

# The tenant's own bridge sits inside 10.0.0.0/8, so the LAN drop would also
# drop rootlessport's forward to its own container: the exception must be
# evaluated first or every published port times out.
net_line=$(grep -nE 'ip daddr 10\.89\.0\.0/24 accept' "$rules" | head -1 | cut -d: -f1)
lan_line=$(grep -nE '^[[:space:]]*10\.0\.0\.0/8,?[[:space:]]*$' "$rules" | head -1 | cut -d: -f1)
if [[ -n $net_line && -n $lan_line ]] && ((net_line < lan_line)); then
  ok 'the tenant network exception is evaluated before the LAN drop'
else
  bad 'the tenant network exception is evaluated before the LAN drop' "net=$net_line lan=$lan_line"
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
if grep -q 'nft -f /usr/etc/nftables/smortress-apps.nft' "$unit"; then
  ok 'the unit loads the immutable vendor ruleset'
else
  bad 'the unit loads the immutable vendor ruleset' "$(cat "$unit")"
fi
# /etc is bootc's merge of the image's vendor copy: it can be hand-edited into
# drift, or deleted outright, and either leaves the tenant unfiltered once the
# unit restarts. Loading the vendor path removes both failure modes.
if grep -qE 'nft .*-f +/etc/' "$unit"; then
  bad 'the unit does not load a mergeable /etc copy' "$(cat "$unit")"
else
  ok 'the unit does not load a mergeable /etc copy'
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

# --- the fail-closed gate ---------------------------------------------------
#
# The ruleset above is the egress boundary when its loader runs. If the loader
# never does — a failed unit, a parse error, a ruleset that cannot be read — no
# table exists and the tenant is unfiltered. So a minimal table under the same
# name is loaded before anything tenant-side can start: the allow-list replaces
# it, and whatever happens to the replacement, the tenant is left dropped rather
# than open.
deny=image/rootfs/etc/nftables/smortress-apps-deny.nft
deny_unit=units/systemd/smortress-apps-deny.service

if [[ -f $deny ]]; then ok 'the deny ruleset exists'; else bad 'the deny ruleset exists'; fi
if [[ -f $deny_unit ]]; then ok 'the deny unit exists'; else bad 'the deny unit exists'; fi
[[ -f $deny && -f $deny_unit ]] || {
  printf '\n%d passed, %d failed\n' "$pass" "$fail"
  exit 1
}

# The deny ruleset is what the allow-list destroys, so it must define the same
# table: a different name would be a second table evaluated beside the first,
# and the tenant would stay dropped after the swap.
allow_table=$(grep -oE '^table [a-z0-9]+ [a-z0-9_]+' "$rules" | awk '{print $2, $3}' | head -1)
deny_table=$(grep -oE '^table [a-z0-9]+ [a-z0-9_]+' "$deny" | awk '{print $2, $3}' | head -1)
if [[ -n $deny_table && $allow_table == "$deny_table" ]]; then
  ok 'both rulesets define the same table, so the swap replaces it'
else
  bad 'both rulesets define the same table, so the swap replaces it' \
    "deny=[$deny_table] allow=[$allow_table]"
fi

# The allow-list must destroy that table before redefining it. Without the
# destroy the second load adds rules to the existing chain instead of replacing
# it, and the deny rule survives into the allow-list.
if [[ -n $deny_table ]] && grep -qE "^destroy table $deny_table\$" "$rules"; then
  ok 'the allow-list destroys the deny table before rebuilding it'
else
  bad 'the allow-list destroys the deny table before rebuilding it' \
    "$(grep -E '^destroy' "$rules" || true)"
fi
# One file is one `nft -f` transaction, and nft applies the whole file or
# nothing. The destroy coming first inside that file is what makes the swap
# atomic: an unparsable allow-list leaves the deny table exactly as it was, and
# a parsed one leaves the allow-list with no deny rule behind.
destroy_line=$(grep -nE '^destroy table' "$rules" | head -1 | cut -d: -f1)
define_line=$(grep -nE '^table ' "$rules" | head -1 | cut -d: -f1)
if [[ -n $destroy_line && -n $define_line ]] && ((destroy_line < define_line)); then
  ok 'the allow-list destroys and rebuilds in one transaction, destroy first'
else
  bad 'the allow-list destroys and rebuilds in one transaction, destroy first' \
    "destroy=$destroy_line table=$define_line"
fi

# The placeholder has to cover exactly the traffic the allow-list covers, or the
# swap would change which hook and priority the tenant is filtered on.
allow_chain=$(grep -oE 'type filter hook [a-z]+ priority [a-z]+; policy [a-z]+;' "$rules" | head -1)
deny_chain=$(grep -oE 'type filter hook [a-z]+ priority [a-z]+; policy [a-z]+;' "$deny" | head -1)
if [[ -n $deny_chain && $allow_chain == "$deny_chain" ]]; then
  ok 'the deny chain sits on the same hook, priority and policy as the allow-list'
else
  bad 'the deny chain sits on the same hook, priority and policy as the allow-list' \
    "deny=[$deny_chain] allow=[$allow_chain]"
fi

# The tenant is named here for the same reason as above — nft resolves the name
# when it loads the file — and the rule is a bare drop, so nothing the
# placeholder keeps can leak while the allow-list is missing.
deny_skuid=$(grep -oE 'meta skuid [^[:space:];]+' "$deny" | awk '{print $3}' | sort -u)
if [[ $deny_skuid == apps ]]; then
  ok 'the deny ruleset names the apps account'
else
  bad 'the deny ruleset names the apps account' "[$deny_skuid]"
fi
if [[ -z $(grep -E 'meta skuid [0-9]' "$deny" || true) ]]; then
  ok 'no deny rule pins a numeric uid'
else
  bad 'no deny rule pins a numeric uid' "$(grep -E 'meta skuid [0-9]' "$deny")"
fi
# One rule and nothing else: every tenant packet is dropped, and every packet
# that is not the tenant's is untouched by the placeholder.
if [[ $(grep -cE '^[[:space:]]+meta skuid' "$deny") == 1 ]] &&
  [[ -z $(grep -E '\baccept\b' "$deny" | grep -v 'policy accept' || true) ]]; then
  ok 'the deny ruleset drops the tenant and accepts nothing else'
else
  bad 'the deny ruleset drops the tenant and accepts nothing else' "$(cat "$deny")"
fi

# The unit: a oneshot that loads the vendor copy, after the account exists and
# before the allow-list can replace it.
if grep -q '^Type=oneshot' "$deny_unit" && grep -q '^RemainAfterExit=yes' "$deny_unit"; then
  ok 'the deny unit stays active once its table is loaded'
else
  bad 'the deny unit stays active once its table is loaded' "$(cat "$deny_unit")"
fi
if grep -q 'nft -f /usr/etc/nftables/smortress-apps-deny.nft' "$deny_unit"; then
  ok 'the deny unit loads the immutable vendor ruleset'
else
  bad 'the deny unit loads the immutable vendor ruleset' "$(cat "$deny_unit")"
fi
if grep -qE 'nft .*-f +/etc/' "$deny_unit"; then
  bad 'the deny unit does not load a mergeable /etc copy' "$(cat "$deny_unit")"
else
  ok 'the deny unit does not load a mergeable /etc copy'
fi
if grep -q '^After=.*systemd-sysusers.service' "$deny_unit"; then
  ok 'the deny rule set loads after the account exists'
else
  bad 'the deny rule set loads after the account exists' "$(cat "$deny_unit")"
fi
# Before the allow-list, so there is never a load order where the tenant runs
# with the placeholder still armed; before logind, so it is in force before a
# lingering manager and every tenant Quadlet it starts.
if grep -qE '^Before=.*smortress-apps-egress\.service' "$deny_unit"; then
  ok 'the deny rule set is in force before the allow-list replaces it'
else
  bad 'the deny rule set is in force before the allow-list replaces it' "$(cat "$deny_unit")"
fi
if grep -qE '^Before=.*systemd-logind\.service' "$deny_unit"; then
  ok 'the deny rule set is in force before a user manager can start'
else
  bad 'the deny rule set is in force before a user manager can start' "$(cat "$deny_unit")"
fi
if grep -q 'smortress-apps-deny.service' image/Containerfile; then
  ok 'the image enables the deny unit'
else
  bad 'the image enables the deny unit'
fi
if grep -q 'smortress-apps-egress.service' image/Containerfile; then
  ok 'the image enables the allow-list unit'
else
  bad 'the image enables the allow-list unit'
fi

# A real parser is better than greps. A user + network namespace gives nft the
# capability it needs without root, and loading twice there proves the reload
# is a no-op; a runner without unprivileged namespaces says so instead.
if command -v nft >/dev/null 2>&1 && unshare -rn true 2>/dev/null; then
    for file in "$rules" "$deny"; do
        if unshare -rn nft -c -f "$file" >/dev/null 2>&1; then
            ok "nft parses $file"
        else
            bad "nft parses $file" "$(unshare -rn nft -c -f "$file" 2>&1)"
        fi
        # shellcheck disable=SC2016  # $1 is the inner shell's argument
        if unshare -rn sh -c 'nft -f "$1" && nft -f "$1"' sh "$file" >/dev/null 2>&1; then
            ok "$file loads twice without error"
        else
            bad "$file loads twice without error" \
                "$(unshare -rn sh -c 'nft -f "$1" && nft -f "$1"' sh "$file" 2>&1)"
        fi
    done
    # The proof of the swap, rather than the claim: load the placeholder, then
    # the allow-list, in one namespace and read back what the kernel holds. A
    # stacked load keeps the bare drop beside the allow rules — the tenant would
    # be denied everything after the swap — so the bare drop has to be gone.
    # nft prints the account as the uid it resolves to, which is why the pattern
    # matches any number: the assertion is about the rule, not the id.
    # shellcheck disable=SC2016  # $1, $2 and the pattern are the inner shell's
    swapped=$(unshare -rn sh -c '
        nft -f "$1" && nft -f "$2" || exit 1
        nft list table inet smortress_apps_egress
    ' sh "$deny" "$rules" 2>&1)
    if [[ $swapped == *'dport 53 accept'* ]] &&
        ! grep -qE '^[[:space:]]*meta skuid [0-9]+ drop$' <<<"$swapped"; then
        ok 'the allow-list replaces the deny table instead of stacking on it'
    else
        bad 'the allow-list replaces the deny table instead of stacking on it' "$swapped"
    fi
else
    printf 'skip nft parse (no unprivileged namespaces)\n'
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
