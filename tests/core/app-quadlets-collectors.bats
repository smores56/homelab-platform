#!/usr/bin/env bats
# bats file_tags=core
# The collectors: the only processes with egress, and the two local-file ones
# that need no network at all.
#
# One file of the suite that was tests/core/app-quadlets.bats, split so bats can
# run the sections as parallel files (a file is one job). The tables, the
# file-scope sources and every checker more than one section calls are in
# tests/core/app-quadlets_lib.bash; the checkers only this file uses stay here.
#
#   bats tests/core/app-quadlets-collectors.bats
load ../helpers
load ./app-quadlets_lib

setup_file() { aq_setup_file; }
setup() { aq_setup; }

# 8. The collectors: the only processes with egress that write into the personal
#    dataset. Each runs the repository's own code out of the booted image, as uid
#    1000, with a read-only root, on the collectors' network -- never a
#    deployment's, because the general network carries the provider key.
collector_cases=(
  "finance|units/systemd/smortress-agent-collect-finance.service|units/systemd/smortress-agent-collect-finance.timer|simplefin-access-url"
)

collector_field() { # spec field number
  cut -d'|' -f"$2" <<<"$1"
}

collector_names_the_quadlet_network() { # spec
  assert_equal "$(grep -cE -- '--network systemd-agent-collect' "$(collector_field "$1" 2)")" 1
}

# Two stages reach two different places: the collector is on the Quadlet's
# network, the projection reads what it published and gets `none` because it
# needs no socket at all. Anything else is a unit that quietly grew egress.
collector_reaches_only_its_network_and_none() { # spec
  local unexpected
  unexpected=$(grep -E -- '^[[:space:]]*--network ' "$(collector_field "$1" 2)" |
    grep -vE -- '--network (systemd-agent-collect|none)([[:space:]\\]|$)' || true)
  if [[ -n $unexpected ]]; then
    printf '%s\n' "$unexpected" >&2
    return 1
  fi
}

collector_starts_the_generated_network_unit() { # spec
  local collector
  collector=$(collector_field "$1" 2)
  grep -qE '^Requires=.*agent-collect-network\.service' "$collector" &&
    grep -qE '^After=.*agent-collect-network\.service' "$collector"
}

collector_is_not_on_a_deployment_network() { # spec
  ! grep -qE -- '--network agent-(local|general)\.network' "$(collector_field "$1" 2)"
}

collector_runs_with() { # spec flag
  grep -qF -- "$2" "$(collector_field "$1" 2)"
}

collector_mounts_only_its_own_credential() { # spec
  grep -qF -- "--secret $(collector_field "$1" 4),type=mount,uid=1000,gid=1000,mode=0400" \
    "$(collector_field "$1" 2)"
}

collector_never_names_another_secret() { # spec
  ! grep -qE -- 'agent-(hosted-key|facade-(personal|general)-token)' "$(collector_field "$1" 2)"
}

collector_runs_a_pinned_image() { # spec image
  image_is_pinned_in_the_table "$2"
}

collector_runs_the_code_its_own_image_ships() { # spec
  baked_by_runtime_image /usr/lib/data-plane &&
    ! grep -qF -- '/usr/lib/data-plane:/usr/lib/data-plane:ro' "$(collector_field "$1" 2)"
}

collector_timer_runs_the_collector() { # spec
  assert_equal "$(sed -n 's/^Unit=//p' "$(collector_field "$1" 3)")" \
    "$(basename "$(collector_field "$1" 2)")"
}

collector_timer_closes_a_missed_run() { # spec
  grep -qxF 'Persistent=true' "$(collector_field "$1" 3)"
}

for _case in "${collector_cases[@]}"; do
  IFS='|' read -r _name _collector _timer _secret <<<"$_case"
  registered "$_collector exists" file_exists "$_collector"
  registered "$_name collector names the network Quadlet actually creates" \
    collector_names_the_quadlet_network "$_case"
  registered "$_name collector reaches only its own network and none" \
    collector_reaches_only_its_network_and_none "$_case"
  registered "$_name collector starts the generated network unit" \
    collector_starts_the_generated_network_unit "$_case"
  registered "$_name collector is not on a deployment network" \
    collector_is_not_on_a_deployment_network "$_case"
  for _flag in '--read-only' '--cap-drop=all' '--security-opt no-new-privileges' '--user 1000:1000'; do
    registered "$_name collector runs with $_flag" collector_runs_with "$_case" "$_flag"
  done
  registered "$_name collector mounts only its own credential" \
    collector_mounts_only_its_own_credential "$_case"
  registered "$_name collector never names another deployment's secret" \
    collector_never_names_another_secret "$_case"
  while IFS= read -r _image; do
    registered "$_name collector runs a pinned image from the table" \
      collector_runs_a_pinned_image "$_case" "$_image"
  done < <(grep -oE 'ghcr\.io/smores56/homelab-platform/[a-z-]+@sha256:[0-9a-f]{64}' "$_collector")
  registered "$_name collector runs the code its own image ships" \
    collector_runs_the_code_its_own_image_ships "$_case"
  registered "$_timer runs the collector" collector_timer_runs_the_collector "$_case"
  registered "$_timer closes a missed run on the next boot" collector_timer_closes_a_missed_run "$_case"
