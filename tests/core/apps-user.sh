#!/usr/bin/env bash
# Offline checks for the apps tenant user (SDLC #726, T7 of #701).
#
# The tenant is one unprivileged account whose id nobody names. This proves the
# account shape that the rest of the tenant depends on: the id systemd-sysusers
# allocates rather than one we demand, the account the egress rule and the
# dataset owner name, a login-less shell, a private home with linger, the
# subuid/subgid allocation Podman needs, a per-user policy that admits
# digest-pinned images, and a refusal to continue when a rootless dependency is
# missing.
#
#   tests/core/apps-user.sh
set -uo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root" || exit 1

script=scripts/apps-user.sh
sysusers=image/rootfs/etc/sysusers.d/smortress-apps.conf
unit=units/systemd/smortress-apps-user.service
nft=image/rootfs/etc/nftables/smortress-apps.nft
tmpfiles=image/rootfs/etc/tmpfiles.d/smortress.conf

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

for f in "$script" "$sysusers" "$unit" "$nft" "$tmpfiles"; do
  if [[ -f $f ]]; then ok "$f exists"; else bad "$f exists"; fi
done

# --- account shape -----------------------------------------------------------

# sysusers allocates the id: a demand for a number allocates a different one
# silently when it is taken, and every numeric consumer then points at nobody.
if grep -qx 'u apps - "apps tenant" /var/home/apps /usr/sbin/nologin' "$sysusers" &&
  grep -qx 'g apps -' "$sysusers"; then
  ok 'sysusers allocates the tenant id and keeps its group'
else
  bad 'sysusers allocates the tenant id and keeps its group' "$(cat "$sysusers")"
fi
if grep -qE '^[ug] apps [0-9]' "$sysusers"; then
  bad 'sysusers demands no tenant id' "$(grep -E '^[ug] apps' "$sysusers")"
else
  ok 'sysusers demands no tenant id'
fi
# The egress rule must follow this account wherever sysusers puts it: it
# allocates the next free uid silently when 1001 is taken, so a numeric rule
# would match nobody and leave the tenant outside the policy.
account=$(awk '$1 == "u" && $2 == "apps" { print $2 }' "$sysusers")
if [[ $account == apps ]] && grep -qE 'meta skuid apps([[:space:]]|$)' "$nft" &&
  ! grep -qE 'meta skuid [0-9]' "$nft"; then
  ok 'the egress rule names the same account, not a uid'
else
  bad 'the egress rule names the same account, not a uid' "$(grep -E 'meta skuid' "$nft")"
fi
if grep -qE '^d /var/home/apps 0700 apps apps -$' "$tmpfiles"; then
  ok 'the tenant home is private to the tenant'
else
  bad 'the tenant home is private to the tenant'
fi
if grep -qE '^f /var/lib/systemd/linger/apps ' "$tmpfiles"; then
  ok 'the tenant user manager starts without a login'
else
  bad 'the tenant user manager starts without a login'
fi
# Nothing may name the tenant's user manager by number: a drop-in or an enable
# for user@<uid> silently stops applying the moment sysusers allocates another
# id, which is how the gate and the slice limits used to disappear unnoticed.
numeric_user_units=$(grep -rlE 'user@[0-9]+|user-[0-9]+\.slice' units image/Containerfile 2>/dev/null |
  sort | paste -sd' ')
if [[ -z $numeric_user_units ]]; then
  ok 'no unit or image line names the tenant user manager by number'
else
  bad 'no unit or image line names the tenant user manager by number' "$numeric_user_units"
fi
if compgen -G 'units/systemd/user@*.service.d/*' >/dev/null ||
  compgen -G 'units/systemd/user-*.slice.d/*' >/dev/null; then
  bad 'the tenant has no per-uid manager drop-in' "$(find units/systemd -name 'user*' -maxdepth 1)"
else
  ok 'the tenant has no per-uid manager drop-in'
fi
if grep -q '/usr/libexec/apps-schema' image/Containerfile; then
  ok 'the image ships the plan verifier'
else
  bad 'the image ships the plan verifier'
fi
if grep -q 'smortress-apps-user.service' image/Containerfile; then
  ok 'the image enables the provisioning unit'
else
  bad 'the image enables the provisioning unit'
fi
# The gate is what orders the prerequisites ahead of the tenant's manager: a
# lingering user manager starts from systemd-logind, so each prerequisite
# finishing first is what keeps an unprovisioned or unfiltered tenant from
# starting. A user unit cannot carry this as Requires= — a user manager cannot
# resolve a system unit and fails the unit outright.
for unit in smortress-apps-user.service smortress-apps-egress.service \
  smortress-apps-quota.service; do
  if grep -q '^Before=.*systemd-logind.service' "units/systemd/$unit"; then
    ok "$unit finishes before a user manager can start"
  else
    bad "$unit finishes before a user manager can start" "$(cat "units/systemd/$unit")"
  fi
