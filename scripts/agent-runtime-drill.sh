#!/usr/bin/env bash
# The probe texts are single-quoted on purpose: the container shell expands
# $1, this one must not. SC2016 is the rule that cannot see the difference.
# shellcheck disable=SC2016
# The operator drill for the agent layer's T6 runtime rows (SDLC #716).
#
# Seven rows of the T6 adversarial cutover matrix need smortress itself: the live
# mount namespaces, the root-only secrets, and a cold restore of an agent dataset
# from a real destination. This runs three of them by hand. Every PASS line is
# one observation on this host; docs/manual-steps.md section 40.18 maps the lines
# to the rows they close and shows what a bad result looks like.
#
#   mounts       no agent namespace contains the other deployment's state or a
#                personal source tree: /var/lib/agent/local, /var/srv/files,
#                /var/srv/photos and /var/srv/repo-archive are absent from the
#                general gateway, /var/lib/agent/general from the personal one.
#   credentials  no agent container and no collector can read the Restic
#                password, the R2 key pair or the age identity, probed as uid 0
#                and uid 1000 inside each namespace; the oneshot collectors that
#                are not running are covered by their unit definitions instead.
#   restore      one agent dataset restored cold from one destination, its tree
#                and ownership checked, the facade's FTS index rebuilt from the
#                restored records, and a second restore into the same target
#                refused. It does not fence: stop the writers first (section
#                40.18), because nothing here can stop a live process writing.
#
# Usage (as root on smortress, from a checkout of this repository):
#   sudo scripts/agent-runtime-drill.sh mounts
#   sudo scripts/agent-runtime-drill.sh credentials
#   sudo scripts/agent-runtime-drill.sh restore agent-local --backend ssd
#   sudo scripts/agent-runtime-drill.sh restore agent-general --backend all
#   scripts/agent-runtime-drill.sh --dry-run restore agent-local
#
# It prints secret names and file modes, never a value, and it never writes into
# a live dataset. `--dry-run` prints every command it would run and executes
# none, and it is the only mode that does not need root.
#
# Exit status: 0 when no check failed, 1 when any did, 2 on a usage error.
# shellcheck disable=SC2154  # the dataset table comes from storage-layout, sourced on demand
set -euo pipefail

readonly SELF=${0##*/}
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd -- "$here/.." && pwd)
layout=$here/storage-layout
[[ -r $layout ]] || layout=$layout.sh

readonly backends=(ssd hdd r2)
# A restore writes tens of GiB. The default parent is a data disk, never /var/tmp:
# the root filesystem holds the system, and a restore that fills it takes every
# service with it (docs/core/pool-rebuild.md). The restore-drill helper picks the
# same disks on its own; this mirrors it so the drill cannot re-point at root.
default_drill_root() {
  local candidate
  for candidate in /var/lib/restic/hdd /var/lib/restic/ssd; do
    if mountpoint -q "$candidate"; then
      printf '%s/drill' "$candidate"
      return 0
    fi
  done
  # Nothing is mounted: name the same disk the helper prefers. restore_one refuses
  # a target that resolves onto the root filesystem, so this cannot become /var/tmp.
  printf '%s' /var/lib/restic/hdd/drill
}
drill_root=${SMORTRESS_AGENT_DRILL_ROOT:-$(default_drill_root)}
readonly drill_root
readonly facade_tree=${AGENT_FACADE_TREE:-/usr/lib/agent-facade}

cmd=""
unit=""
backend=ssd
all_backends=0
snapshot=""
target=""
dry_run=0
stamp=""

