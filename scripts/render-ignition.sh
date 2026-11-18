#!/usr/bin/env bash
# Render the smortress Butane source into an Ignition config.
#
#   scripts/render-ignition.sh --check            # validate real operator values
#   scripts/render-ignition.sh                   # write ignition/smortress.ign
#   scripts/render-ignition.sh --synthetic --check  # CI: fixtures, no operator data
#
# Every value the template needs comes from a file under ignition/operator/
# (gitignored) except the public cosign key and the Tang URL default. Nothing
# here reads a private key. The rendered Ignition contains the two LUKS recovery
# passphrases: it is written mode 0600 and is removed by FCOS after first boot.
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../image/pins.env disable=SC1091
source "$repo/image/pins.env"

synthetic=false
# --stock is only for uCore installer media: it installs onto the pinned base
# and drops the autorebase units. Plain FCOS media needs those units to reach
# uCore at all; the FCOS → uCore transition is the supported path, not a
# direct bootc switch. Unused for the smortress install on FCOS media.
stock=false
check=false
output="$repo/ignition/smortress.ign"

usage() {
  cat <<'EOF' >&2
usage: render-ignition.sh [--check] [--synthetic] [--stock] [--output FILE]
  --check      validate with butane instead of writing output
  --synthetic  use committed fixtures; no ignition/operator values required
  --stock      uCore installer media only: install onto the pinned base and drop
               the autorebase units. Plain FCOS media MUST keep them.
  --output     output path (default: ignition/smortress.ign)
EOF
  exit 2
}

while (($#)); do
  case "$1" in
    --check) check=true ;;
    --synthetic) synthetic=true ;;
    --stock) stock=true ;;
    --output) output=${2:?--output needs a value}; shift ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
  shift
done

butane=${BUTANE:-butane}
if ! command -v "$butane" >/dev/null 2>&1; then
  echo "butane is not installed; run this under 'nix shell nixpkgs#butane' or set BUTANE" >&2
  exit 1
fi

die() { echo "render-ignition: $*" >&2; exit 1; }
escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//&/\\&}
  s=${s//|/\\|}
  printf '%s' "$s"
}

