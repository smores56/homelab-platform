#!/usr/bin/env bats
# bats file_tags=image
# Offline checks for the Ignition secret boundary (SDLC #701, T2; edge: #939, T9).
#
# Design #701: "No secret enters Ignition or the installer media." Root LUKS is
# Clevis-only, the data partition is created unformatted and formatted from a
# keyfile the host generates, and the recovery passphrases are added afterwards
# with `cryptsetup luksAddKey`. The template, the renderer and the render are all
# asserted here, because a passphrase that reappears in the rendered config is
# invisible to every other check.
#
# The edge document is the opposite case and gets the opposite assertion: it is
# public and committed, so what matters is that its file set is exactly the set
# of tracked, public files and that no credential is in it at all.
#
# The render half needs butane; without it the template half still runs and the
# render half skips (server-image-static.yml always has the pinned butane).
#
#   bats tests/image/ignition-boundary.bats
# shellcheck disable=SC2016  # the renderer's source text is matched literally
load ../helpers

template=ignition/smortress.bu
edge_template=ignition/edge.bu
renderer=scripts/render-ignition.sh
butane=${BUTANE:-butane}

# The edge installs from a published digest; any well-formed one renders the
# template, and the renderer refuses anything else.
edge_image="ghcr.io/smores56/homelab-platform/edge@sha256:$(printf '%064d' 0)"
edge_key=bootc/server/rootfs/etc/ssh/authorized_keys.d/smores

# render_synthetic: write the rendered config under this test's own directory and
# print its path. Every render test renders its own copy; a config shared by
# two tests would let one read the other's output.
render_synthetic() {
    local out=$BATS_TEST_TMPDIR/smortress.ign
    BUTANE=$butane "$renderer" --synthetic --output "$out" 2>/dev/null
    printf '%s' "$out"
}

