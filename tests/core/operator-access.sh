#!/usr/bin/env bash
# Offline checks for scripts/operator-access.sh.
#
# The host half — a real dataset owned 1000:1000 and the real operator account —
# is section 40.6 of docs/manual-steps.md. This proves the half that does not
# need root or a real dataset: the account is resolved instead of assumed, the
# ACL specification carries the operator's name and numeric 1000 in both the
# access and the default entries, --check writes nothing, a path that is not a
# mountpoint is refused, and an account that does not exist is louder than a
# grant to the wrong uid.
#
#   tests/core/operator-access.sh
set -uo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root" || exit 1

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
eq() {
  if [[ $1 == "$2" ]]; then ok "$3"; else bad "$3" "got '$1' want '$2'"; fi
}

script=scripts/operator-access.sh
if [[ -x $script ]]; then ok 'operator-access is executable'; else bad 'operator-access is executable'; fi
if bash -n "$script" 2>/dev/null; then ok 'operator-access parses'; else bad 'operator-access parses'; fi

trap 'rm -rf "${tmp:-}"' EXIT
tmp=$(mktemp -d)
mkdir -p "$tmp/bin" "$tmp/mnt/sub"
: >"$tmp/mnt/notes.md"
: >"$tmp/mnt/sub/a.txt"
mnt=$(realpath "$tmp/mnt")

# A mountinfo the script can be pointed at: field 5 is the mount point, exactly
# the comparison zfs-ready and restic-plane-common make. The scratch tree is not
# a mount, and the script must not need one to prove its own behaviour.
printf '%s\n' '36 25 0:32 / / rw,relatime - ext4 /dev/sda1 rw' \
  "77 25 0:50 / $mnt rw,relatime shared:9 - zfs smortress/raw/files rw,xattr,posixacl" \
  >"$tmp/mountinfo"
printf '%s\n' '36 25 0:32 / / rw,relatime - ext4 /dev/sda1 rw' >"$tmp/mountinfo-root"

# The account exists in no fixture: getent is stubbed so the checks do not
# depend on the host's NSS, and a uid that is nobody's on the host proves the
# number is resolved rather than written into the script.
cat >"$tmp/bin/getent" <<'SH'
#!/bin/sh
printf 'getent %s\n' "$*" >>"$STUB_LOG"
if [ "$1" != passwd ] || [ "${GETENT_UID:-}" = none ]; then exit 2; fi
printf '%s:x:%s:%s::/home/%s:/usr/bin/bash\n' "$2" "$GETENT_UID" "$GETENT_UID" "$2"
SH
cat >"$tmp/bin/setfacl" <<'SH'
#!/bin/sh
printf 'setfacl %s\n' "$*" >>"$STUB_LOG"
exit 0
SH
cat >"$tmp/bin/getfacl" <<'SH'
#!/bin/sh
printf 'getfacl %s\n' "$*" >>"$STUB_LOG"
cat "${GETFACL_OUT:-/dev/null}"
SH
chmod 0755 "$tmp/bin"/*

# What getfacl prints for a tree that already carries the grant, one block per
# path, directories with their default entries. The uid is the one the getent
# stub resolves, so a drift check that ignored the resolved account would call
# this tree granted.
granted_access='user::rwx
user:4242:rwx
user:1000:rwx
group::---
group:1000:rwx
mask::rwx
other::---'
granted_default='default:user::rwx
default:user:4242:rwx
default:user:1000:rwx
default:group::---
default:group:1000:rwx
default:mask::rwx
default:other::---'
: >"$tmp/granted"
for p in "$mnt" "$mnt/sub"; do
  printf '# file: %s\n%s\n%s\n' "$p" "$granted_access" "$granted_default" >>"$tmp/granted"
done
for p in "$mnt/notes.md" "$mnt/sub/a.txt"; do
  printf '# file: %s\n%s\n' "$p" "$granted_access" >>"$tmp/granted"
done

getent_uid=4242
operator_account=smores
getfacl_out=/dev/null

# drive <log> <mountinfo> <script args...>: runs the script with the stubs on
# PATH, leaving its output in `out` and its status in `rc`.
drive() {
  local log=$1 info=$2
  shift 2
  : >"$log"
  out=$(env PATH="$tmp/bin:$PATH" STUB_LOG="$log" GETENT_UID="$getent_uid" \
    OPERATOR_ACCOUNT="$operator_account" OPERATOR_ACCESS_MOUNTINFO="$info" \
    GETFACL_OUT="$getfacl_out" \
    "$script" "$@" 2>&1)
  rc=$?
}

# An ungranted tree is what a restore leaves: restic does not carry POSIX ACLs.
drive "$tmp/log-check" "$tmp/mountinfo" --check "$mnt"
eq "$rc" 1 '--check exits 1 on a tree with no grant'
eq "$(grep -c '^setfacl' "$tmp/log-check" || true)" 0 '--check calls no setfacl'
case $out in
  *'lack the grant'*) ok '--check names the paths that lack the grant' ;;
  *) bad '--check names the paths that lack the grant' "$out" ;;
esac

drive "$tmp/log-apply" "$tmp/mountinfo" "$mnt"
eq "$rc" 0 'apply exits 0 against stubs'
eq "$(sed -n 's/^setfacl -R -m \(u:.*\) -- .*/\1/p' "$tmp/log-apply")" \
  'u:smores:rwX,u:1000:rwX,g:1000:rwX,g::---,m::rwx,o::---' \
  'the access ACL names the operator and numeric 1000, and closes the rest'
