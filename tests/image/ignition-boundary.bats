#!/usr/bin/env bats
# bats file_tags=image
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
#   bats tests/image/ignition-boundary.bats
# shellcheck disable=SC2016  # the renderer's source text is matched literally
load ../helpers

template=ignition/smortress.bu
renderer=scripts/render-ignition.sh
butane=${BUTANE:-butane}

# render_synthetic: write the rendered config under this test's own directory and
# print its path. Every render test renders its own copy; a config shared by
# two tests would let one read the other's output.
render_synthetic() {
    local out=$BATS_TEST_TMPDIR/smortress.ign
    BUTANE=$butane "$renderer" --synthetic --output "$out" 2>/dev/null
    printf '%s' "$out"
}

# No keyslot may be keyed from the config: an `inline` key file is a secret on
# the installer media, and a `local` one is the same secret from the checkout.
@test "the template carries no LUKS key file" {
    if grep -nE '^[[:space:]]*key_file:' "$template"; then
        return 1
    fi
}

template_has_no_placeholder() { # placeholder
    ! grep -qF "$1" "$template"
}

for placeholder in '@ROOT_RECOVERY_PASSPHRASE@' '@DATA_RECOVERY_PASSPHRASE@'; do
    register "the template has no $placeholder" template_has_no_placeholder "$placeholder"
done

# Root unlock is the Clevis binding alone.
@test "root unlock is the Clevis SSS binding" {
    grep -qE '^[[:space:]]*threshold: 2$' "$template"
    grep -qE '^[[:space:]]*tpm2: true$' "$template"
    grep -qF "thumbprint: '@TANG_THUMBPRINT@'" "$template"
}

# The renderer must not read the passphrases it no longer substitutes; the only
# secret it is allowed to decrypt is the account hash.
renderer_names_no_stale() { # stale name
    ! grep -qF "$1" "$renderer"
}

for stale in root-recovery-passphrase data-recovery-passphrase \
    '@ROOT_RECOVERY_PASSPHRASE@' '@DATA_RECOVERY_PASSPHRASE@'; do
    register "the renderer no longer names $stale" renderer_names_no_stale "$stale"
done

@test "the renderer decrypts only the account hash" {
    local sops_calls
    sops_calls=$(grep -c '"\$sops_bin" --decrypt' "$renderer")
    assert_equal "$sops_calls" 1
    grep -qF 'secrets/boot.json' "$renderer"
}

# Root is 300 GiB and p5 takes the rest. A ZFS vdev cannot shrink, so an
# installed host cannot reach this size without recreating the pool
# (docs/core/pool-rebuild.md); the test pins the template so a reinstall does
# not quietly hand the space back to the data partition.
@test "root is 300 GiB and the data partition takes the remainder" {
    grep -qE '^[[:space:]]*size_mib: 307200$' "$template"
    grep -qE '^[[:space:]]*resize: true$' "$template"
    grep -qE '^[[:space:]]*size_mib: 0$' "$template"
}

# The data partition is Ignition's to create and the oneshot's to format.
@test "ignition does not format the data partition" {
    ! grep -qE '^[[:space:]]*- name: data$' "$template"
}

@test "the first-boot oneshot formats the data partition" {
    grep -qE '^[[:space:]]*cryptsetup luksFormat' scripts/init-data-luks.sh
}

# cryptsetup refuses --allow-discards on luksFormat (it is an open-time option),
# so a first boot that formats p5 must not pass it there; the flag is persisted
# by the open instead, which is what keeps TRIM working through the mapper.
@test "the data format passes no --allow-discards to luksFormat" {
    if grep -A3 -E '^[[:space:]]*cryptsetup luksFormat' scripts/init-data-luks.sh |
        grep -q -- '--allow-discards'; then
        return 1
    fi
}

@test "the first open persists the discard flag" {
    grep -qE 'cryptsetup open .*--allow-discards --persistent' scripts/init-data-luks.sh
}

@test "the image enables the data formatting oneshot" {
    grep -qE '^ExecStart=/usr/libexec/init-data-luks$' units/systemd/smortress-data-init.service
}

@test "the pool waits for the data formatting oneshot" {
    grep -qE '^Requires=.*smortress-data-init\.service' units/systemd/smortress-zpool.service
}

# The operator steps are part of the promise: a host without them has no
# offline recovery, and the document has to say so with the exact commands.
@test "the manual steps add and verify both recovery passphrases" {
    grep -qF 'luksAddKey --key-file /etc/luks/data /dev/disk/by-partlabel/luks-data' docs/manual-steps.md
    grep -qF 'luksAddKey --key-file /run/root-clevis.key /dev/disk/by-partlabel/root' docs/manual-steps.md
    grep -qF 'cryptsetup open --test-passphrase /dev/disk/by-partlabel/root' docs/manual-steps.md
    grep -qF 'cryptsetup open --test-passphrase /dev/disk/by-partlabel/luks-data' docs/manual-steps.md
}

# The render itself. Synthetic values are the two strings the renderer used to
# substitute, so their absence from the output is the assertion. Without butane
# the two checks it would prove are skipped by name, so a closed host gate is
# visible and never mistaken for a proof.
render_succeeds() {
    render_synthetic >/dev/null
}

rendered_carries_no_secret() { # secret
    local out
    out=$(render_synthetic)
    ! grep -qF "$1" "$out"
}

if command -v "$butane" >/dev/null 2>&1; then
    register 'the synthetic render succeeds' render_succeeds
    for secret in synthetic-root-recovery-passphrase synthetic-data-recovery-passphrase; do
        register "the rendered config carries no $secret" rendered_carries_no_secret "$secret"
    done
else
    register_skip 'the rendered config carries no passphrase (butane not installed)' \
        'butane is not installed on this host'
    register_skip 'the rendered config carries no inline keyslot (butane not installed)' \
        'butane is not installed on this host'
fi

@test "the renderer emits one Clevis-only LUKS device with no key file" {
    local out report
    out=$(render_synthetic)
    report=$(python3 - "$out" <<'PY'
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
    assert_equal "$report" ""
}
