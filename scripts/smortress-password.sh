#!/usr/bin/env bash
# Re-apply the smores account password from the decrypted ciphertext.
#
# bootc never reconciles /var, so /etc/shadow is whatever the install or the last
# change left there. The hash arrives three ways and has to agree: Ignition sets
# it at install (scripts/render-ignition.sh), this unit re-applies it at every
# boot, and the operator changes it by minting a new ciphertext
# (docs/manual-steps.md section 37). The ciphertext is
# secrets/server/smores-password-hash.yaml, decrypted into /run by
# sops-decrypt.service; `value` in the manifest is what makes the file the bare
# hash.
#
# `usermod -p` writes the field verbatim, so a value that is empty or is not
# sha512crypt would leave the account unable to log in at all. Validate first and
# fail the unit instead: a boot that keeps the previous password is recoverable
# over SSH, one that writes garbage is a console trip. The hash reaches argv only
# in that single usermod exec, which is the one place usermod requires it.
set -euo pipefail

hash_file=${SMORTRESS_PASSWORD_HASH_FILE:-/run/smortress/secrets/smores-password-hash.yaml}
account=smores

if [[ ! -s $hash_file ]]; then
  echo "smortress-password: $hash_file is missing or empty; sops-decrypt did not write it" >&2
  exit 1
fi
# The trailing newline sops-decrypt writes is stripped by the substitution.
hash=$(<"$hash_file")
if [[ ! $hash =~ ^\$6\$[^$]{1,16}\$[./A-Za-z0-9]{86}$ ]]; then
  echo "smortress-password: $hash_file does not hold a sha512crypt hash; refusing to touch $account" >&2
  exit 1
fi

usermod -p "$hash" "$account"
echo "smortress-password: re-applied the $account password field from ciphertext"
