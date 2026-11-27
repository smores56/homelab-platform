#!/usr/bin/env bats
# bats file_tags=core
# The finance projection, the calendar pair, the bridge and the mail stream:
# the passes whose stages feed the personal index.
#
# One file of the suite that was tests/core/app-quadlets.bats, split so bats can
# run the sections as parallel files (a file is one job). The tables, the
# file-scope sources and every checker more than one section calls are in
# tests/core/app-quadlets_lib.bash; the checkers only this file uses stay here.
#
#   bats tests/core/app-quadlets-collections.bats
load ../helpers
load ./app-quadlets_lib

setup_file() { aq_setup_file; }
setup() { aq_setup; }

# 8.1. The finance collector's third stage: the hledger projection. It is derived
#     state, so it reads the replica read-only and writes one directory under the
#     personal index -- the same directory the seed unit creates at uid 1000.
readonly finance_unit=units/systemd/smortress-agent-collect-finance.service

@test "units/systemd/smortress-agent-collect-finance.service is collect then project" {
  assert_equal "$(grep -cE '^ExecStart=' "$finance_unit")" 2
}

@test "units/systemd/smortress-agent-collect-finance.service projects the replica into the personal index" {
  grep -qF -- '--volume /var/lib/agent/local/replica:/replica:ro' "$finance_unit" &&
    grep -qF -- '--volume /var/lib/agent/local/index:/index:z' "$finance_unit" &&
    grep -qF -- '--out /index/hledger/finance.journal' "$finance_unit"
}

@test "units/systemd/smortress-agent-collect-finance.service holds its credential in one stage only" {
  assert_equal "$(grep -cF -- '--secret ' "$finance_unit")" 1
}

# 8a. The calendar pair: our own exporter (session held on a volume, no secret)
#     followed by the collector. The session is the account's access, so it is
#     mounted read-write only into stage 1 and never into the collector.
readonly calendar=units/systemd/smortress-agent-collect-calendar.service
readonly calendar_timer=units/systemd/smortress-agent-collect-calendar.timer

@test "units/systemd/smortress-agent-collect-calendar.service exists" {
  [[ -f $calendar ]]
}

@test "units/systemd/smortress-agent-collect-calendar.service is dump then collect" {
  assert_equal "$(grep -cE '^ExecStart=' "$calendar")" 2
}

@test "units/systemd/smortress-agent-collect-calendar.service names the collector network" {
  assert_equal "$(grep -cE -- '--network systemd-agent-collect' "$calendar")" \
    "$(grep -cE -- '--network ' "$calendar")"
}

@test "the calendar pass holds no Podman secret" {
  ! grep -qE -- '--secret ' "$calendar"
}

@test "the calendar pass waits for the sealed session" {
  grep -qE '^ConditionPathExists=.*quarantine/tuta-calendar/session\.gpg' "$calendar"
}

@test "the session volume is mounted once, read-write" {
  assert_equal "$(grep -cF -- '/var/lib/agent/local/quarantine/tuta-calendar:/data:z' "$calendar")" 1
}

@test "the collector reads the dump read-only" {
  grep -qE -- '/var/lib/agent/local/quarantine/calendar:/entities:ro' "$calendar"
}

for _image in $(grep -oE 'ghcr\.io/smores56/homelab-platform/[a-z-]+@sha256:[0-9a-f]{64}' "$calendar"); do
  registered "the calendar pass runs a pinned image from the table" image_is_pinned_in_the_table "$_image"
done
unset _image

@test "units/systemd/smortress-agent-collect-calendar.timer runs the calendar pass" {
  assert_equal "$(sed -n 's/^Unit=//p' "$calendar_timer")" "$(basename "$calendar")"
}

@test "units/systemd/smortress-agent-collect-calendar.timer closes a missed run on the next boot" {
  grep -qxF 'Persistent=true' "$calendar_timer"
}

# 8b. The bridge: the provider half. It holds the Tuta session, so its volume is
#     the account, and it sits on the collectors' network rather than a
#     deployment's.
readonly bridge=units/quadlet/agent-tmail.container

@test "units/quadlet/agent-tmail.container exists" {
  [[ -f $bridge ]]
}

@test "the bridge runs a pinned image from the table" {
  # shellcheck source=/dev/null
  source scripts/app-images.sh
  local image
  image=$(grep -oE '^Image=.*' "$bridge" | cut -d= -f2-)
  if ! app_image_matches "$image"; then
    printf '%s\n' "$image" >&2
    return 1
  fi
}

@test "the bridge names exactly one network" {
  assert_equal "$(grep -cE '^Network=' "$bridge")" 1
}

@test "the bridge is on the collectors' network" {
  grep -qxF 'Network=agent-collect.network' "$bridge"
}

@test "the bridge's session volume is the one dataset path" {
  grep -qxF 'Volume=/var/lib/agent/local/quarantine/tmail:/data:z' "$bridge"
}

@test "the bridge has a read-only root" {
  grep -qxF 'ReadOnly=true' "$bridge"
}

@test "the bridge runs as the uid that owns its certificate" {
  grep -qxF 'User=1000:1000' "$bridge"
}

@test "the bridge has a writable tmpfs for its runtime dir" {
  grep -qE '^Tmpfs=/tmp:' "$bridge"
}

for _flag in 'NoNewPrivileges=true' 'DropCapability=ALL'; do
  registered "the bridge sets $_flag" quadlet_sets "$bridge" "$_flag"
done
unset _flag

@test "the bridge publishes nothing" {
  ! grep -qE '^PublishPort=' "$bridge"
}

# 8c. The mail stream collector: the one process that reads the bridge. It is a
#     long-running service, not a timer, and it must never hold the bridge's
#     session volume -- only the certificate it verifies.
readonly stream=units/systemd/smortress-agent-mail-stream.service

@test "units/systemd/smortress-agent-mail-stream.service exists" {
  [[ -f $stream ]]
}

@test "units/systemd/smortress-agent-mail-stream.service names exactly one network" {
  assert_equal "$(grep -cE -- '--network ' "$stream")" 1
}

@test "the mail stream runs on the collectors' network" {
  grep -qE -- '--network systemd-agent-collect' "$stream"
}

@test "the mail stream requires the Quadlet-generated bridge unit" {
  grep -qE '^(Requires|After)=.*agent-tmail\.service' "$stream"
}

@test "the mail stream waits for the certificate that init creates" {
  grep -qxF 'ConditionPathExists=/var/lib/agent/local/quarantine/tmail/config/tutabridge/cert.pem' \
    "$stream"
}

@test "the mail stream mounts only the bridge password" {
  grep -qF -- '--secret tmail-bridge-password,type=mount,uid=1000,gid=1000,mode=0400' "$stream"
}

@test "the mail stream never mounts the bridge's session volume" {
  ! grep -qE -- '--volume [^ ]*quarantine/tmail(:|/data)' "$stream"
}

@test "the mail stream verifies the bridge certificate" {
  grep -qF -- 'cert.pem:/bridge/cert.pem:ro' "$stream"
}

@test "the mail stream is a supervised long-running service" {
  grep -qE '^Restart=on-failure' "$stream" && grep -qE '^Type=simple' "$stream"
}

@test "the image enables the mail stream" {
  grep -qF 'smortress-agent-mail-stream.service' bootc/server/Containerfile
}
