#!/usr/bin/env bash
# Offline checks for the apps-tenant schema (SDLC #726, T7 of #701).
#
# The schema is the containment boundary: a definition can change which app
# runs and how it is configured, but it has no field for a host path, a mount,
# a capability, a socket or a published port. This proves the half that does
# not need the host: every key the schema does not name is refused, and the
# keys it does name are checked for a digest, a loopback port, own-name
# secrets and a quota inside the platform ceiling.
#
#   tests/apps/check.sh
set -uo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root" || exit 1

validator=scripts/apps-schema.py
[[ -x $validator ]] || {
  printf 'FAIL %s is missing or not executable\n' "$validator" >&2
  exit 1
}

pass=0
fail=0
ok() {
  pass=$((pass + 1))
  printf 'ok   %s\n' "$1"
}
bad() {
  fail=$((fail + 1))
  printf 'FAIL %s\n' "$1"
  [[ -n ${2:-} ]] && printf '     %s\n' "${2//$'\n'/$'\n'     }"
  return 0
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

secrets=$work/secrets.sops.json
cat >"$secrets" <<'JSON'
{
  "apps": {
    "example": {"database-url": "ENC[AES256_GCM,data:x]"},
    "other": {"api-key": "ENC[AES256_GCM,data:y]"}
  },
  "sops": {"version": "3.13.3"}
}
JSON

# app <name> <body> [secret-file]: write one definition into a fresh tree and
# print the tree path.
app() {
  local name=$1 body=$2 secrets=${3:-}
  local tree
  tree=$(mktemp -d "$work/tree.XXXXXX")
  mkdir -p "$tree/apps/$name"
  printf '%s\n' "$body" >"$tree/apps/$name/app.toml"
  [[ -n $secrets ]] && cp "$secrets" "$tree/secrets.sops.json"
  printf '%s' "$tree"
}

validate() {
  local tree=$1
  shift
  if [[ -f $tree/secrets.sops.json ]]; then
    "$validator" validate --root "$tree" --secrets "$tree/secrets.sops.json" "$@" 2>&1
  else
    "$validator" validate --root "$tree" "$@" 2>&1
  fi
}

expect_ok() {
  local label=$1 tree=$2 out
  if out=$(validate "$tree") && [[ -z $out ]]; then
    ok "$label"
  else
    bad "$label" "expected a pass, got: $out"
  fi
}

expect_fail() {
  local label=$1 tree=$2 pattern=$3 out
  if out=$(validate "$tree"); then
    bad "$label" "expected a rejection, got a pass"
  elif [[ $out == *"$pattern"* ]]; then
    ok "$label"
  else
    bad "$label" "rejection does not mention '$pattern': $out"
  fi
}

minimal='image = "ghcr.io/example/app@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
port = 18080
egress = "none"'

# --- the shape it accepts -------------------------------------------------

expect_ok 'a minimal definition passes' "$(app example "$minimal")"
expect_ok 'a fully populated definition passes' "$(app example "$minimal
quota = \"10G\"
secrets = [\"database-url\"]
[env]
TZ = \"UTC\"
LOG_LEVEL = \"info\"" "$secrets")"
mkdir -p "$work/empty/apps"
expect_ok 'an empty apps directory passes' "$work/empty"

# --- keys it does not name are errors ------------------------------------

for key in mounts volumes devices capabilities privileged network networks podman_args user selinux; do
  case $key in
    mounts | volumes | devices | capabilities | podman_args) line="[$key]" ;;
    network | networks) line="$key = \"host\"" ;;
    privileged) line="$key = true" ;;
    user | selinux) line="$key = \"root\"" ;;
  esac
  expect_fail "an unknown key '$key' is refused" "$(app example "$minimal
$line")" "unknown key"
done

# --- image ----------------------------------------------------------------

digest=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
expect_fail 'a tag-only image is refused' "$(app example 'image = "ghcr.io/example/app:latest"
port = 18080
egress = "none"')" 'digest'
expect_fail 'a short digest is refused' "$(app example 'image = "ghcr.io/example/app@sha256:abc"
port = 18080
egress = "none"')" 'digest'
expect_fail 'an image with arguments is refused' "$(app example "image = \"ghcr.io/example/app@sha256:$digest --privileged\"
port = 18080
egress = \"none\"")" 'image'

# --- port, egress, quota --------------------------------------------------

expect_fail 'a missing port is refused' "$(app example "image = \"ghcr.io/example/app@sha256:$digest\"
egress = \"none\"")" 'port'
expect_fail 'a privileged port is refused' "$(app example "image = \"ghcr.io/example/app@sha256:$digest\"
port = 80
egress = \"none\"")" 'port'
expect_fail 'a port above 65535 is refused' "$(app example "image = \"ghcr.io/example/app@sha256:$digest\"
port = 70000
egress = \"none\"")" 'port'
expect_fail 'a port as a string is refused' "$(app example "image = \"ghcr.io/example/app@sha256:$digest\"
port = \"18080\"
egress = \"none\"")" 'port'

expect_fail 'a missing egress is refused' "$(app example "image = \"ghcr.io/example/app@sha256:$digest\"
port = 18080")" 'egress'
expect_fail 'an invented egress class is refused' "$(app example "image = \"ghcr.io/example/app@sha256:$digest\"
port = 18080
egress = \"lan\"")" 'egress'

expect_fail 'a quota above the ceiling is refused' "$(app example "$minimal
quota = \"500G\"")" 'ceiling'
expect_fail 'a quota without a unit is refused' "$(app example "$minimal
quota = \"10\"")" 'quota'
expect_fail 'a fractional quota is refused' "$(app example "$minimal
quota = \"1.5G\"")" 'quota'

# --- env ------------------------------------------------------------------

expect_fail 'a lowercase env name is refused' "$(app example "$minimal
[env]
tz = \"UTC\"")" 'env'
expect_fail 'a non-string env value is refused' "$(app example "$minimal
[env]
PORT = 18080")" 'env'

# --- secrets are own-name only -------------------------------------------

expect_fail 'an undeclared secret is refused' "$(app example "$minimal
secrets = [\"api-key\"]" "$secrets")" 'secret'
expect_fail 'another app secret is refused' "$(app other "$minimal
secrets = [\"database-url\"]" "$secrets")" 'secret'
expect_fail 'a secret reference needs the tenant file' "$(app example "$minimal
secrets = [\"database-url\"]")" 'secrets'

# --- names and parsing ----------------------------------------------------

expect_fail 'an uppercase app name is refused' "$(app Example "$minimal")" 'name'
expect_fail 'an unparsable definition names the file' "$(app example 'image = ')" 'app.toml'
expect_fail 'an empty definition is refused' "$(app example '')" 'image'

printf '\n%s checks, %s failed\n' "$((pass + fail))" "$fail"
((fail == 0))
