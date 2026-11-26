#!/usr/bin/env bats
# bats file_tags=image
# The `server-image` check-all group, as bats (SDLC #907, T13).
#
# The group was a chain of commands in scripts/check-all.sh:
#
#   scripts/check-server-image.sh
#   scripts/render-ignition.sh --synthetic --check
#   tests/core/ignition-boundary.sh            -> tests/image/ignition-boundary.bats
#   scripts/render-ignition.sh --synthetic --stock --check
#
# The Ignition boundary suite is its own file; this one holds the two commands
# that are assertions by exiting 0. check-server-image.sh prints its own ~770
# per-check `ok` lines and its verdict, so the file does not restate them: what
# the group proved about the image is that command's exit status, and a failure
# here is reproduced with `bash scripts/check-server-image.sh`.
#
# The edge artifact's skeleton (design #939, T3) is asserted here as well, because
# both Containerfiles are the same doctrine and the group claims bootc/edge/*:
# what this file proves about the edge is the base tag, the recorded digest and
# the workflow that publishes it. Everything the edge ships on top (rootfs, Caddy,
# the firewall, sshd) belongs to T4 and to its own checker in T5.
#
#   bats tests/image/server-image.bats
load ../helpers

static_checks=scripts/check-server-image.sh
renderer=scripts/render-ignition.sh
edge_containerfile=bootc/edge/Containerfile
edge_workflow=.github/workflows/publish-edge-image.yml

# contains <text> <file>: a failure names the line that went missing instead of a
# bare status, because these assertions read files rather than run commands.
contains() {
    grep -qF -- "$1" "$2" || fail "missing '$1' in $2"
}

@test "server image static checks passed" {
    run "$static_checks"
    assert_success
}

# --check only validates the Butane source with the pinned binary; the two forms
# differ in whether the autorebase units survive, so both are the group's claim.
@test "the synthetic render passes --check, stock and FCOS media" {
    run "$renderer" --synthetic --check
    assert_success
    run "$renderer" --synthetic --stock --check
    assert_success
}

# The moving-tag/digest-label doctrine, restated as an assertion: the base arrives
# as BASE_IMAGE, the digest the build resolved arrives as BASE_DIGEST, and the
# label is the only durable record of what the image was built on.
@test "the edge Containerfile takes the base tag and records the resolved digest" {
    contains 'FROM ${BASE_IMAGE}' "$edge_containerfile"
    contains 'ARG BASE_DIGEST' "$edge_containerfile"
    contains 'org.opencontainers.image.base.name="${BASE_IMAGE}"' "$edge_containerfile"
    contains 'org.opencontainers.image.base.digest="${BASE_DIGEST}"' "$edge_containerfile"
}

# A digest-pinned base rots when upstream garbage-collects it and `:latest` is no
# stream, so the build refuses both rather than shipping an image that cannot be
# rebuilt, and it refuses an empty digest rather than one that cannot say what it
# ran on.
@test "the edge build refuses a floating, pinned or unrecorded base" {
    contains '*:latest) echo "BASE_IMAGE must be a stream tag, not :latest' "$edge_containerfile"
    contains 'BASE_IMAGE must be a stream tag, not a digest' "$edge_containerfile"
    contains 'BASE_IMAGE must be a tagged reference' "$edge_containerfile"
    contains 'BASE_DIGEST is empty' "$edge_containerfile"
}

@test "the edge base is a uCore stream tag and the image has its own repository" {
    run bash -c '. bootc/lib/pins.env
        printf "%s\n%s\n" "$EDGE_IMAGE" "$EDGE_IMAGE_REPO"'
    assert_success
    assert_regex "${lines[0]}" '^ghcr\.io/ublue-os/ucore-minimal:[A-Za-z0-9._-]+$'
    assert_equal "${lines[1]}" ghcr.io/smores56/homelab-platform/edge
}

# build-image.sh takes the artifact as its argument, so one script builds and one
# set of guarantees covers both. `--help` and an unknown artifact are its dry
# path: neither reaches a container engine, which is why they run here.
@test "build-image.sh takes an artifact and names the edge Containerfile" {
    run scripts/build-image.sh --help
    assert_success
    assert_output --partial 'scripts/build-image.sh [server|edge]'
    run scripts/build-image.sh nosuch
    assert_failure 2
    assert_output --partial 'unknown artifact nosuch'
    contains 'bootc/edge/Containerfile' scripts/build-image.sh
    contains 'bootc/server/Containerfile' scripts/build-image.sh
}

# The publish side of the same doctrine: the workflow runs on the edge's own tree
# and the pins it reads, builds the artifact through the one build script, and
# signs the digest it pushed plus the legacy `.sig` tag bootc actually reads.
@test "the edge publish workflow triggers on its tree and signs the digest" {
    run test -s "$edge_workflow"
    assert_success
    contains '- "bootc/edge/**"' "$edge_workflow"
    contains '- "bootc/lib/**"' "$edge_workflow"
    contains 'run: scripts/build-image.sh edge' "$edge_workflow"
    contains 'environment: server-image' "$edge_workflow"
    contains 'cosign sign --key env://COSIGN_PRIVATE_KEY --yes "$image@$digest"' "$edge_workflow"
    contains ':${digest/:/-}.sig' "$edge_workflow"
    contains 'cosign verify --key bootc/server/cosign.pub' "$edge_workflow"
}
