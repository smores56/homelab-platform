#!/usr/bin/env bash
# Rejects a publish input that is unsafe before anything uses it (design #1011).
#
# The reusable workflow hands every caller input to a step through `env:`, so a
# value reaches a shell as data and never as script text. This is the second gate:
# it runs in a job of its own, before the job that holds the signing key exists.
#
# The name is the value that has to hold: it becomes a registry path, a tag and a
# pin name, and `workflow_dispatch` is the one caller whose inputs a person types.
# The other three are paths inside the checkout, and each is quoted into a build
# command, so none of them may be absolute, escape upwards, or carry a character
# a repository path is not written with.
#
# usage: check-publish-inputs.sh   (reads NAME, DOCKERFILE, CONTEXT, PIN_PREFIX)
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

fail() {
  local message=$1
  # The value in the message is one we refused, so it may carry a newline, and a
  # workflow command is parsed one line at a time: folding the newlines is what
  # keeps a rejected input from writing a second annotation.
  message=${message//$'\n'/ }
  message=${message//$'\r'/ }
  printf '::error::%s\n' "$message"
  printf 'check-publish-inputs: %s\n' "$message" >&2
  exit 1
}

for variable in NAME DOCKERFILE CONTEXT PIN_PREFIX; do
  [[ -n ${!variable:-} ]] || fail "$variable is unset or empty"
done

# The design's pattern, verbatim: the name is a GHCR path component and the left
# half of the apps pin row, so it is lowercase, and nothing else is a name.
[[ $NAME =~ ^[a-z0-9-]+$ ]] || fail "name '$NAME' does not match ^[a-z0-9-]+\$"

# relative_path <label> <value>: a path as it will be quoted into a build command.
relative_path() {
  local label=$1 value=$2
  [[ $value =~ ^[A-Za-z0-9._/-]+$ ]] ||
    fail "$label '$value' is not a relative path"
  [[ $value != /* ]] || fail "$label '$value' is absolute"
  case "/$value/" in
    */../*) fail "$label '$value' escapes the checkout" ;;
  esac
}

relative_path dockerfile "$DOCKERFILE"
relative_path context "$CONTEXT"
relative_path pin_prefix "$PIN_PREFIX"

# A row whose paths do not resolve is a matrix typo, and naming it here is the
# difference between a failed validation and a failed build after cosign install.
[[ -f $DOCKERFILE ]] || fail "dockerfile '$DOCKERFILE' is not a file in the checkout"
[[ -d $CONTEXT ]] || fail "context '$CONTEXT' is not a directory in the checkout"

printf 'check-publish-inputs: %s from %s (context %s), pinned as %s\n' \
  "$NAME" "$DOCKERFILE" "$CONTEXT" "$PIN_PREFIX"
