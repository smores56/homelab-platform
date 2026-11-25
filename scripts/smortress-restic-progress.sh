#!/usr/bin/env bash
# Watch a Restic backup as it runs (SDLC #706, T3 follow-up).
#
#   smortress-restic-progress                 # redraw in place until interrupted
#   smortress-restic-progress --once          # one frame, for a log or a paste
#   smortress-restic-progress --all           # each unit's last result, not the count
#   smortress-restic-progress --backend r2 --interval 2
#
# The data is restic's own: while a unit uploads, the backup driver publishes the
# `--json` status records (percent, bytes, files, seconds_remaining) to
# RESTIC_PROGRESS_ROOT, and it publishes the same result line it writes to the
# journal when the unit ends. That tree is world-readable, so this command is
# the operator's read and needs no sudo; the durable state, the journals and the
# restic password stay root-only next door.
#
# The timers are asked rather than assumed: an inactive timer is shown as having
# no next run, because a plane that stops being scheduled looks exactly like a
# plane with nothing due.
# shellcheck disable=SC2034  # sourced vocabulary: consumers use a subset
# shellcheck disable=SC2154  # backends/units come from the sourced layout
set -uo pipefail

# bash reports the path that was executed, not the symlink target, so the
# documented /usr/bin alias would otherwise look for its library in /usr/bin.
# The installed layout is /usr/bin/<name> -> /usr/libexec/<name>, which the
# <here>/../libexec form covers without a hardcoded absolute path.
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
common=$here/restic-plane-common
[[ -r $common ]] || common=$common.sh
[[ -r $common ]] || common=$here/../libexec/restic-plane-common
[[ -r $common ]] || {
  printf 'smortress-restic-progress: cannot find restic-plane-common\n' >&2
  exit 2
}
# shellcheck source=/dev/null
source "$common"

interval=1
once=0
all=0
only=''

usage() {
  cat >&2 <<'EOF'
usage: smortress-restic-progress [--once] [--all] [--backend <ssd|hdd|r2>]
                                 [--interval <seconds>]

  --once      render one frame and exit
  --all       list every unit's last result instead of a per-backend summary
  --backend   report only this destination; repeatable
  --interval  redraw seconds, fractional allowed (default 1)
EOF
}

while (($#)); do
  case $1 in
    --once) once=1; shift ;;
    --all) all=1; shift ;;
    --backend)
      [[ -n ${2-} ]] || { usage; exit 2; }
      printf '%s\n' "${backends[@]}" | grep -qx -- "$2" || { usage; exit 2; }
      only+="$2 "
      shift 2
      ;;
    --interval)
      [[ ${2-} =~ ^[0-9]+([.][0-9]+)?$ ]] || { usage; exit 2; }
      interval=$2
      shift 2
      ;;
    -h | --help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

command -v jq >/dev/null || { printf 'smortress-restic-progress: jq is required\n' >&2; exit 2; }

want() { [[ -z $only || " $only" == *" $1 "* ]]; }

fmt_bytes() {
  numfmt --to=iec-i --suffix=B --format='%.1f' "$1" 2>/dev/null || printf '%sB' "$1"
}

fmt_span() {
  local s=$1 h m
  ((s < 0)) && s=0
  h=$((s / 3600))
  m=$((s % 3600 / 60))
  if ((h > 0)); then printf '%dh%02dm' "$h" "$m"; else printf '%dm' "$m"; fi
}

bar() {
  local pct=$1 width=20 filled
  ((pct < 0)) && pct=0
  ((pct > 100)) && pct=100
  filled=$((pct * width / 100))
  printf '%s%s' "$(printf '%*s' "$filled" '' | tr ' ' '#')" \
    "$(printf '%*s' "$((width - filled))" '' | tr ' ' '.')"
}

