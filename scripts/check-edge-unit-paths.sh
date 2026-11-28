#!/usr/bin/env bash
# Hold bootc/edge/unit-paths.tsv and the edge's units to each other.
#
# Four units on the from-scratch install of the edge assumed state the retired
# hand bootstrap had made on the old VPS, and each
# was patched on the console after it happened. The worst was /var/lib/caddy:
# without it Caddy starts, fails every ACME order with `mkdir /var/lib/caddy:
# permission denied`, and answers 500 on all three names. The quietest was
# /var/lib/smoresnet: edge-boot-gate.service names it in ReadWritePaths, so its
# namespace setup failed with 226/NAMESPACE before the gate's own program ran,
# and the unit that creates the directory starts later. Neither is visible until
# a boot does it, and nobody is watching the boot after an install -- a
# ReadWritePaths target is not a thing a reviewer can see is missing.
#
# Nothing in the image said which paths the units needed or who made them, so
# nothing could fail before a boot did.
#
# bootc/edge/unit-paths.tsv is that statement -- one row per path, with what
# creates it -- and this checker fails when a path the units name has no row,
# when a row no unit names is left behind, or when a row's claim is not true of
# the tree it can see:
#
#   image-dir  the directory is in bootc/edge/rootfs/ itself
#   tmpfiles   a fragment under etc/tmpfiles.d or usr/lib/tmpfiles.d creates it
#   bootstrap  scripts/edge-bootstrap.sh creates it with install -d / mkdir -p
#   operator   a person makes it before the box is useful, and the row's reason
#              names the step in docs/manual-steps.md
#   system     the OS owns it, so nothing has to create it
#
#   scripts/check-edge-unit-paths.sh
#
# Exit 0 when every claim holds; otherwise one `FAIL <path>: <why>` line per
# problem and `N paths, N problems`, in the style of scripts/verify-fleet.sh.
#
# DirectoryNotEmpty is read along with the path keys systemd derives directories
# from (ReadWritePaths, StateDirectory, CacheDirectory, LogsDirectory,
# LoadCredential, EnvironmentFile, WorkingDirectory): the queue that unit watches
# is state like any other, and a queue with the wrong mode is the same bug.
set -uo pipefail

repo=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
rootfs=$repo/bootc/edge/rootfs
units=$rootfs/usr/lib/systemd/system
tsv=$repo/bootc/edge/unit-paths.tsv
bootstrap=$repo/scripts/edge-bootstrap.sh
steps=$repo/docs/manual-steps.md
# A unit may name a path with systemd's `-` prefix, meaning "ignore it if it is
# missing". The prefix is not part of the path, so it is stripped here and the
# row's reason says the path is optional instead.
path_keys='ReadWritePaths|StateDirectory|CacheDirectory|LogsDirectory|LoadCredential|EnvironmentFile|WorkingDirectory|DirectoryNotEmpty'

for required in "$units" "$tsv" "$bootstrap" "$steps"; do
  if [[ ! -e $required ]]; then
    printf 'check-edge-unit-paths: no such path: %s\n' "$required" >&2
    exit 2
  fi
done

problems=0
fail() {
  printf 'FAIL %s: %s\n' "$1" "$2"
  problems=$((problems + 1))
}

