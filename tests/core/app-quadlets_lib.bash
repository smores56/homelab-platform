# The shared half of the application Quadlet suite (SDLC #708, T5): the immutable
# lists, the two file-scope sources the register loops enumerate, the primitives
# a loop names directly, and every checker more than one section calls. Split out
# of tests/core/app-quadlets.bats so the sections run as parallel files; sourced
# with `load ./app-quadlets_lib`.
# `repo_root` comes from tests/helpers.bash; the tables come from
# scripts/app-images.sh and scripts/storage-layout.sh, which are sourced here at
# file scope because a register loop enumerates them before any setup runs, and
# the checkers below source the tables they exercise themselves, so a check of
# this file alone cannot see where they come from or who uses them.
# shellcheck disable=SC2154,SC2034

# bats sources this file, and runs each test, inside a function: a table's
# `declare -A` arrays are local to that function and gone by the test body, so
# every test and every checker here sources the tables it exercises itself. A
# plain assignment survives (the immutable lists below are such), an array
# declared with `declare -A` does not. Forgetting this is the one mistake that
# makes a check pass without reading anything, so each one names its own tables.
#
# `register` is a @test bats only understands as a loop: its description is the
# text the shell suite printed after `ok `, which the conversion compared by name. bats
# also refuses two tests with the same description and the same body, and this
# suite registers one check over one item more than once -- one image in two
# stages of a unit, one readiness instance for three volumes of a facade -- so
# `registered` appends a counter to the body. Every checker ignores an argument
# past the ones it reads.
registered_count=0
registered() { # description command...
  registered_count=$((registered_count + 1))
  register "$1" "${@:2}" "#$registered_count"
}

readonly app_quadlets=(
  units/quadlet/immich-server.container
  units/quadlet/immich-postgres.container
  units/quadlet/immich-valkey.container
  units/quadlet/immich-machine-learning.container
  units/quadlet/opdshelf.container
  units/quadlet/syncthing.container
  units/quadlet/navidrome.container
  units/quadlet/agent-model.container
  units/quadlet/agent-local.container
  units/quadlet/agent-general.container
  units/quadlet/agent-proxy.container
  units/quadlet/agent-webui-personal.container
  units/quadlet/agent-webui-general.container
  units/quadlet/agent-workspace-personal.container
  units/quadlet/agent-tmail.container
  units/quadlet/agent-brave.container
)

readonly image_interpreters=(/bin/sh /bin/bash /usr/bin/python3 /usr/bin/env /usr/bin/sh)
readonly runtime_containerfile=images/agent-runtime/Containerfile

# The file-scope sources below exist only to enumerate the items a register loop
# fans over, never to serve a test body. The loops parse those tables directly
# instead of calling their helpers: bats re-evaluates a section file in every one
# of its test processes, so a fork per row costs a second of wall clock per
# hundred rows, and the loops are the only thing that runs that often.
# shellcheck source=../scripts/app-images.sh disable=SC1091
source scripts/app-images.sh
# shellcheck source=../scripts/storage-layout.sh disable=SC1091
source scripts/storage-layout.sh

# bats' `load` sources this file inside a function, so storage-layout.sh's
# `declare -A` tables are local to it and gone by the register loop of the
# section file that enumerated one. `-g` puts the copy the loop reads in global
# scope; no checker reads it, since each sources the table it exercises itself.
eval "$(declare -p dataset_mount | sed 's/^declare -A /declare -gA /')"

# The checks a register loop can name directly: one statement each, so the loop
# carries no per-item logic of its own.
file_exists() { # path
  [[ -f $1 ]]
}

quadlet_sets() { # quadlet key=value
  grep -qxF "$2" "$1"
}

image_is_pinned_in_the_table() { # image reference
  # shellcheck source=/dev/null
  source scripts/app-images.sh
  if ! app_image_matches "$1"; then
    printf '%s\n' "$1" >&2
    return 1
  fi
}

image_installs() { # unit basename
  grep -qF "units/quadlet/$1" bootc/server/Containerfile
}

readonly tmpfiles=bootc/server/rootfs/etc/tmpfiles.d/smortress.conf

readonly agent_templates=(bootc/server/rootfs/etc/smortress/agent/local-config.yaml
  bootc/server/rootfs/etc/smortress/agent/general-config.yaml)

declares_exactly_one_network() { # quadlet
  assert_equal "$(grep -c '^Network=' "$1")" 1
}

readonly seed_script=scripts/agent-config-seed.sh

runtime_image_paths() { # the destinations the runtime image COPYs into place
  awk '/^COPY / { line = $0
                 while (line ~ /\\$/) { getline nxt; line = line " " nxt }
                 n = split(line, f, /[[:space:]]+/)
                 if (f[n] ~ /^\//) print f[n] }' "$runtime_containerfile"
}

baked_by_runtime_image() { # path
  local dest
  while IFS= read -r dest; do
    if [[ -z $dest ]]; then
      continue
    fi
    # A parent directory is delivered too: installing a file creates it, which is
    # how /usr/lib/data-plane resolves though only its children are COPYed.
    if [[ $1 == "$dest" || $1 == "$dest"/* || $dest == "$1"/* ]]; then
      return 0
    fi
  done < <(runtime_image_paths)
  return 1
}

quadlet_publishes_nothing() { # quadlet
  if grep -q '^PublishPort=' "$1"; then
    printf '%s\n' "$(grep '^PublishPort=' "$1")" >&2
    return 1
  fi
}

runtime_image_installs() { # path in the repository
  grep -qF "$1" images/agent-runtime/Containerfile
}

# bats evaluates this whole file, register loops included, before the first test:
# a section that lost either table would register nothing and report green, so
# the wrappers every section file calls prove the tables are loaded first.
aq_setup_file() {
    declare -F app_image_matches >/dev/null
    declare -F mountpoint_for >/dev/null
}

# Nothing per test: each checker sources the tables it exercises itself, and
# tests/helpers.bash has already put the process at the repository root.
aq_setup() {
    :
}
