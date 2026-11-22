#!/usr/bin/env bash
# Offline checks for the Ignition secret boundary (SDLC #701, T2).
#
# Design #701: "No secret enters Ignition or the installer media." Root LUKS is
# Clevis-only, the data partition is created unformatted and formatted from a
# keyfile the host generates, and the recovery passphrases are added afterwards
# with `cryptsetup luksAddKey`. The template, the renderer and the render are all
# asserted here, because a passphrase that reappears in the rendered config is
# invisible to every other check.
#
# The render half needs butane; without it the template half still runs and the
# render half skips (server-image-static.yml always has the pinned butane).
#
#   tests/core/ignition-boundary.sh
# shellcheck disable=SC2016  # the renderer's source text is matched literally
set -uo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root" || exit 1

pass=0
fail=0
skip=0
ok() {
  pass=$((pass + 1))
  printf 'ok   %s\n' "$1"
}
bad() {
  fail=$((fail + 1))
  printf 'FAIL %s\n' "$1"
  [[ -n ${2:-} ]] && printf '     %s\n' "${2//$'\n'/$'\n'     }"
  return 0
}
skipped() {
  skip=$((skip + 1))
  printf 'skip %s\n' "$1"
}

template=ignition/smortress.bu
renderer=scripts/render-ignition.sh

# No keyslot may be keyed from the config: an `inline` key file is a secret on
# the installer media, and a `local` one is the same secret from the checkout.
if grep -qE '^[[:space:]]*key_file:' "$template"; then
  bad "the template carries no LUKS key file" "$(grep -nE '^[[:space:]]*key_file:' "$template")"
else
  ok 'the template carries no LUKS key file'
fi

for placeholder in '@ROOT_RECOVERY_PASSPHRASE@' '@DATA_RECOVERY_PASSPHRASE@'; do
  if grep -qF "$placeholder" "$template"; then
    bad "the template has no $placeholder"
  else
    ok "the template has no $placeholder"
  fi
done

# Root unlock is the Clevis binding alone.
if grep -qE '^[[:space:]]*threshold: 2$' "$template" &&
  grep -qE '^[[:space:]]*tpm2: true$' "$template" &&
  grep -qF "thumbprint: '@TANG_THUMBPRINT@'" "$template"; then
  ok 'root unlock is the Clevis SSS binding'
else
  bad 'root unlock is the Clevis SSS binding'
fi

# The renderer must not read the passphrases it no longer substitutes; the only
# secret it is allowed to decrypt is the account hash.
for stale in root-recovery-passphrase data-recovery-passphrase \
  '@ROOT_RECOVERY_PASSPHRASE@' '@DATA_RECOVERY_PASSPHRASE@'; do
  if grep -qF "$stale" "$renderer"; then
    bad "the renderer no longer names $stale"
  else
    ok "the renderer no longer names $stale"
  fi
done

sops_calls=$(grep -c '"\$sops_bin" --decrypt' "$renderer")
if [[ $sops_calls -eq 1 ]] && grep -qF 'secrets/server/smores-password-hash.yaml' "$renderer"; then
  ok 'the renderer decrypts only the account hash'
else
  bad 'the renderer decrypts only the account hash' "sops invocations: $sops_calls"
fi

# Root is 300 GiB and p5 takes the rest. A ZFS vdev cannot shrink, so an
# installed host cannot reach this size without recreating the pool
# (docs/core/pool-rebuild.md); the test pins the template so a reinstall does
# not quietly hand the space back to the data partition.
if grep -qE '^[[:space:]]*size_mib: 307200$' "$template" &&
  grep -qE '^[[:space:]]*resize: true$' "$template" &&
  grep -qE '^[[:space:]]*size_mib: 0$' "$template"; then
  ok 'root is 300 GiB and the data partition takes the remainder'
else
  bad 'root is 300 GiB and the data partition takes the remainder'
fi

# The data partition is Ignition's to create and the oneshot's to format.
if grep -qE '^[[:space:]]*- name: data$' "$template"; then
  bad 'ignition does not format the data partition'
else
  ok 'ignition does not format the data partition'
