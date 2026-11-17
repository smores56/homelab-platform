#!/usr/bin/env bash
# Offline checks for the apps-tenant renderer (SDLC #726, T7 of #701).
#
# The renderer is the other half of the containment boundary: it turns a
# validated definition into a rootless Podman Quadlet and a platform plan.
# Nothing in a definition may reach the unit as a flag, a mount, a network or
# a published address, so this proves the shape of what is emitted: loopback
# publication only, pasta or none for egress, one data bind, all capabilities
# dropped, a read-only root, no-new-privileges, a per-app MCS level, own
# secrets only, a stable loopback port, and a plan that names the Serve path.
#
#   tests/apps/render.sh
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
contains() {
  local file=$1 pattern=$2 label=$3
  if grep -qF -- "$pattern" "$file"; then ok "$label"; else bad "$label" "missing '$pattern' in $file"; fi
}
lacks() {
  local file=$1 pattern=$2 label=$3
  if grep -qF -- "$pattern" "$file"; then bad "$label" "unexpected '$pattern' in $file"; else ok "$label"; fi
}

digest=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
tree=$work/tree
out=$work/out
mkdir -p "$tree/apps/alpha" "$tree/apps/beta" "$out"
cat >"$tree/secrets.sops.json" <<'JSON'
{"apps": {"alpha": {"api-key": "ENC[x]"}}, "sops": {}}
JSON
cat >"$tree/apps/alpha/app.toml" <<EOF
image = "ghcr.io/example/alpha@sha256:$digest"
port = 8080
egress = "none"
quota = "5G"
secrets = ["api-key"]

[env]
TZ = "UTC"
EOF
cat >"$tree/apps/beta/app.toml" <<EOF
image = "ghcr.io/example/beta@sha256:$digest"
port = 9090
egress = "internet"
EOF

if ! "$validator" render --root "$tree" --secrets "$tree/secrets.sops.json" --out "$out" >"$work/render.log" 2>&1; then
  bad 'render succeeds on a valid tree' "$(cat "$work/render.log")"
  printf '\n%s checks, %s failed\n' "$((pass + fail))" "$fail"
  exit 1
fi
ok 'render succeeds on a valid tree'

alpha=$out/alpha.container
if [[ -f $alpha ]]; then ok 'one Quadlet per app'; else bad 'one Quadlet per app'; fi

contains "$alpha" "Image=ghcr.io/example/alpha@sha256:$digest" 'the image is the digest-pinned one'
contains "$alpha" 'PublishPort=127.0.0.1:' 'the port is published on loopback'
contains "$alpha" ':8080' 'the published port is the declared container port'
contains "$alpha" 'Network=none' 'egress none renders no network'
contains "$alpha" 'Volume=/srv/apps/alpha:/data:Z' 'the only bind is the app data directory, relabelled'
contains "$alpha" 'ReadOnly=true' 'the root filesystem is read-only'
contains "$alpha" 'NoNewPrivileges=true' 'no-new-privileges is set'
contains "$alpha" 'DropCapability=ALL' 'all capabilities are dropped'
contains "$alpha" 'label=level:s0:c' 'a per-app MCS level is set'
contains "$alpha" 'Environment=TZ=UTC' 'declared env reaches the unit'
contains "$alpha" 'Secret=app-alpha-api-key,type=mount,target=/run/secrets/api-key' 'secrets mount under their own name'
contains "$alpha" 'WantedBy=default.target' 'the unit is a rootless user unit'
lacks "$alpha" '0.0.0.0' 'nothing binds every address'
lacks "$alpha" 'Network=host' 'nothing uses the host network'

beta=$out/beta.container
contains "$beta" 'Network=pasta' 'egress internet renders pasta'
lacks "$beta" 'Secret=' 'an app with no secrets gets none'

alpha_port=$(sed -n 's/^PublishPort=127\.0\.0\.1:\([0-9]*\):.*/\1/p' "$alpha")
beta_port=$(sed -n 's/^PublishPort=127\.0\.0\.1:\([0-9]*\):.*/\1/p' "$beta")
if [[ $alpha_port =~ ^[0-9]+$ ]] && ((alpha_port >= 20000 && alpha_port < 30000)); then
  ok 'the loopback port comes from the platform range'
else
  bad 'the loopback port comes from the platform range' "got '$alpha_port'"
fi
if [[ $alpha_port != "$beta_port" ]]; then ok 'two apps get different loopback ports'; else bad 'two apps get different loopback ports'; fi

if jq -e '.apps.alpha.basePath == "/apps/alpha" and .apps.alpha.egress == "none" and .apps.alpha.quota == "5G"' \
  "$out/plan.json" >/dev/null 2>&1; then
  ok 'the plan names the Serve path, egress class and quota'
else
  bad 'the plan names the Serve path, egress class and quota' "$(head -c 500 "$out/plan.json" 2>/dev/null)"
fi

# Determinism: a second render of the same tree is byte-identical, so a deploy
# can diff it.
cp -r "$out" "$work/first"
if "$validator" render --root "$tree" --secrets "$tree/secrets.sops.json" --out "$out" >/dev/null 2>&1 &&
  diff -r "$work/first" "$out" >/dev/null; then
  ok 'rendering twice produces identical output'
else
  bad 'rendering twice produces identical output'
fi

# --check is the drift gate the deploy uses.
if "$validator" render --root "$tree" --secrets "$tree/secrets.sops.json" --out "$out" --check >/dev/null 2>&1; then
  ok '--check passes against its own output'
else
  bad '--check passes against its own output'
fi
printf 'tampered\n' >>"$out/alpha.container"
if "$validator" render --root "$tree" --secrets "$tree/secrets.sops.json" --out "$out" --check >/dev/null 2>&1; then
  bad '--check fails on drift'
else
  ok '--check fails on drift'
fi

# A rejected definition must not produce a partial plan.
badtree=$work/badtree
mkdir -p "$badtree/apps/gamma" "$work/badout"
cat >"$badtree/apps/gamma/app.toml" <<EOF
image = "ghcr.io/example/gamma@sha256:$digest"
port = 7070
egress = "none"
volumes = ["/:/host"]
EOF
if "$validator" render --root "$badtree" --out "$work/badout" >/dev/null 2>&1; then
  bad 'a schema error stops the render'
else
  ok 'a schema error stops the render'
fi
if [[ -z $(ls -A "$work/badout") ]]; then
  ok 'a rejected tree writes no files'
else
  bad 'a rejected tree writes no files' "$(ls -A "$work/badout")"
fi

printf '\n%s checks, %s failed\n' "$((pass + fail))" "$fail"
((fail == 0))
