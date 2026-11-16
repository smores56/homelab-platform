#!/usr/bin/env bash
# Initialise missing Restic repositories (SDLC #706, T3).
#
#   smortress-restic-init [ssd|hdd|r2]...
#
# A repository is created once. An existing one is never re-initialised, and a
# local repository is only created when its disk is actually mounted: writing a
# repository into the root filesystem under an unmounted /var/lib/restic/<disk>
# would produce a place that looks like a backup destination and is not one.
# shellcheck disable=SC2154  # variables and helpers come from restic-plane-common
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
common=$here/restic-plane-common
[[ -r $common ]] || common=$common.sh
# shellcheck source=/dev/null
source "$common"

# Everything this plane creates (lock files, journals, maintenance logs) is
# private to root by default; explicit modes are set on top of this.
umask 0077

usage() {
  cat >&2 <<'EOF'
usage: smortress-restic-init [ssd|hdd|r2]

With no argument, every backend that is mounted (local) or configured (R2) is
checked. A missing disk is reported, never initialised over.
EOF
}

targets=()
if (($# == 0)); then
  targets=("${backends[@]}")
else
  for b in "$@"; do
    case $b in ssd | hdd | r2) ;; *) usage; exit 2 ;; esac
    targets+=("$b")
  done
fi

init_backend() {
  local backend=$1 repo=$2 rc
  if ! load_backend_env "$backend"; then
    warn "$backend: repository or credentials are not configured; skipping init"
    return 0
  fi

  if [[ $backend != r2 ]] && ! is_mountpoint "$restic_base/$backend"; then
    warn "$backend: $restic_base/$backend is not a mountpoint; refusing to initialise"
    return 1
  fi

  if with_deadline "$(job_deadline "$backend")" "$restic_bin" -r "$repo" cat config \
    >/dev/null 2>&1; then
    say "$backend: $repo is already initialised"
    return 0
  else
    rc=$?
  fi
  if ((rc != 10)); then
    warn "$backend: cannot tell whether $repo is a repository (restic cat config exited $rc)"
    return 1
  fi

  if [[ -d $repo ]] && [[ -n $(find "$repo" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null) ]]; then
    warn "$backend: $repo exists, holds files and is not a Restic repository; refusing to init over it"
    return 1
  fi

  if ! with_deadline "$(job_deadline "$backend")" "$restic_bin" -r "$repo" init \
    >/dev/null 2>&1; then
    warn "$backend: restic init failed for $repo"
    return 1
  fi
  say "$backend: created $repo"
  return 0
}

failed=0
for backend in "${targets[@]}"; do
  if ! repo=$(repo_for "$backend" 2>/dev/null); then
    warn "$backend: repository is not configured; nothing to init"
    continue
  fi
  if ! init_backend "$backend" "$repo"; then failed=1; fi
done

if ((failed)); then
  warn "at least one repository could not be initialised"
  exit 1
fi
say "repository init complete"
