#!/usr/bin/env bash
# Cold-restore matrix for the #709 retirement gate.
#
# Run on smortress as root. For every unit and destination it selects the
# newest `verified` snapshot with the drill helper, restores it into a fresh
# target, compares one sample file against the live tree, and records a row of
# evidence before removing the target.
#
#   sudo scripts/retirement-gate.sh                 # the whole matrix
#   sudo scripts/retirement-gate.sh --dry-run       # plan only, touches nothing
#   sudo scripts/retirement-gate.sh --backend r2    # one destination
#   sudo scripts/retirement-gate.sh --keep          # leave the targets for inspection
#
# The comparison is deliberately weak and honest: a checksum of one sample file
# per restored dataset proves the tree is readable and belongs where it claims.
# It does not prove database recovery, quota state or application correctness;
# those stay operator rows in #716 (docs/core/restic-plane.md, "What is not
# proven yet").
#
# Exit 0 only when every row restored and every sample matched. Evidence is a
# Markdown table on stdout, safe to paste into the issue.
#
# Env: GATE_UNITS, GATE_BACKENDS, GATE_DRILL_ROOT, GATE_SAMPLE_MAX (bytes),
# DRILL_BIN, GATE_LIVE_ROOT (tests only), RESTIC_DRILL_ROOT (passed through).
set -uo pipefail

drill=${DRILL_BIN:-/usr/libexec/smortress-restic-restore-drill}
root=${GATE_DRILL_ROOT:-/var/lib/restic/hdd/drill}
live_root=${GATE_LIVE_ROOT:-/}
sample_max=${GATE_SAMPLE_MAX:-16777216}
# scripts/storage-layout.sh is the source of truth; this list is its restore
# units in the order a person wants to watch them.
units=${GATE_UNITS:-"books wallpapers music git apps repo-archive files photos agent-local agent-general"}
backends=${GATE_BACKENDS:-"ssd hdd r2"}
dry_run=0
keep=0
rows=0
fails=0
evidence=$(mktemp)
trap 'rm -f "$evidence"' EXIT

while (($#)); do
  case $1 in
    --dry-run) dry_run=1 ;;
    --keep) keep=1 ;;
    --backend) backends=${2-}; shift ;;
    --unit) units=${2-}; shift ;;
    --root) root=${2-}; shift ;;
    --help | -h) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

[[ -x $drill ]] || { printf 'retirement-gate: %s is not executable\n' "$drill" >&2; exit 2; }
# GATE_ALLOW_UNPRIVILEGED exists for the stubbed self-check, never for a real
# run: the drill helper needs the repositories and the live trees.
if [[ -z ${GATE_ALLOW_UNPRIVILEGED:-} && $(id -u) -ne 0 && $dry_run -eq 0 ]]; then
  printf 'retirement-gate: run as root; the drill helper needs the repositories\n' >&2
  exit 2
fi

record() { # <backend> <unit> <snapshot> <tags> <rc> <target> <sample> <live> <sha>
  rows=$((rows + 1))
  if [[ $5 != 0 || $9 != match ]]; then fails=$((fails + 1)); fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" >>"$evidence"
}

# Largest regular file that is small enough to hash quickly. A media unit's
# first file may be a 20 GiB video, and hashing that would dominate the drill.
sample_of() { # <restored tree>
  find "$1" -type f -size +0 -size "-${sample_max}c" -printf '%s\t%p\n' 2>/dev/null \
    | sort -n | tail -1 | cut -f2-
}

# The backup recorded absolute paths (`/var/srv/photos/.zfs/snapshot/r2/...`)
# and restic adds the target prefix, so the live counterpart is the same path
# with the target and the snapshot segment removed.
live_of() { # <restored file> <target> <backend>
  local path=${1#"$2"}
  path=$(printf '%s' "$path" | sed "s#/.zfs/snapshot/$3##")
  printf '%s%s\n' "$live_root" "$path"
}

for backend in $backends; do
  for unit in $units; do
    if ((dry_run)); then
      printf 'would restore %s/%s into %s/%s-%s-<utc>\n' \
        "$backend" "$unit" "$root" "$backend" "$unit"
      continue
    fi
    if ! listing=$("$drill" "$backend" "$unit" --list 2>&1); then
      printf 'retirement-gate: %s/%s has no listing: %s\n' \
        "$backend" "$unit" "${listing##*$'\n'}" >&2
      record "$backend" "$unit" - - 1 - - - no-snapshot
      continue
    fi
    snapshot=$(tail -1 <<<"$listing" | awk '{print $1}')
    tags=$(tail -1 <<<"$listing" | awk '{print $4}')
    target=$root/$backend-$unit-$(date -u +%Y%m%dT%H%M%SZ)
    printf '== %s/%s: %s (%s)\n' "$backend" "$unit" "$snapshot" "$tags" >&2
    if ! out=$("$drill" "$backend" "$unit" --target "$target" 2>&1); then
      printf 'retirement-gate: %s/%s restore failed: %s\n' \
        "$backend" "$unit" "$(tail -2 <<<"$out" | tr '\n' ' ')" >&2
      record "$backend" "$unit" "$snapshot" "$tags" 1 "$target" - - restore-failed
      continue
    fi
    # The backup's root was `/var/srv/<dataset>/.zfs/snapshot/<backend>`, so
    # that exact directory is the restored dataset.
    restored=$(find "$target" -type d -path "*/.zfs/snapshot/$backend" -print -quit 2>/dev/null)
    sample=$(sample_of "${restored:-$target}")
    if [[ -z $sample ]]; then
      record "$backend" "$unit" "$snapshot" "$tags" 1 "$target" - - no-sample
    else
      rel=${sample#"$target"}
      live=$(live_of "$sample" "$target" "$backend")
      if [[ -f $live ]]; then
        sha_sample=$(sha256sum -- "$sample" | cut -d' ' -f1)
        sha_live=$(sha256sum -- "$live" | cut -d' ' -f1)
        if [[ $sha_sample == "$sha_live" ]]; then
          record "$backend" "$unit" "$snapshot" "$tags" 0 "$target" "$rel" "$live" match
        else
          record "$backend" "$unit" "$snapshot" "$tags" 0 "$target" "$rel" "$live" mismatch
        fi
      else
        record "$backend" "$unit" "$snapshot" "$tags" 0 "$target" "$rel" "$live" no-live-counterpart
      fi
    fi
    if ((keep == 0)); then
      rm -rf -- "$target"
    fi
  done
done

((dry_run)) && exit 0

printf '\n## Cold-restore matrix\n\n'
printf '| Backend | Unit | Snapshot | Restore | Sample | Live counterpart | Verdict |\n'
printf '| --- | --- | --- | --- | --- | --- | --- |\n'
sort "$evidence" | while IFS=$'\t' read -r backend unit snapshot tags rc target sample live sha; do
  verdict=$sha
  [[ $rc == 0 ]] || verdict="restore failed"
  # shellcheck disable=SC2016  # the backticks are Markdown, not expansion
  printf '| %s | %s | `%s` | %s | %s | %s | %s |\n' \
    "$backend" "$unit" "${snapshot:0:12}" "$([[ $rc == 0 ]] && echo ok || echo FAIL)" \
    "${sample:--}" "${live:--}" "$verdict"
done
printf '\n%d rows, %d failed\n' "$rows" "$fails"
exit $((fails > 0))
