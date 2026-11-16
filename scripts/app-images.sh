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
  body=${upstream%@*}
  # Only the last path segment may hold a tag: a registry port is not one.
  case ${body##*/} in
    *:*) body=${body%:*} ;;
  esac
  printf 'docker://%s@%s\n' "$body" "$(app_image_digest "$name")"
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
