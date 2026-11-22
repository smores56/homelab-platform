#!/usr/bin/env bash
# Offline checks for the restore-drill guardrails (SDLC #706, T3).
#
# A drill streams a whole unit into one directory. The root filesystem is 100
# GiB and `photos` restores 116 GiB, so a drill there can only end in ENOSPC.
# The drill now picks a data disk by default and refuses a target without room
# before writing anything; these prove both, with a fake restic and a fake df.
#
#   tests/core/restic-drill.sh
set -uo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root" || exit 1

script=scripts/smortress-restic-restore-drill.sh
[[ -r $script ]] || {
  printf 'FAIL %s is missing\n' "$script" >&2
  exit 1
}

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

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/secrets" "$work/cache" "$work/drill_root" "$work/tar"
: >"$work/secrets/restic-password.yaml"
: >"$work/log"

# A one-file tar stands in for the restored tree.
printf 'known\n' >"$work/tar/known.txt"
tar -cf "$work/payload.tar" -C "$work/tar" known.txt

cat >"$work/bin/restic" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_LOG"
case $1 in
    -r) shift 2 ;;
esac
case $1 in
    snapshots)
        printf '[{"id":"snap0001","time":"2026-01-01T00:00:00Z","hostname":"smortress","tags":["unit:books","host:smortress","verified"],"paths":[]}]\n' ;;
    stats)
        printf '{"total_size":%s,"total_file_count":1}\n' "${FAKE_RESTORE_SIZE:-1000}" ;;
    dump)
        cat "$FAKE_PAYLOAD" ;;
    restore)
        target=""
        while [ $# -gt 1 ]; do
            case $1 in
                --target) target=$2; shift 2 ;;
                *) shift ;;
            esac
        done
        [ -n "$target" ] || { echo "fake restic: restore without --target" >&2; exit 2; }
        printf 'known\n' >"$target/known.txt" ;;
    *) printf 'fake restic: unexpected command: %s\n' "$*" >&2; exit 2 ;;
esac
EOF
chmod +x "$work/bin/restic"

# df reports 1K blocks in field 4 of the second line, like df -Pk.
cat >"$work/bin/df" <<'EOF'
#!/usr/bin/env bash
cat <<LINE
Filesystem 1024-blocks Used Available Capacity Mounted on
fake ${FAKE_DF_BLOCKS:-100000000} 0 ${FAKE_DF_BLOCKS:-100000000} 1% /
LINE
EOF
chmod +x "$work/bin/df"

run() {
    PATH=$work/bin:$PATH \
        RESTIC_BIN=$work/bin/restic \
        RESTIC_BASE=$work/restic \
        RESTIC_STATE_ROOT=$work/state \
        RESTIC_CACHE_DIR=$work/cache \
        SMORTRESS_SECRETS_DIR=$work/secrets \
        RESTIC_DRILL_ROOT=$work/drill_root \
        FAKE_LOG=$work/log FAKE_PAYLOAD=$work/payload.tar \
        FAKE_DF_BLOCKS=${FAKE_DF_BLOCKS:-100000000} \
        FAKE_RESTORE_SIZE=${FAKE_RESTORE_SIZE:-1000} \
        bash "$script" "$@" >"$work/stdout" 2>"$work/stderr"
}

default_target() {
    find "$work/drill_root" -mindepth 1 -maxdepth 1 -type d -name 'ssd-books-*' -print -quit
}

# --- the default target is a data disk, not /var/tmp ------------------------

if run ssd books; then ok 'a drill with room succeeds'; else bad 'a drill with room succeeds' "$(cat "$work/stderr")"; fi
target=$(default_target)
case $target in
    "$work/drill_root"/ssd-books-*) ok 'the default target lives under the drill root' ;;
    *) bad 'the default target lives under the drill root' "got '$target'" ;;
esac
if [[ -f $target/known.txt ]]; then
    ok 'the restored content lands in the target'
else
    bad 'the restored content lands in the target' "$(ls -A "$target" 2>&1)"
fi

# --- the default method is restore; dump stays behind an override -------------

if grep -qE ' restore .*--target' "$work/log"; then
    ok 'a drill restores through restic restore'
else
    bad 'a drill restores through restic restore' "$(cat "$work/log")"
fi

: >"$work/log"
rm -rf "$work/drill_root"/* 2>/dev/null || true
if RESTIC_DRILL_METHOD=dump run ssd books; then
    ok 'RESTIC_DRILL_METHOD=dump still drills through dump and tar'
else
    bad 'RESTIC_DRILL_METHOD=dump still drills through dump and tar' "$(cat "$work/stderr")"
fi
if grep -q ' dump ' "$work/log"; then
    ok 'the override reaches restic'
else
    bad 'the override reaches restic' "$(cat "$work/log")"
fi

# --- a target without room is refused before writing ------------------------

: >"$work/log"
rm -rf "$work/drill_root"/* 2>/dev/null || true
# 1 GiB of free blocks and a 2 GiB restore (plus the 2 GiB margin).
if FAKE_DF_BLOCKS=1048576 FAKE_RESTORE_SIZE=$((2 * 1024 ** 3)) run ssd books; then
    bad 'a target without room is refused'
else
    ok 'a target without room is refused'
fi
if grep -q 'choose --target' "$work/stderr"; then
    ok 'the refusal names the way out'
else
    bad 'the refusal names the way out' "$(cat "$work/stderr")"
fi
if grep -qE ' (dump|restore) ' "$work/log"; then
    bad 'nothing is restored when the size does not fit' "$(cat "$work/log")"
else
    ok 'nothing is restored when the size does not fit'
fi

# --- a non-empty target is still refused ------------------------------------

mkdir -p "$work/drill_root/busy"
printf 'x\n' >"$work/drill_root/busy/keep"
if run ssd books --target "$work/drill_root/busy"; then
    bad 'a non-empty target is refused'
else
    ok 'a non-empty target is refused'
fi

# --- an unsizable snapshot is refused ---------------------------------------

if FAKE_RESTORE_SIZE=not-a-number run ssd books; then
    bad 'an unsizable snapshot is refused'
else
    ok 'an unsizable snapshot is refused'
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
