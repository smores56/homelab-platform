#!/usr/bin/env bash
# Offline checks for the backup progress command (SDLC #706, T3 follow-up).
#
# The host half — a real restic uploading to a real repository — needs smortress.
# This drives the renderer against the tree the backup driver publishes, with a
# stubbed systemctl for the timer half, so the parsing, the liveness rules, the
# idle state and the no-root promise are exercised without a repository.
#
#   tests/core/smortress-restic-progress.sh
set -uo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root" || exit 1

script=scripts/smortress-restic-progress.sh

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
has() {
  if [[ $1 == *"$2"* ]]; then ok "$3"; else bad "$3" "missing '$2' in: $1"; fi
}

if [[ -x $script ]]; then ok 'the progress command is executable'; else bad 'the progress command is executable'; fi
if bash -n "$script" 2>/dev/null; then ok 'the progress command parses'; else bad 'the progress command parses'; fi
if "$script" --help >/dev/null 2>&1; then ok 'the progress command has --help'; else bad 'the progress command has --help'; fi
if "$script" --nonsense >/dev/null 2>&1; then bad 'the progress command rejects an unknown flag'; else ok 'the progress command rejects an unknown flag'; fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
bin=$work/bin
progress=$work/progress
install -d -m 0755 "$bin" "$progress/last"

# The timer half is the only systemctl call the command makes, so the stub is
# also the proof it asks per backend rather than hardcoding a schedule.
cat >"$bin/systemctl" <<'EOF'
#!/usr/bin/env bash
# show -p <prop> --value <unit>, or is-active <unit>
if [[ $1 == show ]]; then
  prop=$3 unit=$5
  case $prop in
    ActiveState) case $unit in *-hdd.timer) printf 'inactive\n' ;; *) printf 'active\n' ;; esac ;;
    NextElapseUSecRealtime) case $unit in *-ssd.timer) printf '%s\n' "$STUB_NEXT" ;; *) printf '\n' ;; esac ;;
  esac
fi
EOF
chmod 0755 "$bin/systemctl"

now=$(date +%s)
stamp() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

# A live attempt: current names the unit, and the status stream is restic's own
# --json record shape.
cat >"$progress/current-ssd.json" <<JSON
{"backend":"ssd","unit":"agent-local","start":"$(stamp $((now - 90)))","epoch":$((now - 90)),"deadline":14400,"expiry":40000}
JSON
printf '%s\n' \
  '{"message_type":"status","percent_done":0.25,"total_bytes":4000,"bytes_done":1000,"total_files":10,"files_done":2,"seconds_remaining":120}' \
  '{"message_type":"status","percent_done":0.5,"total_bytes":4000,"bytes_done":2000,"total_files":10,"files_done":5,"seconds_remaining":60}' \
  >"$progress/ssd-agent-local.jsonl"

# Durable results as the driver publishes them: one failure, the rest ok.
pub() { printf '%s\n' "$2" >"$progress/last/$1.json"; }
for b in ssd hdd; do
  for u in files books music wallpapers git apps repo-archive agent-general; do
    pub "$b-$u" "{\"schema\":2,\"attempt\":1,\"result\":\"success\",\"exit\":0,\"reason\":\"\",\"snapshot\":\"abc\",\"start\":\"$(stamp $((now - 3600)))\",\"end\":\"$(stamp $((now - 3500)))\",\"backend\":\"$b\",\"unit\":\"$u\"}"
  done
done
pub hdd-photos "{\"schema\":2,\"attempt\":2,\"result\":\"failure\",\"exit\":124,\"reason\":\"timeout\",\"snapshot\":null,\"start\":\"$(stamp $((now - 3600)))\",\"end\":\"$(stamp $((now - 3000)))\",\"backend\":\"hdd\",\"unit\":\"photos\"}"
pub ssd-photos "{\"schema\":2,\"attempt\":2,\"result\":\"failure\",\"exit\":124,\"reason\":\"timeout\",\"snapshot\":null,\"start\":\"$(stamp $((now - 3600)))\",\"end\":\"$(stamp $((now - 3000)))\",\"backend\":\"ssd\",\"unit\":\"photos\"}"