done
unset _case _name _collector _timer _secret _flag _image

# 8.0. The two local-file collectors: a vault and a todo directory need no
#      provider, no network and no secret, so none of the shared case above
#      applies. What they must never grow is exactly that -- an address, a
#      credential, or a writable source -- and what they must carry is the
#      read-only source mount and the writable replica tree.
local_collectors=(
  "notes|units/systemd/smortress-agent-collect-notes.service|units/systemd/smortress-agent-collect-notes.timer|/srv/files/vault"
  "tasks|units/systemd/smortress-agent-collect-tasks.service|units/systemd/smortress-agent-collect-tasks.timer|/srv/files/notes"
  "photos|units/systemd/smortress-agent-collect-photos.service|units/systemd/smortress-agent-collect-photos.timer|/srv/photos"
  "music|units/systemd/smortress-agent-collect-music.service|units/systemd/smortress-agent-collect-music.timer|/srv/music"
)

local_collector_field() { # spec field number
  cut -d'|' -f"$2" <<<"$1"
}

local_collector_runs_with() { # spec flag
  grep -qF -- "$2" "$(local_collector_field "$1" 2)"
}

local_collector_is_one_stage() { # spec
  assert_equal "$(grep -cE '^ExecStart=' "$(local_collector_field "$1" 2)")" 1
}

local_collector_has_no_address() { # spec
  grep -qE -- '--network none([[:space:]\\]|$)' "$(local_collector_field "$1" 2)"
}

local_collector_names_no_network() { # spec
  ! grep -qE -- '--network (systemd-agent-collect|agent-(local|general))\b' \
    "$(local_collector_field "$1" 2)"
}

local_collector_mounts_its_source_read_only() { # spec
  grep -qF -- "--volume $(local_collector_field "$1" 4):/entities:ro" \
    "$(local_collector_field "$1" 2)"
}

local_collector_writes_one_replica_tree() { # spec
  grep -qF -- '--volume /var/lib/agent/local/replica:/replica:z' "$(local_collector_field "$1" 2)"
}

local_collector_holds_no_secret() { # spec
  ! grep -qE -- '--secret|/run/secrets|-e [A-Z_]+=' "$(local_collector_field "$1" 2)"
}

local_collector_runs_the_subcommand() { # spec
  local unit
  unit=$(local_collector_field "$1" 2)
  grep -qE -- '--entrypoint python3' "$unit" &&
    grep -qF -- "$(local_collector_field "$1" 1) --entities /entities" "$unit"
}

local_collector_waits_for_the_replica_dataset() { # spec
  local unit
  unit=$(local_collector_field "$1" 2)
  grep -qE '^Requires=.*zfs-ready@state-agent-local\.service' "$unit" &&
    grep -qE '^After=.*zfs-ready@state-agent-local\.service' "$unit"
}

local_collector_timer_runs_and_closes_a_missed_run() { # spec
  local timer
  timer=$(local_collector_field "$1" 3)
  [[ -f $timer ]] &&
    [[ $(sed -n 's/^Unit=//p' "$timer") == "$(basename "$(local_collector_field "$1" 2)")" ]] &&
    grep -qxF 'Persistent=true' "$timer"
}

for _case in "${local_collectors[@]}"; do
  IFS='|' read -r _name _unit _timer _source_dir <<<"$_case"
  registered "$_unit exists" file_exists "$_unit"
  registered "$_name collector is one stage" local_collector_is_one_stage "$_case"
  registered "$_name collector has no address at all" local_collector_has_no_address "$_case"
  registered "$_name collector names no network" local_collector_names_no_network "$_case"
  registered "$_name collector mounts its source read-only" \
    local_collector_mounts_its_source_read_only "$_case"
  registered "$_name collector writes one replica tree" local_collector_writes_one_replica_tree "$_case"
  for _flag in '--read-only' '--cap-drop=all' '--security-opt no-new-privileges' '--user 1000:1000'; do
    registered "$_name collector runs with $_flag" local_collector_runs_with "$_case" "$_flag"
  done
  registered "$_name collector holds no secret" local_collector_holds_no_secret "$_case"
  registered "$_name collector waits for the replica dataset" \
    local_collector_waits_for_the_replica_dataset "$_case"
  registered "$_name collector runs the collector subcommand" local_collector_runs_the_subcommand "$_case"
  while IFS= read -r _image; do
    registered "$_name collector runs a pinned image from the table" \
      collector_runs_a_pinned_image "$_case" "$_image"
  done < <(grep -oE 'ghcr\.io/smores56/homelab-platform/[a-z-]+@sha256:[0-9a-f]{64}' "$_unit")
  registered "$_timer runs the collector and closes a missed run" \
    local_collector_timer_runs_and_closes_a_missed_run "$_case"
done
unset _case _name _unit _timer _source_dir _flag _image
