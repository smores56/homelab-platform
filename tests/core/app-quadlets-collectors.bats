#!/usr/bin/env bats
# bats file_tags=core
# The collectors: one template, seven drop-ins, and the timers that were already
# per collector.
#
# One file of the suite that was tests/core/app-quadlets.bats, split so bats can
# run the sections as parallel files (a file is one job). The tables, the
# file-scope sources and every checker more than one section calls are in
# tests/core/app-quadlets_lib.bash; the checkers only this file uses stay here.
#
# SDLC #1021 collapsed thirteen units into `smortress-agent-collect@.service` and
# `smortress-agent-collect@<name>.service.d/`. The suite changed with it and stayed
# a parity claim: the same seven collectors, on the same schedules, with the same
# budgets, sources, addresses, credentials and subcommands. What it asserts about
# the *shared* half (the digest, the hardening, the Python environment) is one
# check over the template plus one over every stage of every fragment, so the
# collapse can neither quietly reintroduce a copy nor quietly drop a flag.
#
#   bats tests/core/app-quadlets-collectors.bats
load ../helpers
load ./app-quadlets_lib

setup_file() { aq_setup_file; }
setup() { aq_setup; }

readonly template=units/systemd/smortress-agent-collect@.service

drop_in() { # instance -> the fragment that says what this collector is
  printf 'units/systemd/smortress-agent-collect@%s.service.d/10-collect.conf\n' "$1"
}

# The seven collectors: what starts one, when, and how long its stages may take.
# The schedule and the budget are parity facts moved out of the old units, not
# preferences chosen again, so each is asserted verbatim.
collector_schedules=(
  "brave|units/systemd/smortress-agent-collect-brave.timer|*-*-* 00/6:20:00|600"
  "calendar|units/systemd/smortress-agent-collect-calendar.timer|*-*-* 00/2:40:00|900"
  "finance|units/systemd/smortress-agent-collect-finance.timer|*-*-* 06:30:00|300"
  "music|units/systemd/smortress-agent-collect-music.timer|*-*-* *:50:00|900"
  "notes|units/systemd/smortress-agent-collect-notes.timer|*-*-* *:20:00|300"
  "photos|units/systemd/smortress-agent-collect-photos.timer|*-*-* *:35:00|900"
  "tasks|units/systemd/smortress-agent-collect-tasks.timer|*-*-* *:25:00|120"
)

# The same seven again: the address a collection stage gets, the credential only
# the provider collectors hold, the ordering their source dataset needs, the
# arguments that name the collector's own module and input, the path that has to
# exist first, and the source tree the collection stage is handed read-only. A
# local-file collector leaves the address, the credential and the ordering empty;
# the collector that took its own snapshot leaves the source empty, because its
# source is the quarantine copy its first stage writes.
collector_shapes=(
  "brave|none|||brave --database /quarantine/History --device smortress --profile default|/var/lib/agent/local/quarantine/brave-profile/Default/History|/var/lib/agent/local/quarantine/brave:/quarantine:ro"
  "calendar|systemd-agent-collect||sops-decrypt.service smortress-app-secrets.service agent-collect-network.service|calendar --entities /entities|/var/lib/agent/local/quarantine/tuta-calendar/session.gpg|/var/lib/agent/local/quarantine/calendar:/entities:ro"
  "finance|systemd-agent-collect|simplefin-access-url|sops-decrypt.service smortress-app-secrets.service agent-collect-network.service|finance --access-url-file /run/secrets/simplefin-access-url --include-pending||"
  "music|none|||music --entities /entities|/srv/music|/srv/music:/entities:ro"
  "notes|none|||notes --entities /entities|/srv/files/vault|/srv/files/vault:/entities:ro"
  "photos|none|||photos --entities /entities|/srv/photos|/srv/photos:/entities:ro"
  "tasks|none|||tasks --entities /entities|/srv/files/todos/todo.txt|/srv/files/todos:/entities:ro"
)

# The checkers a register loop names: one claim each, so the loop carries no
# per-item logic of its own.
collector_has_a_fragment() { # fragment
  [[ -f $1 ]]
}

collector_timer_runs_the_instance() { # timer instance
  [[ $(sed -n 's/^Unit=//p' "$1") == "smortress-agent-collect@$2.service" ]]
}

collector_timer_fires_on() { # timer schedule
  grep -qxF "OnCalendar=$2" "$1"
}

collector_timer_closes_a_missed_run() { # timer
  grep -qxF 'Persistent=true' "$1"
}

