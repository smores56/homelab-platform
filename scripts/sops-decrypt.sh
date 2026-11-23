#!/usr/bin/env bash
# Decrypt every listed bundle into /run with least-privilege ownership and mode.
# The age identity and the ciphertext are both root-only on /var, which bootc
# never reconciles: a rotation is an operator write and a restart of this unit,
# not an OS image and a reboot. (The image still carries a set to seed a host
# that has none; see scripts/smortress-secrets-seed.sh.) No plaintext is written
# outside /run.
#
# The manifest is rendered from secrets/index.json by the seed. It has seven
# columns: name bundle key uid gid mode [format]. A five-column line from an
# older image or a fixture is still accepted: bundle = name and key = *.
# `format` is `yaml` (the default; the extracted document is written verbatim)
# or `value` (the extracted scalar is written, which is what a restic password
# file must be).
set -euo pipefail

src=${SMORTRESS_SECRETS_SRC:-/var/lib/smortress/secrets}
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

# The host may hold YAML from before the bundle migration and JSON bundles
# afterwards; both are compared by the bundle name the manifest declares.
unlisted=$(
  find "$src" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.json' \) -printf '%f\n' | sort
)
listed=$(
  awk '
    !/^[[:space:]]*(#|$)/ {
      if (NF >= 7) print $2; else print $1
    }
  ' "$manifest" | sort -u
)
if [[ $unlisted != "$listed" ]]; then
  echo "sops-decrypt: ciphertext set and manifest disagree" >&2
  diff <(printf '%s\n' "$unlisted") <(printf '%s\n' "$listed") >&2 || true
  exit 1
fi

extract() {  # extract <bundle> <key>: write the extracted YAML to $tmp
  local bundle=$1 key=$2 input=yaml path=''
  case $bundle in *.json) input=json ;; esac
  if [[ $key == '*' ]]; then
    SOPS_AGE_KEY_FILE="$age_key" "$sops_bin" --decrypt --input-type "$input" --output-type yaml \
      "$src/$bundle" >"$tmp"
    return
  fi
  local part
  local IFS='.'
  read -ra parts <<<"$key"
  unset IFS
  for part in "${parts[@]}"; do
    [[ $part =~ ^[A-Za-z0-9_-]+$ ]] || {
      echo "sops-decrypt: bad key path for $bundle: $key" >&2
      return 1
    }
    path+="[\"$part\"]"
  done
  SOPS_AGE_KEY_FILE="$age_key" "$sops_bin" --decrypt --input-type "$input" --output-type yaml \
    --extract "$path" "$src/$bundle" >"$tmp"
}

while read -r a b c d e f rest; do
  if [[ $a =~ ^[[:space:]]*(#|$) ]]; then continue; fi
  if [[ -n ${rest:-} && -n ${f:-} ]]; then
    name=$a bundle=$b key=$c uid=$d gid=$e mode=$f format=$rest legacy=0
  else
    name=$a bundle=$a key='*' uid=$b gid=$c mode=$d format=${e:-yaml} legacy=1
  fi
  [[ $name =~ ^[A-Za-z0-9._-]+\.(yaml|json)$ ]] || { echo "sops-decrypt: bad name: $name" >&2; exit 1; }
  [[ $bundle =~ ^[A-Za-z0-9._-]+\.(yaml|json)$ ]] || { echo "sops-decrypt: bad bundle: $bundle" >&2; exit 1; }
  # Only owner-only modes: a manifest typo must not publish a secret
  [[ $mode =~ ^0?[46]00$ ]] || { echo "sops-decrypt: mode must be 0400 or 0600: $mode" >&2; exit 1; }
  format=${format:-yaml}
  case $format in
    yaml | value) ;;
    *) echo "sops-decrypt: unknown format for $name: $format" >&2; exit 1 ;;
  esac
  getent passwd "$uid" >/dev/null || { echo "sops-decrypt: unknown user: $uid" >&2; exit 1; }
  getent group "$gid" >/dev/null || { echo "sops-decrypt: unknown group: $gid" >&2; exit 1; }
  if [[ ! -s $src/$bundle ]]; then
    echo "sops-decrypt: missing ciphertext $bundle" >&2
    exit 1
  fi
  if ! extract "$bundle" "$key"; then
    echo "sops-decrypt: failed to decrypt $name from $bundle" >&2
    exit 1
  fi
  if [[ $format == value ]]; then
    if [[ $legacy == 1 ]]; then
      # A five-column value line decrypted the whole document: its sole key is
      # the value. A second key or an empty value is a manifest mistake.
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
    else
      # A seven-column value line already extracted the scalar; a newline is
      # the only thing sops may add. An empty value or a second line is bad.
      if [[ ! -s $tmp ]] || (($(grep -c '' "$tmp") != 1)); then
        echo "sops-decrypt: $name did not extract to one scalar" >&2
        exit 1
      fi
      value=$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//' "$tmp")
      [[ -n $value ]] || { echo "sops-decrypt: $name extracted to an empty value" >&2; exit 1; }
      printf '%s\n' "$value" >"$tmp"
    fi
  fi
  install -o "$uid" -g "$gid" -m "$mode" "$tmp" "$dst/$name"
  : >"$tmp"
  echo "sops-decrypt: wrote $dst/$name ($uid:$gid $mode $format)"
done < <(awk '!/^[[:space:]]*(#|$)/ { print $1, $2, $3, $4, $5, $6, $7 }' "$manifest")