render_edge() {  # [output path]
    local out=${1:-$BATS_TEST_TMPDIR/edge.json}
    EDGE_REF=$edge_image BUTANE=$butane "$renderer" --no-account --output "$out" 2>/dev/null
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

# The edge document (design #939, T9) has no account at all, so it must not have
# the placeholder the account mode fills: the only two values that could fill it
# are a sops decrypt and the `--check` fixture, and committing either is the
# failure `--no-account` exists to prevent.
@test "the edge template carries no account password" {
    if grep -qE '^[[:space:]]*password_hash:' "$edge_template"; then
        return 1
    fi
    ! grep -qF '@SMORES_PASSWORD_HASH@' "$edge_template"
}

@test "the edge template logs in by the operator key alone" {
    grep -qE '^[[:space:]]*- name: root$' "$edge_template"
    grep -qE '^[[:space:]]*ssh_authorized_keys_local:$' "$edge_template"
    grep -qF -- "- $edge_key" "$edge_template"
    # One tracked copy of the key: the file the smortress image ships (design
    # #767), which is why the document can be rendered without operator state.
    git ls-files --error-unmatch -- "$edge_key" >/dev/null
}

# Same two-stage rebase as the server install, because the edge reaches uCore the
# same way: an unverified stage that installs the policy, then a signed stage.
@test "the edge template rebases through both stages" {
    assert_equal "$(grep -c '@DERIVED_IMAGE@' "$edge_template")" 2
    grep -qF 'ostree-unverified-registry:@DERIVED_IMAGE@' "$edge_template"
    grep -qF 'ostree-image-signed:docker://@DERIVED_IMAGE@' "$edge_template"
}

# Stage 2 is a real signature check only because Ignition wrote the policy, the
# key it names and the sigstore-attachment switch before bootc took over.
@test "the edge template installs the policy, the key and registries.d" {
    grep -qF '/etc/containers/policy.json' "$edge_template"
    grep -qF 'bootc/server/cosign.pub' "$edge_template"
    grep -qF '/etc/containers/registries.d/ghcr.io-smortress.yaml' "$edge_template"
    grep -qF '/etc/pki/containers/smortress.pub' "$edge_template"
}

# The edge is installed by the live ISO onto a BIOS/GRUB disk with no encryption:
# a disk or LUKS section here would be the smortress partition scheme applied to
# a provider disk, and the network arrives as kernel arguments, not as a profile.
@test "the edge template carries no disk, LUKS or network section" {
    if grep -qE '^[[:space:]]*(disks|luks|filesystems):' "$edge_template"; then
        return 1
    fi
    if grep -qF 'key_file:' "$edge_template"; then
        return 1
    fi
    ! grep -qE '^[[:space:]]*networkd:' "$edge_template"
}

@test "the edge template names the host" {
    grep -qE '^[[:space:]]*inline: smoresnet$' "$edge_template"
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
    register 'the edge render refuses an unresolved reference' edge_refuses_a_tag
    register 'the edge render needs no sops and substitutes no hash' edge_ignores_sops
else
    register_skip 'the rendered config carries no passphrase (butane not installed)' \
        'butane is not installed on this host'
    register_skip 'the rendered config carries no inline keyslot (butane not installed)' \
        'butane is not installed on this host'
    register_skip 'the edge render refuses an unresolved reference (butane not installed)' \
        'butane is not installed on this host'
    register_skip 'the edge render needs no sops and substitutes no hash (butane not installed)' \
        'butane is not installed on this host'
fi

# The failure this mode exists to prevent: with sops unusable, an account render
# falls back to the fixture hash under --check, and a fixture hash in a committed
# document is a password nobody holds. The edge render never reaches sops, so the
# document has no hash to be wrong.
edge_ignores_sops() {
    local out=$BATS_TEST_TMPDIR/edge-nosops.json
    SOPS_BIN=/bin/false EDGE_REF=$edge_image BUTANE=$butane \
        "$renderer" --no-account --output "$out" 2>/dev/null
    ! grep -qF '$6$' "$out"
}

# The refusals run before butane is consulted, so they hold on a host without it.
@test "the edge render refuses the synthetic fixture fallback" {
    run env EDGE_REF=$edge_image "$renderer" --no-account --synthetic --check
    assert_failure
    assert_output --partial 'refuses --synthetic'
}

@test "the edge render refuses the stock installer branch" {
    run env EDGE_REF=$edge_image "$renderer" --no-account --stock --check
    assert_failure
    assert_output --partial 'refuses --stock'
}

@test "the edge render refuses to run without a resolved reference" {
    run env -u EDGE_REF "$renderer" --no-account --check
    assert_failure
    assert_output --partial 'needs EDGE_REF='
}

# An unresolved reference is the other half of "refuse a non-resolved ref": a tag
# renders a document whose rebase the install can never verify against a digest.
edge_refuses_a_tag() {
    run env EDGE_REF=ghcr.io/smores56/homelab-platform/edge:latest \
        "$renderer" --no-account --check
    assert_failure
    assert_output --partial '<registry>/<repo>@sha256:<digest>'
}

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

# The edge document is committed to a public repository, so "the file set is
# exactly public" is the whole boundary: every path and every byte comes from a
# tracked file here (or is the hostname literal), and nothing else is in it. The
# expected set is written out rather than derived from the template, so a file
# added there without a decision here fails.
@test "the edge document's file set is exactly the public set" {
    command -v "$butane" >/dev/null 2>&1 || skip 'butane is not installed on this host'
    local out report
    out=$(render_edge)
    report=$(python3 - "$out" <<'PY'
import base64, gzip, json, subprocess, sys, urllib.parse

# The public files the document writes, and the tracked file each must equal.
sources = {
    "/etc/pki/containers/smortress.pub": "bootc/server/cosign.pub",
    "/etc/containers/policy.json": "bootc/server/rootfs/etc/containers/policy.json",
    "/etc/containers/registries.d/ghcr.io-smortress.yaml":
        "bootc/server/rootfs/etc/containers/registries.d/ghcr.io-smortress.yaml",
}
key_file = "bootc/server/rootfs/etc/ssh/authorized_keys.d/smores"
hostname = "smoresnet"
autorebase_dir = "/etc/ucore-autorebase"

problems = []
config = json.load(open(sys.argv[1]))


def inlined(entry):
    # butane embeds a local file verbatim or gzipped, and both spellings of the
    # data URI are the file's own bytes.
    source = entry.get("contents", {}).get("source", "")
    if source.startswith("data:,"):
        return urllib.parse.unquote(source[len("data:,"):])
    if source.startswith("data:;base64,"):
        raw = base64.b64decode(source[len("data:;base64,"):])
        return gzip.decompress(raw).decode() if raw[:2] == b"\x1f\x8b" else raw.decode()
    return None


def tracked(path):
    return subprocess.run(
        ["git", "ls-files", "--error-unmatch", "--", path],
        capture_output=True).returncode == 0


serialized = json.dumps(config)
if "passwordHash" in serialized or "credential" in serialized.lower():
    problems.append("the document carries a passwordHash or a credential")
if "$6$" in serialized:
    problems.append("the document carries a sha512crypt hash")

storage = config.get("storage", {})
for section in ("luks", "disks", "filesystems"):
    if storage.get(section):
        problems.append(f"the document carries a storage.{section} section")

users = config.get("passwd", {}).get("users", [])
if [user.get("name") for user in users] != ["root"]:
    problems.append(f"accounts are {[user.get('name') for user in users]}, want ['root']")
keys = []
for user in users:
    for field in sorted(user):
        if field not in ("name", "sshAuthorizedKeys"):
            problems.append(f"{user['name']} carries {field}")
    keys = user.get("sshAuthorizedKeys", [])
    if not keys or not all(key.startswith("ssh-ed25519 ") for key in keys):
        problems.append(f"{user['name']} has no ed25519 key")
if not tracked(key_file):
    problems.append(f"the key source {key_file} is not tracked")
elif keys != [line for line in open(key_file).read().splitlines() if line]:
    problems.append(f"the keys are not exactly {key_file}")

want = sorted([*sources, "/etc/hostname"])
files = storage.get("files", [])
got = sorted(entry.get("path", "") for entry in files)
if got != want:
    problems.append(f"files are {got}, want {want}")
for entry in files:
    path = entry.get("path", "")
    text = inlined(entry)
    if text is None:
        problems.append(f"{path} is not an inlined file")
    elif path == "/etc/hostname":
        if text != hostname:
            problems.append(f"hostname is {text!r}, want {hostname!r}")
    elif path in sources and tracked(sources[path]):
        if text != open(sources[path]).read():
            problems.append(f"{path} is not {sources[path]}")

directories = storage.get("directories", [])
if directories != [{"path": autorebase_dir, "mode": 0o754}]:
    problems.append(f"directories are {directories}, want [{autorebase_dir}]")

print("\n".join(problems))
PY
)
    assert_equal "$report" ""
}

# The renderer writes the hash of the file it just produced, and the runbook tells
# the operator to compute it from the checked-out file: the two must be the same
# value, or the install pins a document nobody committed.
@test "the edge render's sha512 is the checked-out file's own" {
    command -v "$butane" >/dev/null 2>&1 || skip 'butane is not installed on this host'
    local out printed
    out=$(render_edge)
    printed=$(EDGE_REF=$edge_image BUTANE=$butane "$renderer" --no-account --output "$out" 2>&1 |
        sed -n 's/^sha512 [^:]*: \(sha512-[0-9a-f]*\)$/\1/p')
    assert_equal "$printed" "sha512-$(sha512sum -- "$out" | cut -d' ' -f1)"
    assert_equal "${#printed}" 135
}

# The committed document inlines four tracked files, so it ages silently: change
# edge.bu, the key, the policy or registries.d without a re-render and the edge
# installs a document that disagrees with the image it is running. Rendering the
# ref the document itself names is the only check that cannot drift.
@test "the committed edge document matches a fresh render" {
    command -v "$butane" >/dev/null 2>&1 || skip 'butane is not installed on this host'
    local committed ref out
    committed=$BATS_TEST_DIRNAME/../../ignition/edge.json
    [[ -f $committed ]] || fail 'ignition/edge.json is not committed'
    ref=$(grep -o 'ghcr.io/smores56/homelab-platform/edge@sha256:[0-9a-f]\{64\}' "$committed" | head -1)
    [[ -n $ref ]] || fail 'the committed document names no edge digest'
    out=$(mktemp)
    EDGE_REF=$ref BUTANE=$butane "$renderer" --no-account --output "$out" >/dev/null
    run cmp -s "$out" "$committed"
    assert_success
    rm -f "$out"
}