collector_keeps_its_budget() { # fragment seconds
  grep -qxF "TimeoutStartSec=$2" "$1"
}

collector_reaches_no_address() { # fragment
  ! grep -q '^Environment="\?AGENT_COLLECT_NETWORK=' "$1"
}

collector_reaches_only_the_collectors_network() { # fragment network
  grep -qxF "Environment=AGENT_COLLECT_NETWORK=$2" "$1"
}

collector_starts_the_generated_network_unit() { # fragment
  grep -qE '^Requires=.*agent-collect-network\.service' "$1"
}

collector_is_ordered_after_the_generated_network_unit() { # fragment
  grep -qE '^After=.*agent-collect-network\.service' "$1"
}

collector_is_not_on_a_deployment_network() { # template fragment
  ! grep -qE -- '--network agent-(local|general)\.network' "$1" "$2"
}

collector_holds_its_credential_once() { # fragment secret
  assert_equal "$(grep -cF -- "--secret $2,type=mount,uid=1000,gid=1000,mode=0400" "$1")" 1
}

collector_holds_no_credential() { # template fragment
  assert_equal "$(grep -c -- '--secret' "$1" "$2" | awk -F: '{n += $2} END {print n}')" 0
}

collector_never_names_another_secret() { # fragment
  ! grep -qE -- 'agent-(hosted-key|facade-(personal|general)-token)' "$1"
}

collector_waits_for() { # fragment unit
  grep -qE "^Requires=.*$2" "$1"
}

collector_is_ordered_after() { # fragment unit
  grep -qE "^After=.*$2" "$1"
}

collector_mounts_its_source_read_only() { # fragment source
  grep -qF -- "AGENT_COLLECT_SOURCE=--volume $2" "$1"
}

collector_reads_the_source_it_staged() { # fragment
  ! grep -q '^Environment="\?AGENT_COLLECT_SOURCE=--volume' "$1"
}

collector_runs_its_own_subcommand() { # fragment arguments
  grep -qxF "Environment=\"AGENT_COLLECT_ARGS=$2\"" "$1"
}

collector_is_skipped_until_its_input_exists() { # fragment path
  grep -qxF "ConditionPathExists=$2" "$1"
}

collector_needs_no_input_condition() { # fragment
  ! grep -q '^ConditionPathExists=' "$1"
}

collector_stages_all_run_with() { # instance variable
  # Every stage this collector runs carries the template's flag set -- including
  # the stage the template itself holds, and every stage the fragment adds: the
  # shared half is not optional for a stage that was written here.
  assert_equal "$(cat "$template" "$(drop_in "$1")" | grep -cF "\${$2}" || true)" \
    "$(collector_stages "$1")"
}

collector_names_no_runtime_digest() { # fragment
  ! grep -qF 'agent-runtime@sha256' "$1"
}

collector_runs_the_code_its_own_image_ships() { # template fragment
  baked_by_runtime_image /usr/lib/data-plane &&
    ! grep -qF -- '--volume /usr/lib/data-plane' "$1" "$2"
}

collector_pins_its_image_to_the_table() { # fragment
  local literal
  while IFS= read -r literal; do
    image_is_pinned_in_the_table "$literal" || return 1
  done < <(grep -oE 'ghcr\.io/[a-z0-9./-]+@sha256:[0-9a-f]{64}' "$1")
}

# The stages of one collector are the template's collection stage plus whatever
# its fragment adds in front (`ExecStartPre=`) or behind (`ExecStart=`), so the
# count is only true of the pair.
collector_stages() { # instance -> number of stages the merged unit runs
  local file total=0
  for file in "$template" "$(drop_in "$1")"; do
    total=$((total + $(grep -cE '^ExecStart(Pre)?=' "$file")))
  done
  printf '%s\n' "$total"
}

# 8. The template: the pinned runtime, the container's Python environment, the
#    flag set every stage runs under, and the one stage every collector has.
#    Everything here is written once, which is the whole point of the collapse.
@test "units/systemd/smortress-agent-collect@.service exists" {
  [[ -f $template ]]
}

@test "the collector template is the only collector unit that names the runtime digest" {
  # `units/systemd/smortress-agent-collect*` covers the template, the seven
  # fragments and the seven timers: the digest belongs to the template alone, and
  # every stage in every fragment spells `${AGENT_COLLECT_IMAGE}` instead.
  assert_equal "$(grep -rlF 'agent-runtime@sha256' units/systemd/smortress-agent-collect*)" \
    "$template"
}

