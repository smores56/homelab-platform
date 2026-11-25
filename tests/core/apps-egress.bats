#!/usr/bin/env bats
# bats file_tags=core
# Offline checks for the apps-tenant egress policy (SDLC #726, T7 of #701).
#
# `egress = "internet"` is a public network, not the host's networks. A
# tenant-wide nftables rule drops every destination that is not the public
# internet for the apps uid: LAN and link-local ranges, the Tailscale ranges,
# host loopback, and the cloud metadata address. This proves the rule set
# statically and, where the runner can, that nft itself parses it.
#
#   bats tests/core/apps-egress.bats
load ../helpers

rules=image/rootfs/etc/nftables/smortress-apps.nft
unit=units/systemd/smortress-apps-egress.service

@test "the tenant egress ruleset exists" {
    [[ -f $rules ]]
}

@test "the loader unit exists" {
    [[ -f $unit ]]
}

# The rule matches the tenant by account name, not by uid. nft resolves the
# name when it loads the ruleset, so the policy keeps following the tenant after
# systemd-sysusers silently allocates a different uid because 1001 was taken; a
# numeric rule would then match nobody and leave the chain's `policy accept` in
# force. Every skuid operand must be the name.
@test "every skuid rule names the apps account" {
    skuid_operands=$(grep -oE 'meta skuid [^[:space:]]+' "$rules" | awk '{print $3}' | sort -u || true)
    assert_equal "$skuid_operands" apps
}

# The class of bug, not the instance: no skuid rule may pin a number.
@test "no skuid rule pins a numeric uid" {
    numeric_skuid=$(grep -E 'meta skuid [0-9]' "$rules" || true)
    assert_equal "$numeric_skuid" ""
}

@test "the rule is on the output path" {
    grep -qE 'hook output' "$rules"
}

@test "every non-public destination is dropped" {
    required=(
        10.0.0.0/8
        172.16.0.0/12
        192.168.0.0/16
        169.254.0.0/16
        127.0.0.0/8
        100.64.0.0/10
    )
    missing=''
    for cidr in "${required[@]}"; do
        grep -qF -- "$cidr" "$rules" || missing="$missing $cidr"
    done
    [[ -z $missing ]] || printf 'missing:%s\n' "$missing" >&2
    assert_equal "$missing" ""
}

# Everything this host answers on is local, including an address that is not in
# a private range; resolve it through fib instead of enumerating it.
@test "every local address is dropped, not just the ranges" {
    grep -qE 'meta skuid apps fib daddr type local drop' "$rules"
}

# Pasta forwards the tenant's DNS to the host resolver as the tenant uid, so
# port 53 to a local address must stay open or no app can resolve a name.
@test "DNS is reachable wherever the resolver lives" {
    grep -qE 'meta skuid apps udp dport 53 accept' "$rules"
    grep -qE 'meta skuid apps tcp dport 53 accept' "$rules"
}

@test "IPv6 egress is dropped entirely" {
    grep -qE 'meta skuid apps meta nfproto ipv6 drop' "$rules"
}

# A missing skuid on any drop rule would take out traffic for every user.
@test "every drop rule is bound to the tenant account" {
    unbound=$(grep -E '[[:space:]]drop$' "$rules" | grep -v '^[[:space:]]*}' |
        grep -vE 'meta skuid apps([[:space:]]|$)' || true)
    assert_equal "$unbound" ""
}

# The DNS accepts must precede the local-address drop or DNS dies again.
@test "the DNS exception is evaluated before the drops" {
    dns_line=$(grep -nE '(udp|tcp) dport 53 accept' "$rules" | head -1 | cut -d: -f1 || true)
    local_line=$(grep -nE 'fib daddr type local drop' "$rules" | head -1 | cut -d: -f1 || true)
    ordered=false
    if [[ -n $dns_line && -n $local_line ]] && ((dns_line < local_line)); then
        ordered=true
    fi
    [[ $ordered == true ]] || printf 'dns=%s local=%s\n' "$dns_line" "$local_line" >&2
    assert "$ordered"
}

# The internet class keeps the public internet, so the policy must not accept
# everything and the drops must come before any accept.
@test "the tenant chain keeps the public internet reachable" {
    grep -qE '^\s*table' "$rules"
    ! grep -qE '^\s*policy drop' "$rules"
}

@test "only the DNS exception is explicitly accepted" {
    explicit=$(grep -E '(udp|tcp) dport 53 accept' "$rules" || true)
    others=$(grep -E '\baccept\b' "$rules" | grep -v 'policy accept' |
        grep -vE '(udp|tcp) dport 53 accept' || true)
    [[ -z $others ]] || printf 'other accepts:\n%s\n' "$others" >&2
    assert_equal "$(printf '%s\n' "$explicit" | grep -c .)" 2
    assert_equal "$others" ""
}

