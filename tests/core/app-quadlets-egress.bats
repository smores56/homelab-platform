#!/usr/bin/env bats
# bats file_tags=core
# The egress gate and the browsing collector behind it, plus every unit the
# image enables.
#
# One file of the suite that was tests/core/app-quadlets.bats, split so bats can
# run the sections as parallel files (a file is one job). The tables, the
# file-scope sources and every checker more than one section calls are in
# tests/core/app-quadlets_lib.bash; the checkers only this file uses stay here.
#
#   bats tests/core/app-quadlets-egress.bats
load ../helpers
load ./app-quadlets_lib

setup_file() { aq_setup_file; }
setup() { aq_setup; }

image_enables() { # unit basename
  grep -qF "$1" bootc/server/Containerfile
}

# 8d. The egress gate: an internal network with exactly two peers, and a policy
#     that lives in the image. A collector's reach is a reviewed fact, not
#     something a container can edit, and nothing is published.
@test "the browsing network is internal and addressed" {
  local brave_net=units/quadlet/agent-brave.network
  [[ -f $brave_net ]] && grep -qxF 'Internal=true' "$brave_net" && grep -qE '^Subnet=' "$brave_net"
}

@test "the egress policy is a document that grants exactly the sync host" {
  python3 - bootc/server/rootfs/etc/smortress/agent/egress-policy.json <<'PYJSON'
import json, sys
document = json.load(open(sys.argv[1], encoding="utf-8"))
allow = document["sources"]["brave"]["allow"]
assert "sync-v2.brave.com:443" in allow
PYJSON
}

egress_gate() { # gate (proxy or dns)
  printf 'units/quadlet/agent-egress-%s.container\n' "$1"
}

egress_gate_joins_only_the_internal_network() { # gate
  assert_equal "$(sed -n 's/^Network=agent-brave\.network.*//p' "$(egress_gate "$1")" | grep -c .)" 0
}

egress_gate_is_on_the_internal_network() { # gate
  grep -qE '^Network=agent-brave\.network(:ip=[0-9.]+)?$' "$(egress_gate "$1")"
}

egress_gate_reaches_upstream_on_the_collectors_network() { # gate
  grep -qxF 'Network=agent-collect.network' "$(egress_gate "$1")"
}

egress_gate_reads_the_policy_read_only() { # gate
  grep -qF 'egress-policy.json:/etc/smortress/agent/egress-policy.json:ro' "$(egress_gate "$1")"
}

quadlet_runs_a_pinned_image() { # quadlet
  # shellcheck source=/dev/null
  source scripts/app-images.sh
  local image
  image=$(grep -oE '^Image=.*' "$1" | cut -d= -f2-)
  image_is_pinned_in_the_table "$image"
}