@test "the template's runtime image is the digest the table pins" {
  local image
  image=$(sed -n 's/^Environment=AGENT_COLLECT_IMAGE=//p' "$template")
  image_is_pinned_in_the_table "$image"
}

@test "the template hardens every stage in one flag set" {
  local hardening flag
  hardening=$(sed -n 's/^Environment="AGENT_COLLECT_HARDENING=\(.*\)"$/\1/p' "$template")
  for flag in '--read-only' '--cap-drop=all' '--security-opt no-new-privileges' '--user 1000:1000'; do
    assert_contains "$hardening" "$flag"
  done
}

@test "the template's collection stage replaces a stale container" {
  # `--replace` on every stage start: a killed run leaves a container behind, and
  # without it the next pass fails on the name instead of collecting.
  grep -qF -- '--rm --replace --name smortress-agent-collect-%i' "$template"
}

@test "the template puts the data plane's package root on PYTHONPATH once" {
  # `/usr/lib/data-plane/libs` *and* `/usr/lib/data-plane`: the package lives under
  # the first, and a unit naming only the second imports nothing -- which is how
  # both collectors shipped once.
  grep -qF -- 'AGENT_COLLECT_ENV=--env PYTHONPATH=/usr/lib/data-plane/libs:/usr/lib/data-plane' "$template" &&
    grep -qF -- '--env PYTHONDONTWRITEBYTECODE=1' "$template"
}

@test "the template's collection stage is the only one, and it writes the replica tree" {
  assert_equal "$(grep -cE '^ExecStart=' "$template")" 1
  grep -qF -- '--volume /var/lib/agent/local/replica:/replica:z' "$template"
  # One writable mount, the replica: a collection stage can add read-only mounts
  # but never a second place to write.
  assert_equal "$(grep -cE -- '--volume [^ ]*:z' "$template")" 1
  # The collector itself is handed no address and no secret of its own -- the
  # defaults are the local-file case, and a provider collector overrides the keys
  # its fragment needs.
  grep -qxF 'Environment=AGENT_COLLECT_NETWORK=none' "$template"
  assert_equal "$(grep -c -- '--secret' "$template")" 0
}

@test "the template waits for the replica dataset and the agent config" {
  grep -qE '^Requires=.*zfs-ready@state-agent-local\.service' "$template" &&
    grep -qE '^After=.*zfs-ready@state-agent-local\.service' "$template" &&
    grep -qE '^Requires=.*smortress-agent-config\.service' "$template" &&
    grep -qE '^After=.*smortress-agent-config\.service' "$template"
}

@test "the collector set is the seven instances, and no collector service is left behind" {
  # The unit set did not change in the collapse: seven collectors, each with one
  # fragment for the things only that collector knows.
  local expected
  expected=$(printf '%s\n' "${collector_schedules[@]}" | cut -d'|' -f1 | sort)
  assert_equal "$(ls -d units/systemd/smortress-agent-collect@*.service.d |
    sed -e 's|.*collect@||' -e 's|\.service\.d||' | sort)" "$expected"
  assert_equal "$(ls units/systemd/smortress-agent-collect-*.service 2>/dev/null | wc -l)" 0
}

# The ExecStart blocks of a unit file, continuation lines and all: an image, an
# environment or a flag belongs to a stage, and a claim about stages cannot be
# counted over the whole file without counting the comments and the definitions.
stage_blocks() { # file
  awk '/^ExecStart(Pre)?=/ {printing = 1} printing {print} printing && !/\\$/ {printing = 0}' "$1"
}

