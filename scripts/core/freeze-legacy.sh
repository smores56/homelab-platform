#!/usr/bin/env bash
# Freeze or resume the legacy Flux graph (SDLC #703, T0 of #701).
#
# T0 exists so the legacy system stops changing before its data is inventoried
# and the new core replaces it. Freezing means suspending Flux, not stopping
# workloads: applications keep serving and the nightly restic jobs keep running
# — what stops is git→cluster reconciliation, Helm drift repair and image
# automation. Nothing is deleted.
#
# `--apply` records each object's previous `spec.suspend` under
# /var/lib/freeze-legacy before touching it, and `--resume` restores exactly
# that state. Both modes fail loudly: an unreadable kind, a rejected patch, or a
# `spec.suspend` that is still wrong afterwards exits non-zero, so "suspended
# nothing" cannot look like success.
#
#   sudo scripts/core/freeze-legacy.sh --check     # what is suspended today
#   sudo scripts/core/freeze-legacy.sh --apply     # freeze, record prior state
#   sudo scripts/core/freeze-legacy.sh --resume    # restore the recorded state
set -euo pipefail

readonly SELF=${0##*/}
readonly STATE_DIR=${STATE_DIR:-/var/lib/freeze-legacy}
readonly KINDS=(
  "kustomizations.kustomize.toolkit.fluxcd.io"
  "helmreleases.helm.toolkit.fluxcd.io"
  "imageupdateautomations.image.toolkit.fluxcd.io"
)

mode=check
kubectl=${KUBECTL:-}
REFS=()

usage() {
  cat <<'EOF'
usage: freeze-legacy.sh [--check|--apply|--resume]

  --check    list every Flux object and its suspend flag (default, read-only)
  --apply    record current state, then suspend reconciliation, Helm drift
             repair and image automation
  --resume   restore the state recorded by the last --apply
  -h, --help this text

KUBECTL=/path/to/kubectl overrides the client (default: cluster-kubectl, then kubectl).
STATE_DIR overrides where the prior state is kept (default: /var/lib/freeze-legacy).
EOF
}

while (($#)); do
  case $1 in
  --check)
    mode=check
    shift
    ;;
  --apply)
    mode=apply
    shift
    ;;
  --resume)
    mode=resume
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    echo "$SELF: unknown argument: $1" >&2
    usage >&2
    exit 2
    ;;
  esac
done

if [[ -z $kubectl ]]; then
  kubectl=$(command -v cluster-kubectl || command -v kubectl || true)
fi
[[ -n $kubectl ]] || {
  echo "$SELF: no kubectl found; set KUBECTL=/path/to/kubectl" >&2
  exit 1
}
if ! "$kubectl" version --request-timeout=10s >/dev/null 2>&1; then
  echo "$SELF: cannot reach the cluster with $kubectl (kubeconfig is root-only)" >&2
  exit 1
fi

# namespace/name pairs for one kind. A kind the cluster does not serve is the
# only acceptable empty result; any other kubectl error is fatal.
objects() {
  local kind=$1 out err rc=0
  err=$(mktemp)
  out=$("$kubectl" get "$kind" --all-namespaces --no-headers \
    -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name 2>"$err") || rc=$?
  if ((rc != 0)); then
    if grep -qiE 'does not have a resource type|the server could not find the requested resource' "$err"; then
      rm -f "$err"
      return 0
    fi
    echo "$SELF: kubectl get $kind failed:" >&2
    sed 's/^/  /' "$err" >&2
    rm -f "$err"
    return 1
  fi
  rm -f "$err"
  printf '%s\n' "$out" | awk 'NF == 2 {print $1 "/" $2}'
}

load_refs() { # load_refs <kind>; fills REFS, empty when the kind is absent
  local kind=$1 out
  out=$(objects "$kind")
  REFS=()
  if [[ -n $out ]]; then
    mapfile -t REFS <<<"$out"
  fi
  return 0
}

suspend_of() { # suspend_of <kind> <namespace/name>
  local kind=$1 ref=$2
  "$kubectl" get "$kind" -n "${ref%%/*}" "${ref#*/}" \
    -o jsonpath='{.spec.suspend}' 2>/dev/null || echo ""
}

set_suspend() { # set_suspend <kind> <namespace/name> <true|false>
  local kind=$1 ref=$2 value=$3
  "$kubectl" patch "$kind" -n "${ref%%/*}" "${ref#*/}" --type=merge \
    -p "{\"spec\":{\"suspend\":$value}}" >/dev/null
}

print_state() {
  local kind ref
  printf '## Flux graph state\n\n'
  for kind in "${KINDS[@]}"; do
    printf '### %s\n\n' "$kind"
    load_refs "$kind"
    if ((${#REFS[@]} == 0)); then
      printf -- '- (none)\n'
    else
      for ref in "${REFS[@]}"; do
        printf -- '- %s suspended=%s\n' "$ref" "$(suspend_of "$kind" "$ref")"
      done
    fi
    printf '\n'
  done
}

if [[ $mode == check ]]; then
  print_state
  exit 0
fi

state_file=""
if [[ $mode == apply ]]; then
  desired=true
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  state_file=$STATE_DIR/$(date -u '+%Y%m%dT%H%M%SZ').state
  : >"$state_file"
  chmod 600 "$state_file"
  printf '## Recording prior state in %s\n\n' "$state_file"
  for kind in "${KINDS[@]}"; do
    load_refs "$kind"
    for ref in "${REFS[@]}"; do
      printf '%s %s %s\n' "$kind" "$ref" "$(suspend_of "$kind" "$ref")" >>"$state_file"
    done
  done
  sed 's/^/- /' "$state_file"
else
  desired=false
  state_file=$(find "$STATE_DIR" -maxdepth 1 -name '*.state' -type f 2>/dev/null |
    sort | tail -1)
  if [[ -z $state_file ]]; then
    echo "$SELF: no recorded state under $STATE_DIR; every object will be set to false" >&2
  fi
fi

printf '\n## Applying\n\n'
mismatch=0
for kind in "${KINDS[@]}"; do
  load_refs "$kind"
  if ((${#REFS[@]} == 0)); then
    printf '### %s\n\n- (none)\n' "$kind"
    continue
  fi
  printf '### %s\n\n' "$kind"
  for ref in "${REFS[@]}"; do
    value=$desired
    if [[ $mode == resume && -n $state_file ]]; then
      recorded=$(awk -v k="$kind" -v r="$ref" '$1 == k && $2 == r {print $3; exit}' "$state_file")
      [[ -n $recorded ]] && value=$recorded
    fi
    set_suspend "$kind" "$ref" "$value"
    observed=$(suspend_of "$kind" "$ref")
    if [[ $observed == "$value" ]]; then
      printf -- '- %s suspended=%s\n' "$ref" "$observed"
    else
      printf -- '- %s MISMATCH wanted %s got %s\n' "$ref" "$value" "$observed"
      mismatch=$((mismatch + 1))
    fi
  done
  printf '\n'
done

if ((mismatch > 0)); then
  echo "$SELF: $mismatch object(s) did not reach the requested state" >&2
  exit 1
fi
echo "$SELF: $mode complete"
