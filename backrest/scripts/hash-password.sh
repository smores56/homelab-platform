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
# and store the printed hash as the BACKREST_OPERATOR_BCRYPT Worker secret. It
# needs a host whose container policy allows docker.io: smorespro's does, the
# server image's distro policy has no docker.io entry at all.
set -euo pipefail

if [[ -t 0 ]]; then
  printf 'usage: pipe the password on stdin, never as an argument\n' >&2
  exit 64
fi

err=$(mktemp)
trap 'rm -f "$err"' EXIT

# htpasswd prints ":<hash>", and the command substitution drops the newline the
# field ends with, so the host gets exactly the 60 characters and nothing else.
if ! hash=$(podman run --rm -i docker.io/library/alpine:3.22 sh -c '
  set -eu
  apk add -q --no-cache apache2-utils >/dev/null
  htpasswd -niBC 12 ""
' 2>"$err"); then
  if grep -qF 'rejected by policy' "$err"; then
    printf 'hash-password: this host refuses docker.io images, so the throwaway\n' >&2
    printf 'container cannot run (see /etc/containers/policy.json). Run it on a\n' >&2
    printf 'host whose policy allows docker.io, and paste the hash where it is needed.\n' >&2
    exit 78
  fi
  cat "$err" >&2
  exit 1
fi

hash=${hash#:}
hash=${hash/\$2y\$/\$2a\$}

# A silent no-op rewrite is what shipped once, so the shape is checked rather
# than trusted: Go answers "crypto/bcrypt: hashedSecret too short" otherwise.
if [[ ${#hash} -ne 60 || $hash != \$2a\$12\$* ]]; then
  printf 'hash-password: htpasswd printed an unexpected hash: %s\n' "$hash" >&2
  exit 1
fi

printf '%s' "$hash" | base64 | tr -d '\n'
printf '\n'