@test "every collector stage names exactly one image" {
  # One image per stage is what makes the digest reviewable: a stage naming two
  # images, or none at all, would run code no table lists.
  local file stages images
  for file in "$template" units/systemd/smortress-agent-collect@*.service.d/*.conf; do
    stages=$(grep -cE '^ExecStart(Pre)?=' "$file" || true)
    images=$(stage_blocks "$file" |
      grep -oE '\$\{AGENT_COLLECT_IMAGE\}|ghcr\.io/[a-z0-9./-]+@sha256:[0-9a-f]{64}' | wc -l)
    if [[ $stages != "$images" ]]; then
      printf '%s: %s stages, %s images\n' "$file" "$stages" "$images" >&2
      return 1
    fi
  done
}

@test "every stage that runs the runtime image carries the data plane's environment" {
  # PYTHONPATH and PYTHONDONTWRITEBYTECODE belong to the code the runtime image
  # ships, so a stage that runs that image is handed both and a stage that runs
  # another image (the calendar's exporter) is not given a path it cannot use.
  local file
  for file in "$template" units/systemd/smortress-agent-collect@*.service.d/*.conf; do
    assert_equal "$(stage_blocks "$file" | grep -cF '${AGENT_COLLECT_IMAGE}')" \
      "$(stage_blocks "$file" | grep -cF '${AGENT_COLLECT_ENV}')"
  done
}

for _case in "${collector_schedules[@]}"; do
  IFS='|' read -r _name _timer _schedule _timeout <<<"$_case"
  registered "$_name collector has a fragment" collector_has_a_fragment "$(drop_in "$_name")"
  registered "$_timer runs the $_name instance" \
    collector_timer_runs_the_instance "$_timer" "$_name"
  registered "$_timer still fires on $_schedule" collector_timer_fires_on "$_timer" "$_schedule"
  registered "$_timer closes a missed run on the next boot" \
    collector_timer_closes_a_missed_run "$_timer"
  registered "$_name keeps its $_timeout second budget" \
    collector_keeps_its_budget "$(drop_in "$_name")" "$_timeout"
done
unset _case _name _timer _schedule _timeout

for _case in "${collector_shapes[@]}"; do
  IFS='|' read -r _name _network _credential _requires _arguments _condition _source <<<"$_case"
  _frag=$(drop_in "$_name")
  if [[ $_network == none ]]; then
    registered "$_name reaches no address at all" collector_reaches_no_address "$_frag"
  else
    registered "$_name reaches only the collectors' network" \
      collector_reaches_only_the_collectors_network "$_frag" "$_network"
    registered "$_name starts the generated network unit" \
      collector_starts_the_generated_network_unit "$_frag"
    registered "$_name is ordered after the generated network unit" \
      collector_is_ordered_after_the_generated_network_unit "$_frag"
  fi
  # A deployment's network carries the provider key: no collector may join one.
  registered "$_name is not on a deployment network" \
    collector_is_not_on_a_deployment_network "$template" "$_frag"
  if [[ -n $_credential ]]; then
    registered "$_name mounts only its own credential, in one stage" \
      collector_holds_its_credential_once "$_frag" "$_credential"
  else
    registered "$_name holds no credential" collector_holds_no_credential "$template" "$_frag"
  fi
  registered "$_name never names another deployment's secret" \
    collector_never_names_another_secret "$_frag"
  for _unit in $_requires; do
    registered "$_name waits for $_unit" collector_waits_for "$_frag" "$_unit"
    registered "$_name is ordered after $_unit" collector_is_ordered_after "$_frag" "$_unit"
  done
  if [[ -n $_source ]]; then
    registered "$_name mounts its source read-only" \
      collector_mounts_its_source_read_only "$_frag" "$_source"
  else
    registered "$_name reads the source it staged itself" \
      collector_reads_the_source_it_staged "$_frag"
  fi
  registered "$_name runs its own subcommand over its own input" \
    collector_runs_its_own_subcommand "$_frag" "$_arguments"
  if [[ -n $_condition ]]; then
    registered "$_name is skipped until its input exists" \
      collector_is_skipped_until_its_input_exists "$_frag" "$_condition"
  else
    registered "$_name needs no input condition" collector_needs_no_input_condition "$_frag"
  fi
  registered "$_name's stages all carry the template's flag set" \
    collector_stages_all_run_with "$_name" AGENT_COLLECT_HARDENING
  registered "$_name names no runtime digest of its own" \
    collector_names_no_runtime_digest "$_frag"
  registered "$_name runs the code its own image ships" \
    collector_runs_the_code_its_own_image_ships "$template" "$_frag"
  registered "$_name's own image is the digest the table pins" \
    collector_pins_its_image_to_the_table "$_frag"
done
unset _case _name _frag _unit _network _credential _requires _arguments _condition _source

# The four collectors that only walk a local tree are one stage each; the three
# provider collectors are three. That count is the collapse's parity claim at the
# only place it can be read, so it is asserted here as well as in the suites that
# own each stage sequence.
@test "the local-file collectors are still one stage" {
  local name
  for name in music notes photos tasks; do
    assert_equal "$(collector_stages "$name")" 1
  done
}

@test "the three provider collectors are still three stages" {
  local name
  for name in brave calendar finance; do
    assert_equal "$(collector_stages "$name")" 3
  done
}
