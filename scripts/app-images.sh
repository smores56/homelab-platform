#!/usr/bin/env bash
# Pinned application images for the smortress Quadlets (SDLC #708, T5).
#
# Sourced by scripts/mirror-app-images.sh and tests/core/app-quadlets.sh; never
# run on its own. The table is the only place an application version is decided.
#
# Nothing here may name an upstream registry: the runtime default-reject policy
# accepts an application image only when it is signed by the smortress cosign key
# and pushed under ghcr.io/smores56/homelab-platform. `mirror-app-images.sh`
# copies each upstream image into that namespace by digest, so the bytes and the
# digest are identical to upstream and the signature is ours.
#
# name|upstream reference|digest
#
# An `upstream reference` is either an upstream image reference, which
# `mirror-app-images.sh` copies by digest, or `built:<Containerfile>`, which
# names an image this repository builds and signs itself
# (.github/workflows/publish-agent-webui.yml). A built row has no upstream
# digest to preserve because the bytes are ours; the digest is the last build's,
# and the row is written from the digest that run printed.
#
# Immich stays on v3.0.3 until the cutover restore has passed: the database in
# the legacy backup was written by that version, and a major upgrade belongs in
# its own maintenance window, not inside a data migration.
#
# shellcheck disable=SC2034  # sourced library: consumers use a subset

app_repo=ghcr.io/smores56/homelab-platform

app_images=(
  'immich-server|ghcr.io/immich-app/immich-server:v3.0.3|sha256:c716dc20f957aafd89fa9d284a2ec63e25c9e2d8d8e87c6197d540a3dce237db'
  'immich-machine-learning|ghcr.io/immich-app/immich-machine-learning:v3.0.3|sha256:d76fe88b69282c09a97eac4f82dafa82cfd77bce274bc742591cde974f87dacb'
  'immich-postgres|ghcr.io/immich-app/postgres:17-vectorchord0.4.3-pgvector0.8.1|sha256:79b95b795f0911e95ffa4d092a2162c4d81a984d5629bc8f786afe0bc0657671'
  'immich-valkey|docker.io/valkey/valkey:9|sha256:3add1a336a920ea54770a001ab6feb3da5fceea96a40373a3a2cd469b815f0b7'
  'opdshelf|docker.io/koalilla/opds-server@sha256:b82f94f72b41686fd9169a2269d65550f411a97dfa341a330df88b0bfab0af35|sha256:b82f94f72b41686fd9169a2269d65550f411a97dfa341a330df88b0bfab0af35'
  'syncthing|docker.io/syncthing/syncthing:2.1.7|sha256:2b71da7c0d0a91a6ae5285ad079226fecc0a365d08b27720e1f7037b018f7546'
  # Agent deployments (SDLC #711). agent-model is the pinned local inference
  # server; agent-runtime is Hermes, used by both gateways and by the hosted
  # proxy, which is why the proxy needs no third image and no package manager.
  'agent-model|ghcr.io/ggml-org/llama.cpp:server-cuda|sha256:ae96e52f8b2106ea82bad786ee2d08bb9b0a8c93403df9c27ae1bf065a118089'
  'agent-runtime|docker.io/nousresearch/hermes-agent:v0.23.1|sha256:276d44685c65c0cb2a25f190b63c65c8906f9dc76486fb1c05ae71b5826bda08'
  # Built by this repository (SDLC #775), not mirrored: upstream's entrypoint
  # installs its Python dependencies from PyPI at container start, which a sealed
  # deployment can never do. The digest is the publish-agent-webui run for the
  # Containerfile at that path; a rebuild prints a new row.
  'agent-webui|built:images/agent-webui/Containerfile|sha256:fb50509ef43bcdbe4dc5bda35d725a839ba851a3455a74bb5135d706cf622220'
  # The mail collector's provider half. Tuta serves no IMAP on purpose, so the far
  # side of the sync is TutaBridge: a local TLS IMAP server in front of Tuta's API,
  # and the only process that holds the account session. Mirrored, signed by our
  # key and pinned like every other application image. `latest` is unusable here:
  # Tuta raises the minimum client version it accepts (see manual-steps 40.15).
  'agent-tmail|docker.io/spartanz51/tutabridge:0.2.0-rc.2|sha256:044415d323d3c876c4275cc4cd0bdcbef303218bf5b1356b06aa31e0b6c92ba7'
  # The calendar's provider half: our own Tuta client (apps/tuta_calendar), built
  # and signed here because Tuta serves no CalDAV and no SDK of theirs ships. The
  # digest is the publish-tuta-calendar run for the Containerfile at that path.
  'tuta-calendar|built:images/tuta-calendar/Containerfile|sha256:c60a3021245e7874821daa54ede7cef7cfb35da6bf58855b5538d2037fd37e4b'
  # The collector egress gate (apps/agent_egress): an allowlist proxy and its DNS
  # responder, the only two peers a browsing collector may reach. Built here
  # because the policy and the checks that enforce it are ours.
  'agent-egress|built:images/agent-egress/Containerfile|sha256:535b96b8ca9efd303a168c9efe59c5acc8ef65e624d64f0ca22dbf58a31919c4'
  # The browsing collector's provider half: a real Brave from Brave's own release
  # `.deb`, which is the only way to get a browser that speaks the Sync protocol.
  # Built and signed here because the artifact is pinned by version and hash in the
  # Containerfile rather than mirrored. The digest is the publish-brave run for
  # that Containerfile; a rebuild prints a new row, and the Quadlet's `Image=` is
  # the other half and moves with it.
  'brave|built:images/brave/Containerfile|sha256:9b505ba383925597812ffb1d52876b3b5f8f00b2bf999418936521cbb13d707e'
)