require_file() { [[ -s $1 ]] || die "missing or empty operator file: $1"; }
read_line() { local v=""; IFS= read -r v <"$1" || true; printf '%s' "$v"; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
files_dir=$repo
template=$repo/ignition/smortress.bu

if $synthetic; then
  files_dir=$tmp
  template=$tmp/ignition/smortress.bu
  mkdir -p "$tmp/ignition/operator" "$tmp/image/rootfs/etc/containers/registries.d" "$tmp/image/rootfs/etc/containers"
  cp "$repo/ignition/smortress.bu" "$template"
  cp "$repo/ignition/smortress-authorized-keys" "$tmp/ignition/smortress-authorized-keys"
  cp "$repo/image/rootfs/etc/containers/policy.json" "$tmp/image/rootfs/etc/containers/policy.json"
  cp "$repo/image/rootfs/etc/containers/registries.d/ghcr.io-smortress.yaml" \
    "$tmp/image/rootfs/etc/containers/registries.d/ghcr.io-smortress.yaml"
  cp "$repo/tests/fixtures/cosign.pub" "$tmp/image/cosign.pub"
  printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureOnlyForButaneValidation smortress-fixture' \
    >"$tmp/ignition/operator/ssh_authorized_keys"
  derived_image="${IMAGE_REPO}@sha256:0000000000000000000000000000000000000000000000000000000000000000"
  disk='/dev/disk/by-id/nvme-SyntheticDisk'
  password_hash="\$6\$synthetic\$aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  root_pass='synthetic-root-recovery-passphrase-000000000000000000000000'
  data_pass='synthetic-data-recovery-passphrase-000000000000000000000000'
  tang_url='http://10.0.0.193:7654'
  tang_thumbprint=$(printf 'A%.0s' {1..43})
else
  require_file "$repo/image/cosign.pub"
  for f in derived-image disk smores-password-hash root-recovery-passphrase \
    data-recovery-passphrase tang-thumbprint ssh_authorized_keys; do
    require_file "$repo/ignition/operator/$f"
  done
  if $stock; then
    derived_image=$UCORE_IMAGE
  else
    derived_image=$(read_line "$repo/ignition/operator/derived-image")
  fi
  disk=$(read_line "$repo/ignition/operator/disk")
  password_hash=$(read_line "$repo/ignition/operator/smores-password-hash")
  root_pass=$(read_line "$repo/ignition/operator/root-recovery-passphrase")
  data_pass=$(read_line "$repo/ignition/operator/data-recovery-passphrase")
  tang_url='http://10.0.0.193:7654'
  if [[ -s $repo/ignition/operator/tang-url ]]; then
    tang_url=$(read_line "$repo/ignition/operator/tang-url")
  fi
  tang_thumbprint=$(read_line "$repo/ignition/operator/tang-thumbprint")
  require_file "$repo/ignition/operator/ssh_authorized_keys"
fi

[[ $derived_image =~ ^[a-z0-9][a-z0-9./-]*@sha256:[0-9a-f]{64}$ ]] \
  || die "derived image must be <registry>/<repo>@sha256:<digest>: $derived_image"
if ! $stock && [[ $derived_image == "$UCORE_IMAGE" ]]; then
  die "derived image equals the pinned base; publish it first, or use --stock on uCore installer media"
fi
[[ $disk =~ ^/dev/disk/by-id/[A-Za-z0-9._:-]+$ ]] \
  || die "disk must be a /dev/disk/by-id path: $disk"
[[ $password_hash =~ ^\$6\$[^$]{1,16}\$[./A-Za-z0-9]{86}$ ]] \
  || die "smores password hash must be sha512crypt (openssl passwd -6)"
[[ $root_pass =~ ^[[:print:]]{12,}$ ]] \
  || die "root recovery passphrase must be >=12 printable characters and one line"
[[ $data_pass =~ ^[[:print:]]{12,}$ ]] \
  || die "data recovery passphrase must be >=12 printable characters and one line"
[[ $tang_url =~ ^https?://[A-Za-z0-9.:-]+$ ]] \
  || die "Tang URL must be http(s)://host:port: $tang_url"
[[ $tang_thumbprint =~ ^[A-Za-z0-9_-]{43}$ ]] \
  || die "Tang thumbprint must be 43 base64url characters: $tang_thumbprint"

work=$tmp/smortress.bu
cp "$template" "$work"
# The substitutions carry the passphrases, so they go through a 0600 script
# file instead of sed's argv, which /proc exposes to every local user.
subs=$tmp/subs.sed
umask 077
printf '%s\n' \
  "s|@DERIVED_IMAGE@|$(escape "$derived_image")|g" \
  "s|@DISK_BY_ID@|$(escape "$disk")|g" \
  "s|@SMORES_PASSWORD_HASH@|$(escape "$password_hash")|g" \
  "s|@ROOT_RECOVERY_PASSPHRASE@|$(escape "$root_pass")|g" \
  "s|@DATA_RECOVERY_PASSPHRASE@|$(escape "$data_pass")|g" \
  "s|@TANG_URL@|$(escape "$tang_url")|g" \
  "s|@TANG_THUMBPRINT@|$(escape "$tang_thumbprint")|g" >"$subs"
sed -i -f "$subs" "$work"
rm -f "$subs"

if $stock; then
  sed -i '/# BEGIN AUTOREBASE/,/# END AUTOREBASE/d' "$work"
  if grep -q 'rpm-ostree rebase' "$work"; then
    die "--stock left an autorebase unit in the rendered config"
  fi
fi

if grep -nE '@[A-Z_]+@' "$work" >/dev/null; then
  grep -nE '@[A-Z_]+@' "$work" >&2
  die "unsubstituted placeholder remains"
fi

if command -v "$butane" >/dev/null 2>&1; then
  if ! "$butane" --version 2>/dev/null | grep -q '0\.29\.'; then
    echo "render-ignition: warning: butane is not the pinned 0.29.x" >&2
  fi
fi

if $check; then
  "$butane" --check --strict --files-dir "$files_dir" "$work"
  echo "render-ignition: butane accepted $template"
  exit 0
fi

umask 077
"$butane" --pretty --strict --files-dir "$files_dir" "$work" >"$output"
chmod 0600 "$output"
echo "wrote $output" >&2
printf 'next: sudo coreos-installer install %s --ignition-file %s --append-karg ip=dhcp --append-karg rd.neednet=1\n' \
  "$disk" "$output" >&2
