# shellcheck shell=bash
# Shared output helpers. Source after `set -euo pipefail`; the caller's name is
# the program prefix, and an installed helper and a checkout run print the same
# thing because `.sh` is stripped from the basename.
#
# The image installs this file at /usr/libexec/lib/log.sh, beside the helpers
# that live at /usr/libexec; a checkout sources scripts/lib/log.sh.

SMOLIB_PROG=${SMOLIB_PROG:-${0##*/}}
SMOLIB_PROG=${SMOLIB_PROG%.sh}

say() { printf '%s: %s\n' "$SMOLIB_PROG" "$*"; }
warn() { printf '%s: %s\n' "$SMOLIB_PROG" "$*" >&2; }
die() { printf '%s: %s\n' "$SMOLIB_PROG" "$*" >&2; exit 1; }
note() { printf '%s\n' "$*"; }
