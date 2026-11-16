#!/usr/bin/env bash
# Offline checks for the T0 gate scripts (SDLC #703).
#
# The privileged half — freezing a real cluster, reading a real repository —
# needs smortress and root. This checks the half that does not: argument
# handling, the read-only default, the refusal to run unprivileged, and the
# promises the gate document makes about what these scripts can do.
#
#   tests/core/check.sh
set -uo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root" || exit 1

failures=0
checks=0

fail() {
  printf 'FAIL %s\n' "$*" >&2
  failures=$((failures + 1))
}

pass() { printf 'ok   %s\n' "$*"; }

scripts=(scripts/core/legacy-audit.sh scripts/core/verify-legacy-backups.sh scripts/core/freeze-legacy.sh)

for s in "${scripts[@]}"; do
  checks=$((checks + 1))
  if [[ ! -x $s ]]; then
    fail "$s is not executable"
    continue
  fi
  if bash -n "$s"; then pass "$s parses"; else fail "$s does not parse"; fi

  checks=$((checks + 1))
  if "$s" --help >/dev/null 2>&1; then pass "$s --help"; else fail "$s --help"; fi

  checks=$((checks + 1))
  if "$s" --nonsense >/dev/null 2>&1; then
    fail "$s accepts an unknown flag"
  else
    pass "$s rejects an unknown flag"
  fi
done

# Freeze defaults to the read-only mode: an accidental plain invocation must not
# suspend anything.
checks=$((checks + 1))
grep -q '^mode=check$' scripts/core/freeze-legacy.sh &&
  ! grep -q -- '--apply) mode=apply' scripts/core/freeze-legacy.sh &&
  pass 'freeze defaults to --check' || fail 'freeze does not default to --check'

# Resume must restore recorded state, not a hard-coded false.
checks=$((checks + 1))
grep -q 'recorded=' scripts/core/freeze-legacy.sh &&
  grep -q 'state_file' scripts/core/freeze-legacy.sh &&
  pass 'freeze records and restores prior suspend state' ||
  fail 'freeze resume ignores recorded state'

# The verifier must never change retention or snapshots.
checks=$((checks + 1))
if grep -nE 'restic .*(forget|prune|init|unlock)|"\$restic_bin" (forget|prune|init|unlock)' \
  scripts/core/verify-legacy-backups.sh >/dev/null; then
  fail 'verifier invokes a mutating restic command'
else
  pass 'verifier has no forget/prune/init/unlock'
fi

# The verifier deletes only a scratch directory it created itself.
checks=$((checks + 1))
if [[ $(grep -c 'rm -rf' scripts/core/verify-legacy-backups.sh) -eq 1 ]] &&
  grep -q 'scratch_owned == 1' scripts/core/verify-legacy-backups.sh; then
  pass 'verifier deletes only its own scratch tree'
else
  fail 'verifier deletes a path it may not own'
fi

# Scratch must be rooted under /var/tmp and never reused when non-empty.
checks=$((checks + 1))
grep -q 'SCRATCH_ROOT=/var/tmp' scripts/core/verify-legacy-backups.sh &&
  grep -q 'refusing to reuse it' scripts/core/verify-legacy-backups.sh &&
  pass 'scratch is confined and non-empty targets are refused' ||
  fail 'scratch confinement is missing'

# Neither script may print secret values.
checks=$((checks + 1))
if grep -nE 'cat /run/secrets|cat .*restic-password|cat .*restic-r2.env' \
  "${scripts[@]}" >/dev/null; then
  fail 'a gate script prints a secret file'
else
  pass 'no gate script prints secret contents'
fi

# The audit must not start or unlock anything.
checks=$((checks + 1))
if grep -nE 'systemctl (start|stop|restart)|cryptsetup|restic (backup|forget|prune)' \
  scripts/core/legacy-audit.sh >/dev/null; then
  fail 'audit mutates state'
else
  pass 'audit is read-only'
fi

# The gate document must point at scripts that exist.
checks=$((checks + 1))
missing=0
for ref in $(grep -o 'scripts/core/[a-z-]*\.sh' docs/core/t0-gate.md | sort -u); do
  [[ -f $ref ]] || {
    fail "gate references a missing $ref"
    missing=1
  }
done
((missing)) || pass 'gate document references existing scripts'

# The Restic plane has its own harness: it stubs restic, zfs, curl and sops so
# exit codes, tags and the freshness join can be exercised without a disk.
checks=$((checks + 1))
if tests/core/restic-plane.sh; then
  pass 'restic plane checks'
else
  fail 'restic plane checks'
fi

# The application Quadlets have their own harness: it proves every image is the
# signed mirror at the pinned digest, and that readiness, Serve routes, Podman
# secrets and the firewall boundary line up.
checks=$((checks + 1))
if tests/core/app-quadlets.sh; then
  pass 'application quadlet checks'
else
  fail 'application quadlet checks'
fi

printf '\n%d checks, %d failed\n' "$checks" "$failures"
((failures == 0))
