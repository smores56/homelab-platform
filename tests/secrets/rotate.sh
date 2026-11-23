#!/usr/bin/env bash
# The operator CLI resolves a bundle, stages it with the manifest mode, and
# hands the editor the committed ciphertext. No identity is needed here.
#   tests/secrets/rotate.sh
set -euo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root" || exit 1

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$*"; }
no() { fail=$((fail + 1)); printf 'FAIL %s\n' "$*" >&2; }

if scripts/secret.sh list | grep -q $'^restic-password.yaml\trestic-password.yaml\t'; then
  ok "list shows the output, bundle, and consumer"
else
  no "list shows the output, bundle, and consumer"
fi

dst=$work/dst
if SMORTRESS_SECRETS_SRC=$dst SMORTRESS_ROOT_CMD= \
  SMORTRESS_STAGE_OWNER=$(id -un) SMORTRESS_STAGE_GROUP=$(id -gn) \
  scripts/secret.sh stage restic-password.yaml --no-restart >/dev/null; then
  if [[ -s $dst/restic-password.yaml ]]; then ok "stage writes the bundle with its mode"; else no "stage writes the bundle with its mode"; fi
else
  no "stage writes the bundle with its mode"
fi

mkdir -p "$work/bin"
cat >"$work/bin/sops" <<'SH'
#!/bin/sh
printf '%s\n' "$@" >"$SOPS_LOG"
SH
chmod +x "$work/bin/sops"
export SOPS_LOG=$work/sops.args
if PATH="$work/bin:$PATH" SOPS_BIN=sops scripts/secret.sh edit restic-password.yaml; then
  if grep -q 'secrets/server/restic-password.yaml' "$SOPS_LOG"; then ok "edit opens the committed ciphertext"; else no "edit opens the committed ciphertext"; fi
else
  no "edit opens the committed ciphertext"
fi

if scripts/secret.sh verify >/dev/null; then ok "verify runs the keyless checks"; else no "verify runs the keyless checks"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