for _gate in proxy dns; do
  _unit=units/quadlet/agent-egress-$_gate.container
  _base=${_unit##*/}
  registered "$_unit exists" file_exists "$_unit"
  registered "$_unit joins the internal network" egress_gate_joins_only_the_internal_network "$_gate"
  registered "$_unit is on the internal network" egress_gate_is_on_the_internal_network "$_gate"
  registered "$_unit reaches upstream on the collectors' network" \
    egress_gate_reaches_upstream_on_the_collectors_network "$_gate"
  registered "$_unit reads the policy read-only" egress_gate_reads_the_policy_read_only "$_gate"
  registered "$_unit publishes nothing" quadlet_publishes_nothing "$_unit"
  registered "$_unit runs a pinned image from the table" quadlet_runs_a_pinned_image "$_unit"
  registered "the image installs $_base" image_installs "$_base"
done
unset _gate _unit _base

@test "the DNS responder holds only the capability it needs" {
  grep -qxF 'AddCapability=NET_BIND_SERVICE' units/quadlet/agent-egress-dns.container &&
    grep -qxF 'DropCapability=ALL' units/quadlet/agent-egress-dns.container
}

@test "the collector network ships in the image" {
  grep -qF 'units/quadlet/agent-collect.network' bootc/server/Containerfile
}

secret_has_a_strict_manifest_entry() { # secret
  grep -qE "^${1//./\\.}\.yaml[[:space:]]" bootc/server/rootfs/usr/share/smortress/secrets.manifest
}

secret_becomes_a_podman_secret() { # secret
  grep -qF "$1" scripts/app-secrets.sh
}

for _secret in simplefin-access-url tmail-bridge-password; do
  registered "$_secret has a decrypt manifest entry" secret_has_a_strict_manifest_entry "$_secret"
  registered "$_secret becomes a Podman secret" secret_becomes_a_podman_secret "$_secret"
done
unset _secret

# 8e. The browsing collector (#713): a real browser whose only egress is the gate
#     above, a profile seeded before it starts, a snapshot the collector can
#     accept, and a watcher on the profile's own database. The peer addresses are
#     derived from the two gate Quadlets rather than repeated here: moving the
#     proxy or the resolver has to fail this section too.
readonly brave=units/quadlet/agent-brave.container
readonly brave_seed=units/systemd/smortress-agent-brave-seed.service
readonly brave_collect=units/systemd/smortress-agent-collect-brave.service
readonly brave_path=units/systemd/smortress-agent-collect-brave.path
readonly brave_timer=units/systemd/smortress-agent-collect-brave.timer

egress_proxy_ip() {
  sed -n 's/^Network=agent-brave\.network:ip=\([0-9.]*\)$/\1/p' units/quadlet/agent-egress-proxy.container
}
egress_proxy_port() {
  sed -n 's/^Exec=proxy .*--listen [0-9.]*:\([0-9]*\)$/\1/p' units/quadlet/agent-egress-proxy.container
}
egress_dns_ip() {
  sed -n 's/^Network=agent-brave\.network:ip=\([0-9.]*\)$/\1/p' units/quadlet/agent-egress-dns.container
}

@test "the egress gate names two distinct peers" {
  local proxy_ip proxy_port dns_ip
  proxy_ip=$(egress_proxy_ip)
  proxy_port=$(egress_proxy_port)
  dns_ip=$(egress_dns_ip)
  if [[ -z $proxy_ip || -z $proxy_port || -z $dns_ip || $proxy_ip == "$dns_ip" ]]; then
    printf 'proxy=%s:%s dns=%s\n' "$proxy_ip" "$proxy_port" "$dns_ip" >&2
    return 1
  fi
}

@test "units/quadlet/agent-brave.container exists" {
  [[ -f $brave ]]
}

@test "units/quadlet/agent-brave.container joins exactly one network" {
  assert_equal "$(grep -cE '^Network=' "$brave")" 1
}

@test "the browser is on the internal network and nowhere else" {
  grep -qE '^Network=agent-brave\.network(:ip=[0-9.]+)?$' "$brave"
}

@test "the browser publishes nothing" {
  ! grep -qE '^PublishPort=' "$brave"
}

@test "the browser runs a pinned image from the table" {
  quadlet_runs_a_pinned_image "$brave"
}

@test "the profile volume is the chain membership, label-shared" {
  grep -qxF 'Volume=/var/lib/agent/local/quarantine/brave-profile:/data:z' "$brave"
}

for _flag in 'ReadOnly=true' 'User=1000:1000' 'NoNewPrivileges=true' 'DropCapability=ALL'; do
  registered "the browser sets $_flag" quadlet_sets "$brave" "$_flag"
done
unset _flag

@test "the browser has a writable tmpfs for its scratch space" {
  grep -qE '^Tmpfs=/tmp:' "$brave"
}

@test "the browser resolves through the allowlist responder" {
  local dns_ip
  dns_ip=$(egress_dns_ip)
  if ! grep -qE -- "--dns=$dns_ip( |$)" "$brave"; then
    printf 'want --dns=%s\n' "$dns_ip" >&2
    return 1
  fi
}

@test "the browser's only egress is the allowlist proxy" {
  local proxy_ip proxy_port
  proxy_ip=$(egress_proxy_ip)
  proxy_port=$(egress_proxy_port)
  if ! grep -qE -- "--proxy-server=http://$proxy_ip:$proxy_port( |\$)" "$brave"; then
    printf 'want http://%s:%s\n' "$proxy_ip" "$proxy_port" >&2
    return 1
  fi
}

@test "the browser is bounded at 640/800 MiB" {
  grep -qE -- '--memory=640m' "$brave" && grep -qE -- '--memory-swap=800m' "$brave"
}

browser_runs_with() { # flag
  grep -qF -- "$1" "$brave"
}

for _flag in '--headless=new' '--no-sandbox' '--password-store=basic' '--user-data-dir=/data'; do
  registered "the browser runs with $_flag" browser_runs_with "$_flag"
done
unset _flag

@test "the browser restarts except on a deliberate stop" {
  grep -qxF 'Restart=always' "$brave" && grep -qxF 'SuccessExitStatus=143' "$brave"
}

@test "the browser starts after its profile is seeded" {
  grep -qE '^After=.*smortress-agent-brave-seed\.service' "$brave"
}

@test "units/systemd/smortress-agent-brave-seed.service exists" {
  [[ -f $brave_seed ]]
}

@test "the seed is planted before the Quadlet-generated browser unit" {
  grep -qE '^Before=.*agent-brave\.service' "$brave_seed"
}

@test "the seed is a Podman secret at uid 1000 mode 0400" {
  assert_equal "$(grep -cF -- '--secret brave-sync-seed,type=mount,uid=1000,gid=1000,mode=0400' "$brave_seed")" 1
}

@test "the seed unit waits for the profile directory the seeder creates" {
  grep -qxF 'ConditionPathExists=/var/lib/agent/local/quarantine/brave-profile' "$brave_seed"
}

@test "the seeder is a local one-shot with no address" {
  assert_equal "$(grep -cE '^ *--network ' "$brave_seed")" 1 &&
    grep -qE '^ *--network none' "$brave_seed" &&
    grep -qF -- '-m apps.brave_ingest.seed' "$brave_seed"
}

@test "the seeder is the second process that may write the profile" {
  grep -qE -- '/var/lib/agent/local/quarantine/brave-profile:/data:z' "$brave_seed"
}

@test "the image enables the seed unit" {
  grep -qF 'smortress-agent-brave-seed.service' bootc/server/Containerfile
}

@test "units/systemd/smortress-agent-collect-brave.service exists" {
  [[ -f $brave_collect ]]
}

@test "units/systemd/smortress-agent-collect-brave.service is snapshot then collect" {
  assert_equal "$(grep -cE '^ExecStart=' "$brave_collect")" 2
}

@test "the snapshot stage runs before the collector stage" {
  local snapshot_line collect_line
  snapshot_line=$(grep -nF 'apps.brave_ingest.snapshot' "$brave_collect" | cut -d: -f1)
  collect_line=$(grep -nF 'data_plane.collectors.raw' "$brave_collect" | cut -d: -f1)
  if [[ -z $snapshot_line || -z $collect_line || $snapshot_line -ge $collect_line ]]; then
    printf 'snapshot=%s collect=%s\n' "$snapshot_line" "$collect_line" >&2
    return 1
  fi
}

@test "only the snapshot writes the quarantine copy" {
  grep -qE -- '/var/lib/agent/local/quarantine/brave-profile:/profile:ro' "$brave_collect" &&
    grep -qE -- '/var/lib/agent/local/quarantine/brave:/quarantine:z' "$brave_collect"
}

@test "the collector reads the copy read-only" {
  grep -qE -- '/var/lib/agent/local/quarantine/brave:/quarantine:ro' "$brave_collect"
}

@test "the collector names the device and profile the replica is keyed by" {
  grep -qF -- 'brave --database /quarantine/History --device smortress --profile default' \
    "$brave_collect"
}

@test "neither stage has a network" {
  assert_equal "$(grep -cE -- '--network none' "$brave_collect")" 2
}

@test "the collection pass holds no Podman secret" {
  ! grep -qE -- '--secret ' "$brave_collect"
}

for _image in $(grep -oE 'ghcr\.io/smores56/homelab-platform/[a-z-]+@sha256:[0-9a-f]{64}' "$brave_collect"); do
  registered "the collection pass runs a pinned image from the table" image_is_pinned_in_the_table "$_image"
done
unset _image

for _unit in smortress-agent-collect-brave.path smortress-agent-collect-brave.timer; do
  registered "the image enables $_unit" image_enables "$_unit"
done
unset _unit

@test "units/systemd/smortress-agent-collect-brave.path exists" {
  [[ -f $brave_path ]]
}

@test "the watcher runs the collection pass" {
  assert_equal "$(sed -n 's/^Unit=//p' "$brave_path")" "$(basename "$brave_collect")"
}

@test "the watcher follows the profile's History" {
  assert_equal \
    "$(grep -cE '^PathModified=/var/lib/agent/local/quarantine/brave-profile/Default/History$' "$brave_path")" 1
}

@test "the watcher also follows the sidecar a write appears in first" {
  grep -qxF 'PathModified=/var/lib/agent/local/quarantine/brave-profile/Default/History-wal' \
    "$brave_path"
}

@test "the reconcile timer runs the collection pass" {
  assert_equal "$(sed -n 's/^Unit=//p' "$brave_timer")" "$(basename "$brave_collect")"
}

@test "the reconcile timer closes a missed pass on the next boot" {
  grep -qxF 'Persistent=true' "$brave_timer"
}

@test "the reconcile timer is six-hourly" {
  grep -qE '^OnCalendar=\*-\*-\* 00/6:' "$brave_timer"
}

# shellcheck disable=SC2016  # the matched text is a line of the seed script
@test "the seeder creates the profile 0700 and the copy 0750, personal only" {
  grep -qF 'install -d -o 1000 -g 1000 -m 0700 "$home/quarantine/brave-profile"' "$seed_script" &&
    grep -qF 'install -d -o 1000 -g 1000 -m 0750 "$home/quarantine/brave"' "$seed_script"
}

for _module in apps/brave_ingest/*.py; do
  registered "the runtime image installs ${_module#apps/brave_ingest/}" runtime_image_installs "$_module"
done
unset _module

@test "brave-sync-seed has a decrypt manifest entry" {
  grep -qE '^brave-sync-seed\.yaml[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+root[[:space:]]+root[[:space:]]+0400[[:space:]]+value' \
    bootc/server/rootfs/usr/share/smortress/secrets.manifest
}

@test "brave-sync-seed becomes a Podman secret" {
  grep -qF 'brave-sync-seed' scripts/app-secrets.sh
}

# `systemctl enable` on a unit with no [Install] section is a silent no-op: the
# build succeeds, `is-enabled` reports "static", and nothing starts it at boot.
# The mail stream and the Brave seed shipped that way and stayed dead until an
# operator started them by hand on every boot, so every unit the image enables
# has to be enableable. Template instances in the list come from packaged units
# and are skipped.
@test "every smortress unit the image enables declares [Install]" {
  local enable_block never_starts=() unit
  enable_block=$(sed -n '/systemctl enable \\$/,/;[[:space:]]*\\$/p' bootc/server/Containerfile)
  while read -r unit; do
    if [[ $unit == *@* ]]; then
      continue
    fi
    if [[ ! -f units/systemd/$unit ]]; then
      continue
    fi
    if ! grep -qx '\[Install\]' "units/systemd/$unit"; then
      never_starts+=("$unit")
    fi
  done < <(grep -oE 'smortress-[a-z0-9.-]+\.(service|timer|path)' <<<"$enable_block" | sort -u)
  if ((${#never_starts[@]} != 0)); then
    printf '%s\n' "${never_starts[*]}" >&2
    return 1
  fi
}

# A unit that runs the data plane has to hand the container the package, not
# only the facade tree: `-m data_plane` with `/usr/lib/agent-facade` alone is
# `No module named data_plane` on every tick. The calendar collector shipped
# that way and failed its first real run after a clean dump.
puts_the_data_plane_on_pythonpath() { # unit
  if ! grep -q -- '--env PYTHONPATH=/usr/lib/agent-facade/libs:/usr/lib/agent-facade' "$1"; then
    printf '%s\n' "$(grep -n 'PYTHONPATH' "$1" || echo 'no PYTHONPATH at all')" >&2
    return 1
  fi
}

for _unit in units/systemd/*.service; do
  _runs_data_plane=0
  while IFS= read -r _line; do
    case $_line in
      *'-m data_plane'*)
        _runs_data_plane=1
        break
        ;;
    esac
  done <"$_unit"
  if ((!_runs_data_plane)); then
    continue
  fi
  registered "$_unit puts the data plane on PYTHONPATH" puts_the_data_plane_on_pythonpath "$_unit"
done
unset _unit _line _runs_data_plane
