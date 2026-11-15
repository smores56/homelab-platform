#!/usr/bin/env bash
# Render the smortress autoinstall config and build its cidata seed ISO.
#
#   SMORTRESS_ROOT_PASSPHRASE='…' \
#   SMORTRESS_ADMIN_PASSWORD_HASH='…' \
#   SMORTRESS_ADMIN_KEY=~/.ssh/id_ed25519.pub \
#   SMORTRESS_HOST_KEYS_TAR=/path/host-keys.tar \
#     provision/smortress/build-seed.sh [--iso /path/ubuntu-26.04.1-live-server-amd64.iso]
#
# Required tools (the controller has no python3/gnupg/qemu on PATH):
#   nix-shell -p curl gnupg coreutils python3 cloud-utils tar
#
# On success it prints the 0700 directory holding user-data, meta-data and
# seed.iso, and keeps it. It is a secret: destroy it after the install, never
# commit or copy it into the repo. On failure the directory is removed.
set -euo pipefail

here=$(cd -- "$(dirname -- "$0")" && pwd)
die() { printf 'build-seed: %s\n' "$*" >&2; exit 1; }

iso=
render_only=0
while (($#)); do
  case $1 in
    --iso) [[ ${2:-} ]] || die "--iso needs a path"; iso=$2; shift 2 ;;
    --render-only) render_only=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

for tool in base64 python3 tar; do
  command -v "$tool" >/dev/null 2>&1 || die "missing tool: $tool"
done
if ((!render_only)); then
  for tool in curl gpg sha256sum cloud-localds; do
    command -v "$tool" >/dev/null 2>&1 || die "missing tool: $tool"
  done
fi

: "${SMORTRESS_ROOT_PASSPHRASE:?set the root LUKS passphrase}"
: "${SMORTRESS_ADMIN_PASSWORD_HASH:?set the smores password hash}"
: "${SMORTRESS_ADMIN_KEY:?set the path to the admin public key}"
: "${SMORTRESS_HOST_KEYS_TAR:?set the path to the old host-keys tar}"