# unit_paths: every path the units and their drop-ins name, one per line.
unit_paths() {
  local file line key value word
  while IFS= read -r file; do
    while IFS= read -r line; do
      [[ $line =~ ^($path_keys)=(.*)$ ]] || continue
      key=${BASH_REMATCH[1]}
      value=${BASH_REMATCH[2]}
      # systemd takes a space-separated list for all of these.
      # shellcheck disable=SC2086 # word splitting is the assignment's own
      for word in $value; do
        # LoadCredential=<id>:<path>; a bare id names a tmpfs file, not a path.
        if [[ $key == LoadCredential ]]; then word=${word#*:}; fi
        word=${word#-}
        [[ $word == /* ]] || continue
        printf '%s\n' "${word%/}"
      done
    done <"$file"
  done < <(find "$units" -type f \
    \( -name '*.service' -o -name '*.path' -o -name '*.timer' -o -name '*.socket' \
    -o -name '*.mount' -o -name '*.target' -o -name '*.conf' \) | sort)
}

# tmpfiles_creates <path>: a shipped fragment makes it. Only the line types that
# create count -- z/Z/r adjust or remove a path something else has to make.
tmpfiles_creates() {
  local fragment
  for fragment in "$rootfs"/etc/tmpfiles.d/*.conf "$rootfs"/usr/lib/tmpfiles.d/*.conf; do
    [[ -f $fragment ]] || continue
    if awk -v want="$1" '
      /^[[:space:]]*#/ { next }
      $1 ~ /^[dDvqQpLcbC]$/ && $2 == want { found = 1; exit }
      END { exit(found ? 0 : 1) }
    ' "$fragment"; then
      return 0
    fi
  done
  return 1
}

# bootstrap_dirs: the directories edge-bootstrap.sh creates, resolved through the
# variable each one is passed as. Matching the variable and not the string is
# what keeps a path the script only explains in a comment ("/var/lib/caddy,
# which the package expects to exist") from counting as a creator.
bootstrap_dirs() {
  local line name value dir arg
  local i
  local -a argv
  local -A assigned=()
  while IFS= read -r line; do
    [[ $line =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    name=${BASH_REMATCH[1]}
    value=${BASH_REMATCH[2]}
    if [[ $value =~ ^\$\{[A-Za-z_][A-Za-z0-9_]*:?-([^}]*)\}$ ]]; then
      assigned[$name]=${BASH_REMATCH[1]}
    elif [[ $value == /* ]]; then
      assigned[$name]=$value
    fi
  done <"$bootstrap"
  while IFS= read -r line; do
    [[ $line =~ ^[[:space:]]*(install[[:space:]]+-d|mkdir[[:space:]]+-p)([[:space:]].*)?$ ]] || continue
    argv=()
    read -ra argv <<<"${BASH_REMATCH[2]}"
    i=0
    while ((i < ${#argv[@]})); do
      arg=${argv[i]}
      case $arg in
        -o | --owner | -g | --group | -m | --mode | -Z | --context) ((i += 2)) ;;
        -*) ((i += 1)) ;;
        *)
          dir=${arg//\"/}
          dir=${dir//\'/}
          if [[ $dir =~ ^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$ ]]; then
            dir=${assigned[${BASH_REMATCH[1]}]:-}
          fi
          if [[ $dir == /* ]]; then printf '%s\n' "${dir%/}"; fi
          ((i += 1))
          ;;
      esac
    done
  done <"$bootstrap"
}

# doc_anchor_exists <anchor>: the operator row's reason names a manual step, and
# a renamed heading must fail here rather than send an operator to a dead link.
doc_anchor_exists() {
  local anchor=$1 heading slug
  while IFS= read -r heading; do
    [[ $heading =~ ^#+[[:space:]]+(.*)$ ]] || continue
    slug=${BASH_REMATCH[1]}
    slug=${slug,,}
    slug=${slug//[^a-z0-9 ]/}
    slug=${slug// /-}
    if [[ $slug == "$anchor" ]]; then return 0; fi
  done < <(grep -E '^#{1,6}[[:space:]]' "$steps")
  return 1
}

declare -A claim_of=() reason_of=()
lineno=0
while IFS=$'\t' read -r path claim reason extra || [[ -n ${path:-} ]]; do
  lineno=$((lineno + 1))
  case $path in '' | '#'*) continue ;; esac
  if [[ -n ${claim_of[$path]:-} ]]; then
    fail "$path" "two rows, the second at line $lineno"
    continue
  fi
  claim_of[$path]=$claim
  reason_of[$path]=$reason
  if [[ -n ${extra:-} ]]; then
    fail "$path" "line $lineno has a fourth field: a reason holds no tabs"
  fi
done <"$tsv"

mapfile -t named < <(unit_paths | sort -u)

# claim_denied <path> <created_by>: prints why the claim is not true of the tree,
# or nothing when it holds. `operator` and `system` are the two a tree cannot
# prove, so they are held to what can be read: the manual step exists, and the
# row says something.
claim_denied() {
  local path=$1 claim=$2 reason=$3
  case $claim in
    image-dir)
      [[ -d $rootfs$path ]] && return 0
      printf 'bootc/edge/rootfs%s is not a directory' "$path"
      ;;
    tmpfiles)
      tmpfiles_creates "$path" && return 0
      printf 'no tmpfiles.d fragment creates it'
      ;;
    bootstrap)
      case $'\n'$created_dirs$'\n' in
        *$'\n'"$path"$'\n'*) return 0 ;;
      esac
      printf 'scripts/edge-bootstrap.sh installs no directory there'
      ;;
    operator)
      if [[ $reason =~ docs/manual-steps\.md#([a-z0-9-]+) ]]; then
        doc_anchor_exists "${BASH_REMATCH[1]}" && return 0
        printf 'docs/manual-steps.md has no heading for #%s' "${BASH_REMATCH[1]}"
      else
        printf 'an operator row names its step as docs/manual-steps.md#<anchor>'
      fi
      ;;
    system) return 0 ;;
    *)
      printf 'created_by=%s is not image-dir, tmpfiles, bootstrap, operator or system' "$claim"
      ;;
  esac
  return 0
}

created_dirs=$(bootstrap_dirs)
for path in "${named[@]}"; do
  if [[ -z ${claim_of[$path]:-} ]]; then
    fail "$path" 'no row in bootc/edge/unit-paths.tsv'
    continue
  fi
  reason=${reason_of[$path]:-}
  if [[ -z $reason ]]; then
    fail "$path" 'the row has no reason'
    continue
  fi
  denied=$(claim_denied "$path" "${claim_of[$path]}" "$reason")
  if [[ -n $denied ]]; then
    fail "$path" "$denied"
  else
    printf 'ok   %s (%s)\n' "$path" "${claim_of[$path]}"
  fi
done

for path in "${!claim_of[@]}"; do
  if [[ " ${named[*]} " != *" $path "* ]]; then
    fail "$path" 'the row is unused: no unit names the path'
  fi
done

printf '\n%d paths, %d problems\n' "${#named[@]}" "$problems"
((problems == 0))
