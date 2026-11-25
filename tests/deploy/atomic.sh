#!/usr/bin/env bash
# Offline parity check for the one durability rule behind three atomic writes
# (SDLC #812): the state library's `atomic_write`, the verifier's `write_atomic`
# and the receiver's `atomic_write`.
#
# The three are separate code because nothing shared can be installed where the
# listener and the drain both run, so the rule survives only as long as each
# copy keeps it: the target holds one whole payload (never a truncation tail), a
# replace renames a new inode over it instead of rewriting it in place, it is 0600
# whoever wrote it, no temp file outlives the call, and a directory that cannot be
# written fails the call with nothing left behind. Every case below is
# driven against each implementation from the same fixture. No root, no bootc,
# no network.
#
#   tests/deploy/atomic.sh
set -uo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root" || exit 1

lib=scripts/deploy-state.sh
verify=image/rootfs/usr/libexec/deploy-verify.py
receiver=image/rootfs/usr/libexec/deploy-receiver.py
for file in "$lib" "$verify" "$receiver"; do
  [[ -r $file ]] || {
    printf 'FAIL %s is missing\n' "$file" >&2
    exit 1
  }
done
command -v python3 >/dev/null || {
  printf 'FAIL python3 is required\n' >&2
  exit 1
}

# shellcheck source=tests/deploy/lib.sh
source "$root/tests/deploy/lib.sh"
check_same() { # target payload label
  if cmp -s "$1" "$2"; then ok "$3"; else bad "$3" "$1 differs from $(basename -- "$2")"; fi
}
strays_in() { # <dir> <target name>: everything beside the target, whatever it is called
  find "$1" -mindepth 1 -maxdepth 1 ! -name "$2" | wc -l
}
# The inode is the only thing an outside reader can see. It proves the target was
# not truncated in place: an unlink-and-create lands a fresh inode just as a
# rename does, so this assertion cannot tell a rename from a delete-then-create,
# and it does not claim to -- the rename itself is the implementation's business.
check_not_truncated_in_place() { # <path> <inode before> <label>
  local now=''
  [[ -e $1 ]] && now=$(stat -c %i -- "$1")
  if [[ -z $now ]]; then
    bad "$3" "$1 is gone"
  elif [[ $now == "$2" ]]; then
    bad "$3" "inode stayed $2: the write truncated in place instead of landing a new file"
  else
    ok "$3"
  fi
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

export DEPLOY_STATE_DIR=$work/state
export DEPLOY_LOCK_FILE=$work/deploy.lock
mkdir -p "$DEPLOY_STATE_DIR"
# shellcheck source=/dev/null
source "$lib"

# `short` is a strict prefix of `long`: an implementation that rewrites the file
# in place without truncating leaves the old tail behind and fails both the size
# and the content check.
long=$work/payload.long
short=$work/payload.short
head -c 4096 /dev/zero | tr '\0' 'x' >"$long"
head -c 24 "$long" >"$short"

label_for() { # <impl>
  case $1 in
    state) printf 'atomic_write (deploy-state.sh)' ;;
    verify) printf 'write_atomic (deploy-verify.py)' ;;
    receiver) printf 'atomic_write (deploy-receiver.py)' ;;
  esac
}

# Each implementation's own entry point, unchanged: the library reads its
# content from stdin, the two scripts take (path, bytes). The loader is the one
# tests/deploy/verify.sh and tests/deploy/receiver.sh already use.
write_with() { # <impl> <path> <payload-file>
  case $1 in
    state) atomic_write "$2" <"$3" ;;
    verify | receiver)
      python3 - "$1" "$2" "$3" <<'PY'
import importlib.util
import sys

impl, path, payload = sys.argv[1], sys.argv[2], sys.argv[3]
name = "deploy_verify" if impl == "verify" else "deploy_receiver"
spec = importlib.util.spec_from_file_location(name, f"image/rootfs/usr/libexec/deploy-{impl}.py")
module = importlib.util.module_from_spec(spec)
sys.modules[name] = module
spec.loader.exec_module(module)
with open(payload, "rb") as handle:
    data = handle.read()
(module.write_atomic if impl == "verify" else module.atomic_write)(path, data)
PY
      ;;
  esac
}

for impl in state verify receiver; do
  who=$(label_for "$impl")
  dir=$work/$impl
  mkdir -p "$dir"
  chmod 0700 "$dir"
  target=$dir/state.json

  # --- a fresh write ---------------------------------------------------------
  if write_with "$impl" "$target" "$long"; then
    ok "$who writes the record"
  else
    bad "$who writes the record"
  fi
  check_same "$target" "$long" "$who writes exactly the payload"
  check_eq "$(stat -c %s "$target")" 4096 "$who writes the whole payload"
  check_eq "$(stat -c %a "$target")" 600 "$who writes the record 0600"
  check_eq "$(strays_in "$dir" state.json)" 0 "$who leaves no temp file"

  # --- replacing a longer payload over a wider-mode file ---------------------
  # The previous record is both longer and more readable than the new one, so
  # this is the case where a rename would keep the old tail or the old mode.
  chmod 0664 "$target"
  # A new inode means the old file was never written through; rewriting it in
  # place keeps the inode, which is exactly the non-atomic write this test exists
  # to reject.
  ino_before=$(stat -c %i -- "$target")
  if write_with "$impl" "$target" "$short"; then
    ok "$who replaces an existing record"
  else
    bad "$who replaces an existing record"
  fi
  check_same "$target" "$short" "$who keeps exactly the new payload"
  check_eq "$(stat -c %s "$target")" 24 "$who leaves no tail from the longer payload"
  check_eq "$(stat -c %a "$target")" 600 "$who replaces the mode with 0600"
  check_not_truncated_in_place "$target" "$ino_before" "$who does not truncate the record in place"
  check_eq "$(strays_in "$dir" state.json)" 0 "$who leaves no temp file after a replace"

  # --- a directory that cannot be written ------------------------------------
  # The mktemp/open of the temp file is the first write, so this fails before
  # the rename: no partial target, and nothing to clean up afterwards.
  locked=$dir/locked
  mkdir -p "$locked"
  chmod 0500 "$locked"
  # The probe, not `EUID -eq 0`: root, a uid holding CAP_DAC_OVERRIDE and some
  # overlay/9p mounts all keep writing through 0500, and failing such a host
  # would report a hole in the implementation that is really in the filesystem.
  if [[ -w $locked ]]; then
    ok "$who fails on an unwritable directory (skipped: this filesystem does not enforce the mode)"
  elif write_with "$impl" "$locked/state.json" "$short" 2>/dev/null; then
    bad "$who fails on an unwritable directory" "the write reported success"
  else
    ok "$who fails on an unwritable directory"
    check_eq "$(strays_in "$locked" state.json)" 0 \
      "$who leaves no temp file and no partial record behind"
  fi
  chmod 0700 "$locked"
done

finish
