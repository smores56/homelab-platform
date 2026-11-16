#!/usr/bin/env bash
# Read-only inventory of the legacy smortress host (SDLC #703, T0 of #701).
#
# The replacement core keeps data and nothing else, so before anything is
# destroyed this has to be provable: which trees exist, who owns them, how big
# they are, and which ones a later task may call disposable.
#
# The output is markdown meant to be pasted into `docs/core/t0-gate.md` and the
# #703 issue. Run it as root on smortress:
#
#   sudo scripts/core/legacy-audit.sh --out /var/tmp/t0-audit.md
#
# It only reads: `lsblk`, `findmnt`, `stat`, `du`, `find`, `systemctl show`,
# `ssh-keygen -l` and a `journalctl` tail. Nothing here unlocks a disk, starts
# a unit, or touches a repository.
set -euo pipefail

readonly SELF=${0##*/}
readonly DATA_ROOT=/var/lib/data
readonly BACKUP_ROOT=/var/backup
readonly RETAINED_STATE=(
  /home/smores/.local/state/letta
  /home/smores/.local/state/nanobot
)

usage() {
  cat <<'EOF'
usage: legacy-audit.sh [--out FILE]

Read-only inventory of the legacy smortress host. Markdown on stdout.
  --out FILE   also write the report to FILE (mode 0400)
  -h, --help   this text
EOF
}

out=""
while (($#)); do
  case $1 in
  --out)
    out=${2:?--out needs a path}
    shift 2
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    echo "$SELF: unknown argument: $1" >&2
    usage >&2
    exit 2
    ;;
  esac
done

if ((EUID != 0)); then
  echo "$SELF: run as root; unreadable trees would silently disappear from the inventory" >&2
  exit 1
fi

section() { printf '\n## %s\n\n' "$*"; }
code() {
  printf '```text\n'
  "$@" || printf '(%s exited %s)\n' "$*" "$?"
  printf '```\n'
}

# One row per recovery candidate: path, owner:group, mode, apparent bytes,
# regular-file count and the newest mtime. `-x` keeps a mount from being walked
# twice and keeps `find` inside the tree it was pointed at.
tree_row() {
  local path=$1
  if [[ ! -e $path ]]; then
    printf '| `%s` | missing | | | |\n' "$path"
    return
  fi
  printf '| `%s` | %s %s | %s | %s | %s |\n' \
    "$path" \
    "$(stat -c '%U:%G' "$path")" "$(stat -c '%a' "$path")" \
    "$(du -sbx "$path" 2>/dev/null | cut -f1)" \
    "$(find "$path" -xdev -type f -printf '.' 2>/dev/null | wc -c)" \
    "$(find "$path" -xdev -type f -printf '%TY-%Tm-%Td\n' 2>/dev/null | sort | tail -1)"
}

tree_table() {
  local root=$1 p
  printf '| path | owner:group mode | apparent bytes | files | newest file |\n'
  printf '| --- | --- | --- | --- | --- |\n'
  for p in "$root"/*; do
    [[ -e $p ]] || continue
    tree_row "$p"
  done
}

restic_units() {
  local unit
  for unit in restic-backups-local.service restic-backups-r2.service; do
    systemctl cat "$unit" >/dev/null 2>&1 || continue
    printf '### %s\n\n' "$unit"
    code systemctl show -p ActiveState -p Result -p ExecMainStartTimestamp \
      -p ExecMainExitTimestamp -p ExecMainStatus -p Environment "$unit"
    printf '\n'
  done
}

report() {
  printf '# Legacy smortress audit\n\n'
  printf 'Generated: %s (UTC)  \n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'Host: %s  \n' "$(hostname)"
  if [[ -r /run/current-system/nixos-version ]]; then
    printf 'NixOS: %s  \n' "$(< /run/current-system/nixos-version)"
  fi
  printf 'Kernel: %s\n' "$(uname -r)"

  section "Block devices"
  code lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINT

  section "Mounts"
  code findmnt -rn -o TARGET,SOURCE,FSTYPE,OPTIONS / /boot "$DATA_ROOT" "$BACKUP_ROOT"

  section "Data trees ($DATA_ROOT)"
  printf 'Every row is a candidate recovery group; `t0-gate.md` records the\n'
  printf 'disposition of each one.\n\n'
  tree_table "$DATA_ROOT"

  section "Backup disk ($BACKUP_ROOT)"
  tree_table "$BACKUP_ROOT"

  section "Loop-backed trees"
  printf 'A whole filesystem inside one file: the file is the recovery unit.\n\n'
  printf '```text\n'
  findmnt -rn -o TARGET,SOURCE,FSTYPE | grep -F "$DATA_ROOT/" || printf '(none)\n'
  printf '```\n'

  section "Legacy restic units"
  restic_units

  section "Legacy timers"
  code systemctl list-timers --all --no-pager 'restic-*'

  section "Legacy user state"
  printf '| path | owner:group mode | apparent bytes | files | newest file |\n'
  printf '| --- | --- | --- | --- | --- |\n'
  local p
  for p in "${RETAINED_STATE[@]}"; do tree_row "$p"; done

  section "SSH host identity"
  printf 'Public fingerprints only; the private key stays where it is.\n\n'
  local k
  for k in /etc/ssh/ssh_host_ed25519_key.pub /etc/ssh/ssh_host_rsa_key.pub; do
    [[ -r $k ]] || continue
    printf -- '- `%s`: %s\n' "$k" "$(ssh-keygen -lf "$k" | cut -d' ' -f1-2)"
  done

  section "Last restic journal lines"
  code journalctl --no-pager -n 20 -u restic-backups-local.service -u restic-backups-r2.service
}

if [[ -n $out ]]; then
  (umask 077 && report >"$out")
  echo "$SELF: wrote $out" >&2
else
  report
fi
