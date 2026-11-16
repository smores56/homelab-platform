#!/usr/bin/env bash
# Freeze or resume the legacy Flux graph (SDLC #703, T0 of #701).
#
# T0 exists so the legacy system stops changing before its data is inventoried
# and the new core starts replacing it. Freezing means suspending Flux, not
# stopping workloads: the applications keep serving and the nightly restic jobs
# keep running — what stops is git→cluster reconciliation, Helm drift repair and
# image automation. Nothing is deleted, and `--resume` restores the previous
# state exactly (every object ends up with `spec.suspend: false`).
#
# The default is a read-only `--check`. `--apply` and `--resume` need the
# cluster admin kubeconfig, which is root-only on smortress:
#
#   sudo scripts/core/freeze-legacy.sh --check     # what is suspended today
#   sudo scripts/core/freeze-legacy.sh --apply     # freeze
#   sudo scripts/core/freeze-legacy.sh --resume    # undo
set -euo pipefail

readonly SELF=${0##*/}
readonly KINDS=(
  "kustomizations.kustomize.toolkit.fluxcd.io"
  "helmreleases.helm.toolkit.fluxcd.io"
  "imageupdateautomations.image.toolkit.fluxcd.io"
)

mode=check
kubectl=${KUBECTL:-}

usage() {
  cat <<'EOF'
usage: freeze-legacy.sh [--check|--apply|--resume]

  --check    list every Flux object and its suspend flag (default, read-only)
  --apply    suspend reconciliation, Helm drift repair and image automation
  --resume   clear every suspend flag again
  -h, --help this text

KUBECTL=/path/to/kubectl overrides the client (default: cluster-kubectl, then kubectl).
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

# The host's cluster-kubectl already points at the guest's admin kubeconfig.
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

# namespace/name pairs for one kind; empty output means the CRD is absent.
objects() {
  local kind=$1
  "$kubectl" get "$kind" --all-namespaces --no-headers \
    -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name 2>/dev/null |
    awk 'NF == 2 {print $1 "/" $2}' || true
}

suspended_state() {
  local kind=$1
  "$kubectl" get "$kind" --all-namespaces --no-headers \
    -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,SUSPEND:.spec.suspend \
    2>/dev/null | awk 'NF == 3 {print $1 "/" $2 " suspended=" $3}' || true
}

set_suspend() { # set_suspend <kind> <namespace/name> <true|false>
  local kind=$1 ref=$2 value=$3 ns name
  ns=${ref%%/*}
  name=${ref#*/}
  "$kubectl" patch "$kind" -n "$ns" "$name" --type=merge \
    -p "{\"spec\":{\"suspend\":$value}}" >/dev/null
  printf 'patched %s %s suspend=%s\n' "$kind" "$ref" "$value"
}

if [[ $mode == check ]]; then
  printf '## Flux graph state\n\n'
  for kind in "${KINDS[@]}"; do
    printf '### %s\n\n' "$kind"
    if suspended_state "$kind" | grep -q .; then
      suspended_state "$kind" | sed 's/^/- /'
    else
      printf -- '- (none)\n'
    fi
    printf '\n'
  done
  exit 0
fi

value=true
[[ $mode == resume ]] && value=false

printf '## Flux graph %s\n\n' "$mode"
for kind in "${KINDS[@]}"; do
  mapfile -t refs < <(objects "$kind")
  if ((${#refs[@]} == 0)); then
    printf '### %s\n\n- (none)\n\n' "$kind"
    continue
  fi
  printf '### %s\n\n' "$kind"
  for ref in "${refs[@]}"; do
    set_suspend "$kind" "$ref" "$value" | sed 's/^/- /'
  done
  printf '\n'
done

printf '## Verified state\n\n'
for kind in "${KINDS[@]}"; do
  printf '### %s\n\n' "$kind"
  if suspended_state "$kind" | grep -q .; then
    suspended_state "$kind" | sed 's/^/- /'
  else
    printf -- '- (none)\n'
  fi
  printf '\n'
done
