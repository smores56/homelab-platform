#!/usr/bin/env bash
# Offline checks for the apps tenant user (SDLC #726, T7 of #701).
#
# The tenant is one unprivileged account. This proves the account shape that
# the rest of the tenant depends on: the uid the nftables rule names, a
# login-less shell, a private home with linger, the subuid/subgid allocation
# Podman needs, a per-user policy that admits digest-pinned images, and a
# refusal to continue when a rootless dependency is missing.
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

if grep -qE '^u apps 1001:1001 "apps tenant" /var/home/apps /usr/sbin/nologin$' "$sysusers"; then
  ok 'the tenant user has the fixed uid and no login shell'
else
  bad 'the tenant user has the fixed uid and no login shell' "$(cat "$sysusers")"
fi
if grep -qE 'meta skuid 1001' "$nft"; then
  ok 'the egress rule names the same uid'
else
  bad 'the egress rule names the same uid'
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
if grep -q 'smortress-apps-user.service' image/Containerfile; then
  ok 'the image enables the provisioning unit'
else
  bad 'the image enables the provisioning unit'
fi
if grep -qE '^Before=.*smortress-apps-apply' "$unit"; then
  ok 'provisioning finishes before any tenant container starts'
else
  bad 'provisioning finishes before any tenant container starts'
fi

# --- behaviour with a fake account and fake files ----------------------------

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/subids" "$work/policy" "$work/linger"

cat >"$work/bin/id" <<'EOF'
#!/bin/sh
[ "${FAKE_MISSING_USER:-}" = 1 ] && exit 1
case $1 in
    -u) echo 1001 ;;
    -g) echo 1000 ;;
esac
exit 0
exit 0
EOF
chmod +x "$work/bin/id"

run() {
    PATH=$work/bin:$PATH \
        SUBUID_FILE=$work/subids/subuid SUBGID_FILE=$work/subids/subgid \
        APPS_POLICY_DIR=$work/policy APPS_OWNER=$(id -u):$(id -g) \
        APPS_REQUIRE_BINS='' APPS_SUBID_RANGE=200000-265535 \
        bash "$script" >"$work/stdout" 2>"$work/stderr"
}

if run; then ok 'provisioning succeeds with the account present'; else bad 'provisioning succeeds with the account present' "$(cat "$work/stderr")"; fi
if grep -qx 'apps:200000-265535' "$work/subids/subuid" 2>/dev/null; then
  ok 'the tenant gets a subuid range'
else
  bad 'the tenant gets a subuid range' "$(cat "$work/subids/subuid" 2>&1)"
fi
if grep -qx 'apps:200000-265535' "$work/subids/subgid" 2>/dev/null; then
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
if jq -e '.default[0].type == "insecureAcceptAnything"' "$work/policy/policy.json" >/dev/null 2>&1; then
  ok 'the tenant policy admits its pinned images'
else
  bad 'the tenant policy admits its pinned images' "$(cat "$work/policy/policy.json" 2>&1)"
fi
if [[ $(stat -c %a "$work/policy/policy.json" 2>/dev/null) == 600 ]]; then
  ok 'the policy is private to the tenant'
else
  bad 'the policy is private to the tenant'
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