export PATH="$bin:$PATH" RESTIC_PROGRESS_ROOT=$progress
STUB_NEXT="$(date -u -d @$((now + 600)) '+%a %Y-%m-%d %H:%M:%S UTC')"
export STUB_NEXT

out=$("$script" --once 2>&1)
eq "$?" 0 'one frame exits 0'
has "$out" 'ssd' 'the frame names every backend'
has "$out" 'agent-local' 'the live unit is named'
has "$out" '50%' "restic's own percentage is rendered"
has "$out" '2.0KiB' 'the transferred byte count is rendered'
has "$out" '5/10 files' 'the file count is rendered'
has "$out" 'eta' 'an estimate is rendered'
has "$out" 'inactive' 'a timer that is not scheduled is not hidden'
has "$out" '10m' 'the next run is rendered as a countdown'
has "$out" 'timeout' 'a failed unit from the last run is reported'

if [[ $out == *'[#'* ]]; then ok 'a progress bar is drawn'; else bad 'a progress bar is drawn' "$out"; fi

out=$("$script" --once --all 2>&1)
has "$out" 'photos' '--all lists a unit that failed'
has "$out" 'files' '--all lists the units that succeeded'

# A frame for a backend with no current marker must say it is idle instead of
# rendering a unit that is not running.
out=$("$script" --once --backend hdd 2>&1)
has "$out" 'idle' 'a backend with no running unit reads idle'
if [[ $out == *'agent-local'* ]]; then bad "a backend filter does not borrow another backend's live unit" "$out"; else ok "a backend filter does not borrow another backend's live unit"; fi

# A marker left behind by a killed driver must not look live forever.
old=$((now - 86400))
cat >"$progress/current-ssd.json" <<JSON
{"backend":"ssd","unit":"agent-local","start":"$(stamp $old)","epoch":$old,"deadline":1800,"expiry":60}
JSON
out=$("$script" --once --backend ssd 2>&1)
has "$out" 'stale' 'an abandoned marker is called stale'

# A long unit is legal for its lock wait, its bounded attempts and the
# post-upload calls; the deadline alone is not the window.
legal=$((now - 2160))
cat >"$progress/current-ssd.json" <<JSON
{"backend":"ssd","unit":"agent-local","start":"$(stamp "$legal")","epoch":$legal,"deadline":1800}
JSON
out=$("$script" --once --backend ssd 2>&1)
if [[ $out == *'stale'* ]]; then
  bad 'a healthy long run is not called stale' "$out"
else
  ok 'a healthy long run is not called stale'
fi

# Nothing published yet is an answer, not an error.
out=$(RESTIC_PROGRESS_ROOT=$work/empty "$script" --once 2>&1)
eq "$?" 0 'an empty progress tree exits 0'
has "$out" 'no runs recorded' 'an empty progress tree says so'

# The installed command is /usr/bin/<name> -> /usr/libexec/<name>, and bash
# reports the symlink, not the target. Resolving the library from the sibling
# libexec directory is what makes the documented alias work at all.
install -d -m 0755 "$work/sbin" "$work/libexec"
ln -s "$PWD/scripts/smortress-restic-progress.sh" "$work/sbin/restic-progress"
# The installed names drop the .sh; the layout keeps its suffix because the
# common library falls back to it.
ln -s "$PWD/scripts/restic-plane-common.sh" "$work/libexec/restic-plane-common"
ln -s "$PWD/scripts/storage-layout.sh" "$work/libexec/storage-layout.sh"
out=$("$work/sbin/restic-progress" --once 2>&1)
has "$out" 'no runs recorded' 'the installed symlink resolves its library'

printf '\n%d checks, %d failed\n' "$pass" "$fail"
((fail == 0))
