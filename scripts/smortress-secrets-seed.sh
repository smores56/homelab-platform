#!/usr/bin/env bash
# Seed the root-only host ciphertext from the set the image carries.
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
set -euo pipefail

baked=${SMORTRESS_SECRETS_BAKED:-/etc/smortress/secrets}
dst=${SMORTRESS_SECRETS_SRC:-/var/lib/smortress/secrets}

[[ -d $baked ]] || exit 0
shopt -s nullglob
files=("$baked"/*.yaml)
((${#files[@]})) || exit 0

# The host copy is authoritative per file: an existing file is a rotation or a
# previous boot and is never overwritten, while a *missing* one is a secret the
# image added since the last boot. Seeding only an empty directory left exactly
# that case broken -- the manifest listed the new file, the host did not have it,
# and the decrypt's set check failed every consumer for a file sitting in the
# image.
#
# Runs as root (the unit is root's), so the copies are root-owned by
# construction; `install -m` keeps the source's 0600 and the destination's 0700.
install -d -m 0700 "$dst"
seeded=0
for file in "${files[@]}"; do
  name=$(basename -- "$file")
  [[ -e $dst/$name ]] && continue
  install -m 0600 -- "$file" "$dst/$name"
  seeded=$((seeded + 1))
done
((seeded)) || exit 0
printf 'sops-decrypt: seeded %d ciphertext file(s) into %s\n' "$seeded" "$dst" >&2
