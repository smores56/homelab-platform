#!/usr/bin/env bash
# What "this host works" means, for greenboot — the half every host shares.
#
# greenboot runs every executable in check/required.d after boot and rolls the
# deployment back when one exits non-zero, which is the automatic rollback for a
# host that boots into a sick image. The boot counter covers the deployment that
# never reaches userspace; neither covers the other's failure, and together they
# replace the post-boot gate this repository used to hand-roll.
#
# What a host asserts is its own job and is data: each image installs exactly one
# file under /etc/greenboot/assertions.d/, which sets the check's name and budget
# and defines assertions(). This script is the part that must be right whatever
# is asserted — source that file, hand it one deadline, report in one shape, exit
# non-zero — so it exists once instead of once per host.
#
# Waiting is the point rather than a nicety: a boot is not a steady state, and
# the things a host asserts come up over a minute. The assertions use expired()
# and wait_step() rather than their own clocks, so one budget bounds them all,
# and each image's unit timeout is raised to cover its budget — a probe that gave
# up early would roll back a healthy deployment on a slow boot.
set -uo pipefail

assertions_dir=${GREENBOOT_ASSERTIONS_DIR:-/etc/greenboot/assertions.d}
check_name=10-health
budget=60
failures=0

report() { printf '%s: %s: %s\n' "$check_name" "$1" "$2" >&2; failures=1; }
expired() { ((SECONDS >= deadline)); }
wait_step() { sleep "${GREENBOOT_POLL:-3}"; }

shopt -s nullglob
assertion_files=("$assertions_dir"/*.sh)
shopt -u nullglob
if ((${#assertion_files[@]} != 1)); then
  # Zero would pass a host nobody checked; two would run whichever the glob
  # ordered last, so a stale file left beside a new one would be the assertion
  # that never ran.
  printf '10-health: %d assertion files in %s, expected exactly one\n' \
    "${#assertion_files[@]}" "$assertions_dir" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "${assertion_files[0]}"
if ! declare -F assertions >/dev/null; then
  printf '10-health: %s defines no assertions()\n' "${assertion_files[0]}" >&2
  exit 1
fi

deadline=$((SECONDS + budget))
assertions

if ((failures)); then
  printf '%s: this deployment is not serving; greenboot will roll it back\n' "$check_name" >&2
fi
exit "$failures"
