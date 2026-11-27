#!/usr/bin/env bats
# bats file_tags=provision
# Static checks for the smortress autoinstall artifact.
# Runtime proof lives in provision/smortress/verify.sh; this runs in CI.
#
#   bats tests/provision/check.bats
#
# The shell suite this replaced ran every check in one process against the
# checkout; here each assertion is its own test, so a failure names the pinned
# property instead of only the line it came from. Nothing here writes: the
# suite reads provision/ as text.
load ../helpers

art=provision/smortress

# has <needle> <file>: the file must carry the literal text. The needles are
# expectations of literal source text, not expansions.
has() {
    grep -qF -- "$1" "$2" && return 0
    printf '%s not found in %s\n' "$1" "$2" >&2
    return 1
}

# lacks <needle> <file>: the file must not carry the literal text.
lacks() {
    grep -qF -- "$1" "$2" || return 0
    printf '%s found in %s\n' "$1" "$2" >&2
    return 1
}

setup_file() {
    [ -d "$art" ] || {
        printf 'missing %s\n' "$art" >&2
        return 1
    }
}

# --- the autoinstall artifact ------------------------------------------------

@test "user-data keeps the disk-serial placeholder" {
    has '__DISK_SERIAL__' "$art/user-data"
}

@test "user-data has no spike-only serial" {
    lacks 'SMORTRESS980' "$art/user-data"
}

@test "user-data installs clevis-tpm2" {
    has 'clevis-tpm2' "$art/user-data"
}

@test "user-data wipes the whole disk" {
    has 'wipe: superblock-recursive' "$art/user-data"
}

@test "user-data adds the data keyslot" {
    has 'luksAddKey' "$art/user-data"
}

@test "user-data backs up the data header" {
    has 'luks-data.header' "$art/user-data"
}

@test "user-data fails a missing ip=dhcp" {
    has "grep -q 'ip=dhcp'" "$art/user-data"
}

@test "provision unit follows the cryptsetup unit" {
    has 'systemd-cryptsetup@luks\x2ddata.service' "$art/user-data"
}

@test "provision unit skips without the mapper" {
    has 'ConditionPathExists=/dev/mapper/luks-data' "$art/user-data"
}

@test "data crypttab entry carries nofail" {
    has 'luks,discard,nofail' "$art/user-data"
}

@test "pool creation sets cachefile=none" {
    has 'zpool create -o cachefile=none' "$art/user-data"
}

@test "installer logs are scrubbed" {
    has '/var/log/installer/*autoinstall*' "$art/user-data"
}

@test "user-data carries the host-key placeholder" {
    has '__HOST_KEY_ESCAPED__' "$art/user-data"
}

@test "user-data derives the host-key pubfile" {
    has 'ssh_host_ed25519_key.pub' "$art/user-data"
}

@test "user-data drops generated rsa/ecdsa host keys" {
    has 'ssh_host_rsa*' "$art/user-data"
}

@test "seed builder requires the host key" {
    has 'SMORTRESS_HOST_KEY is required' "$art/build-seed.sh"
}

@test "seed builder rejects a protected host key" {
    has 'passphrase-protected' "$art/build-seed.sh"
}

@test "seed builder rejects leftover placeholders" {
    has 'unsubstituted placeholder' "$art/build-seed.sh"
}

@test "seed builder writes the seed 0600" {
    has 'chmod 600 "$seed"' "$art/build-seed.sh"
}

@test "seed defaults outside the repo" {
    has '$HOME/.cache/smortress' "$art/build-seed.sh"
}

@test "seed builder verifies the ISO signature" {
    has 'VALIDSIG' "$art/build-seed.sh"
}

@test "spike waits for the swtpm socket" {
    has 'swtpm did not create' "$art/spike.sh"
}

@test "spike passes swtpm not-need-init" {
    has 'not-need-init' "$art/spike.sh"
}

# --- the suite's own lint ----------------------------------------------------
# has/lacks are invoked through the tests, the grep patterns are literal, and the
# suite itself is in the set: shellcheck reads .bats as bash.

shellcheck_suite() {
    shellcheck -e SC2329,SC2016 "$art"/*.sh tests/provision/check.bats
}

yamllint_suite() {
    yamllint -c .yamllint.yaml "$art/user-data"
}

if command -v shellcheck >/dev/null 2>&1; then
    register "shellcheck clean" shellcheck_suite
else
    register_skip "shellcheck clean" "shellcheck is not installed"
fi

if command -v yamllint >/dev/null 2>&1; then
    register "yamllint parses user-data" yamllint_suite
else
    register_skip "yamllint parses user-data" "yamllint is not installed"
fi