# app_image_ref NAME -> the only reference a Quadlet may contain.
app_image_ref() {
  local name=$1 upstream digest
  while IFS='|' read -r entry upst digest; do
    [[ -n $entry ]] || continue
    if [[ $entry == "$name" ]]; then
      printf '%s/%s@%s\n' "$app_repo" "$name" "$digest"
      return 0
    fi
  done < <(printf '%s\n' "${app_images[@]}")
  echo "app-images: unknown application image: $name" >&2
  return 1
}

# app_image_upstream NAME -> the upstream reference and digest the mirror copies.
app_image_upstream() {
  local name=$1 entry upst digest
  while IFS='|' read -r entry upst digest; do
    [[ -n $entry ]] || continue
    if [[ $entry == "$name" ]]; then
      printf '%s\n' "$upst"
      return 0
    fi
  done < <(printf '%s\n' "${app_images[@]}")
  echo "app-images: unknown application image: $name" >&2
  return 1
}

# app_image_digest NAME -> the digest, which the mirror must preserve.
app_image_digest() {
  local name=$1 entry upst digest
  while IFS='|' read -r entry upst digest; do
    [[ -n $entry ]] || continue
    if [[ $entry == "$name" ]]; then
      printf '%s\n' "$digest"
      return 0
    fi
  done < <(printf '%s\n' "${app_images[@]}")
  echo "app-images: unknown application image: $name" >&2
  return 1
}

# app_image_source NAME -> the reference the mirror copies from: the upstream
# repository at the pinned digest, with no tag.
#
# skopeo refuses a reference that carries both a tag and a digest ("Docker
# references with both a tag and digest are currently not supported"), so the
# tag in the table stays documentation. The digest is the pin either way.
app_image_source() {
  local name=$1 upstream body
  upstream=$(app_image_upstream "$name") || return 1
  if [[ $upstream == built:* ]]; then
    echo "app-images: $name is built from ${upstream#built:}, not copied from an upstream image" >&2
    return 1
  fi
  body=${upstream%@*}
  # Only the last path segment may hold a tag: a registry port is not one.
  case ${body##*/} in
    *:*) body=${body%:*} ;;
  esac
  printf 'docker://%s@%s\n' "$body" "$(app_image_digest "$name")"
}

# app_image_built NAME -> the Containerfile a built row names. Succeeds only for
# a built image, whose bytes are ours: there is no upstream digest for the mirror
# to preserve, and mirror-app-images.sh must not try to copy it.
app_image_built() {
  local name=$1 upstream
  upstream=$(app_image_upstream "$name") || return 1
  [[ $upstream == built:* ]] || return 1
  printf '%s\n' "${upstream#built:}"
}

# app_image_names -> every name, one per line, in table order.
app_image_names() {
  local entry _upstream _digest
  while IFS='|' read -r entry _upstream _digest; do
    [[ -n $entry ]] || continue
    printf '%s\n' "$entry"
  done < <(printf '%s\n' "${app_images[@]}")
}

# app_image_matches REF -> true when REF is exactly this namespace's image at
# its pinned digest. Anything else is an unsigned or unpinned pull.
app_image_matches() {
  local ref=$1 name
  while IFS= read -r name; do
    if [[ $ref == "$(app_image_ref "$name")" ]]; then
      return 0
    fi
  done < <(app_image_names)
  return 1
}

# app_image_platform_digests -> read an OCI image index on stdin and print the
# digest of every manifest a host could select.
#
# containers/image verifies the platform manifest it copies, not the index
# digest, so these are the digests the mirror has to sign in addition to the
# index. Attestation manifests ("unknown/unknown") are never pulled as images
# and are skipped. A single-manifest image prints nothing.
app_image_platform_digests() {
  jq -r '.manifests[]?
    | select((.platform.os // "unknown") != "unknown"
        and (.platform.architecture // "unknown") != "unknown")
    | .digest'
}