timer_text() { # <backend>
  local b=$1 state next in
  state=$(systemctl show -p ActiveState --value "smortress-restic-backup-$b.timer" 2>/dev/null) || state=''
  if [[ -z $state ]]; then
    printf 'timer state unknown'
    return
  fi
  if [[ $state != active ]]; then
    printf 'timer %s: no next run' "$state"
    return
  fi
  next=$(systemctl show -p NextElapseUSecRealtime --value \
    "smortress-restic-backup-$b.timer" 2>/dev/null) || next=''
  if [[ -z $next ]] || ! in=$(iso_epoch "$next"); then
    printf 'timer active, next run unknown'
    return
  fi
  in=$(($(now_epoch) > in ? 0 : in - $(now_epoch)))
  printf 'timer active, next run in %s' "$(fmt_span "$in")"
}

# The last *status* record, not the last line: after the upload restic writes a
# summary and goes on to tag and verify, and the percentage it already reached
# is still the truth for that phase.
last_status() { # <file>
  [[ -r $1 && -s $1 ]] || return 1
  tac -- "$1" 2>/dev/null | jq -c 'select(.message_type == "status")' 2>/dev/null | head -n 1
}

# The current marker is per backend, because the hourly ssd and hdd units fire at
# the same minute. A marker older than the window it publishes is a run that died
# without clearing it: showing it as live would be a lie that never expires.
cur_unit=''
cur_epoch=0
cur_deadline=0
cur_expiry=0
cur_stale=0
load_current() { # <backend>
  local marker
  cur_unit=''
  cur_epoch=0
  cur_deadline=0
  cur_expiry=0
  cur_stale=0
  marker=$(progress_current_for "$1")
  [[ -r $marker ]] || return 0
  cur_unit=$(jq -r '.unit // ""' "$marker" 2>/dev/null) || cur_unit=''
  cur_epoch=$(jq -r '.epoch // 0' "$marker" 2>/dev/null) || cur_epoch=0
  cur_deadline=$(jq -r '.deadline // 0' "$marker" 2>/dev/null) || cur_deadline=0
  cur_expiry=$(jq -r '.expiry // 0' "$marker" 2>/dev/null) || cur_expiry=0
  [[ -n $cur_unit ]] || cur_unit=''
  # The driver publishes the window the attempt is legal for; a marker that
  # predates the field falls back to the loosest bound the plane allows.
  ((cur_expiry > 0)) || cur_expiry=$((cur_deadline + lock_wait + kill_after + 300))
  if [[ -n $cur_unit ]] && (($(now_epoch) - cur_epoch > cur_expiry)); then
    cur_stale=1
  fi
}

# Byte rate across frames, keyed per unit. restic's seconds_remaining is
# authoritative but reads 0 while it scans and again at the end, which is
# exactly when a watcher is looked at.
declare -A prev_ts=() prev_bytes=()
rate_for() { # <key> <ts> <bytes> -> bytes/s, or 0 when there is no sample yet
  local key=$1 ts=$2 bytes=$3 prev_t prev_b rate=0
  if [[ -n ${prev_ts[$key]:-} && -n ${prev_bytes[$key]:-} ]]; then
    prev_t=${prev_ts[$key]}
    prev_b=${prev_bytes[$key]}
    if ((ts > prev_t && bytes > prev_b)); then
      rate=$(((bytes - prev_b) / (ts - prev_t)))
    fi
  fi
  prev_ts[$key]=$ts
  prev_bytes[$key]=$bytes
  printf '%s' "$rate"
}

summarize() { # <backend> -> "last 17:05: 8 ok, 1 failed (photos:timeout)"
  local b=$1 u f result end newest='' ok=0 bad=0 fails='' when='' detail
  for u in "${units[@]}"; do
    f=$(progress_last_for "$b" "$u")
    [[ -r $f ]] || continue
    result=$(jq -r '.result // ""' "$f" 2>/dev/null) || result=''
    end=$(jq -r '.end // ""' "$f" 2>/dev/null) || end=''
    [[ -n $end && $end > $newest ]] && newest=$end
    if [[ $result == success ]]; then
      ok=$((ok + 1))
    else
      bad=$((bad + 1))
      fails+="${u}:$(jq -r '.reason // .result // "failed"' "$f" 2>/dev/null) "
    fi
  done
  if ((ok + bad == 0)); then
    printf 'no runs recorded'
    return
  fi
  [[ -n $newest ]] && when="$(date -u -d "$newest" +%H:%M): "
  detail="${ok} ok"
  ((bad > 0)) && detail+=", ${bad} failed (${fails% })"
  printf 'last %s%s' "$when" "$detail"
}

