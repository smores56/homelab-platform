#!/usr/bin/env bats
# bats file_tags=core
# Every application image is our namespace at the pinned digest, and the
# source skopeo copies is the upstream repository at that digest.
#
# One file of the suite that was tests/core/app-quadlets.bats, split so bats can
# run the sections as parallel files (a file is one job). The tables, the
# file-scope sources and every checker more than one section calls are in
# tests/core/app-quadlets_lib.bash; the checkers only this file uses stay here.
#
#   bats tests/core/app-quadlets-images.bats
load ../helpers
load ./app-quadlets_lib

setup_file() { aq_setup_file; }
setup() { aq_setup; }

quadlet_images() { # quadlet
  sed -n 's/^Image=//p' "$1"
}

# 1. Every application image is our namespace at the pinned digest, and the pin
#    preserves the upstream digest the mirror verified.
declares_one_image() { # quadlet
  local images
  mapfile -t images < <(quadlet_images "$1")
  assert_equal "${#images[@]}" 1
}

runs_the_pinned_signed_mirror() { # quadlet
  # shellcheck source=/dev/null
  source scripts/app-images.sh
  local images
  mapfile -t images < <(quadlet_images "$1")
  printf '%s\n' "${images[0]:-}" >&2
  app_image_matches "${images[0]:-}"
}

for _q in "${app_quadlets[@]}"; do
  registered "$_q declares one image" declares_one_image "$_q"
  registered "$_q runs the pinned signed mirror" runs_the_pinned_signed_mirror "$_q"
done
unset _q

pin_is_a_digest() { # name
  # shellcheck source=/dev/null
  source scripts/app-images.sh
  local digest
  digest=$(app_image_digest "$1")
  printf '%s\n' "$digest" >&2
  [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]]
}

builds_from_an_existing_containerfile() { # name
  # shellcheck source=/dev/null
  source scripts/app-images.sh
  local built
  built=$(app_image_built "$1") || return 1
  if [[ ! -f $built ]]; then
    printf 'missing Containerfile %s\n' "$built" >&2
    return 1
  fi
}

built_row_has_no_copyable_source() { # name
  # shellcheck source=/dev/null
  source scripts/app-images.sh
  [[ $(app_image_source "$1" 2>/dev/null) == "" ]]
}

upstream_digest_equals_the_pin() { # name
  # shellcheck source=/dev/null
  source scripts/app-images.sh
  local digest upstream
  digest=$(app_image_digest "$1")
  upstream=$(app_image_upstream "$1")
  assert_equal "${upstream##*@}" "$digest"
}

pin_is_upstream() { # name
  # shellcheck source=/dev/null
  source scripts/app-images.sh
  local upstream
  upstream=$(app_image_upstream "$1")
  printf '%s\n' "$upstream" >&2
  [[ $upstream != "$(app_image_ref "$1")" ]]
}

for _row in "${app_images[@]}"; do
  IFS='|' read -r _name _upstream _digest <<<"$_row"
  if [[ -z $_name ]]; then
    continue
  fi
  registered "$_name pin is a digest" pin_is_a_digest "$_name"
  # A built row names the Containerfile this repository builds and signs itself
  # (publish-images.yml). The bytes are ours, so there is no upstream digest
  # to preserve and nothing for the mirror to copy -- only the Containerfile has
  # to exist, and the digest has to be the one that run printed.
  if [[ $_upstream == built:* ]]; then
    _built=${_upstream#built:}
    registered "$_name builds from $_built" builds_from_an_existing_containerfile "$_name"
    registered "$_name built row has no copyable source" built_row_has_no_copyable_source "$_name"
    continue
  fi
  if [[ $_upstream == *@sha256:* ]]; then
    registered "$_name upstream digest equals the pin" upstream_digest_equals_the_pin "$_name"
  fi
  # A pin that already names our namespace would make the mirror a no-op and the
  # signature check meaningless.
  registered "$_name pin is upstream" pin_is_upstream "$_name"
done
unset _row _name _upstream _digest _built

# 1b. The reference handed to skopeo is the upstream repository at the pinned
#     digest and carries no tag: skopeo refuses a name with both ("Docker
#     references with both a tag and digest are currently not supported"), which
#     is how the first publish run failed after merge. Built rows are skipped:
#     their workflow pushes them by digest and nothing copies them.
skopeo_source_is_repo_at_digest() { # name
  # shellcheck source=/dev/null
  source scripts/app-images.sh
  local digest upstream want_repo
  digest=$(app_image_digest "$1")
  upstream=$(app_image_upstream "$1")
  # Independent of app_image_source: strip the digest and then the tag with sed.
  want_repo=$(printf '%s\n' "$upstream" | sed -E 's/@sha256:[0-9a-f]+$//; s/:[^/:]+$//')
  assert_equal "$(app_image_source "$1")" "docker://$want_repo@$digest"
}

for _row in "${app_images[@]}"; do
  IFS='|' read -r _name _upstream _digest <<<"$_row"
  if [[ -z $_name || $_upstream == built:* ]]; then
    continue
  fi
  registered "$_name skopeo source is repo@digest" skopeo_source_is_repo_at_digest "$_name"
done
unset _row _name _upstream _digest

# 1b'. The refusal is what protects a built row from the mirror: with a
#      `built:` upstream there is no repository to copy, so a source that
#      silently stripped the prefix would hand skopeo a name that cannot resolve.
built_row_probe() {
  # shellcheck disable=SC2034  # the sourced helpers read this table
  app_images=("probe|built:images/agent-webui/Containerfile|sha256:$(printf 'a%.0s' {1..64})")
}

@test "a built row has no copyable source" {
  # shellcheck source=/dev/null
  source scripts/app-images.sh
  built_row_probe
  run app_image_source probe
  assert_failure
}

@test "a built row names its Containerfile" {
  # shellcheck source=/dev/null
  source scripts/app-images.sh
  built_row_probe
  assert_equal "$(app_image_built probe)" images/agent-webui/Containerfile
}

@test "a built row is referenced by our namespace at the pinned digest" {
  # shellcheck source=/dev/null
  source scripts/app-images.sh
  built_row_probe
  assert_equal "$(app_image_ref probe)" \
    "ghcr.io/smores56/homelab-platform/probe@sha256:$(printf 'a%.0s' {1..64})"
}
@test "the runtime image names repositories safe for git" {
    # SDLC #1009: git refuses a repository owned by another uid, and it compares
    # uids -- a shared group would not clear it. The general deployment edits the
    # operator's bare repos under /srv/git, so the image says so once.
    grep -qF -- "git config --system --add safe.directory '*'" \
        images/agent-runtime/Containerfile
}
