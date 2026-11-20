#!/bin/sh
# Enroll every attached YubiKey with smortress's sudo TOTP secret and install
# /var/lib/homelab/sudo/users.oath there (image/rootfs/etc/pam.d/sudo).
#
# The secret is twenty random bytes that exist in this process's memory and,
# after the install, in one root-only file on smortress. It is never written to
# this machine's disk, never passed in argv, never echoed, and never enters
# SOPS or either repository: a copy an agent running as smores can read is a
# second factor that agent holds, and eight digits is 10^8 candidates.
#
# The two paths follow the gate's own ordering. That stack fails closed until
# the usersfile exists, so a host that has never been enrolled cannot be fixed
# through sudo over ssh - there is nothing to authenticate against yet - and its
# first enrollment is --fifo: a root shell at the physical console holds a fifo
# open and the line is written into it. The direct sudo -S path is rotation on
# an already-enabled host, where both factors exist and the file is only
# replaced. Either path rotates: both keys get the new secret and the install
# replaces the usersfile, so the old secret stops working the moment it lands.
#
# ykman reads a piped line before it prompts for the secret, which is how the
# value reaches both keys without touching argv or the terminal (ykman 5.9.2,
# ykman/_cli/util.py click_prompt). liboath parses the usersfile key field with
# oath_hex2bin, so that file gets hex; the keys get base32 because that is the
# only encoding ykman accepts (yubikit/oath.py parse_b32_key).

# The two ssh commands below are double-quoted so the paths expand here, on the
# laptop, and the host needs nothing but sh to run them.
# shellcheck disable=SC2029

set -eu

usersfile=/var/lib/homelab/sudo/users.oath
account=smortress

usage() {
  cat <<'EOF'
usage: enroll-yubikey-totp.sh <host>
       enroll-yubikey-totp.sh --fifo <path> <host>

<host> is smortress as ssh reaches it. Both YubiKey 5C Nanos must be attached;
they carry the same credential, so a partial enrollment is not a gate.

--fifo <path> is the bootstrap path and the only one that works on a host that
has never been enrolled: the sudo stack fails closed until the usersfile exists,
so the line goes into a fifo a root shell at the physical console is holding
open. Without --fifo the script installs through sudo over ssh, which is
rotation on an already-enabled host.
EOF
}

die() {
  printf 'enroll-yubikey-totp: %s\n' "$*" >&2
  exit 1
}

# The console path, printed before the direct install - so the operator of an
# unenrolled host reads the way in before being prompted for anything - and
# again when that install fails. The script cannot look at the usersfile to tell
# the two cases apart: /var/lib/homelab/sudo is 0700 root.
console_steps() {
  printf '%s\n' "$1" >&2
  cat >&2 <<EOF
  1. at the physical console, log in as smores with the account password (the
     /dev/tty* row needs no code) and run: sudo -i
  2. in that root shell: mkfifo -m 0600 /run/smortress-enroll
     and: chown smores /run/smortress-enroll
  3. in that root shell: install -m 0600 /dev/stdin $usersfile \\
       < /run/smortress-enroll
  4. on this laptop: $0 --fifo /run/smortress-enroll <host>
The fifo holds nothing once it has been read, so the secret never sits in a
file on either side. sudo over ssh fails closed until $usersfile exists.
EOF
}

repair() {
  console_steps "The remote install failed, so this host is still unenrolled and
sudo over ssh keeps failing closed: $usersfile still has to arrive through the
console path below."
}

