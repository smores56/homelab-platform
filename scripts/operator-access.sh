#!/usr/bin/env bash
# Give the human operator access to a two-writer dataset.
#
# The applications write as numeric uid/gid 1000 and the operator is an account
# whose number differs between hosts. A core dataset is owned 1000:1000 and
# 0750, so the person who restored a tree cannot read their own notes. The grant
# is a POSIX ACL rather than a chown: the container keeps its ownership, and the
# default entries make the grant outlive the restore for everything created
# later. Without them a file the operator creates is smores:smores 0644, which
# the uid-1000 writer can read but cannot rename or rewrite.
#
# Restic does not preserve POSIX ACLs, so every restore silently drops the
# grant: run this after a production restore of a two-writer dataset. The drill
# targets under /var/lib/restic/hdd/drill and /var/tmp/drill-pg are scratch and
# stay 1000:1000; this refuses them because neither is a mountpoint.
#
#   operator-access <mountpoint>          apply, printing what changed
#   operator-access --check <mountpoint>  report drift, change nothing
set -euo pipefail

operator=${OPERATOR_ACCOUNT:-smores}
setfacl_bin=${SETFACL:-setfacl}
getfacl_bin=${GETFACL:-getfacl}
getent_bin=${GETENT:-getent}
find_bin=${FIND:-find}
mountinfo=${OPERATOR_ACCESS_MOUNTINFO:-/proc/self/mountinfo}

usage() { echo "usage: operator-access [--check] <mountpoint>" >&2; }
fail() {
  echo "operator-access: $*" >&2
  exit 1
}

check=false
paths=()
for arg in "$@"; do
  case $arg in
    --check) check=true ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      usage
      exit 2
      ;;
    *) paths+=("$arg") ;;
  esac
done
if ((${#paths[@]} != 1)); then
  usage
  exit 2
fi
path=${paths[0]}

# The operator is an account, not a uid: a hardcoded number grants the wrong
# person on the next install, and an account that does not resolve is a
# misspelt name rather than a reason to fall back.
if ! entry=$("$getent_bin" passwd "$operator" 2>/dev/null) || [[ -z $entry ]]; then
  fail "no such account: $operator"
fi
operator_name=${entry%%:*}
operator_uid=$(cut -d: -f3 <<<"$entry")
[[ $operator_uid =~ ^[0-9]+$ ]] || fail "$operator resolves to no numeric uid: $entry"

[[ -d $path ]] || fail "$path is not a directory"
path=$(realpath -- "$path")
[[ -r $mountinfo ]] || fail "cannot read $mountinfo"
# A directory that merely exists is how a restore would land on the root
# filesystem; field 5 is the mount point, compared exactly, the same test
# zfs-ready and restic-plane-common make.
if ! awk -v p="$path" '$5 == p { found = 1 } END { exit !found }' "$mountinfo"; then
  fail "$path is not a mountpoint; a restore lands under one, and a bare directory grants access to the wrong tree"
fi

# `rwX` keeps execute to what the tree already has, so a restored notes tree
# does not become executable and its scripts stay runnable. uid/gid 1000 is
# named explicitly because a restore can leave an inode owned root:root, and the
# container's write path must not depend on the owner entry. group:: and other::
# are closed, with the mask open so only the two named grants are effective.
access_spec="u:$operator_name:rwX,u:1000:rwX,g:1000:rwX,g::---,m::rwx,o::---"
default_spec="d:u:$operator_name:rwX,d:u:1000:rwX,d:g:1000:rwX,d:g::---,d:m::rwx,d:o::---"

# One listing serves both questions: access entries are unprefixed, default
# entries carry `default:`. Numeric ids keep the comparison independent of NSS.
listing() { "$getfacl_bin" -R -npE -- "$1" 2>/dev/null; }

# Paths whose access ACL does not reach the grant. `rwX` is compared as `rw`:
# whether an entry carries execute follows the file's own mode, not the grant.
missing_access() { # path
  listing "$1" | awk -v op="$operator_uid" '
    # A key is everything before the permissions, so a base entry keeps its
    # trailing colon ("group:") and a named one carries the id ("user:1000").
    function deficient() {
      return (e["user:" op] !~ /^rw/ || e["user:1000"] !~ /^rw/ || e["group:1000"] !~ /^rw/ ||
        e["group:"] != "---" || e["mask:"] != "rwx" || e["other:"] != "---")
    }
    $1 == "#" {
      if ($2 == "file:") {
        if (file != "" && deficient()) print file
        file = substr($0, 9)
        split("", e)
      }
      next
    }
    /^default:/ { next }
    {
      n = split($0, f, ":")
      key = f[1]
      for (i = 2; i < n; i++) key = key ":" f[i]
      e[key] = f[n]
    }
    END { if (file != "" && deficient()) print file }'
}

# Directories a default ACL does not reach. getfacl prints default entries only
# for directories that have some, so a restored directory — none at all — is
# indistinguishable from a file there: the directory set and the complete
# default set are compared instead.
missing_defaults() { # path
  comm -23 \
    <("$find_bin" "$1" -xdev -type d -print | LC_ALL=C sort) \
    <(listing "$1" | awk -v op="$operator_uid" '
      function complete() {
        return (d["user:" op] ~ /^rw/ && d["user:1000"] ~ /^rw/ && d["group:1000"] ~ /^rw/ &&
          d["group:"] == "---" && d["mask:"] == "rwx" && d["other:"] == "---")
      }
      $1 == "#" {
        if ($2 == "file:") {
          if (file != "" && complete()) print file
          file = substr($0, 9)
          split("", d)
        }
        next
      }
      /^default:/ {
        sub(/^default:/, "")
        n = split($0, f, ":")
        key = f[1]
        for (i = 2; i < n; i++) key = key ":" f[i]
        d[key] = f[n]
      }
      END { if (file != "" && complete()) print file }' | LC_ALL=C sort)
}

# One line per path, not one per missing half: a restored tree is missing both,
# and a count that double-counts it would not be a path count.
drift=$({
  missing_access "$path"
  missing_defaults "$path"
} | LC_ALL=C sort -u)

if [[ -z $drift ]]; then
  echo "operator-access: $path already grants $operator_name (uid $operator_uid) rwX"
  exit 0
fi
count=$(printf '%s\n' "$drift" | wc -l)

if [[ $check == true ]]; then
  echo "operator-access: $path: $count paths lack the grant" >&2
  printf '%s\n' "$drift" | sed -n '1,20p' | sed 's/^/  /' >&2
  if ((count > 20)); then echo "  ..." >&2; fi
  echo "operator-access: rerun without --check to grant $operator_name rwX" >&2
  exit 1
fi

"$setfacl_bin" -R -m "$access_spec" -- "$path" || fail "setfacl failed on $path"
"$setfacl_bin" -R -m "$default_spec" -- "$path" || fail "setfacl failed on $path"
echo "operator-access: $path: set access  $access_spec"
echo "operator-access: $path: set default $default_spec"
echo "operator-access: granted $operator_name (uid $operator_uid) rwX on $count paths under $path"