list_units() { # <backend>
  local b=$1 u f result end reason
  for u in "${units[@]}"; do
    f=$(progress_last_for "$b" "$u")
    [[ -r $f ]] || continue
    result=$(jq -r '.result // "unknown"' "$f" 2>/dev/null) || result=unknown
    end=$(jq -r '.end // ""' "$f" 2>/dev/null) || end=''
    reason=$(jq -r '.reason // ""' "$f" 2>/dev/null) || reason=''
    printf '      %-12s %-8s %s%s\n' "$u" "$result" \
      "${end:+$(date -u -d "$end" +%H:%M) }" "${reason:+($reason)}"
  done
}

render_live() { # <backend>
  local b=$1 now=$2 status pct bdone btotal fdone ftotal eta rate line key
  status=$(last_status "$(progress_file_for "$b" "$cur_unit")")
  if [[ -z $status ]]; then
    printf '      %-12s running, no status record yet (%s)\n' "$cur_unit" \
      "$(fmt_span $((now - cur_epoch)))"
    return
  fi
  IFS=$'\t' read -r pct bdone btotal fdone ftotal eta < <(
    jq -r '[(((.percent_done // 0) * 100) | floor), (.bytes_done // 0),
            (.total_bytes // 0), (.files_done // 0), (.total_files // 0),
            (.seconds_remaining // 0)] | @tsv' <<<"$status"
  )
  key="$b-$cur_unit"
  rate=$(rate_for "$key" "$now" "$bdone")
  if ((eta <= 0 && rate > 0 && btotal > bdone)); then
    eta=$(((btotal - bdone) / rate))
  fi
  line=$(printf '      %-12s [%s] %3d%%  %s / %s  %s files' \
    "$cur_unit" "$(bar "$pct")" "$pct" \
    "$(fmt_bytes "$bdone")" "$(fmt_bytes "$btotal")" "$fdone/$ftotal")
  ((eta > 0)) && line+=$(printf '  eta %s' "$(fmt_span "$eta")")
  ((rate > 0)) && line+=$(printf '  %s/s' "$(fmt_bytes "$rate")")
  ((btotal > 0)) || line+='  scanning'
  line+=$(printf '  (%s of %s)' "$(fmt_span $((now - cur_epoch)))" \
    "$(fmt_span "$cur_deadline")")
  local stream_age=0 stream_mtime
  stream_mtime=$(stat -c %Y "$(progress_file_for "$b" "$cur_unit")" 2>/dev/null) || stream_mtime=$now
  stream_age=$((now - stream_mtime))
  ((stream_age > 120)) && line+=$(printf '  no update for %s' "$(fmt_span "$stream_age")")
  printf '%s\n' "$line"
}

frame() {
  local b now
  now=$(now_epoch)
  printf 'restic backup progress  %s\n' "$(date -u +%H:%M:%SZ)"
  for b in "${backends[@]}"; do
    want "$b" || continue
    printf '%-4s %s\n' "$b" "$(timer_text "$b")"
    load_current "$b"
    if [[ -n $cur_unit && $cur_stale == 1 ]]; then
      printf '      %-12s stale marker from %s: the driver did not clear it\n' \
        "$cur_unit" "$(date -u -d "@$cur_epoch" +%H:%M)"
      printf '      idle; %s\n' "$(summarize "$b")"
    elif [[ -n $cur_unit ]]; then
      render_live "$b" "$now"
    else
      printf '      idle; %s\n' "$(summarize "$b")"
    fi
    ((all)) && list_units "$b"
  done
}

if ((once)); then
  frame
  exit 0
fi

trap 'printf "\033[?25h"; exit 0' INT TERM
trap 'printf "\033[?25h"' EXIT
printf '\033[?25l'
while :; do
  printf '\033[H\033[J'
  frame
  sleep "$interval"
done
