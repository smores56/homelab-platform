#!/usr/bin/env bash
# Render a Butane source into an Ignition config.
#
#   scripts/render-ignition.sh --check            # validate real operator values
#   scripts/render-ignition.sh                   # write ignition/smortress.ign
#   scripts/render-ignition.sh --synthetic --check  # CI: fixtures, no operator data
#   scripts/render-ignition.sh --no-account      # write ignition/edge.json (public)
#
# --no-account renders the edge's document (design #939): no console account, no
# sops, and no `--check` fixture fallback, because that document is committed to
# a public repository and a synthetic hash in it would be published rather than
# caught. Its image reference comes from EDGE_REF and must be a resolved
# digest; the output is mode 0644 and its sha512 is what the install passes as
# --ignition-hash.
#
# Every value the smortress template needs comes from a file under
# ignition/operator/ (gitignored) except the public cosign key, the Tang URL
# default and the smores account password hash. The hash is image ciphertext
# (secrets/boot.json, key smores.password_hash): the same value is re-applied at boot
# by units/systemd/smortress-password.service, so a reinstall must not need an
# operator file. Nothing here reads a private key and nothing here reads a
# recovery passphrase: no secret enters Ignition or the installer media (design
# #701), and the operator adds both LUKS passphrases after the install
# (hosts/server/runbook.md, "Add the offline recovery passphrases"). The smortress render still carries
# the account hash, so it is written mode 0600 and removed by FCOS after first
# boot; the edge render carries no secret, and 0644 is what lets it be committed.
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../bootc/lib/pins.env disable=SC1091
source "$repo/bootc/lib/pins.env"

synthetic=false
no_account=false
# --stock is only for uCore installer media: it installs onto the base and drops
# the autorebase units. Plain FCOS media needs those units to reach uCore at all;
# the FCOS → uCore transition is the supported path, not a direct bootc switch.
# Unused for the smortress install on FCOS media.
stock=false
check=false
# Resolved after the flags, because the default depends on the mode.
output=''

usage() {
  cat <<'EOF' >&2
usage: render-ignition.sh [--check] [--synthetic] [--stock] [--no-account] [--output FILE]
  --check      validate with butane instead of writing output
  --synthetic  use committed fixtures; no ignition/operator values required
  --stock      uCore installer media only: install onto the base and drop the
               autorebase units. Plain FCOS media MUST keep them.
  --no-account render ignition/edge.bu: the public, committed edge document.
               No console account, no sops, no fixture fallback, and the image
               reference must come from EDGE_REF as a resolved digest.
  --output     output path (default: ignition/smortress.ign, or
               ignition/edge.json with --no-account)
EOF
  exit 2
}

while (($#)); do
  case "$1" in
    --check) check=true ;;
    --synthetic) synthetic=true ;;
    --stock) stock=true ;;
    --no-account) no_account=true ;;
    --output) output=${2:?--output needs a value}; shift ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
  shift
done

if [[ -z $output ]]; then
  if $no_account; then
    output=$repo/ignition/edge.json
  else
    output=$repo/ignition/smortress.ign
  fi
fi

butane=${BUTANE:-butane}
if ! command -v "$butane" >/dev/null 2>&1; then
  echo "butane is not installed; install butane or set BUTANE" >&2
  exit 1
fi
sops_bin=${SOPS_BIN:-sops}
hash_ciphertext=$repo/secrets/boot.json

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

# Both flags produce a value the edge document must never carry: --synthetic
# substitutes a fixture digest, --stock installs onto the uCore base instead of
# the published edge digest, and either would be committed as if a host ran it.
# Refused before any input is read, so the refusal is the whole answer.
if $no_account && $synthetic; then
  die "--no-account refuses --synthetic: the edge document is published, so a fixture render would commit a digest no image was pushed to"
fi
if $no_account && $stock; then
  die "--no-account refuses --stock: the edge install rebases onto the published edge digest, not onto the base"
fi

# sha512crypt: $6$<salt>$<86 base64-ish characters>. Synthetic mode and a --check
# that cannot decrypt use it, so the template still renders to a valid hash.
fixture_hash="\$6\$synthetic\$aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