usage() {
  cat <<'EOF'
usage: agent-runtime-drill.sh <subcommand> [options]

subcommands:
  mounts
      Probe the hostile mounts from inside the running gateways. From
      smortress-agent-general, attempt to read /var/lib/agent/local,
      /var/srv/files, /var/srv/photos and /var/srv/repo-archive; from
      smortress-agent-local, attempt /var/lib/agent/general. One PASS/FAIL line
      per path with the error the namespace answered, as uid 0 and uid 1000.
      Only the error is printed: no file name, no file content.

  credentials
      Prove no agent container (agent-local, agent-general, both facades, the
      model server, the proxy, both web UIs) and no collector can read the
      Restic password, the R2 key pair or the age identity. Each secret is
      probed inside every running namespace as uid 0 and uid 1000; a oneshot
      collector that is not running is covered by its unit definition instead.
      The host copy must be staged root-only first, and that is checked.

  restore <agent-local|agent-general>
      Restore one agent dataset cold with smortress-restic-restore-drill and
      check the result: gateway state (.env, config.yaml, webui.env), the web UI
      state and workspace, the facade memory profile, the collector quarantine
      and a published replica generation on the personal side, ownership
      1000:1000 with writability as uid 1000, an FTS rebuild of the restored
      memory records, and a second restore into the same target refused.

options:
  --backend ssd|hdd|r2|all   destination for `restore` (default: ssd)
  --snapshot <id>            restore this verified snapshot instead of the latest
  --target <dir>             restore target for a single backend; it must not be
                             inside a live dataset, and it must be empty
  --dry-run                  print every command, execute none
  -h, --help                 this text

Refuses to probe without root: the decrypted secrets are root-only 0400 and the
containers belong to root's Podman. `--dry-run` is the exception, because it
performs no I/O.

Environment:
  SMORTRESS_RESTIC_RESTORE_DRILL   path to the restore-drill helper
  SMORTRESS_AGENT_DRILL_ROOT       parent of the default restore target
                                   (default: the first mounted restic data disk,
                                   /var/lib/restic/ssd/drill or /var/lib/restic/hdd/drill)
  AGENT_FACADE_TREE                the facade code tree (/usr/lib/agent-facade)
EOF
}

say() { printf '%s\n' "$*"; }
warn() { printf '%s: %s\n' "$SELF" "$*" >&2; }
usage_error() {
  warn "$*"
  usage >&2
  exit 2
}

# Every external command goes through one of these two, so --dry-run cannot miss
# a call: `run` executes and `capture` executes into a variable, and both print
# themselves instead of running when the flag is set.
run() {
  if ((dry_run)); then
    { printf 'would run:'; printf ' %q' "$@"; printf '\n'; }
    return 0
  fi
  "$@"
}

capture() { # capture <variable> <command>...
  # The locals are prefixed: printf -v "$1" must never write into a name of its
  # own, or a caller asking for `out` would get an empty variable.
  local __out __rc=0
  if ((dry_run)); then
    { printf 'would run:'; printf ' %q' "${@:2}"; printf '\n'; }
    printf -v "$1" '%s' ''
    return 0
  fi
  __out=$("${@:2}" 2>&1) || __rc=$?
  printf -v "$1" '%s' "$__out"
  return "$__rc"
}

pass=0
fail=0
skip=0

record() { # record <PASS|FAIL|SKIP> <label> [detail]
  case $1 in
    PASS) pass=$((pass + 1)) ;;
    FAIL) fail=$((fail + 1)) ;;
    SKIP) skip=$((skip + 1)) ;;
  esac
  printf '%-4s %s\n' "$1" "$2"
  if [[ -n ${3:-} ]]; then
    printf '     %s\n' "${3//$'\n'/$'\n'     }"
  fi
  return 0
}

last_line() {
  local text=${1%$'\n'}
  printf '%s' "${text##*$'\n'}"
}

while (($#)); do
  case $1 in
    -h | --help)
      usage
      exit 0
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --backend)
      backend=${2:?--backend needs a value}
      shift 2
      ;;
    --snapshot)
      snapshot=${2:?--snapshot needs an id}
      shift 2
      ;;
    --target)
      target=${2:?--target needs a directory}
      shift 2
      ;;
    mounts | credentials | restore)
      [[ -z $cmd ]] || usage_error "one subcommand at a time: got $cmd and $1"
      cmd=$1
      shift
      ;;
    agent-local | agent-general)
      unit=$1
      shift
      ;;
    *)
      usage_error "unknown argument: $1"
      ;;
  esac
done

[[ -n $cmd ]] || usage_error "a subcommand is required: mounts, credentials or restore"
case $cmd in
  mounts | credentials)
    [[ -z $unit ]] || usage_error "$cmd takes no unit: $unit"
    ;;
  restore)
    [[ -n $unit ]] || usage_error "restore needs a unit: agent-local or agent-general"
    ;;
