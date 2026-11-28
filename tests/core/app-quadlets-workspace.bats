#!/usr/bin/env bats
# bats file_tags=core
# The personal Hermes Workspace: it shares the gateway's network namespace so it
# can reach the loopback dashboard, publishes nothing itself, and keeps the
# operator's data plane to the gateway's own write targets.
#
#   bats tests/core/app-quadlets-workspace.bats
load ../helpers
load ./app-quadlets_lib

setup_file() { aq_setup_file; }
setup() { aq_setup; }

readonly workspace=units/quadlet/agent-workspace-personal.container
readonly agent_local=units/quadlet/agent-local.container

@test "the workspace shares the gateway's network namespace" {
  assert_equal "$(sed -n 's/^Network=//p' "$workspace")" agent-local.container
  ! grep -q '^PublishPort=' "$workspace"
}

@test "the gateway publishes the workspace's loopback UI port and matches its PORT" {
  grep -qxF 'PublishPort=127.0.0.1:18008:3000' "$agent_local"
  assert_equal "$(sed -n 's/^Environment=PORT=//p' "$workspace")" 3000
}

@test "the workspace runs the pinned signed mirror" {
  # shellcheck source=/dev/null
  source scripts/app-images.sh
  assert_equal "$(sed -n 's/^Image=//p' "$workspace")" "$(app_image_ref agent-workspace)"
}

@test "the workspace points at the gateway and dashboard on the shared loopback" {
  grep -qxF 'Environment=HERMES_API_URL=http://127.0.0.1:18001' "$workspace" &&
    grep -qxF 'Environment=HERMES_DASHBOARD_URL=http://127.0.0.1:9119' "$workspace"
}

@test "the dashboard binds loopback, where only the shared namespace can reach it" {
  grep -qxF 'Environment=HERMES_DASHBOARD=1' "$agent_local" &&
    grep -qxF 'Environment=HERMES_DASHBOARD_HOST=127.0.0.1' "$agent_local" &&
    grep -qxF 'Environment=HERMES_DASHBOARD_PORT=9119' "$agent_local"
}

@test "the workspace follows the gateway's namespace lifecycle" {
  grep -qxF 'BindsTo=agent-local.service' "$workspace" &&
    grep -qxF 'PartOf=agent-local.service' "$workspace" &&
    grep -qxF 'Upholds=agent-workspace-personal.service' "$agent_local"
}

@test "the workspace remaps the image account to uid 1000 instead of forcing --user" {
  grep -qxF 'Environment=HERMES_UID=1000' "$workspace" &&
    grep -qxF 'Environment=HERMES_GID=1000' "$workspace" &&
    ! grep -q '^User=' "$workspace"
}

@test "the workspace takes its token and password from the root-only runtime file" {
  assert_equal "$(sed -n 's/^EnvironmentFile=//p' "$workspace")" \
    /run/smortress/workspace.env
  ! grep -qE '^Environment=(HERMES_API_TOKEN|HERMES_PASSWORD)=' "$workspace"
}

@test "the seed writes the workspace values into /run, outside the agent dataset" {
  grep -qF 'HERMES_API_TOKEN=%s' "$seed_script" &&
    grep -qF 'HERMES_PASSWORD=%s' "$seed_script" &&
    grep -qF '/run/smortress/workspace.env' "$seed_script" &&
    grep -qF 'install -o 0 -g 0 -m 0400 "$home/webui.env.new" "$home/webui.env"' "$seed_script" &&
    grep -qF 'install -o 0 -g 0 -m 0400 /run/smortress/workspace.env.new' "$seed_script"
}

@test "the workspace keeps the gateway's data-plane write targets" {
  grep -qxF 'Volume=/srv/files:/workspace:ro' "$workspace" &&
    grep -qxF 'Volume=/srv/files/todos:/workspace/todos:rw' "$workspace" &&
    grep -qxF 'Volume=/srv/files/notes:/workspace/notes:rw' "$workspace" &&
    grep -qxF 'Volume=/srv/files/vault:/workspace/vault:ro' "$workspace"
}

@test "the workspace mounts its state volume and the agent's memory read-only" {
  grep -qxF 'Environment=HERMES_HOME=/home/workspace/.hermes' "$workspace" &&
    grep -qxF 'Volume=agent-workspace-state:/home/workspace/.hermes' "$workspace" &&
    grep -qxF 'Volume=/var/lib/agent/local/memory:/home/workspace/.hermes/memory:ro' "$workspace"
}

@test "the workspace does not trust forwarded headers from bridge peers" {
  ! grep -q '^Environment=TRUST_PROXY=' "$workspace"
}

@test "the workspace never names the hosted provider key" {
  ! grep -qF 'agent-hosted-key' "$workspace"
}

@test "the assistant Service is the workspace, not the legacy web UI" {
  grep -qF -- '--service=svc:assistant --https=443 http://127.0.0.1:18008' scripts/tailscale-serve.sh &&
    ! grep -qE '\[[0-9]+\]=18006|svc:assistant .*:18006' scripts/tailscale-serve.sh
}

@test "the tailnet probe expects the workspace's served shell" {
  grep -qE '^\s*\[assistant\]=2$' scripts/verify-tailnet-names.sh
}

@test "the restore drill covers the workspace container" {
  grep -qF 'smortress-agent-workspace-personal' scripts/agent-runtime-drill.sh
}
