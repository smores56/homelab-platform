#!/usr/bin/env bash
# Seed the root-only host state from what the image carries: the ciphertext set
# and the manifest that names it.
#
# The ciphertext a boot unit decrypts used to live only in the image, so every
# rotation rebuilt the OS and needed a deploy. It belongs in /var instead, which
# bootc never reconciles and which an operator (not a publish) writes. This runs
# once, as sops-decrypt's ExecStartPre, and copies the baked set into that path
# only when the path holds no ciphertext yet: an existing file is a rotation or a
# previous boot, and copying over it would silently reinstate the older value.
#
# A release after this one drops the baked set; with nothing to seed this is a
# no-op, which is why it can stay in the unit until then.
#
# The manifest is the other half, and it is the opposite rule: it holds metadata
# (name, owner, group, mode, format), never a secret, so the image owns it and the
# host copy is replaced on every run. It is rendered from the image's index, so a
# new line is a boot and an /etc edit is neither needed nor kept.
#
# 2026-11-22: the seed copied two new ciphertexts while /etc still listed the old
# set, and sops-decrypt failed "ciphertext set and manifest disagree" for every
# consumer until an operator appended the lines by hand. The same failure appears
# in reverse when a set is renamed: an old file that the new index does not name
# is retired, never deleted, and `--rollback` puts it back.
set -euo pipefail

baked=${SMORTRESS_SECRETS_BAKED:-/etc/smortress/secrets}
dst=${SMORTRESS_SECRETS_SRC:-/var/lib/smortress/secrets}
baked_index=${SMORTRESS_SECRETS_IMAGE_INDEX:-/usr/share/smortress/secrets.index.json}
baked_manifest=${SMORTRESS_SECRETS_IMAGE_MANIFEST:-/usr/share/smortress/secrets.manifest}
manifest=${SMORTRESS_SECRETS_MANIFEST:-/etc/smortress/secrets.manifest}
retired=${SMORTRESS_SECRETS_RETIRED:-/var/lib/smortress/secrets.retired}
index_bin=${SMORTRESS_INDEX_BIN:-/usr/libexec/secrets-index}

tmp=''
cleanup() {
  [[ -n $tmp ]] && rm -f -- "$tmp"
  return 0
}
trap cleanup EXIT

rollback() {
  local run file name
  # shellcheck disable=SC2012  # the run names are a timestamp and mktemp suffix
  run=$(ls -1d -- "$retired"/*/ 2>/dev/null | sort | tail -n 1) || true
  if [[ -z $run ]]; then
    printf 'sops-decrypt: no retired ciphertext to restore under %s\n' "$retired" >&2
    exit 1
  fi
  install -d -m 0700 "$dst"
  for file in "$run"/*.yaml "$run"/*.json; do
    [[ -e $file ]] || continue
    name=$(basename -- "$file")
    if [[ -e $dst/$name ]]; then
      printf 'sops-decrypt: refusing to overwrite %s during rollback\n' "$dst/$name" >&2
      exit 1
    fi
    mv -- "$file" "$dst/$name"
  done
  rmdir -- "$run" 2>/dev/null || true
  printf 'sops-decrypt: restored the ciphertext retired in %s\n' "$run" >&2
  exit 0
}

if [[ ${1:-} == --rollback ]]; then
  rollback
fi

# The host copy is authoritative per file: an existing file is a rotation or a
# previous boot and is never overwritten, while a *missing* one is a secret the
# image added since the last boot. Seeding only an empty directory left exactly
# that case broken -- the manifest listed the new file, the host did not have it,
# and the decrypt's set check failed every consumer for a file sitting in the
# image.
#
# Runs as root (the unit is root's), so the copies are root-owned by
# construction; `install -m` keeps the source's 0600 and the destination's 0700.
seeded=0
shopt -s nullglob
files=("$baked"/*.yaml "$baked"/*.json)
if ((${#files[@]})); then
  install -d -m 0700 "$dst"
  for file in "${files[@]}"; do
    name=$(basename -- "$file")
    [[ -e $dst/$name ]] && continue
    install -m 0600 -- "$file" "$dst/$name"
    seeded=$((seeded + 1))
  done
  if ((seeded)); then
    printf 'sops-decrypt: seeded %d ciphertext file(s) into %s\n' "$seeded" "$dst" >&2
  fi
fi

# Retire, never delete, a ciphertext the image's index does not name. This is
# what makes a rename (one file per secret to bundles, or a removed secret)
# survive the next boot: the decrypt's set check stays exact, and `--rollback`
# can put the old set back.
declare -A keep=()
if [[ -s $baked_index && -x $index_bin ]] && bundles=$("$index_bin" bundles --index "$baked_index"); then
  while IFS= read -r bundle; do
    [[ -n $bundle ]] && keep[$bundle]=1
  done <<<"$bundles"
  run=''
  moved=0
  for file in "$dst"/*.yaml "$dst"/*.json; do
    name=$(basename -- "$file")
    [[ -n ${keep[$name]:-} ]] && continue
    if [[ -z $run ]]; then
      install -d -m 0700 "$retired"
      run=$(mktemp -d "$retired/$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")
    fi
    mv -- "$file" "$run/$name"
    moved=$((moved + 1))
  done
  if ((moved)); then
    printf 'sops-decrypt: retired %d unlisted ciphertext file(s) into %s\n' "$moved" "$run" >&2
  fi
fi

# Replace the host manifest from the index, or from the image manifest when the
# image predates the index. Idempotent in what it writes: an unchanged file is
# left alone, and a changed one is renamed into place so a crash never leaves
# half a manifest for the next boot to fail on.
manifest_dir=$(dirname -- "$manifest")
install -d -m 0755 "$manifest_dir"
tmp=$(mktemp "$manifest_dir/.secrets.manifest.XXXXXX")
if [[ -s $baked_index && -x $index_bin ]]; then
  "$index_bin" render-manifest --index "$baked_index" --out "$tmp"
elif [[ -s $baked_manifest ]]; then
  install -m 0644 -- "$baked_manifest" "$tmp"
else
  rm -f -- "$tmp"
  tmp=''
  exit 0
fi
if cmp -s -- "$tmp" "$manifest" 2>/dev/null; then
  rm -f -- "$tmp"
  tmp=''
else
  mv -f -- "$tmp" "$manifest"
  tmp=''
  printf 'sops-decrypt: replaced %s\n' "$manifest" >&2
fi
