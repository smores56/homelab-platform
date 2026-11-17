#!/usr/bin/env bash
# Decrypt every listed SOPS ciphertext into /run with least-privilege ownership
# and mode. The age identity is staged root-only from the offline recovery kit;
# the image carries ciphertext only. No plaintext is written outside /run.
#
# The manifest has five columns: name uid gid mode [format]. `format` is `yaml`
# (the default; the decrypted file is written verbatim) or `value` (the sole
# top-level scalar is written, which is what a restic password file must be).
set -euo pipefail

src=${SMORTRESS_SECRETS_SRC:-/etc/smortress/secrets}
dst=${SMORTRESS_SECRETS_DST:-/run/smortress/secrets}
manifest=${SMORTRESS_SECRETS_MANIFEST:-/etc/smortress/secrets.manifest}
age_key=${SMORTRESS_AGE_KEY:-/var/lib/homelab/age/keys.txt}
sops_bin=${SOPS_BIN:-sops}

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

while read -r name uid gid mode format; do
  [[ $name =~ ^[A-Za-z0-9._-]+\.yaml$ ]] || { echo "sops-decrypt: bad name: $name" >&2; exit 1; }
  # Only owner-only modes: a manifest typo must not publish a secret
  [[ $mode =~ ^0?[46]00$ ]] || { echo "sops-decrypt: mode must be 0400 or 0600: $mode" >&2; exit 1; }
  format=${format:-yaml}
  case $format in
    yaml | value) ;;
    *) echo "sops-decrypt: unknown format for $name: $format" >&2; exit 1 ;;
  esac
  getent passwd "$uid" >/dev/null || { echo "sops-decrypt: unknown user: $uid" >&2; exit 1; }
  getent group "$gid" >/dev/null || { echo "sops-decrypt: unknown group: $gid" >&2; exit 1; }
  if [[ ! -s $src/$name ]]; then
    echo "sops-decrypt: missing ciphertext $name" >&2
    exit 1
  fi
  if ! SOPS_AGE_KEY_FILE="$age_key" "$sops_bin" --decrypt --input-type yaml --output-type yaml \
      "$src/$name" >"$tmp"; then
    echo "sops-decrypt: failed to decrypt $name" >&2
    exit 1
  fi
  if [[ $format == value ]]; then
    # A single-value secret must decrypt to exactly one scalar: a second key or
    # an empty value is a manifest or ciphertext mistake, not something to
    # publish half of.
    if ! value=$(awk '
      /^[[:space:]]*(#|$)/ { next }
      {
        i = index($0, ":")
        if (i <= 1) { bad = 1; exit 2 }
        key = substr($0, 1, i - 1)
        if (key !~ /^[A-Za-z0-9_.-]+$/) { bad = 1; exit 2 }
        val = substr($0, i + 1)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
        if (val ~ /^".*"$/ || val ~ /^\047.*\047$/) val = substr(val, 2, length(val) - 2)
        n++
        out = val
      }
      END { if (bad || n != 1 || out == "") exit 3; print out }
    ' "$tmp"); then
      echo "sops-decrypt: $name is not a single scalar; cannot write it as value" >&2
      exit 1
    fi
    printf '%s\n' "$value" >"$tmp"
  fi
  install -o "$uid" -g "$gid" -m "$mode" "$tmp" "$dst/$name"
  : >"$tmp"
  echo "sops-decrypt: wrote $dst/$name ($uid:$gid $mode $format)"
done < <(awk '!/^[[:space:]]*(#|$)/ { print $1, $2, $3, $4, $5 }' "$manifest")
