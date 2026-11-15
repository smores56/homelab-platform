#!/bin/sh
# Build the NoCloud seed for the smortress autoinstall.
#
# The seed carries three things that never enter git: the SSH public key the
# bootstrap user accepts, the root LUKS passphrase curtin uses at install time,
# and a random keyfile for the data volume. Destroy the seed after the install.

set -eu

here=$(cd -- "$(dirname -- "$0")" && pwd)
release=26.04.1
base_url=https://releases.ubuntu.com/$release

iso=${SMORTRESS_ISO:-"$here/ubuntu-$release-live-server-amd64.iso"}
seed=${SMORTRESS_SEED:-"$here/seed.iso"}
key_file=${SMORTRESS_SSH_KEY:-"$HOME/.ssh/id_ed25519.pub"}
pass_file=${SMORTRESS_ROOT_PASSPHRASE_FILE:-"$HOME/.config/smortress/luks-root.passphrase"}
keyring=${UBUNTU_KEYRING:-}

die() {
  printf 'build-seed: %s\n' "$*" >&2
  exit 1
}

escape_sed() {
  printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'
}

command -v xorriso >/dev/null 2>&1 || die "xorriso is required (nix-shell -p xorriso)"
command -v curl >/dev/null 2>&1 || die "curl is required"
[ -f "$key_file" ] || die "SSH public key not found: $key_file (set SMORTRESS_SSH_KEY)"

if [ ! -f "$pass_file" ]; then
  install -d -m 0700 "$(dirname -- "$pass_file")"
  (umask 077; head -c 48 /dev/urandom | base64 > "$pass_file")
  printf 'Generated %s\n' "$pass_file"
  printf 'Store it in Bitwarden now; it is the root LUKS passphrase.\n'
fi

passphrase=$(tr -d '\n' < "$pass_file")
case "$passphrase" in
  *[!A-Za-z0-9+/=]*) die "$pass_file contains characters outside base64" ;;
esac
[ -n "$passphrase" ] || die "$pass_file is empty"

iso_dir=$(dirname -- "$iso")
iso_name=$(basename -- "$iso")

if [ ! -f "$iso" ]; then
  printf 'Fetching %s\n' "$base_url/$iso_name"
  curl -fL --retry 3 -o "$iso" "$base_url/$iso_name"
  curl -fsSL -o "$iso_dir/SHA256SUMS" "$base_url/SHA256SUMS"
  curl -fsSL -o "$iso_dir/SHA256SUMS.gpg" "$base_url/SHA256SUMS.gpg"
fi

# Ubuntu CD Image Automatic Signing Key (2012), published at
# https://documentation.ubuntu.com/security/software-integrity/image-verification
cdimage_fpr=843938DF228D22F7B3742BC0D94AA3F0EFE21092

if [ -f "$iso_dir/SHA256SUMS" ]; then
  if [ -z "$keyring" ]; then
    for candidate in \
      /usr/share/keyrings/ubuntu-archive-keyring.gpg \
      /usr/share/keyrings/ubuntu-keyring-2012-cdimage.gpg \
      /etc/apt/trusted.gpg.d/ubuntu-keyring-2012-cdimage.gpg; do
      if [ -f "$candidate" ]; then
        keyring=$candidate
        break
      fi
    done
  fi
  if [ -z "$keyring" ]; then
    keyring=$iso_dir/ubuntu-archive-keyring.gpg
    if [ ! -f "$keyring" ]; then
      printf 'Fetching the Ubuntu image signing keyring\n'
      curl -fsSL -o "$keyring" https://archive.ubuntu.com/ubuntu/project/ubuntu-archive-keyring.gpg \
        || die "could not fetch the Ubuntu image signing keyring"
    fi
  fi
  if [ -f "$iso_dir/SHA256SUMS.gpg" ]; then
    gpg --no-default-keyring --keyring "$keyring" --with-colons --list-keys 2>/dev/null \
      | awk -F: '$1 == "fpr" { print $10 }' | grep -qx "$cdimage_fpr" \
      || die "$keyring does not hold the pinned image signing key $cdimage_fpr"
    status=$(gpgv --keyring "$keyring" --status-fd 1 \
      "$iso_dir/SHA256SUMS.gpg" "$iso_dir/SHA256SUMS" 2>/dev/null) \
      || die "SHA256SUMS signature did not verify against $keyring"
    printf '%s\n' "$status" | grep -q "^\[GNUPG:\] VALIDSIG $cdimage_fpr " \
      || die "SHA256SUMS was not signed by the pinned image signing key"
  elif [ "${SMORTRESS_SKIP_SIGNATURE:-0}" != "1" ]; then
    die "missing $iso_dir/SHA256SUMS.gpg; re-run with the network available or SMORTRESS_SKIP_SIGNATURE=1 for checksum only"
  fi
  (cd "$iso_dir" && grep -F "$iso_name" SHA256SUMS > SHA256SUMS.iso && sha256sum -c SHA256SUMS.iso) \
    || die "ISO checksum mismatch"
  rm -f "$iso_dir/SHA256SUMS.iso"
else
  die "missing SHA256SUMS next to $iso; delete the ISO and re-run to fetch it"
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

esc_pass=$(escape_sed "$passphrase")
esc_key=$(escape_sed "$(tr -d '\n' < "$key_file")")
sed -e "s|__LUKS_ROOT_PASSPHRASE__|$esc_pass|" \
  -e "s|__SSH_AUTHORIZED_KEY__|$esc_key|" \
  "$here/user-data" > "$work/user-data"
cp "$here/meta-data" "$work/meta-data"

xorriso -as mkisofs -quiet -volid cidata -joliet -rock \
  -output "$seed" "$work/user-data" "$work/meta-data"

printf 'Seed written to %s\n' "$seed"
printf 'It contains the root LUKS passphrase. Destroy it after the install.\n'
