#!/usr/bin/env bats
# bats file_tags=apps
# Offline checks for the apps-tenant schema (SDLC #726, T7 of #701).
#
# The schema is the containment boundary: a definition can change which app
# runs and how it is configured, but it has no field for a host path, a mount,
# a capability, a socket or a published port. This proves the half that does
# not need the host: every key the schema does not name is refused, and the
# keys it does name are checked for a digest, a loopback port, own-name
# secrets and a quota inside the platform ceiling.
#
#   bats tests/apps/check.bats
#
# Every test builds its own tenant tree under $BATS_TEST_TMPDIR, so the checks
# run in any order and never share a definition.
load ../helpers

validator=scripts/apps-schema.py

minimal='image = "ghcr.io/example/app@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
port = 18080
egress = "none"'

digest=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

setup() {
    # The validator is the subject of every check; a missing one fails them all
    # instead of passing on an absent binary.
    [ -x "$validator" ]
    work=$BATS_TEST_TMPDIR
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
}

# app <name> <body> [secret-file]: write one definition into a fresh tree and
# print the tree path.
app() {
    local name=$1 body=$2 secret_file=${3:-} tree
    tree=$(mktemp -d "$work/tree.XXXXXX")
    mkdir -p "$tree/apps/$name"
    printf '%s\n' "$body" >"$tree/apps/$name/app.toml"
    if [[ -n $secret_file ]]; then cp "$secret_file" "$tree/secrets.sops.json"; fi
    printf '%s' "$tree"
}

validate() { # tree
    local tree=$1
    shift
    if [[ -f $tree/secrets.sops.json ]]; then
        "$validator" validate --root "$tree" --secrets "$tree/secrets.sops.json" "$@" 2>&1
    else
        "$validator" validate --root "$tree" "$@" 2>&1
    fi
}

# expect_ok <tree>: a run that must pass and say nothing.
expect_ok() {
    local out='' rc=0
    out=$(validate "$1") || rc=$?
    assert_equal "$rc" 0
    assert_equal "$out" ''
}

# expect_fail <tree> <pattern>: a rejection that must name the reason.
expect_fail() {
    local out='' rc=0
    out=$(validate "$1") || rc=$?
    assert_not_equal "$rc" 0
    assert_contains "$out" "$2"
}

# expect_reject <command...>: a run that must fail, whatever it says.
expect_reject() {
    local rc=0
    "$@" >/dev/null 2>&1 || rc=$?
    assert_not_equal "$rc" 0
}

# --- the shape it accepts -------------------------------------------------

@test "a minimal definition passes" {
    expect_ok "$(app example "$minimal")"
}

@test "a fully populated definition passes" {
    expect_ok "$(app example "$minimal
quota = \"10G\"
secrets = [\"database-url\"]
[env]
TZ = \"UTC\"
LOG_LEVEL = \"info\"" "$secrets")"
}

@test "an empty apps directory passes" {
    mkdir -p "$work/empty/apps"
    expect_ok "$work/empty"
}

# --- keys it does not name are errors ------------------------------------

unknown_key_is_refused() { # key
    local line
    case $1 in
        mounts | volumes | devices | capabilities | podman_args) line="[$1]" ;;
        network | networks) line="$1 = \"host\"" ;;
        privileged) line="$1 = true" ;;
        user | selinux) line="$1 = \"root\"" ;;
    esac
    expect_fail "$(app example "$minimal
$line")" 'unknown key'
}

for key in mounts volumes devices capabilities privileged network networks podman_args user selinux; do
    register "an unknown key '$key' is refused" unknown_key_is_refused "$key"
done

# --- image ----------------------------------------------------------------

@test "a tag-only image is refused" {
    expect_fail "$(app example 'image = "ghcr.io/example/app:latest"
port = 18080
egress = "none"')" 'digest'
}

@test "a short digest is refused" {
    expect_fail "$(app example 'image = "ghcr.io/example/app@sha256:abc"
port = 18080
egress = "none"')" 'digest'
}

@test "an image with arguments is refused" {
    expect_fail "$(app example "image = \"ghcr.io/example/app@sha256:$digest --privileged\"
port = 18080
egress = \"none\"")" 'image'
}

# --- port, egress, quota --------------------------------------------------

@test "a missing port is refused" {
    expect_fail "$(app example "image = \"ghcr.io/example/app@sha256:$digest\"
egress = \"none\"")" 'port'
}

@test "port zero is refused" {
    expect_fail "$(app example "image = \"ghcr.io/example/app@sha256:$digest\"
port = 0
egress = \"none\"")" 'port'
}

@test "a boolean port is refused" {
    expect_fail "$(app example "image = \"ghcr.io/example/app@sha256:$digest\"
port = true
egress = \"none\"")" 'port'
}

@test "a container port below 1024 is accepted" {
    expect_ok "$(app example "image = \"ghcr.io/example/app@sha256:$digest\"
port = 80
egress = \"none\"")"
}

@test "a port above 65535 is refused" {
    expect_fail "$(app example "image = \"ghcr.io/example/app@sha256:$digest\"
port = 70000
egress = \"none\"")" 'port'
}

@test "a port as a string is refused" {
    expect_fail "$(app example "image = \"ghcr.io/example/app@sha256:$digest\"
port = \"18080\"
egress = \"none\"")" 'port'
}

@test "a missing egress is refused" {
    expect_fail "$(app example "image = \"ghcr.io/example/app@sha256:$digest\"
port = 18080")" 'egress'
}