fifo=
if [ "${1:-}" = --fifo ]; then
  [ $# -eq 3 ] || { usage >&2; exit 2; }
  fifo=$2
  shift 2
fi
[ $# -eq 1 ] || { usage >&2; exit 2; }
host=$1

command -v ykman >/dev/null 2>&1 ||
  die "ykman is not installed: uv tool install yubikey-manager==5.9.2"
command -v ssh >/dev/null 2>&1 || die "ssh is not installed"

serials=$(ykman list --serials)
keys=$(printf '%s\n' "$serials" | grep -c . || true)
[ "$keys" -ge 2 ] ||
  die "expected at least two YubiKeys attached, found $keys: every key that can sudo must carry the same credential, and a key left out is a key that cannot"

# Twenty bytes is RFC 4226's recommended secret length. awk converts them so
# the script needs nothing but od, and the conversion happens inside one
# process: no file, no argument, no environment.
secret_pair=$(od -An -tu1 -N20 /dev/urandom | awk '
  BEGIN { alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567" }
  {
    for (i = 1; i <= NF; i++) {
      byte = $i + 0
      hex = hex sprintf("%02x", byte)
      for (bit = 7; bit >= 0; bit--)
        bits = bits ((int(byte / 2 ^ bit) % 2) ? "1" : "0")
    }
  }
  END {
    for (i = 1; i + 4 <= length(bits); i += 5) {
      value = 0
      for (j = 0; j < 5; j++) value = value * 2 + substr(bits, i + j, 1)
      b32 = b32 substr(alphabet, value + 1, 1)
    }
    print hex
    print b32
  }')
secret_hex=$(printf '%s\n' "$secret_pair" | sed -n 1p)
secret_b32=$(printf '%s\n' "$secret_pair" | sed -n 2p)
unset secret_pair
if [ "${#secret_hex}" -ne 40 ] || [ "${#secret_b32}" -ne 32 ]; then
  die "could not generate a 160-bit secret"
fi

# --force makes a rerun a rotation instead of an overwrite prompt, which would
# eat the piped secret as its answer. --touch is the physical-presence half:
# without it the key would mint codes for anything that can talk to it.
while IFS= read -r serial; do
  printf '%s\n' "$secret_b32" |
    ykman --device "$serial" oath accounts add \
      --oath-type TOTP --digits 8 --touch --force "$account"
  printf 'enrolled YubiKey %s\n' "$serial" >&2
done <<EOF
$serials
EOF

# smores is the PAM username sudo authenticates, not the key's credential label:
# pam_oath picks the usersfile line by PAM_USER, which is the invoking account.
line="HOTP/T30/8 smores - $secret_hex"

if [ -n "$fifo" ]; then
  # The reader is the operator's job and must already be blocked: a fifo's
  # reader blocks in open(2) until a writer appears, so starting it after this
  # run leaves both ends waiting. The hint is printed before the write because
  # when it is missing, the script simply appears to hang here.
  printf 'writing into %s on %s; the console reader must already be blocked\n' \
    "$fifo" "$host" >&2
  # dd, not a shell redirect: the usersfile line may only ever travel through a
  # pipe, so no edit of this path can grow into a temporary file.
  printf '%s\n' "$line" | ssh "$host" "dd of=$fifo status=none"
  printf 'wrote the usersfile line into %s on %s\n' "$fifo" "$host" >&2
else
  console_steps "If this host has no $usersfile yet, sudo over ssh fails closed
and none of it reaches the install below: the first run is the console path.
The direct path is rotation on an already-enabled host."

  # One stdin stream carries all three lines. sudo's -S makes every PAM prompt
  # read from stdin, one byte at a time, so the password and the code are
  # consumed by pam_unix and pam_oath and install then reads the usersfile line
  # from the same stream (sudo src/tgetpass.c, src/conversation.c). sudo runs
  # the ssh session's pty-less shell, which is why -S is needed at all.
  printf 'smortress account password: ' >&2
  stty -echo 2>/dev/null || true
  IFS= read -r password || die "no password on stdin"
  stty echo 2>/dev/null || true
  printf '\n' >&2
  printf 'touch the YubiKey and type its 8-digit code: ' >&2
  stty -echo 2>/dev/null || true
  IFS= read -r otp || die "no code on stdin"
  stty echo 2>/dev/null || true
  printf '\n' >&2

  if ! {
    printf '%s\n' "$password"
    printf '%s\n' "$otp"
    printf '%s\n' "$line"
  } | ssh "$host" "sudo -S install -m 0600 /dev/stdin $usersfile"; then
    unset password otp line secret_hex
    repair
    die "the remote install failed"
  fi
  unset password otp
fi

unset line secret_hex

cat >&2 <<EOF
Enrolled every attached YubiKey ($keys) and installed $usersfile on $host.
Prove it: sudo -k; sudo true   (password, then touch for the code)
EOF