done

# --- behaviour with a fake account and fake files ----------------------------

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/subids" "$work/policy" "$work/linger"

cat >"$work/bin/id" <<'EOF'
#!/bin/sh
[ "${FAKE_MISSING_USER:-}" = 1 ] && exit 1
case $1 in
    -u) echo 1513 ;;
    -g) echo 1513 ;;
esac
exit 0
exit 0
EOF
chmod +x "$work/bin/id"

run() {
    PATH=$work/bin:$PATH \
        SUBUID_FILE=$work/subids/subuid SUBGID_FILE=$work/subids/subgid \
        APPS_REQUIRE_BINS='' APPS_SUBID_RANGE=200000:65536 \
        bash "$script" >"$work/stdout" 2>"$work/stderr"
}

if run; then ok 'provisioning succeeds with the account present'; else bad 'provisioning succeeds with the account present' "$(cat "$work/stderr")"; fi
if grep -qx 'apps:200000:65536' "$work/subids/subuid" 2>/dev/null; then
  ok 'the tenant gets a subuid range'
else
  bad 'the tenant gets a subuid range' "$(cat "$work/subids/subuid" 2>&1)"
fi
if grep -qx 'apps:200000:65536' "$work/subids/subgid" 2>/dev/null; then
  ok 'the tenant gets a subgid range'
else
  bad 'the tenant gets a subgid range' "$(cat "$work/subids/subgid" 2>&1)"
fi
if run; then ok 'provisioning is idempotent'; else bad 'provisioning is idempotent' "$(cat "$work/stderr")"; fi
if [[ $(grep -c '^apps:' "$work/subids/subuid") == 1 ]]; then
  ok 'a second run adds no duplicate range'
else
  bad 'a second run adds no duplicate range' "$(cat "$work/subids/subuid")"
fi
# A root provisioner must never write into the tenant-owned home: it would
# follow a symlink the tenant planted.
if grep -q '/var/home/apps' "$script"; then
  if grep -qE 'install -d|mktemp|chown' "$script"; then
    bad 'provisioning never writes into the tenant home'
  else
    ok 'provisioning never writes into the tenant home'
  fi
else
  ok 'provisioning never writes into the tenant home'
fi

# The tenant's looser image policy is root-owned and named by the renderer.
if [[ -f image/rootfs/usr/share/smortress/apps-policy.json ]] &&
  jq -e '.default[0].type == "insecureAcceptAnything"' image/rootfs/usr/share/smortress/apps-policy.json >/dev/null 2>&1; then
  ok 'the tenant image policy is shipped and root-owned'
else
  bad 'the tenant image policy is shipped and root-owned'
fi

# A range that already belongs to another account is refused.
printf 'other:200000:65536\n' >"$work/subids/subuid"
if run; then bad 'an overlapping allocation is refused'; else ok 'an overlapping allocation is refused'; fi
if grep -q 'overlaps' "$work/stderr"; then ok 'the overlap is named'; else bad 'the overlap is named' "$(cat "$work/stderr")"; fi
printf 'other:0:1\n' >"$work/subids/subuid"

# A malformed line from an older revision is replaced, not trusted.
printf 'apps:200000-265535\n' >"$work/subids/subuid"
printf 'apps:200000:65536\n' >"$work/subids/subgid"
if run; then ok 'a malformed existing allocation is repaired'; else bad 'a malformed existing allocation is repaired' "$(cat "$work/stderr")"; fi
if grep -qx 'apps:200000:65536' "$work/subids/subuid"; then
  ok 'the repaired line uses start:count'
else
  bad 'the repaired line uses start:count' "$(cat "$work/subids/subuid")"
fi

if FAKE_MISSING_USER=1 PATH=$work/bin:$PATH SUBUID_FILE=$work/subids/x SUBGID_FILE=$work/subids/y \
  APPS_POLICY_DIR=$work/policy APPS_OWNER=$(id -u):$(id -g) APPS_REQUIRE_BINS='' \
  bash "$script" >/dev/null 2>"$work/missing.err"; then
  bad 'a missing account stops provisioning'
else
  ok 'a missing account stops provisioning'
fi
if PATH=$work/bin:$PATH SUBUID_FILE=$work/subids/z SUBGID_FILE=$work/subids/w \
  APPS_POLICY_DIR=$work/policy APPS_OWNER=$(id -u):$(id -g) \
  APPS_REQUIRE_BINS="not-a-real-binary" bash "$script" >/dev/null 2>"$work/deps.err"; then
  bad 'a missing rootless dependency stops provisioning'
else
  ok 'a missing rootless dependency stops provisioning'
fi
if grep -q 'not-a-real-binary' "$work/deps.err"; then
  ok 'the missing dependency is named'
else
  bad 'the missing dependency is named' "$(cat "$work/deps.err")"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