# Loading twice must be a no-op: a plain `delete` aborts a reload when the
# table is absent on the first boot.
@test "the table is destroyed idempotently" {
    destroyed=false
    if grep -qE '^destroy table' "$rules"; then
        destroyed=true
    fi
    [[ $destroyed == true ]] || head -5 "$rules" >&2
    assert "$destroyed"
}

@test "the image enables the loader" {
    grep -q 'smortress-apps-egress.service' image/Containerfile
}

@test "the unit loads the immutable vendor ruleset" {
    grep -q 'nft -f /usr/etc/nftables/smortress-apps.nft' "$unit"
}

# /etc is bootc's merge of the image's vendor copy: it can be hand-edited into
# drift, or deleted outright, and either leaves the tenant unfiltered once the
# unit restarts. Loading the vendor path removes both failure modes.
@test "the unit does not load a mergeable /etc copy" {
    ! grep -qE 'nft .*-f +/etc/' "$unit"
}

# The ruleset names the account, so the account must exist when nft loads it;
# with DefaultDependencies=no nothing else orders this unit after sysusers.
@test "the account exists before the ruleset is loaded" {
    grep -q '^After=.*systemd-sysusers.service' "$unit"
}

# The rule set must be in force before a lingering user manager (and any
# tenant Quadlet it starts) can run.
@test "the rule set is in force before a user manager can start" {
    grep -q '^Before=.*systemd-logind.service' "$unit"
}

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

@test "the deny ruleset exists" {
    [[ -f $deny ]]
}

@test "the deny unit exists" {
    [[ -f $deny_unit ]]
}

# The deny ruleset is what the allow-list destroys, so it must define the same
# table: a different name would be a second table evaluated beside the first,
# and the tenant would stay dropped after the swap.
@test "both rulesets define the same table, so the swap replaces it" {
    allow_table=$(grep -oE '^table [a-z0-9]+ [a-z0-9_]+' "$rules" | awk '{print $2, $3}' | head -1 || true)
    deny_table=$(grep -oE '^table [a-z0-9]+ [a-z0-9_]+' "$deny" | awk '{print $2, $3}' | head -1 || true)
    same=false
    if [[ -n $deny_table && $allow_table == "$deny_table" ]]; then
        same=true
    fi
    [[ $same == true ]] || printf 'deny=[%s] allow=[%s]\n' "$deny_table" "$allow_table" >&2
    assert "$same"
}

# The allow-list must destroy that table before redefining it. Without the
# destroy the second load adds rules to the existing chain instead of replacing
# it, and the deny rule survives into the allow-list.
@test "the allow-list destroys the deny table before rebuilding it" {
    deny_table=$(grep -oE '^table [a-z0-9]+ [a-z0-9_]+' "$deny" | awk '{print $2, $3}' | head -1 || true)
    destroyed=false
    if [[ -n $deny_table ]] && grep -qE "^destroy table $deny_table\$" "$rules"; then
        destroyed=true
    fi
    [[ $destroyed == true ]] || grep -E '^destroy' "$rules" >&2 || true
    assert "$destroyed"
}

# One file is one `nft -f` transaction, and nft applies the whole file or
# nothing. The destroy coming first inside that file is what makes the swap
# atomic: an unparsable allow-list leaves the deny table exactly as it was, and
# a parsed one leaves the allow-list with no deny rule behind.
@test "the allow-list destroys and rebuilds in one transaction, destroy first" {
    destroy_line=$(grep -nE '^destroy table' "$rules" | head -1 | cut -d: -f1 || true)
    define_line=$(grep -nE '^table ' "$rules" | head -1 | cut -d: -f1 || true)
    first=false
    if [[ -n $destroy_line && -n $define_line ]] && ((destroy_line < define_line)); then
        first=true
    fi
    [[ $first == true ]] || printf 'destroy=%s table=%s\n' "$destroy_line" "$define_line" >&2
    assert "$first"
}

# The placeholder has to cover exactly the traffic the allow-list covers, or the
# swap would change which hook and priority the tenant is filtered on.
@test "the deny chain sits on the same hook, priority and policy as the allow-list" {
    allow_chain=$(grep -oE 'type filter hook [a-z]+ priority [a-z]+; policy [a-z]+;' "$rules" | head -1 || true)
    deny_chain=$(grep -oE 'type filter hook [a-z]+ priority [a-z]+; policy [a-z]+;' "$deny" | head -1 || true)
    same=false
    if [[ -n $deny_chain && $allow_chain == "$deny_chain" ]]; then
        same=true
    fi
    [[ $same == true ]] || printf 'deny=[%s] allow=[%s]\n' "$deny_chain" "$allow_chain" >&2
    assert "$same"
}