((${#SMORTRESS_ROOT_PASSPHRASE} >= 20)) || die "root passphrase must be at least 20 characters"
case $SMORTRESS_ADMIN_PASSWORD_HASH in
  \$6\$*|\$5\$*|\$y\$*) ;;
  *) die "SMORTRESS_ADMIN_PASSWORD_HASH is not a crypt(3) hash" ;;
esac
[[ -f $SMORTRESS_ADMIN_KEY ]] || die "admin key not found: $SMORTRESS_ADMIN_KEY"
grep -qE '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256) ' "$SMORTRESS_ADMIN_KEY" \
  || die "admin key is not an OpenSSH public key"
[[ -f $SMORTRESS_HOST_KEYS_TAR ]] || die "host-keys tar not found: $SMORTRESS_HOST_KEYS_TAR"

work=$(mktemp -d)
chmod 0700 "$work"
keep=0
cleanup() { if ((!keep)); then rm -rf "$work"; fi; }
trap cleanup EXIT

line=$(grep -v '^[[:space:]]*$' "$here/iso.sha256")
name=${line##* }
name=${name#\*}
[[ $line == *"*$name" ]] && [[ $name == ubuntu-26.04.1-live-server-amd64.iso ]] \
  || die "iso.sha256 must pin the 26.04.1 server ISO"
url=https://releases.ubuntu.com/26.04.1

if ((!render_only)); then
  mkdir -p "$work/iso"
  if [[ -z $iso ]]; then
    iso=$work/iso/$name
    printf 'downloading %s\n' "$url/$name" >&2
    curl -fL --retry 3 -o "$iso" "$url/$name"
  fi
  [[ -f $iso ]] || die "ISO not found: $iso"

  printf 'verifying the signed manifest and the pinned hash\n' >&2
  curl -fsS -o "$work/iso/SHA256SUMS" "$url/SHA256SUMS"
  curl -fsS -o "$work/iso/SHA256SUMS.gpg" "$url/SHA256SUMS.gpg"
  gpg --verify "$work/iso/SHA256SUMS.gpg" "$work/iso/SHA256SUMS" >/dev/null 2>&1 \
    || die "SHA256SUMS signature did not verify; import Ubuntu's key D94AA3F0EFE21092"
  grep -qxF -- "$line" "$work/iso/SHA256SUMS" \
    || die "the pinned ISO line is not in the signed SHA256SUMS"
  ( cd "$(dirname -- "$iso")" && printf '%s\n' "$line" | sha256sum -c - >/dev/null ) \
    || die "ISO hash mismatch"
fi

mkdir -p "$work/hostkeys"
tar -xf "$SMORTRESS_HOST_KEYS_TAR" -C "$work/hostkeys"
find "$work/hostkeys" -type f -name 'ssh_host_*' | grep -q . \
  || die "host-keys tar contains no ssh_host_* files"

# The renderer reads the secrets from the environment, never argv: argv is
# visible in ps to every local user.
python3 - "$here" "$work" <<'PY'
import base64
import json
import os
from pathlib import Path
import re
import sys

here = Path(sys.argv[1])
work = Path(sys.argv[2])
hostkeys = work / "hostkeys"
units = here / "units"

root_pass = os.environ["SMORTRESS_ROOT_PASSPHRASE"]
password_hash = os.environ["SMORTRESS_ADMIN_PASSWORD_HASH"]
admin_key = Path(os.environ["SMORTRESS_ADMIN_KEY"]).read_text(encoding="utf-8").strip()


def yaml_scalar(value: str) -> str:
    # Single-quoted YAML scalar: only ' needs escaping.
    return "'" + value.replace("'", "''") + "'"


def command(shell: str) -> str:
    # JSON string quoting is valid YAML double-quoted syntax.
    return '    - ["sh", "-c", ' + json.dumps(shell) + ']'


lines: list[str] = []
lines.append(command("install -d -m 0755 /target/usr/local/sbin /target/etc/systemd/system"))

for path in sorted(units.iterdir()):
    if not path.is_file():
        continue
    if path.suffix == ".service":
        target = f"/target/etc/systemd/system/{path.name}"
        mode = "0644"
    elif path.suffix == ".sh":
        target = f"/target/usr/local/sbin/{path.stem}"
        mode = "0755"
    else:
        continue
    payload = base64.b64encode(path.read_bytes()).decode("ascii")
    lines.append(
        command(
            f"printf %s '{payload}' | base64 -d > {target}"
            f" && chmod {mode} {target} && chown 0:0 {target}"
        )
    )

keys = sorted(p for p in hostkeys.rglob("ssh_host_*") if p.is_file())
if not keys:
    sys.exit("build-seed: no host keys to install")
for path in keys:
    payload = base64.b64encode(path.read_bytes()).decode("ascii")
    target = f"/target/etc/ssh/{path.name}"
    mode = "0644" if path.name.endswith(".pub") else "0600"
    lines.append(
        command(
            f"install -d -m 0755 /target/etc/ssh"
            f" && printf %s '{payload}' | base64 -d > {target}"
            f" && chmod {mode} {target} && chown 0:0 {target}"
        )
    )

lines.append(
    command(
        "curtin in-target -- systemctl enable"
        " smortress-provision.service zpool-import-tank.service"
    )
)

text = (here / "user-data").read_text(encoding="utf-8")
text = text.replace("@LATE_COMMANDS@", "\n".join(lines))
text = text.replace("@ROOT_PASSPHRASE@", yaml_scalar(root_pass))
text = text.replace("@ADMIN_PASSWORD_HASH@", yaml_scalar(password_hash))
text = text.replace("@ADMIN_KEY@", yaml_scalar(admin_key))

leftover = re.search(r"@[A-Z_]+@", text)
if leftover:
    sys.exit(f"build-seed: unrendered token {leftover.group(0)}")
if "\x00" in text:
    sys.exit("build-seed: NUL byte in the rendered config")

(work / "user-data").write_text(text, encoding="utf-8")
(work / "meta-data").write_text((here / "meta-data").read_text(encoding="utf-8"), encoding="utf-8")
PY

chmod 0600 "$work/user-data" "$work/meta-data"
keep=1
if ((render_only)); then
  printf '%s\n' "$work"
  exit 0
fi
cloud-localds "$work/seed.iso" "$work/user-data" "$work/meta-data"
chmod 0600 "$work/seed.iso"
printf '%s\n' "$work"
