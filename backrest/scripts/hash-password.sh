#!/usr/bin/env bash
# Prints the value Backrest stores in auth.users[].passwordBcrypt for a password
# read from stdin. Backrest accepts base64(bcrypt); Go's bcrypt rejects the
# $2y$ prefix htpasswd emits, so it is rewritten to $2a$ (same hash, different
# prefix convention).
#
# The password is never an argument and never touches the host: it is piped into
# a throwaway Alpine container. Run it as
#
#   read -rsp 'backrest password: ' pw && printf '%s' "$pw" | backrest/scripts/hash-password.sh
#
# and store the printed hash as the BACKREST_OPERATOR_BCRYPT Worker secret.
set -euo pipefail

if [[ -t 0 ]]; then
  printf 'usage: pipe the password on stdin, never as an argument\n' >&2
  exit 64
fi

exec podman run --rm -i docker.io/library/alpine:3.22 sh -c '
  set -eu
  apk add -q --no-cache apache2-utils >/dev/null
  htpasswd -niBC 12 "" \
    | cut -d: -f2 \
    | sed "s/^\$2y\$/\$2a\$/" \
    | base64 \
    | tr -d "\n"
  printf "\n"
'
