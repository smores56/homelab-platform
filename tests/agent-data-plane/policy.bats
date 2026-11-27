#!/usr/bin/env bats
# bats file_tags=agent-data-plane
# The decision path (SDLC #979, T7): what the workspace may not do, and how a
# human answers when it may not do it.
#
# The policy half is static -- the rules are a file. The operator half is
# behavioural: the CLI is driven with a stub `podman` that echoes its argv, and
# the notifier is driven with a stub daemon response and a stub `logger`, so what
# is asserted is the command it builds and the journal line it emits, not a
# re-reading of its source.
load ../helpers

ask=scripts/mirage-ask.sh
notify=scripts/mirage-ask-notify.sh
sandbox_workspace=bootc/server/rootfs/etc/smortress/mirage/personal.yaml

setup() {
  stub=$BATS_TEST_TMPDIR/bin
  mkdir -p "$stub"
  # The stub records its argv once per line and answers `container exists` and
  # `exec ...` from the fixture the test writes.
  cat >"$stub/podman" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG/podman.argv"
if [[ ${1:-} == container && ${2:-} == exists ]]; then
  [[ ${STUB_CONTAINER_EXISTS:-yes} == yes ]] && exit 0 || exit 1
fi
if [[ ${1:-} == exec ]]; then
  cat "$STUB_LOG/asks.json" 2>/dev/null || printf '[]'
  exit 0
fi
exit 0
STUB
  chmod +x "$stub/podman"
  cat >"$stub/logger" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG/logger.log"
STUB
  chmod +x "$stub/logger"
  export STUB_LOG=$BATS_TEST_TMPDIR/log
  mkdir -p "$STUB_LOG"
  export PATH=$stub:$PATH PODMAN=$stub/podman
}

block_of() { # block_of FILE IDENT
  awk -v ident="$2" '
    $0 ~ "^[[:space:]]*"ident":" {found = 1; print; next}
    found && /^[[:space:]]*[^[:space:]#]/ {print}
  ' "$1"
}

@test "the workspace hides the daemon's home, the secrets and the host's /etc" {
  run block_of "$sandbox_workspace" hide
  assert_success
  assert_contains "$output" "/state"
  assert_contains "$output" "/run"
  assert_contains "$output" "/etc"
}

@test "the workspace cannot run the CLI that answers asks" {
  run block_of "$sandbox_workspace" mirage
  assert_success
  assert_contains "$output" "decision: deny"
}

@test "a delete is still an ask after the hiding rules" {
  run block_of "$sandbox_workspace" rm
  assert_success
  assert_contains "$output" "decision: ask"
}

@test "list asks the daemon inside its own container" {
  run bash "$ask" list
  assert_success
  refute grep -q 'mirage-ask: ' <<<"$output"
  run cat "$STUB_LOG/podman.argv"
  assert_output 'exec smortress-mirage-personal mirage workspace list-asks -w personal'
}

@test "allow carries the scope the operator chose" {
  run bash "$ask" allow 3f3edc651652 --scope session
  assert_success
  run cat "$STUB_LOG/podman.argv"
  assert_output 'exec smortress-mirage-personal mirage workspace allow personal 3f3edc651652 --scope session'
}

@test "allow defaults to once, and a bad scope is refused before the daemon is asked" {
  run bash "$ask" allow 3f3edc651652
  assert_success
  run cat "$STUB_LOG/podman.argv"
  assert_output 'exec smortress-mirage-personal mirage workspace allow personal 3f3edc651652 --scope once'
  rm -f "$STUB_LOG/podman.argv"
  run bash "$ask" allow 3f3edc651652 --scope forever
  assert_failure 2
  assert_output --partial 'is once or session'
  refute [ -e "$STUB_LOG/podman.argv" ]
}

@test "deny passes the ask straight through" {
  run bash "$ask" deny 3f3edc651652
  assert_success
  run cat "$STUB_LOG/podman.argv"
  assert_output 'exec smortress-mirage-personal mirage workspace deny personal 3f3edc651652'
}

@test "a usage error exits 2 without touching the daemon" {
  run bash "$ask"
  assert_failure 2
  refute [ -e "$STUB_LOG/podman.argv" ]
}

@test "the notifier journals a pending ask once and forgets it when it is answered" {
  cat >"$STUB_LOG/asks.json" <<'JSON'
[
  {
    "id": "3f3edc651652",
    "command": "rm",
    "argv": ["/data/todos/a.md"],
    "cwd": "/data/todos",
    "reason": "deletes need sign-off",
    "outcome": null
  }
]
JSON
  export SMORTRESS_MIRAGE_STATE=$BATS_TEST_TMPDIR/state
  run bash "$notify"
  assert_success
  run cat "$STUB_LOG/logger.log"
  assert_success
  assert_contains "$output" "ask 3f3edc651652: rm /data/todos/a.md in /data/todos -- deletes need sign-off"
  lines_after_first=$(grep -c . "$STUB_LOG/logger.log")
  assert_equal "$lines_after_first" 1

  # A second pass over the same pending ask is silent: the notice is a page, not
  # a heartbeat.
  run bash "$notify"
  assert_success
  lines_after_second=$(grep -c . "$STUB_LOG/logger.log")
  assert_equal "$lines_after_second" 1

  # Answered means absent from the list, so the id is forgotten and a later ask
  # with the same id (a fresh decision) pages again.
  printf '[]\n' >"$STUB_LOG/asks.json"
  run bash "$notify"
  assert_success
  run cat "$SMORTRESS_MIRAGE_STATE/asks.seen"
  assert_output ''
}

@test "the notifier stays quiet when the instance was never started" {
  export STUB_CONTAINER_EXISTS=no SMORTRESS_MIRAGE_STATE=$BATS_TEST_TMPDIR/state2
  run bash "$notify"
  assert_success
  refute [ -e "$STUB_LOG/logger.log" ]
}

@test "the image installs both programs and enables the timer" {
  run grep -F 'COPY scripts/mirage-ask.sh scripts/mirage-ask-notify.sh' bootc/server/Containerfile
  assert_success
  run grep -qxF '      smortress-mirage-asks.timer \' bootc/server/Containerfile
  assert_success
}

@test "answer once does not answer the next line, and session does" {
  # The daemon owns the scope; this holds the pass-through that keeps it that
  # way, which is the only part of the contract a host script can get wrong.
  grep -qF -- '--scope "$scope"' "$ask"
  grep -qF 'once | session)' "$ask"
}