# The tenant is named here for the same reason as above — nft resolves the name
# when it loads the file — and the rule is a bare drop, so nothing the
# placeholder keeps can leak while the allow-list is missing.
@test "the deny ruleset names the apps account" {
    deny_skuid=$(grep -oE 'meta skuid [^[:space:];]+' "$deny" | awk '{print $3}' | sort -u || true)
    assert_equal "$deny_skuid" apps
}

@test "no deny rule pins a numeric uid" {
    numeric_skuid=$(grep -E 'meta skuid [0-9]' "$deny" || true)
    assert_equal "$numeric_skuid" ""
}

# One rule and nothing else: every tenant packet is dropped, and every packet
# that is not the tenant's is untouched by the placeholder.
@test "the deny ruleset drops the tenant and accepts nothing else" {
    assert_equal "$(grep -cE '^[[:space:]]+meta skuid' "$deny")" 1
    accepted=$(grep -E '\baccept\b' "$deny" | grep -v 'policy accept' || true)
    [[ -z $accepted ]] || cat "$deny" >&2
    assert_equal "$accepted" ""
}

# The unit: a oneshot that loads the vendor copy, after the account exists and
# before the allow-list can replace it.
@test "the deny unit stays active once its table is loaded" {
    grep -q '^Type=oneshot' "$deny_unit"
    grep -q '^RemainAfterExit=yes' "$deny_unit"
}

@test "the deny unit loads the immutable vendor ruleset" {
    grep -q 'nft -f /usr/etc/nftables/smortress-apps-deny.nft' "$deny_unit"
}

@test "the deny unit does not load a mergeable /etc copy" {
    ! grep -qE 'nft .*-f +/etc/' "$deny_unit"
}

@test "the deny rule set loads after the account exists" {
    grep -q '^After=.*systemd-sysusers.service' "$deny_unit"
}

# Before the allow-list, so there is never a load order where the tenant runs
# with the placeholder still armed; before logind, so it is in force before a
# lingering manager and every tenant Quadlet it starts.
@test "the deny rule set is in force before the allow-list replaces it" {
    grep -qE '^Before=.*smortress-apps-egress\.service' "$deny_unit"
}

@test "the deny rule set is in force before a user manager can start" {
    grep -qE '^Before=.*systemd-logind\.service' "$deny_unit"
}

@test "the image enables the deny unit" {
    grep -q 'smortress-apps-deny.service' image/Containerfile
}

@test "the image enables the allow-list unit" {
    grep -q 'smortress-apps-egress.service' image/Containerfile
}

# nft_parses <file>: the real parser reads the file, run in a user + network
# namespace so nft has the capability it needs without root.
nft_parses() {
    unshare -rn nft -c -f "$1"
}

# nft_loads_twice <file>: one file is one transaction, so loading it again must
# be a no-op rather than an error.
nft_loads_twice() {
    # shellcheck disable=SC2016  # $1 is the inner shell's argument
    unshare -rn sh -c 'nft -f "$1" && nft -f "$1"' sh "$1"
}

# The proof of the swap, rather than the claim: load the placeholder, then the
# allow-list, in one namespace and read back what the kernel holds. A stacked
# load keeps the bare drop beside the allow rules — the tenant would be denied
# everything after the swap — so the bare drop has to be gone. nft prints the
# account as the uid it resolves to, which is why the pattern matches any
# number: the assertion is about the rule, not the id.
nft_swaps() {
    # shellcheck disable=SC2016  # $1, $2 are the inner shell's arguments
    swapped=$(unshare -rn sh -c '
        nft -f "$1" && nft -f "$2" || exit 1
        nft list table inet smortress_apps_egress
    ' sh "$deny" "$rules" 2>&1 || true)
    assert_contains "$swapped" 'dport 53 accept'
    ! grep -qE '^[[:space:]]*meta skuid [0-9]+ drop$' <<<"$swapped"
}

# A real parser is better than greps, but only a runner that has unprivileged
# namespaces and the account nft resolves `meta skuid apps` against can offer
# one. Elsewhere the shell suite printed a single `skip nft parse` line and
# asserted nothing, so here that runner registers no test: the assertion count
# of a conversion has to match the suite it replaced on the same host.
if command -v nft >/dev/null 2>&1 && unshare -rn true 2>/dev/null &&
    getent passwd apps >/dev/null 2>&1; then
    for file in "$rules" "$deny"; do
        register "nft parses $file" nft_parses "$file"
        register "$file loads twice without error" nft_loads_twice "$file"
    done
    register 'the allow-list replaces the deny table instead of stacking on it' nft_swaps
else
    # Reported as skipped, not omitted: a host that cannot parse the rules must
    # not look like one that proved they are safe.
    why='no unprivileged network namespaces or no apps account'
    for file in "$rules" "$deny"; do
        register_skip "nft parses $file" "$why"
        register_skip "$file loads twice without error" "$why"
    done
    register_skip 'the allow-list replaces the deny table instead of stacking on it' "$why"
fi
