#!/usr/bin/env bash
# Prove a converted suite kept its assertions: run the shell suite as it is on a
# base ref and the bats file that replaced it, and compare the passing counts.
#
# usage: tests/parity.sh tests/core/storage-layout [<base>]
#
# The old suite is read from the base ref, so this works after it is deleted
# from the tree. Exit codes, counts and the assertion texts are compared: the
# shell suite prints `ok   <text>` and bats prints `ok <n> <text>`, so names are
# normalized before the diff, which catches a dropped check replaced by a
# duplicate in another test.
#
# A conversion aid for #907; it stops being useful once the last shell suite is
# gone (#931 deletes it with check-all.sh).
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

name=${1:?usage: tests/parity.sh <suite path without extension> [<base>]}
base=${2:-origin/main}
old=$name.sh
new=$name.bats

[[ -f $new ]] || {
  printf 'parity: %s is not in the tree\n' "$new" >&2
  exit 2
}
git cat-file -e "$base:$old" 2>/dev/null || {
  printf 'parity: %s has no %s\n' "$base" "$old" >&2
  exit 2
}

work=$(mktemp -d)
trap 'rm -rf "$work"; git worktree remove --force "$work/tree" 2>/dev/null' EXIT

# The old suite checks the tree it shipped with, and some of its assertions look
# at sibling files, so it runs in a checkout of the base rather than in the tree
# the conversion already changed.
git worktree add -q --detach "$work/tree" "$base"
old_rc=0 new_rc=0
(cd "$work/tree" && bash "$old") >"$work/old.log" 2>&1 || old_rc=$?
bats "$new" >"$work/new.log" 2>&1 || new_rc=$?
names() {  # names <log>: the assertion texts, without the runner's prefix
  grep '^ok' "$1" | sed -E 's/^ok +([0-9]+ +)?//' | sort
}
old_ok=$(names "$work/old.log" | wc -l)
new_ok=$(names "$work/new.log" | wc -l)
diff -u <(names "$work/old.log") <(names "$work/new.log") >"$work/names.diff" || true

printf 'parity: %s shell %s ok (exit %s), bats %s ok (exit %s)\n' \
  "$name" "$old_ok" "$old_rc" "$new_ok" "$new_rc"

if [[ $old_rc -ne 0 || $new_rc -ne 0 || $old_ok -ne $new_ok || -s $work/names.diff ]]; then
  cat "$work/names.diff" >&2
  printf 'parity: MISMATCH; logs follow\n' >&2
  printf -- '--- %s ---\n' "$old" >&2
  cat "$work/old.log" >&2
  printf -- '--- %s ---\n' "$new" >&2
  cat "$work/new.log" >&2
  exit 1
fi