esac
case $backend in
  ssd | hdd | r2) ;;
  all) all_backends=1 ;;
  *) usage_error "--backend must be ssd, hdd, r2 or all: $backend" ;;
esac
if ((all_backends)) && [[ -n $target ]]; then
  usage_error "--target names one target for one backend; drop --backend all"
fi
if [[ -n $snapshot && $cmd != restore ]]; then
  usage_error "--snapshot is a restore option"
fi
if [[ -n $target && $cmd != restore ]]; then
  usage_error "--target is a restore option"
fi

if ((EUID != 0)); then
  if ((dry_run)); then
    warn 'not root: printing the plan only. A real run needs root, because the' \
      'decrypted secrets under /run/smortress/secrets are root-only 0400 and the' \
      'agent containers belong to root Podman'
  else
    warn 'needs root: EUID is not 0, so the root-only secrets and root Podman are' \
      'unreachable; run this with sudo'
    exit 1
  fi
fi

restic_drill=${SMORTRESS_RESTIC_RESTORE_DRILL:-}
if [[ -z $restic_drill ]]; then
  for candidate in /usr/libexec/smortress-restic-restore-drill \
    "$here/smortress-restic-restore-drill.sh"; do
    if [[ -x $candidate ]]; then
      restic_drill=$candidate
      break
    fi
  done
  restic_drill=${restic_drill:-/usr/libexec/smortress-restic-restore-drill}
fi

# The probe scripts are constants: the path travels as $1, so a path is data and
# never shell text. Both send whatever they read to /dev/null, so a probe can
# report why the read failed and never what was in there.
tree_probe='if [ ! -e "$1" ]; then printf "absent: no such path in this namespace"; exit 0; fi; if ls -A -- "$1" >/dev/null 2>&1; then printf "present and listable"; exit 3; fi; printf "present but not listable"; exit 4'

file_probe='if [ ! -e "$1" ]; then printf "absent: no such path in this namespace"; exit 0; fi; if cat -- "$1" >/dev/null 2>&1; then printf "readable"; exit 3; fi; printf "present but not readable"; exit 4'