fi
if grep -qE '^[[:space:]]*cryptsetup luksFormat' scripts/init-data-luks.sh 2>/dev/null; then
  ok 'the first-boot oneshot formats the data partition'
else
  bad 'the first-boot oneshot formats the data partition'
fi
# cryptsetup refuses --allow-discards on luksFormat (it is an open-time option),
# so a first boot that formats p5 must not pass it there; the flag is persisted
# by the open instead, which is what keeps TRIM working through the mapper.
if grep -A3 -E '^[[:space:]]*cryptsetup luksFormat' scripts/init-data-luks.sh |
  grep -q -- '--allow-discards'; then
  bad 'the data format passes no --allow-discards to luksFormat'
else
  ok 'the data format passes no --allow-discards to luksFormat'
fi
if grep -qE 'cryptsetup open .*--allow-discards --persistent' scripts/init-data-luks.sh; then
  ok 'the first open persists the discard flag'
else
  bad 'the first open persists the discard flag'
fi

if grep -qE '^ExecStart=/usr/libexec/init-data-luks$' units/systemd/smortress-data-init.service 2>/dev/null; then
  ok 'the image enables the data formatting oneshot'
else
  bad 'the image enables the data formatting oneshot'
fi
if grep -qE '^Requires=.*smortress-data-init\.service' units/systemd/smortress-zpool.service; then
  ok 'the pool waits for the data formatting oneshot'
else
  bad 'the pool waits for the data formatting oneshot'
fi

# The operator steps are part of the promise: a host without them has no
# offline recovery, and the document has to say so with the exact commands.
if grep -qF 'luksAddKey --key-file /etc/luks/data /dev/disk/by-partlabel/luks-data' docs/manual-steps.md &&
  grep -qF 'luksAddKey --key-file /run/root-clevis.key /dev/disk/by-partlabel/root' docs/manual-steps.md &&
  grep -qF 'cryptsetup open --test-passphrase /dev/disk/by-partlabel/root' docs/manual-steps.md &&
  grep -qF 'cryptsetup open --test-passphrase /dev/disk/by-partlabel/luks-data' docs/manual-steps.md; then
  ok 'the manual steps add and verify both recovery passphrases'
else
  bad 'the manual steps add and verify both recovery passphrases'
fi

# The render itself. Synthetic values are the two strings the renderer used to
# substitute, so their absence from the output is the assertion.
butane=${BUTANE:-butane}
if ! command -v "$butane" >/dev/null 2>&1; then
  skipped 'the rendered config carries no passphrase (butane not installed)'
  skipped 'the rendered config carries no inline keyslot (butane not installed)'
else
  out=$(mktemp)
  trap 'rm -f "$out"' EXIT
  if ! BUTANE=$butane scripts/render-ignition.sh --synthetic --output "$out" 2>/dev/null; then
    bad 'the synthetic render succeeds'
  else
    ok 'the synthetic render succeeds'
    for secret in synthetic-root-recovery-passphrase synthetic-data-recovery-passphrase; do
      if grep -qF "$secret" "$out"; then
        bad "the rendered config carries no $secret"
      else
        ok "the rendered config carries no $secret"
      fi
    done

    luks_report=$(python3 - "$out" <<'PY'
import json, sys
config = json.load(open(sys.argv[1]))
entries = config.get("storage", {}).get("luks", [])
problems = []
for entry in entries:
    if "keyFile" in entry:
        problems.append(f"{entry['name']} carries a keyFile")
    source = entry.get("keyFile", {}).get("source", "")
    if source.startswith("data:"):
        problems.append(f"{entry['name']} has an inline keyFile")
names = [entry["name"] for entry in entries]
if names != ["root"]:
    problems.append(f"luks devices are {names}, want ['root']")
root_entry = entries[0] if entries else {}
if "clevis" not in root_entry:
    problems.append("root has no clevis binding")
print("\n".join(problems))
PY
)
    if [[ -n $luks_report ]]; then
      bad 'the renderer emits one Clevis-only LUKS device with no key file' "$luks_report"
    else
      ok 'the renderer emits one Clevis-only LUKS device with no key file'
    fi
  fi
fi

printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
[[ $fail -eq 0 ]]
