#!/usr/bin/env bats
# bats file_tags=agent-data-plane
# The general deployment's Mirage instance (SDLC #979, T5): the same image and
# daemon shape as the personal one, and the opposite authority. What this suite
# exists to hold is the split: general sees repositories and nothing personal, and
# the two instances never share a token, a mount or a port.
#
# Static, because the only things that differ from the personal slice are the
# things a file can state. The virtual `git` CLI is Mirage's own and needs no
# network; a real `gh` waits for the machine support Mirage 0.1.0 does not have
# (#980), so nothing here pretends to push.
load ../helpers

general_quadlet=units/quadlet/mirage-general.container
personal_quadlet=units/quadlet/mirage-personal.container
general_workspace=bootc/server/rootfs/etc/smortress/mirage/general.yaml
personal_workspace=bootc/server/rootfs/etc/smortress/mirage/personal.yaml
general_hermes=bootc/server/rootfs/etc/smortress/agent/general-config.yaml

block_of() { # block_of FILE IDENT
  awk -v ident="$2" '
    $0 ~ "^[[:space:]]*"ident":" {found = 1; print; next}
    found && /^[[:space:]]*[^[:space:]#]/ {print}
  ' "$1"
}

@test "the general instance joins the egress network and publishes nothing" {
  grep -qxF 'Network=agent-general.network' "$general_quadlet"
  refute grep -q '^PublishPort=' "$general_quadlet"
}

@test "the general instance runs the same pinned image as the personal one" {
  general_digest=$(sed -n 's/^Image=//p' "$general_quadlet")
  personal_digest=$(sed -n 's/^Image=//p' "$personal_quadlet")
  assert_equal "$general_digest" "$personal_digest"
  run grep -F "'mirage|built:images/mirage/Containerfile|${general_digest#*@}'" scripts/app-images.sh
  assert_success
}

@test "the general workspace has the repositories read-write" {
  run block_of "$general_workspace" /data/git
  assert_success
  assert_contains "$output" "root: /srv/git"
  assert_contains "$output" "mode: write"
}

@test "the general workspace has no personal path at all" {
  refute grep -qE '/data/(todos|vault)|/feed' "$general_workspace"
  refute grep -qE '/srv/files' "$general_quadlet"
}

@test "the personal instance cannot see the repositories" {
  refute grep -qE '/srv/git' "$personal_quadlet" "$personal_workspace"
}

@test "the general workspace has no delete ask, because git is YOLO by decision" {
  refute grep -q 'decision: ask' "$general_workspace"
  grep -qE '^\s+"?\*"?: allow$' "$general_workspace"
}

@test "the general workspace shell has no network" {
  grep -qxF '    network: false' "$general_workspace"
}

@test "the general gateway reaches its own instance on its own port" {
  run grep -A3 '^  mirage:' "$general_hermes"
  assert_success
  assert_contains "$output" "http://smortress-mirage-general:18011/v1/workspaces/general/mcp"
  assert_contains "$output" "Authorization: __MIRAGE_TOKEN__"
}

@test "each instance's token is its own and the general templates never name the personal one" {
  run grep -qxF 'mirage-general-token.yaml mirage-general.json mirage.general_token root root 0400 value' \
    bootc/server/rootfs/usr/share/smortress/secrets.manifest
  assert_success
  refute grep -q 'mirage-personal-token' "$general_quadlet" "$general_hermes"
  run python3 -c 'import json;print(json.load(open("secrets/mirage-general.json"))["mirage"]["general_token"])'
  assert_success
  assert_contains "$output" 'ENC['
}

@test "the seed names each deployment's token and writes its mirage.env" {
  grep -qxF '      general) mirage_token=$secrets_dir/mirage-general-token.yaml ;;' scripts/agent-config-seed.sh
  grep -qxF '      personal) mirage_token=$secrets_dir/mirage-personal-token.yaml ;;' scripts/agent-config-seed.sh
  run grep -n 'MIRAGE_AUTH_TOKEN=%s' scripts/agent-config-seed.sh
  assert_success
}

@test "the image installs the general Quadlet" {
  run grep -F 'units/quadlet/mirage-general.container' bootc/server/Containerfile
  assert_success
}