# --------------------------------------------------------------- the probes
# Every container is probed twice: as uid 0, which is the entrypoint's own uid
# for the gateway and the strongest a compromise can reach, and as uid 1000,
# which is the uid the workload actually runs at. Exit 0 from a probe means the
# path is absent, which is the only result that passes.
# A timer-driven collector is a `Type=oneshot` unit that runs `podman run --rm`:
# between runs there is no container to exec into, and that absence is the
# schedule working, not a failure. The unit that brings it back is what the
# definition drill audits, so an absent oneshot is a SKIP. The signal is
# `Type=oneshot` and not `--rm`, because the long-running services use `--rm` too
# (the mail stream does) and their absence is a real failure. The unit is found
# by the container it actually creates, not by any mention of its name.
container_is_transient() { # container_is_transient <container>
  local name=$1 file
  for file in "$repo"/units/quadlet/*.container \
    "$repo"/units/systemd/smortress-agent-*.service; do
    grep -qE "^ContainerName=${name}$|--name[= ]${name}( |\$)" "$file" 2>/dev/null || continue
    grep -qE '^Type=oneshot$' "$file" && return 0
  done
  return 1
}

probe_path() { # probe_path <container> <path> <probe> <label>
  local container=$1 path=$2 probe=$3 label=$4
  local running rc=0 out detail='' failed=0 uid

  capture running podman inspect --format '{{.State.Running}}' "$container" || rc=$?
  if ((dry_run)); then
    for uid in 0 1000; do
      capture out podman exec --user "$uid:$uid" "$container" /bin/sh -c "$probe" _ "$path" || true
    done
    return 0
  fi
  if ((rc != 0)); then
    if container_is_transient "$container"; then
      record SKIP "$label" "$container is a oneshot and is absent between runs; the definition drill covers its next run"
    else
      record FAIL "$label" "$container: $(last_line "$running")"
    fi
    return 0
  fi
  if [[ $running != true ]]; then
    record SKIP "$label" "$container is not running; start it and rerun"
    return 0
  fi

  for uid in 0 1000; do
    rc=0
    capture out podman exec --user "$uid:$uid" "$container" /bin/sh -c "$probe" _ "$path" || rc=$?
    case $rc in
      126 | 127)
        record SKIP "$label" "the probe could not run in $container: $(last_line "$out")"
        return 0
        ;;
    esac
    ((rc == 0)) || failed=1
    detail+="${detail:+; }uid $uid: $(last_line "$out")"
  done

  if ((failed)); then
    record FAIL "$label" "$detail"
  else
    record PASS "$label" "$detail"
  fi
}

mounts_drill() {
  local entry
  local targets=(
    'smortress-agent-general /var/lib/agent/local'
    'smortress-agent-general /var/srv/files'
    'smortress-agent-general /var/srv/photos'
    'smortress-agent-general /var/srv/repo-archive'
    'smortress-agent-local /var/lib/agent/general'
  )
  say 'the general gateway must not see the personal side, nor the personal one the general side'
  for entry in "${targets[@]}"; do
    probe_path "${entry%% *}" "${entry#* }" "$tree_probe" "${entry%% *} ${entry#* }"
  done
}

# The three plane secrets, named by what they are and never by value. The paths
# are the ones the real code reads: restic-plane-common for the first two, and
# sops-decrypt's default age identity for the third.
secrets=(
  'restic-password /run/smortress/secrets/restic-password.yaml'
  'r2-credentials /run/smortress/secrets/r2-credentials.yaml'
  'age-identity /var/lib/homelab/age/keys.txt'
)
agent_containers=(
  smortress-agent-local
  smortress-agent-general
  smortress-agent-facade-personal
  smortress-agent-facade-general
  smortress-agent-model
  smortress-agent-proxy
  smortress-agent-webui-personal
  smortress-agent-webui-general
)
collector_containers=(
  smortress-agent-collect-finance
  smortress-agent-collect-finance-hledger
  smortress-agent-mail-stream
  smortress-agent-calendar-dump
  smortress-agent-collect-calendar
  smortress-agent-brave-snapshot
  smortress-agent-collect-brave
  smortress-agent-collect-notes
  smortress-agent-collect-tasks
  smortress-agent-brave-seed
  smortress-agent-tmail
  smortress-agent-brave
  smortress-agent-egress-proxy
  smortress-agent-egress-dns
)

# A host secret this drill cannot see at all proves nothing about the
# containers, so it is checked first and its container probes are dropped when
# it fails.
secret_staged() { # secret_staged <path> -> prints the observed owner and mode
  local out rc=0 mode
  capture out stat --format='%u:%g %a' "$1" || rc=$?
  if ((dry_run)); then
    printf 'planned'
    return 0
  fi
  if ((rc != 0)); then
    printf 'not staged: %s' "$(last_line "$out")"
    return 1
  fi
  mode=${out##* }
  if [[ ${out%% *} != 0:0 ]]; then
    printf 'owned by %s, not root' "${out%% *}"
    return 1
  fi
  case $mode in
    400 | 600) ;;
    *)
      printf 'mode %s, not 0400 or 0600' "$mode"
      return 1
      ;;
  esac
  printf 'root-only %s' "$mode"
}

# The oneshot collectors are `podman run --rm`: between runs there is no
# container to exec into. Their definitions are the other half of the evidence,
# because the next timer brings back exactly those mounts, so a unit that names a
# plane secret fails the drill.
definition_drill() {
  local unit_path files=() hits=() count=0
  if ((dry_run)); then
    say "would audit $repo/units/quadlet/agent-*.container and $repo/units/systemd/smortress-agent-*.service for a plane secret"
    return 0
  fi
  for unit_path in "$repo"/units/quadlet/agent-*.container \
    "$repo"/units/systemd/smortress-agent-*.service; do
    if [[ -r $unit_path ]]; then
      files+=("$unit_path")
    fi
  done
  if ((${#files[@]} == 0)); then
    record SKIP 'no agent unit names a plane secret' "no unit tree under $repo/units"
    return 0
  fi
  for unit_path in "${files[@]}"; do
    count=$((count + 1))
    if grep -qE 'restic-password|r2-credentials|/run/smortress/secrets|/var/lib/homelab/age' \
      "$unit_path"; then
      hits+=("${unit_path#"$repo"/}")
    fi
  done
  if ((${#hits[@]})); then
    record FAIL 'no agent unit names a plane secret' "${hits[*]}"
  else
    record PASS 'no agent unit names a plane secret' "$count unit definitions"
  fi
}

credentials_drill() {
  local entry name path detail container
  local containers=("${agent_containers[@]}" "${collector_containers[@]}")
  for entry in "${secrets[@]}"; do
    name=${entry%% *}
    path=${entry#* }
    say "$name must be readable from no agent namespace"
    if ((dry_run)); then
      detail=$(secret_staged "$path") || true
      for container in "${containers[@]}"; do
        probe_path "$container" "$path" "$file_probe" "$container cannot read $name"
      done
      continue
    fi
    if detail=$(secret_staged "$path"); then
      record PASS "$name is staged root-only" "$detail"
    else
      record FAIL "$name is staged root-only" "$detail; the container probes prove nothing"
      continue
    fi
    for container in "${containers[@]}"; do
      probe_path "$container" "$path" "$file_probe" "$container cannot read $name"
    done
  done
  definition_drill
}

# -------------------------------------------------------------- the restore
live_dataset_for() { # live_dataset_for <path> -> the dataset key whose mountpoint holds it
  (
    unset STORAGE_MOUNT_ROOT
    # shellcheck source=/dev/null
    source "$layout"
    local key
    for key in "${dataset_order[@]}"; do
      if [[ $1 == "$(mountpoint_for "$key")" || $1 == "$(mountpoint_for "$key")"/* ]]; then
        printf '%s\n' "$key"
        return 0
      fi
    done
    return 1
  )
}

dataset_mountpoint() { # dataset_mountpoint <key>
  (
    unset STORAGE_MOUNT_ROOT
    # shellcheck source=/dev/null
    source "$layout"
    mountpoint_for "$1"
  )
}

non_empty() { # non_empty <dir> -> 0 when it holds at least one entry
  local out rc=0
  capture out find "$1" -mindepth 1 -maxdepth 1 -print -quit || rc=$?
  ((rc == 0)) && [[ -n $out ]]
}

kind_of() { # kind_of <path> -> dir|file|absent
  local out rc=0
  capture out find "$1" -maxdepth 0 -printf '%y\n' || rc=$?
  if ((rc != 0)) || [[ -z $out ]]; then
    printf 'absent\n'
    return 0
  fi
  case $out in
    d) printf 'dir\n' ;;
    f) printf 'file\n' ;;
    *) printf 'other\n' ;;
  esac
}

committed_states() { # committed_states <root>
  find "$1/replica" -mindepth 2 -maxdepth 2 -type f -name state.sqlite -print 2>/dev/null || true
}

expect_paths() { # expect_paths <unit> <root>
  local root=$2 side=${1#agent-} path kind
  local files=(.env webui.env config.yaml)
  local dirs=(memory webui webui/state webui/workspace)
  if [[ $side == local ]]; then
    dirs+=(quarantine index replica)
    files+=(index/hledger/accounts.json)
  fi
  for path in "${files[@]}" "${dirs[@]}"; do
    kind=$(kind_of "$root/$path")
    if [[ $kind == absent ]]; then
      record FAIL "restored $path" "missing from $root"
    else
      record PASS "restored $path" "$kind"
    fi
  done
}

expect_content() { # expect_content <unit> <root>
  local root=$2 side=${1#agent-} profile out rc records manifests
  if [[ $side == local ]]; then
    profile=local
  else
    profile=external
  fi

  # The values are never printed: grep -q is the whole assertion.
  rc=0
  capture out grep -q '^API_SERVER_KEY=' "$root/.env" || rc=$?
  if ((rc == 0)); then
    record PASS 'restored .env carries API_SERVER_KEY' 'value not printed'
  else
    record FAIL 'restored .env carries API_SERVER_KEY' 'the gateway would start without a key'
  fi
  rc=0
  capture out grep -q '^HERMES_WEBUI_PASSWORD=' "$root/webui.env" || rc=$?
  if ((rc == 0)); then
    record PASS 'restored webui.env carries HERMES_WEBUI_PASSWORD' 'value not printed'
  else
    record FAIL 'restored webui.env carries HERMES_WEBUI_PASSWORD' 'the UI would refuse every login'
  fi

  if non_empty "$root/webui/state"; then
    record PASS 'restored web UI state is not empty' 'the chat store came back with the tree'
  else
    record FAIL 'restored web UI state is not empty' 'no chat state in the restored tree'
  fi

  records=$(find "$root/memory/$profile" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l) ||
    records=0
  if ((records > 0)); then
    record PASS "restored facade memory has $profile records" "$records record files"
  else
    record FAIL "restored facade memory has $profile records" \
      "no *.json under $root/memory/$profile"
  fi

  manifests=$(committed_states "$root")
  if [[ $side == local ]]; then
    if non_empty "$root/quarantine"; then
      record PASS 'restored collector quarantine is not empty' "$root/quarantine"
    else
      record FAIL 'restored collector quarantine is not empty' \
        'the provider sessions did not come back'
    fi
    if [[ -n $manifests ]]; then
      record PASS 'restored replica carries a committed state' \
        "$(printf '%s\n' "$manifests" | wc -l) committed state(s)"
    else
      record FAIL 'restored replica carries a committed state' \
        'no replica/*/state.sqlite'
    fi
    if [[ -e $root/index/hledger/finance.journal ]]; then
      record PASS 'restored hledger projection is present' 'the derived journal came back'
    else
      record SKIP 'restored hledger projection is present' \
        'derived, not yet projected; it rebuilds on the next collection'
    fi
  else
    if [[ -z $manifests ]]; then
      record PASS 'general tree carries no collector generation' \
        'the general side runs no collector'
    else
      record FAIL 'general tree carries no collector generation' "$manifests"
    fi
  fi
}

