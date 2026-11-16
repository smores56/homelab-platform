#!/usr/bin/env bash
# Read-only inventory of the legacy smortress host (SDLC #703, T0 of #701).
#
# The replacement core keeps data and nothing else, so before anything is
# destroyed this has to be provable: which trees exist, who owns them, how big
# they are, which secrets exist, and which ones a later task may call
# disposable. Markdown on stdout, meant to be pasted into `docs/core/t0-gate.md`
# and the #703 issue:
#
#   sudo scripts/core/legacy-audit.sh --out /var/tmp/t0-audit.md
#
# It only reads: `lsblk`, `findmnt`, `stat`, `du`, `find`, `systemctl show`,
# `ssh-keygen -l`, `ls` and a `journalctl` tail. Nothing here unlocks a disk,
# starts a unit, or touches a repository. Secret *values* are never printed.
set -euo pipefail

readonly SELF=${0##*/}
readonly DATA_ROOT=/var/lib/data
readonly BACKUP_ROOT=/var/backup
# State the host restic job does not walk, so it must be dispositioned here.
readonly OUTSIDE_TREES=(
  /var/lib/syncthing
  /var/lib/syncthing-versions
  /var/lib/todo.img
  /var/lib/data/db
  /home/smores/.local/state/letta
  /home/smores/.local/state/nanobot
)

out=""
quick=0

usage() {
  cat <<'EOF'
usage: legacy-audit.sh [--out FILE] [--quick]

Read-only inventory of the legacy smortress host. Markdown on stdout.
  --out FILE   also write the report to FILE (mode 0600)
  --quick      skip the byte/file walk inside /var/backup/restic
  -h, --help   this text
EOF
}

while (($#)); do
  case $1 in
  --out)
    out=${2:?--out needs a path}
    shift 2
    ;;
  --quick)
    quick=1
    shift
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

tree_row() { # tree_row <path> [skip]
  local path=$1 skip=${2:-0}
  if [[ ! -e $path ]]; then
    printf '| `%s` | missing | | | |\n' "$path"
    return
  fi
  local size files newest
  if ((skip)); then
    size="(skipped)"
    files="(skipped)"
    newest="(skipped)"
  else
    size=$(du -sbx "$path" 2>/dev/null | cut -f1)
    files=$(find "$path" -xdev -type f -printf '.' 2>/dev/null | wc -c)
    newest=$(find "$path" -xdev -type f -printf '%TY-%Tm-%Td\n' 2>/dev/null | sort | tail -1)
  fi
  printf '| `%s` | %s %s | %s | %s | %s |\n' \
    "$path" \
    "$(stat -c '%U:%G' "$path")" "$(stat -c '%a' "$path")" \
    "${size:-?}" "${files:-?}" "${newest:-?}"
}

tree_table() {
  local root=$1 p
  printf '| path | owner:group mode | apparent bytes | files | newest file |\n'
  printf '| --- | --- | --- | --- | --- |\n'
  for p in "$root"/*; do
    [[ -e $p ]] || continue
    if ((quick)) && [[ $p == "$BACKUP_ROOT/restic" ]]; then
      tree_row "$p" 1
    else
      tree_row "$p"
    fi
  done
}

restic_units() {
  local unit
  for unit in restic-db-dump.service restic-backups-local.service restic-backups-r2.service; do
    if ! systemctl cat "$unit" >/dev/null 2>&1; then
      printf '### %s\n\nabsent\n\n' "$unit"
      continue
    fi
    printf '### %s\n\n' "$unit"
    code systemctl show -p ActiveState -p Result -p ExecMainStartTimestamp \
      -p ExecMainExitTimestamp -p ExecMainStatus -p Environment -p EnvironmentFiles "$unit"
    printf '\n'
  done
}

report() {
  printf '# Legacy smortress audit\n\n'
  printf 'Generated: %s  \n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
  printf 'Host: %s  \n' "$(hostname)"
  if [[ -r /run/current-system/nixos-version ]]; then
    printf 'NixOS: %s  \n' "$(< /run/current-system/nixos-version)"
  fi
  printf 'Kernel: %s\n' "$(uname -r)"

  section "Block devices"
  printf 'Serial and model are what a wipe selects on; record both NVMe and the HDD.\n\n'
  code lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID,SERIAL,MODEL,MOUNTPOINT

  section "Mounts"
  code findmnt -rn -o TARGET,SOURCE,FSTYPE,OPTIONS / /boot "$DATA_ROOT" "$BACKUP_ROOT"

  section "Data trees ($DATA_ROOT)"
  printf 'Every row is a candidate recovery group; `t0-gate.md` records the\n'
  printf 'disposition of each one.\n\n'
  tree_table "$DATA_ROOT"

  section "Backup disk ($BACKUP_ROOT)"
  tree_table "$BACKUP_ROOT"

  section "Trees outside $DATA_ROOT"
  printf 'State the host restic job does not walk. Each needs an explicit\n'
  printf 'disposition or a rescue copy before the disk is wiped.\n\n'
  printf '| path | owner:group mode | apparent bytes | files | newest file |\n'
  printf '| --- | --- | --- | --- | --- |\n'
  local p
  for p in "${OUTSIDE_TREES[@]}"; do tree_row "$p"; done

  section "Loop-backed trees"
  printf 'A whole filesystem inside one file: the file is the recovery unit for\n'
  printf 'the mounted contents, not a second copy of them.\n\n'
  printf '```text\n'
  findmnt -rn -o TARGET,SOURCE,FSTYPE | grep -F "$DATA_ROOT/" || printf '(none)\n'
  printf '```\n'

  section "Immich dump"
  printf 'The host-side writer was retired with #509; the live dump is written by\n'
  printf 'the in-cluster CronJob into the Immich tree.\n\n'
  local dump
  for dump in "$DATA_ROOT/immich/db-dumps/immich.dump" "$DATA_ROOT/db/immich.dump"; do
    if [[ -e $dump ]]; then
      printf -- '- `%s`: %s bytes, %s\n' "$dump" \
        "$(stat -c '%s' "$dump")" "$(stat -c '%y' "$dump")"
    else
      printf -- '- `%s`: absent\n' "$dump"
    fi
  done

  section "Secrets on this host"
  printf 'Names, owners and modes only. The cluster also holds hand-created\n'
  printf 'Secrets in etcd; that copy dies with the disk.\n\n'
  printf '```text\n'
  ls -la /run/secrets.d/ 2>/dev/null || printf '(no /run/secrets.d)\n'
  printf '```\n'
  if [[ -d /run/secrets.d ]]; then
    local link
    for link in /run/secrets.d/*; do
      [[ -e $link ]] || continue
      printf '```text\n'
      ls -la "$link" 2>/dev/null || printf '(unreadable)\n'
      printf '```\n'
    done
  fi

  section "Legacy restic units"
  restic_units

  section "Legacy timers"
  code systemctl list-timers --all --no-pager 'restic-*'

  section "SSH host identity"
  printf 'Public fingerprints only; the private key is the SOPS identity and must\n'
  printf 'not be copied by this script.\n\n'
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
