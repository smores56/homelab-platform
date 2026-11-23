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
# host copy is replaced on every run. bootc merges /etc once per deployment and
# keeps what the host already had, so a manifest line a later image added never
# reached an existing host: on 2026-11-22 the seed copied two new ciphertexts
# while /etc still listed the old set, and sops-decrypt failed "ciphertext set and
# manifest disagree" for every consumer until an operator appended the lines by
# hand. With this copy a new line is a boot, and an /etc edit is neither needed
# nor kept.
set -euo pipefail

baked=${SMORTRESS_SECRETS_BAKED:-/etc/smortress/secrets}
dst=${SMORTRESS_SECRETS_SRC:-/var/lib/smortress/secrets}
baked_manifest=${SMORTRESS_SECRETS_IMAGE_MANIFEST:-/usr/share/smortress/secrets.manifest}
manifest=${SMORTRESS_SECRETS_MANIFEST:-/etc/smortress/secrets.manifest}

tmp=''
cleanup() {
  [[ -n $tmp ]] && rm -f -- "$tmp"
  return 0
}
trap cleanup EXIT

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
files=("$baked"/*.yaml)
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

# Replace the host manifest from the image. Unconditional in what it accepts and
# idempotent in what it writes: an unchanged file is left alone so a boot does no
# I/O, and a changed one is renamed into place so a crash never leaves half a
# manifest for the next boot to fail on. An image that carries no manifest leaves
# the host copy alone -- that is the release that drops the baked set, and a
# rollback to an image which only ever read /etc must still find one there.
if [[ -s $baked_manifest ]]; then
  manifest_dir=$(dirname -- "$manifest")
  install -d -m 0755 "$manifest_dir"
  if ! cmp -s -- "$baked_manifest" "$manifest" 2>/dev/null; then
    tmp=$(mktemp "$manifest_dir/.secrets.manifest.XXXXXX")
    install -m 0644 -- "$baked_manifest" "$tmp"
    mv -f -- "$tmp" "$manifest"
    tmp=''
    printf 'sops-decrypt: replaced %s from %s\n' "$manifest" "$baked_manifest" >&2
  fi
fi