# The mandatory half of a real restore: Restic carries no security.selinux and
# the archive comes out root-owned, so the runbook chowns before anything starts
# (docs/manual-steps.md section 40.6). The drill applies the same step and then
# proves uid 1000 could write what the gateway and the facade write.
expect_ownership() { # expect_ownership <unit> <root>
  local root=$2 side=${1#agent-} out rc=0 foreign path missed=()
  local writable=(memory webui)
  if [[ $side == local ]]; then
    writable+=(quarantine replica index)
  fi

  capture out find "$root" -maxdepth 4 -printf '%U\n' || rc=$?
  if ((rc != 0)); then
    record FAIL 'restored tree carries no foreign owner' "$(last_line "$out")"
    return 0
  fi
  foreign=$(printf '%s\n' "$out" | grep -vxE '0|1000' | sort -u | paste -sd' ' || true)
  if [[ -z $foreign ]]; then
    record PASS 'restored tree carries no foreign owner' 'uids at depth 4 are 0 and 1000 only'
  else
    record FAIL 'restored tree carries no foreign owner' "uids: $foreign"
  fi

  run chown -R 1000:1000 "$root"

  rc=0
  capture out find "$root" -maxdepth 4 \( ! -uid 1000 -o ! -gid 1000 \) -print || rc=$?
  if ((rc == 0)) && [[ -z $out ]]; then
    record PASS 'restored tree is owned by 1000:1000' 'after the documented chown'
  else
    record FAIL 'restored tree is owned by 1000:1000' "${out:-chown failed}"
  fi

  for path in "${writable[@]}"; do
    rc=0
    capture out setpriv --reuid=1000 --regid=1000 --clear-groups test -w "$root/$path" || rc=$?
    ((rc == 0)) || missed+=("$path")
  done
  if ((${#missed[@]} == 0)); then
    record PASS 'uid 1000 can write the restored service roots' "${writable[*]}"
  else
    record FAIL 'uid 1000 can write the restored service roots' "not writable: ${missed[*]}"
  fi
}

fts_rebuild_py='import sys
from apps.agent_facade.memory import MemoryIndex
from data_plane.model import Visibility
print(MemoryIndex(sys.argv[1], Visibility(sys.argv[2])).rebuild())'

# The index is derived and disposable: a restore that loses it is still a
# restore, so the drill proves it can be rebuilt from the records that came back
# (docs/agent-facade.md, "Memory and index rules").
expect_fts_rebuild() { # expect_fts_rebuild <unit> <root>
  local root=$2 deployment=general profile=external out rc=0 indexed records
  if [[ ${1#agent-} == local ]]; then
    deployment=personal
    profile=local
  fi
  if [[ ! -d $facade_tree ]]; then
    record SKIP 'FTS index rebuilds from the restored records' "no facade tree at $facade_tree"
    return 0
  fi
  capture out env "PYTHONPATH=$facade_tree/libs:$facade_tree" \
    setpriv --reuid=1000 --regid=1000 --clear-groups python3 -c "$fts_rebuild_py" \
    "$root/memory" "$deployment" || rc=$?
  if ((rc != 0)); then
    record FAIL 'FTS index rebuilds from the restored records' "$(last_line "$out")"
    return 0
  fi
  indexed=$(last_line "$out")
  records=$(find "$root/memory/$profile" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l) ||
    records=0
  if [[ $indexed =~ ^[0-9]+$ ]] && ((indexed > 0)) && ((indexed <= records)); then
    record PASS 'FTS index rebuilds from the restored records' \
      "$indexed of $records records indexed"
  else
    record FAIL 'FTS index rebuilds from the restored records' \
      "rebuild reported '$indexed' with $records record files"
  fi
}

expect_second_restore_refused() { # expect_second_restore_refused <backend> <unit> <target>
  local rc=0 out
  capture out "$restic_drill" "$1" "$2" --target "$3" || rc=$?
  if ((rc != 0)) && grep -q 'not empty' <<<"$out"; then
    record PASS "$1/$2 refuses a second restore into the same target" "$(last_line "$out")"
  else
    record FAIL "$1/$2 refuses a second restore into the same target" \
      "exit $rc: $(last_line "$out")"
  fi
}

restore_one() { # restore_one <backend>
  local b=$1 tgt root guard out rc kind
  tgt=$target
  if [[ -z $tgt ]]; then
    tgt=$drill_root/$b-$unit-$stamp
  fi
  if guard=$(live_dataset_for "$tgt"); then
    record FAIL "$b/$unit: restore target $tgt" "inside the live dataset $guard"
    return 0
  fi
  if [[ $(findmnt -no TARGET -T "$tgt" 2>/dev/null) == / ]]; then
    record FAIL "$b/$unit: restore target $tgt" 'resolves to the root filesystem'
    return 0
  fi
  root=$tgt$(dataset_mountpoint "state/$unit")/.zfs/snapshot/$b

  say "$b/$unit: restoring into $tgt"
  if ((dry_run)); then
    if [[ -n $snapshot ]]; then
      capture out "$restic_drill" "$b" "$unit" --target "$tgt" --snapshot "$snapshot" || true
    else
      capture out "$restic_drill" "$b" "$unit" --target "$tgt" || true
    fi
    say "would check $root: .env webui.env config.yaml memory webui quarantine index" \
      'replica, ownership 1000:1000, the FTS rebuild and the second-restore refusal'
    return 0
  fi

  rc=0
  if [[ -n $snapshot ]]; then
    capture out "$restic_drill" "$b" "$unit" --target "$tgt" --snapshot "$snapshot" || rc=$?
  else
    capture out "$restic_drill" "$b" "$unit" --target "$tgt" || rc=$?
  fi
  if ((rc != 0)); then
    record FAIL "$b/$unit restores" "exit $rc: $(last_line "$out")"
    return 0
  fi
  record PASS "$b/$unit restores" "$tgt"

  kind=$(kind_of "$root")
  if [[ $kind != dir ]]; then
    record FAIL "$b/$unit restored the expected tree root" "$root is $kind"
    return 0
  fi
  record PASS "$b/$unit restored the expected tree root" "$root"

  expect_paths "$unit" "$root"
  expect_content "$unit" "$root"
  expect_second_restore_refused "$b" "$unit" "$tgt"
  expect_ownership "$unit" "$root"
  expect_fts_rebuild "$unit" "$root"
}

restore_drill() {
  local b
  local -a wanted=(ssd)
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  if ((all_backends)); then
    wanted=("${backends[@]}")
  else
    wanted=("$backend")
  fi
  for b in "${wanted[@]}"; do
    restore_one "$b"
  done
}

if ((dry_run)); then
  say 'dry run: every command below is printed, nothing is executed'
fi

case $cmd in
  mounts) mounts_drill ;;
  credentials) credentials_drill ;;
  restore) restore_drill ;;
esac

printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
((fail == 0))
