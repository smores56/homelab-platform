#!/usr/bin/env bash
# Static checks for the smortress autoinstall artifact (SDLC #680 T6.1).
#
# No ISO, no QEMU, no network: it proves the shape of the installer config,
# the seed builder's secret handling and the first-boot units.
#
#   nix-shell -p python3 yamllint shellcheck --run 'tests/provision/check.sh'
set -uo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root" || exit 1

pass=0
fail=0
skipped=0

ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; }
skipped() { skipped=$((skipped + 1)); printf 'skip %s\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

d=provision/smortress

# --- required files ---------------------------------------------------------
for f in user-data meta-data build-seed.sh iso.sha256 qemu-spike.sh README.md \
         units/smortress-provision.service units/smortress-provision.sh \
         units/zpool-import-tank.service units/zpool-import-tank.sh; do
  if [[ -f "$d/$f" ]]; then ok "file $d/$f"; else bad "file $d/$f is missing"; fi
done

ud=$d/user-data
if [[ -f $ud ]]; then
  [[ $(head -1 "$ud") == '#cloud-config' ]] && ok "user-data starts with #cloud-config" \
    || bad "user-data first line must be #cloud-config"

  for needle in 'autoinstall:' 'version: 1' 'identity:' 'username: smores' \
                '@ADMIN_PASSWORD_HASH@' 'hostname: smortress' \
                'dm_name: luks-root' 'dm_name: luks-data' \
                '@ROOT_PASSPHRASE@' 'keyfile: /etc/luks/data.key' \
                'path: /boot/efi' 'path: /' 'install-server: true' \
                'allow-pw: false' 'authorized-keys:' '@ADMIN_KEY@' \
                'shutdown: reboot' 'error-commands:' \
                '@LATE_COMMANDS@' 'grub_device: true' 'wipe: superblock' \
                'luks-root UUID=' 'luks-data UUID=' 'cryptsetup-initramfs'; do
    grep -qF -- "$needle" "$ud" && ok "user-data has ${needle}" \
      || bad "user-data is missing ${needle}"
  done

  # The data mapper stays unformatted: no format action may reference it.
  if grep -nE 'type: format' "$ud" | grep -q 'crypt-data'; then
    bad "user-data formats the data mapper"
  else
    ok "user-data leaves luks-data unformatted"
  fi

  for pkg in linux-modules-zfs-generic zfsutils-linux zfs-zed openssh-server \
             python3 clevis clevis-initramfs cryptsetup cryptsetup-initramfs; do
    grep -qE "^[[:space:]]+- ${pkg}\$" "$ud" && ok "packages include $pkg" \
      || bad "packages are missing $pkg"
  done
  for banned in zfs-initramfs nvidia-driver-580; do
    grep -qE "^[[:space:]]+- ${banned}\$" "$ud" && bad "packages must not include $banned" \
      || ok "packages exclude $banned"
  done

  # Secret policy: tokens only. A literal crypt hash or key would be a leak.
  grep -qE '\$[56y]\$' "$ud" && bad "user-data contains a literal crypt hash" \
    || ok "user-data contains no literal crypt hash"
  grep -qi 'NOPASSWD' "$ud" && bad "user-data grants NOPASSWD" \
    || ok "user-data grants no NOPASSWD"
  grep -qE 'ssh-(ed25519|rsa) AAAA' "$ud" && bad "user-data contains a literal ssh key" \
    || ok "user-data contains no literal ssh key"
else
  skipped "user-data assertions (file missing)"
fi

# --- ISO pin ----------------------------------------------------------------
if [[ -f $d/iso.sha256 ]]; then
  line=$(grep -v '^[[:space:]]*$' "$d/iso.sha256")
  if [[ $(printf '%s\n' "$line" | wc -l) -eq 1 ]] \
     && [[ $line =~ ^[0-9a-f]{64}\ \*ubuntu-26\.04\.1-live-server-amd64\.iso$ ]]; then
    ok "iso.sha256 pins exactly the 26.04.1 server ISO"
  else
    bad "iso.sha256 must hold one 'hash *ubuntu-26.04.1-live-server-amd64.iso' line"
  fi
else
  skipped "iso.sha256 assertions (file missing)"
fi

# --- seed builder -----------------------------------------------------------
bs=$d/build-seed.sh
if [[ -f $bs ]]; then
  bash -n "$bs" && ok "build-seed.sh parses" || bad "build-seed.sh does not parse"
  for needle in 'SMORTRESS_ROOT_PASSPHRASE' 'SMORTRESS_ADMIN_PASSWORD_HASH' \
                'SMORTRESS_ADMIN_KEY' 'SMORTRESS_HOST_KEYS_TAR' 'mktemp' \
                'cloud-localds' 'sha256sum -c' 'gpg --verify' 'iso.sha256'; do
    grep -qF -- "$needle" "$bs" && ok "build-seed.sh references $needle" \
      || bad "build-seed.sh is missing $needle"
  done
  grep -qE 'set -euo pipefail' "$bs" && ok "build-seed.sh is strict" \
    || bad "build-seed.sh must set -euo pipefail"
fi

# --- first-boot units -------------------------------------------------------
for unit in smortress-provision zpool-import-tank; do
  f=$d/units/$unit.service
  [[ -f $f ]] || { skipped "$unit unit assertions (file missing)"; continue; }
  grep -qF 'systemd-cryptsetup@luks\x2ddata.service' "$f" \
    && ok "$unit waits for the data mapper" \
    || bad "$unit does not order after systemd-cryptsetup@luks\x2ddata.service"
  grep -qF 'systemd-cryptsetup@luks\x2ddata.service' "$f" \
    && ok "$unit waits for the mapper device" \
    || bad "$unit does not order after the mapper device"
done

if [[ -f $d/units/smortress-provision.service ]]; then
  grep -qF 'ConditionPathExists=!' "$d/units/smortress-provision.service" \
    && ok "provision unit is guarded by a marker" \
    || bad "provision unit needs a ConditionPathExists=! guard"
  grep -qE 'WantedBy=multi-user\.target' "$d/units/smortress-provision.service" \
    && ok "provision unit is enabled at boot" \
    || bad "provision unit must be WantedBy=multi-user.target"
fi

if [[ -f $d/units/smortress-provision.sh ]]; then
  bash -n "$d/units/smortress-provision.sh" \
    && ok "provision script parses" || bad "provision script does not parse"
  for prop in 'ashift=12' 'compression=zstd' 'atime=off' 'xattr=sa' \
              'acltype=posixacl' 'mountpoint=none' 'canmount=off' 'cachefile=none'; do
    grep -qF -- "$prop" "$d/units/smortress-provision.sh" \
      && ok "provision script sets $prop" \
      || bad "provision script is missing $prop"
  done
  grep -qF '/dev/mapper/luks-data' "$d/units/smortress-provision.sh" \
    && ok "provision script builds on the data mapper" \
    || bad "provision script must target /dev/mapper/luks-data"
fi

# --- render + YAML syntax ---------------------------------------------------
# The template is not valid YAML until rendered; render it with fixtures so the
# real substitution and the real structure are what gets linted.
render_dir=
if [[ -x $d/build-seed.sh ]] && have python3 && have tar; then
  fix=$(mktemp -d)
  printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixture\n' >"$fix/admin.pub"
  mkdir -p "$fix/etc/ssh"
  printf 'private\n' >"$fix/etc/ssh/ssh_host_ed25519_key"
  printf 'public\n' >"$fix/etc/ssh/ssh_host_ed25519_key.pub"
  tar -C "$fix" -cf "$fix/host-keys.tar" etc/ssh

  if render_dir=$(SMORTRESS_ROOT_PASSPHRASE='spike-passphrase-0123456789' \
      SMORTRESS_ADMIN_PASSWORD_HASH='$6$fixture$hash' \
      SMORTRESS_ADMIN_KEY="$fix/admin.pub" \
      SMORTRESS_HOST_KEYS_TAR="$fix/host-keys.tar" \
      "$d/build-seed.sh" --render-only 2>/dev/null); then
    ok "build-seed --render-only"
    if grep -qE '@[A-Z_]+@' "$render_dir/user-data"; then
      bad "the rendered config still has a token"
    else
      ok "the rendered config has no leftover token"
    fi
    for needle in 'dm_name: luks-root' 'dm_name: luks-data' \
                  'keyfile: /etc/luks/data.key' \
                  '/target/etc/systemd/system/smortress-provision.service' \
                  '/target/usr/local/sbin/smortress-provision' \
                  'systemctl enable smortress-provision.service zpool-import-tank.service' \
                  '/target/etc/ssh/ssh_host_ed25519_key'; do
      grep -qF -- "$needle" "$render_dir/user-data" \
        && ok "rendered config has ${needle}" \
        || bad "rendered config is missing ${needle}"
    done
    if have yamllint; then
      lint=$render_dir/yamllint.log
      if yamllint --no-warnings -c tests/provision/yamllint.yaml \
           "$render_dir/user-data" >"$lint" 2>&1 \
         && yamllint --no-warnings -c .yamllint.yaml "$d/meta-data" >>"$lint" 2>&1; then
        ok "yamllint the rendered config"
      else
        bad "yamllint the rendered config" "$(cat "$lint")"
      fi
    else
      skipped "yamllint not found"
    fi
  else
    bad "build-seed --render-only failed"
  fi
  rm -rf "$fix" "$render_dir"
else
  skipped "renderer checks (build-seed.sh, python3 or tar missing)"
fi

# --- scripts ----------------------------------------------------------------
if have shellcheck; then
  if out=$(shellcheck "$bs" "$d/qemu-spike.sh" "$d/units/smortress-provision.sh" 2>&1); then
    ok "shellcheck provision scripts"
  else
    bad "shellcheck provision scripts" "$out"
  fi
else
  skipped "shellcheck not found"
fi

# --- no rendered secrets in the tree ---------------------------------------
if grep -rIlE '\$[56y]\$|BEGIN (OPENSSH|RSA|EC|DSA) PRIVATE KEY' provision 2>/dev/null | grep -q .; then
  bad "a provision file contains a hash or private key"
else
  ok "no hash or private key committed under provision/"
fi

printf '\nprovision: %d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skipped"
[[ $fail -eq 0 ]]