eq "$(sed -n 's/^setfacl -R -m \(d:.*\) -- .*/\1/p' "$tmp/log-apply")" \
  'd:u:smores:rwX,d:u:1000:rwX,d:g:1000:rwX,d:g::---,d:m::rwx,d:o::---' \
  'the default ACL carries the same grant for content created later'
case $out in
  *'uid 4242'*) ok 'the uid in the report is the one NSS resolved' ;;
  *) bad 'the uid in the report is the one NSS resolved' "$out" ;;
esac

# A different account must reach the grant by its own name: a hardcoded smores
# would grant the wrong person after a rebuild.
operator_account=backup
getent_uid=4243
drive "$tmp/log-other" "$tmp/mountinfo" "$mnt"
eq "$(sed -n 's/^setfacl -R -m \(u:.*\) -- .*/\1/p' "$tmp/log-other")" \
  'u:backup:rwX,u:1000:rwX,g:1000:rwX,g::---,m::rwx,o::---' \
  'the grant follows the resolved account, not a hardcoded name'
operator_account=smores
getent_uid=4242

# --check on a granted tree reports and writes nothing.
getfacl_out=$tmp/granted
drive "$tmp/log-clean" "$tmp/mountinfo" --check "$mnt"
eq "$rc" 0 '--check exits 0 on a granted tree'
eq "$(grep -c '^setfacl' "$tmp/log-clean" || true)" 0 '--check on a granted tree calls no setfacl'
getfacl_out=/dev/null

# A directory on the root filesystem is a bug, not a target: a restore lands
# under a mountpoint.
drive "$tmp/log-nomount" "$tmp/mountinfo-root" "$mnt"
eq "$rc" 1 'a path that is not a mountpoint is refused'
eq "$(grep -c '^setfacl' "$tmp/log-nomount" || true)" 0 'the refusal happens before any write'
case $out in
  *'not a mountpoint'*) ok 'the refusal says why' ;;
  *) bad 'the refusal says why' "$out" ;;
esac

# An account that does not exist must fail, never fall back to a uid.
getent_uid=none
drive "$tmp/log-noaccount" "$tmp/mountinfo" "$mnt"
eq "$rc" 1 'a missing operator account is fatal'
eq "$(grep -c '^setfacl' "$tmp/log-noaccount" || true)" 0 'a missing account grants nothing'
case $out in
  *'no such account: smores'*) ok 'the missing account is named' ;;
  *) bad 'the missing account is named' "$out" ;;
esac
getent_uid=4242

# Argument handling, the way the other core suites check it.
drive "$tmp/log-flag" "$tmp/mountinfo" --nonsense
eq "$rc" 2 'an unknown flag is refused'
drive "$tmp/log-bare" "$tmp/mountinfo"
eq "$rc" 2 'a missing path is refused'
drive "$tmp/log-help" "$tmp/mountinfo" --help
eq "$rc" 0 '--help succeeds'

printf '\n%s checks, %s failed\n' "$((pass + fail))" "$fail"
((fail == 0))