# The hash comes from ciphertext, not from the operator tree: sops resolves its
# identity itself (SOPS_AGE_KEY_FILE, SOPS_AGE_KEY_CMD or the default key file),
# so this script never handles a key. The key name matches what the mint command
# in hosts/server/runbook.md writes; the manifest's `value` format is
# what hands the bare hash to the boot unit.
read_password_hash() {
  "$sops_bin" --decrypt --extract '["smores"]["password_hash"]' "$hash_ciphertext" 2>"$tmp/sops.err"
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
template=$repo/ignition/smortress.bu

if $no_account; then
  # The edge's document: no secret to read, no account to splice, and the
  # resolved reference supplied by the publisher. A template that carried the
  # hash placeholder would be reachable only through sops or the fixture, so it
  # is refused here rather than rendered.
  template=$repo/ignition/edge.bu
  require_file "$template"
  [[ -s $repo/lib/containers/cosign.pub ]] \
    || die "lib/containers/cosign.pub is missing; the document installs it as the key its policy trusts"
  derived_image=${EDGE_REF:-}
  [[ -n $derived_image ]] \
    || die "--no-account needs EDGE_REF=<registry>/<repo>@sha256:<digest>: the published edge digest, pinned after the signature verifies"
  if grep -qF '@SMORES_PASSWORD_HASH@' "$template"; then
    die "$template carries an account hash placeholder; the edge document has no account, and the only values that could fill it are a sops decrypt or a fixture"
  fi
elif $synthetic; then
  template=$tmp/ignition/smortress.bu
  mkdir -p "$tmp/ignition"
  cp "$repo/ignition/smortress.bu" "$template"
  derived_image="${IMAGE_REPO}@sha256:0000000000000000000000000000000000000000000000000000000000000000"
  disk='/dev/disk/by-id/nvme-SyntheticDisk'
  password_hash=$fixture_hash
  tang_url='http://10.0.0.193:7654'
  tang_thumbprint=$(printf 'A%.0s' {1..43})
else
  require_file "$repo/lib/containers/cosign.pub"
  for f in derived-image disk tang-thumbprint ssh_authorized_keys; do
    require_file "$repo/ignition/operator/$f"
  done
  command -v "$sops_bin" >/dev/null 2>&1 \
    || die "sops is not installed; install sops or set SOPS_BIN"
  if $stock; then
    # The base is a stream tag and Ignition takes a digest only, so the tag is
    # resolved here: a render that cannot reach the registry fails instead of
    # writing a tag into a deployment reference.
    command -v skopeo >/dev/null 2>&1 \
      || die "--stock resolves the uCore tag to a digest; install skopeo"
    base_digest=$(skopeo inspect --format '{{.Digest}}' "docker://$UCORE_IMAGE") \
      || die "cannot resolve ${UCORE_IMAGE} to a digest; the installer must boot a digest"
    derived_image="${UCORE_IMAGE%%:*}@${base_digest}"
  else
    derived_image=$(read_line "$repo/ignition/operator/derived-image")
  fi
  disk=$(read_line "$repo/ignition/operator/disk")
  if ! password_hash=$(read_password_hash); then
    # --check only proves the template and the plan render; the real render is the
    # one that must not substitute anything for the owner's hash.
    if $check; then
      password_hash=$fixture_hash
      echo "render-ignition: warning: could not read the account hash from ${hash_ciphertext#"$repo"/}" >&2
      echo "render-ignition: warning: --check validates the template with a fixture hash; the install render needs the ciphertext and an age identity" >&2
    else
      sed 's/^/  /' "$tmp/sops.err" >&2 || true
      die "cannot read the smores password hash from ${hash_ciphertext#"$repo"/}; mint it with sops (hosts/server/runbook.md) and re-run with SOPS_AGE_KEY_FILE pointing at the admin identity"
    fi
  fi
  tang_url='http://10.0.0.193:7654'
  if [[ -s $repo/ignition/operator/tang-url ]]; then
    tang_url=$(read_line "$repo/ignition/operator/tang-url")
  fi
  tang_thumbprint=$(read_line "$repo/ignition/operator/tang-thumbprint")
  require_file "$repo/ignition/operator/ssh_authorized_keys"
fi

[[ $derived_image =~ ^[a-z0-9][a-z0-9./-]*@sha256:[0-9a-f]{64}$ ]] \
  || die "derived image must be <registry>/<repo>@sha256:<digest>: $derived_image"
# The base is a tag, so the reference is compared by repository: a derived image
# that names the uCore repository is the base itself, not a published build.
if ! $stock && [[ ${derived_image%@*} == "${UCORE_IMAGE%%:*}" ]]; then
  die "derived image is the uCore base itself; publish the derived image first, or use --stock on uCore installer media"
fi
# The remaining references are the smortress install's: the edge has no disk,
# no Tang binding and no account, so it has nothing here to validate.
if ! $no_account; then
  [[ $disk =~ ^/dev/disk/by-id/[A-Za-z0-9._:-]+$ ]] \
    || die "disk must be a /dev/disk/by-id path: $disk"
  [[ $password_hash =~ ^\$6\$[^$]{1,16}\$[./A-Za-z0-9]{86}$ ]] \
    || die "the smores password hash must be sha512crypt (openssl passwd -6)"
  [[ $tang_url =~ ^https?://[A-Za-z0-9.:-]+$ ]] \
    || die "Tang URL must be http(s)://host:port: $tang_url"
  [[ $tang_thumbprint =~ ^[A-Za-z0-9_-]{43}$ ]] \
    || die "Tang thumbprint must be 43 base64url characters: $tang_thumbprint"
fi

# Every file a template names as `contents.local:` is resolved under --files-dir,
# and the containers policy is not one of them: it is rendered from the shared
# contract and this host's registry table (lib/containers), so no tracked file
# holds the finished document. The render therefore stages its own files dir in
# every mode -- real, --check and --synthetic -- at the relative paths the
# templates name, so all three read one shape and the document the installer
# writes is the one the image renders.
files_dir=$tmp/files
mkdir -p "$files_dir/lib/containers/registries.d" "$files_dir/ignition/operator" \
  "$files_dir/bootc/server/rootfs/etc/ssh/authorized_keys.d"
"$repo/lib/containers/render-policy.sh" smortress >"$files_dir/lib/containers/policy.json"
cp "$repo/lib/containers/registries.d/ghcr.io-smortress.yaml" \
  "$files_dir/lib/containers/registries.d/ghcr.io-smortress.yaml"
cp "$repo/bootc/server/rootfs/etc/ssh/authorized_keys.d/smores" \
  "$files_dir/bootc/server/rootfs/etc/ssh/authorized_keys.d/smores"
# A synthetic render must not be mistakable for a real one, so it carries the
# fixture key rather than the operator's public one.
if $synthetic; then
  cp "$repo/tests/fixtures/cosign.pub" "$files_dir/lib/containers/cosign.pub"
  printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureOnlyForButaneValidation smortress-fixture' \
    >"$files_dir/ignition/operator/ssh_authorized_keys"
else
  cp "$repo/lib/containers/cosign.pub" "$files_dir/lib/containers/cosign.pub"
  if ! $no_account; then
    cp "$repo/ignition/operator/ssh_authorized_keys" "$files_dir/ignition/operator/ssh_authorized_keys"
  fi
fi

work=$tmp/$(basename -- "$template")
cp "$template" "$work"
# The account hash is the one secret in the output, so it goes through a 0600
# script file instead of sed's argv, which /proc exposes to every local user.
subs=$tmp/subs.sed
umask 077
printf '%s\n' \
  "s|@DERIVED_IMAGE@|$(escape "$derived_image")|g" >"$subs"
if ! $no_account; then
  printf '%s\n' \
    "s|@DISK_BY_ID@|$(escape "$disk")|g" \
    "s|@SMORES_PASSWORD_HASH@|$(escape "$password_hash")|g" \
    "s|@TANG_URL@|$(escape "$tang_url")|g" \
    "s|@TANG_THUMBPRINT@|$(escape "$tang_thumbprint")|g" >>"$subs"
fi
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

if $no_account; then
  # Public by construction and committed: the operator reads the file over
  # raw.githubusercontent.com, so 0644 is the point, not an oversight, and the
  # hash the install pins is computed from the file in the tree rather than
  # transcribed from a CI log.
  umask 022
  "$butane" --pretty --strict --files-dir "$files_dir" "$work" >"$output"
  chmod 0644 "$output"
  echo "wrote $output" >&2
  printf 'sha512 %s: sha512-%s\n' "$output" "$(sha512sum -- "$output" | cut -d' ' -f1)" >&2
  echo "next: pass that value as --ignition-hash on the install line in bootc/edge/runbook.md, \"Install the edge from the live ISO\"" >&2
  exit 0
fi

umask 077
"$butane" --pretty --strict --files-dir "$files_dir" "$work" >"$output"
chmod 0600 "$output"
echo "wrote $output" >&2
printf 'next: sudo coreos-installer install %s --ignition-file %s --append-karg ip=dhcp --append-karg rd.neednet=1\n' \
  "$disk" "$output" >&2
