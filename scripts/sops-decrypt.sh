#!/usr/bin/env bash
# Decrypt every listed SOPS ciphertext into /run with least-privilege ownership
# and mode. The age identity is staged root-only from the offline recovery kit;
# the image carries ciphertext only. No plaintext is written outside /run.
set -euo pipefail

readonly src=/etc/smortress/secrets
readonly dst=/run/smortress/secrets
readonly manifest=/etc/smortress/secrets.manifest
readonly age_key=/var/lib/smortress/age/keys.txt

if [[ ! -s $age_key ]]; then
  echo "sops-decrypt: $age_key is missing; stage the age identity from the recovery kit" >&2
  exit 1
fi
if [[ ! -d $src ]]; then
  echo "sops-decrypt: $src is missing" >&2
  exit 1
fi
if [[ ! -s $manifest ]]; then
  echo "sops-decrypt: $manifest is missing" >&2
  exit 1
fi

install -d -m 0700 "$dst"
tmp=$(mktemp "$dst/.decrypt.XXXXXX")
trap 'rm -f "$tmp"' EXIT

unlisted=$(find "$src" -maxdepth 1 -type f -name '*.yaml' -printf '%f\n' | sort)
listed=$(awk '!/^[[:space:]]*(#|$)/ { print $1 }' "$manifest" | sort)
if [[ $unlisted != "$listed" ]]; then
  echo "sops-decrypt: ciphertext set and manifest disagree" >&2
  diff <(printf '%s\n' "$unlisted") <(printf '%s\n' "$listed") >&2 || true
  exit 1
fi

while read -r name uid gid mode; do
  [[ $name =~ ^[A-Za-z0-9._-]+\.yaml$ ]] || { echo "sops-decrypt: bad name: $name" >&2; exit 1; }
  # Only owner-only modes: a manifest typo must not publish a secret
  [[ $mode =~ ^0?[46]00$ ]] || { echo "sops-decrypt: mode must be 0400 or 0600: $mode" >&2; exit 1; }
  getent passwd "$uid" >/dev/null || { echo "sops-decrypt: unknown user: $uid" >&2; exit 1; }
  getent group "$gid" >/dev/null || { echo "sops-decrypt: unknown group: $gid" >&2; exit 1; }
  if [[ ! -s $src/$name ]]; then
    echo "sops-decrypt: missing ciphertext $name" >&2
    exit 1
  fi
  if ! SOPS_AGE_KEY_FILE="$age_key" sops --decrypt --input-type yaml --output-type yaml \
      "$src/$name" >"$tmp"; then
    echo "sops-decrypt: failed to decrypt $name" >&2
    exit 1
  fi
  install -o "$uid" -g "$gid" -m "$mode" "$tmp" "$dst/$name"
  : >"$tmp"
  echo "sops-decrypt: wrote $dst/$name ($uid:$gid $mode)"
done < <(awk '!/^[[:space:]]*(#|$)/ { print $1, $2, $3, $4 }' "$manifest")