@test "an invented egress class is refused" {
    expect_fail "$(app example "image = \"ghcr.io/example/app@sha256:$digest\"
port = 18080
egress = \"lan\"")" 'egress'
}

@test "a quota above the ceiling is refused" {
    expect_fail "$(app example "$minimal
quota = \"500G\"")" 'ceiling'
}

@test "a zero quota is refused" {
    expect_fail "$(app example "$minimal
quota = \"0G\"")" 'greater than zero'
}

@test "a quota without a unit is refused" {
    expect_fail "$(app example "$minimal
quota = \"10\"")" 'quota'
}

@test "a fractional quota is refused" {
    expect_fail "$(app example "$minimal
quota = \"1.5G\"")" 'quota'
}

# --- env ------------------------------------------------------------------

@test "a lowercase env name is refused" {
    expect_fail "$(app example "$minimal
[env]
tz = \"UTC\"")" 'env'
}

@test "a non-string env value is refused" {
    expect_fail "$(app example "$minimal
[env]
PORT = 18080")" 'env'
}

# --- secrets are own-name only -------------------------------------------

@test "an undeclared secret is refused" {
    expect_fail "$(app example "$minimal
secrets = [\"api-key\"]" "$secrets")" 'secret'
}

@test "another app secret is refused" {
    expect_fail "$(app other "$minimal
secrets = [\"database-url\"]" "$secrets")" 'secret'
}

@test "a secret reference needs the tenant file" {
    expect_fail "$(app example "$minimal
secrets = [\"database-url\"]")" 'secrets'
}

# --- names and parsing ----------------------------------------------------

@test "an uppercase app name is refused" {
    expect_fail "$(app Example "$minimal")" 'name'
}

@test "an unparsable definition names the file" {
    expect_fail "$(app example 'image = ')" 'app.toml'
}

@test "an empty definition is refused" {
    expect_fail "$(app example '')" 'image'
}

@test "a list egress is refused without a traceback" {
    expect_fail "$(app example "image = \"ghcr.io/example/app@sha256:$digest\"
port = 18080
egress = [\"none\"]")" 'egress'
}

@test "a table egress is refused" {
    expect_fail "$(app example "image = \"ghcr.io/example/app@sha256:$digest\"
port = 18080
[egress]
class = \"none\"")" 'egress'
}

@test "a string secrets value is refused" {
    expect_fail "$(app example "$minimal
secrets = \"database-url\"" "$secrets")" 'secrets'
}

@test "an env value with a newline is refused" {
    expect_fail "$(app example "$minimal
[env]
LOG = \"info\\nEnvironment=LD_PRELOAD=/tmp/x.so\"")" 'control'
}

@test "an env value with a NUL byte is refused" {
    expect_fail "$(app example "$minimal
[env]
LOG = \"x\\u0000y\"")" 'control'
}

# bats resolves a registered description with `eval`, so a value carrying a
# quote, a backslash or a backtick has to survive that round trip to keep the
# assertion text the shell suite printed.
registered() { # description command...
    local escaped=${1//\\/\\\\}
    escaped=${escaped//\"/\\\"}
    escaped=${escaped//\`/\\\`}
    escaped=${escaped//\$/\\\$}
    register "$escaped" "${@:2}"
}

env_value_is_refused() { # value
    expect_fail "$(app example "$minimal
[env]
K = '$1'")" 'env value'
}

for value in 'hello world' "trail\\" '100%n' 'a"b' 'a#b' 'a`b'; do
    registered "an env value [$value] is refused" env_value_is_refused "$value"
done

@test "a dotted key is refused" {
    expect_fail "$(app example "$minimal
limits.memory = \"1G\"")" 'unknown key'
}

@test "an array of tables for env is refused" {
    expect_fail "$(app example "$minimal
[[env]]
TZ = \"UTC\"")" 'env'
}

@test "a trailing newline in the image is refused" {
    expect_fail "$(app example "image = \"ghcr.io/example/app@sha256:$digest\\n\"
port = 18080
egress = \"none\"")" 'image'
}

@test "an image with a unit specifier is refused" {
    expect_fail "$(app example "image = \"ghcr.io/example/app%n@sha256:$digest\"
port = 18080
egress = \"none\"")" 'image'
}

@test "a trailing hyphen in the app name is refused" {
    expect_fail "$(app example- "$minimal")" 'name'
}

@test "a missing apps directory fails closed" {
    expect_fail "$(mktemp -d "$work/none.XXXXXX")" 'no apps/'
}

@test "a root that is not a directory fails closed" {
    touch "$work/notadir"
    expect_fail "$work/notadir" 'no apps/'
}

@test "invalid tenant JSON is refused" {
    mkdir -p "$work/badjson"
    printf 'not json' >"$work/badjson/secrets.sops.json"
    expect_reject "$validator" validate --root "$work/badjson" --secrets "$work/badjson/secrets.sops.json"
}

@test "a non-object tenant JSON is refused" {
    mkdir -p "$work/listjson"
    printf '[]' >"$work/listjson/secrets.sops.json"
    expect_reject "$validator" validate --root "$work/listjson" --secrets "$work/listjson/secrets.sops.json"
}

@test "a secrets directory is refused" {
    mkdir -p "$work/listjson" "$work/secretsdir"
    touch "$work/secretsdir/apps"
    expect_reject "$validator" validate --root "$work/listjson" --secrets "$work/secretsdir"
}
