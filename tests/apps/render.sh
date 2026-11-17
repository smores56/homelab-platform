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
contains "$alpha" 'Network=smortress-apps' 'egress none joins the internal network'
contains "$out/smortress-apps.network" 'Internal=true' 'the internal network has no route out'
contains "$alpha" 'Volume=/srv/apps/alpha:/data:Z' 'the only bind is the app data directory, relabelled'
contains "$alpha" 'ReadOnly=true' 'the root filesystem is read-only'
contains "$alpha" 'NoNewPrivileges=true' 'no-new-privileges is set'
contains "$alpha" 'DropCapability=ALL' 'all capabilities are dropped'
contains "$alpha" 'SecurityLabelLevel=s0:c' 'a per-app MCS level is set'
contains "$alpha" 'Environment=TZ=UTC' 'declared env reaches the unit'
contains "$alpha" 'Secret=app-alpha-api-key,type=mount,target=/run/secrets/api-key' 'secrets mount under their own name'
contains "$alpha" 'WantedBy=default.target' 'the unit is a rootless user unit'
contains "$alpha" 'PodmanArgs=--signature-policy=/usr/share/smortress/apps-policy.json' \
  'the unit names the root-owned tenant policy'
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

alpha_level=$(sed -n 's/^SecurityLabelLevel=//p' "$alpha")
beta_level=$(sed -n 's/^SecurityLabelLevel=//p' "$beta")
if [[ -n $alpha_level && -n $beta_level && $alpha_level != "$beta_level" ]]; then
  ok 'two apps get different MCS levels'
else
  bad 'two apps get different MCS levels' "alpha='$alpha_level' beta='$beta_level'"
fi

if [[ $(grep -c '^Volume=' "$alpha") == 1 && $(grep -c '^PublishPort=' "$alpha") == 1 ]]; then
  ok 'exactly one bind and one published port'
else
  bad 'exactly one bind and one published port'
fi

if jq -e '.apps.alpha.basePath == "/apps/alpha" and .apps.alpha.egress == "none" and .apps.alpha.quota == "5G"' \
  "$out/plan.json" >/dev/null 2>&1; then
  ok 'the plan names the Serve path, egress class and quota'
else
  bad 'the plan names the Serve path, egress class and quota' "$(head -c 500 "$out/plan.json" 2>/dev/null)"
fi

alpha_project=$(jq -r '.apps.alpha.projectId' "$out/plan.json" 2>/dev/null)
beta_project=$(jq -r '.apps.beta.projectId' "$out/plan.json" 2>/dev/null)
if [[ $alpha_project =~ ^[0-9]+$ ]] && ((alpha_project >= 1 && alpha_project <= 4294967295)); then
  ok 'the plan gives each app a ZFS project id'
else
  bad 'the plan gives each app a ZFS project id' "got '$alpha_project'"
fi
if [[ -n $alpha_project && $alpha_project != "$beta_project" ]]; then
  ok 'two apps get different project ids'
else
  bad 'two apps get different project ids' "alpha='$alpha_project' beta='$beta_project'"
fi
# An app arriving must not move another app's quota accounting.
mkdir -p "$tree/apps/gamma"
cat >"$tree/apps/gamma/app.toml" <<EOF
image = "ghcr.io/example/gamma@sha256:$digest"
port = 7070
egress = "internet"
EOF
"$validator" render --root "$tree" --secrets "$tree/secrets.sops.json" --out "$work/gamma" >/dev/null 2>&1
if [[ $(jq -r '.apps.alpha.projectId' "$work/gamma/plan.json") == "$alpha_project" ]]; then
  ok 'an unrelated app does not move an existing project id'
else
  bad 'an unrelated app does not move an existing project id'
fi
rm -rf "$tree/apps/gamma"

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

# A symlinked target would let the deploy write into a directory it does not own.
linkout=$work/linkout
mkdir -p "$work/realout"
ln -s "$work/realout" "$linkout"
if "$validator" render --root "$tree" --secrets "$tree/secrets.sops.json" --out "$linkout" >/dev/null 2>&1; then
  bad 'a symlinked output directory is refused'
else
  ok 'a symlinked output directory is refused'
fi
if [[ -z $(ls -A "$work/realout") ]]; then ok 'the symlink target stays untouched'; else bad 'the symlink target stays untouched'; fi

# A network file this renderer wrote is removed when the last no-egress app
# becomes internet, so the marker must match what render_network emits.
nonet=$work/nonet
mkdir -p "$nonet"
"$validator" render --root "$tree" --secrets "$tree/secrets.sops.json" --out "$nonet" >/dev/null 2>&1
sed -i 's/^egress = "none"$/egress = "internet"/' "$tree/apps/alpha/app.toml"
if "$validator" render --root "$tree" --secrets "$tree/secrets.sops.json" --out "$nonet" >/dev/null 2>&1 &&
  [[ ! -f $nonet/smortress-apps.network ]]; then
  ok 'a stale network file is removed with the last no-egress app'
else
  bad 'a stale network file is removed with the last no-egress app' "$(cat "$work/render.log" 2>/dev/null)"
fi
sed -i 's/^egress = "internet"$/egress = "none"/' "$tree/apps/alpha/app.toml"

# --- ownership of the output directory -----------------------------------

# A foreign unit in the target directory is never overwritten or deleted.
foreign=$work/foreign
mkdir -p "$foreign"
printf '[Container]\nImage=example\n' >"$foreign/other.container"
if "$validator" render --root "$tree" --secrets "$tree/secrets.sops.json" --out "$foreign" >/dev/null 2>&1; then
  bad 'a foreign unit in the output directory is refused'
else
  ok 'a foreign unit in the output directory is refused'
fi
if [[ -f $foreign/other.container ]]; then ok 'the foreign unit survives'; else bad 'the foreign unit survives'; fi

# A stale unit this renderer wrote is removed when its app disappears.
stale=$work/stale
mkdir -p "$stale"
"$validator" render --root "$tree" --secrets "$tree/secrets.sops.json" --out "$stale" >/dev/null 2>&1
rm -rf "$tree/apps/beta"
"$validator" render --root "$tree" --secrets "$tree/secrets.sops.json" --out "$stale" >/dev/null 2>&1
if [[ ! -f $stale/beta.container && -f $stale/smortress-apps.network ]]; then
  ok 'a removed app loses its unit and the network stays while it is still used'
else
  bad 'a removed app loses its unit and the network stays while it is still used' "$(ls "$stale")"
fi
mkdir -p "$tree/apps/beta"
cat >"$tree/apps/beta/app.toml" <<EOF
image = "ghcr.io/example/beta@sha256:$digest"
port = 9090
egress = "internet"
EOF

# An empty tenant is refused rather than rendered as an empty plan.
emptytree=$work/emptytree
mkdir -p "$emptytree/apps"
if "$validator" render --root "$emptytree" --out "$work/emptyout" >/dev/null 2>&1; then
  bad 'an empty tenant is refused'
else
  ok 'an empty tenant is refused'
fi

# --out pointing at a file is a diagnostic, not a traceback.
if "$validator" render --root "$tree" --secrets "$tree/secrets.sops.json" --out "$work/render.log" >"$work/outfile.log" 2>&1; then
  bad '--out pointing at a file is refused'
elif grep -q 'Traceback' "$work/outfile.log"; then
  bad '--out pointing at a file is refused' "$(cat "$work/outfile.log")"
else
  ok '--out pointing at a file is refused'
fi

# Hostile env values cannot reach the unit: the validator refuses them.
for value in 'hello world' "trail\\" '100%n' 'a"b' 'a#b' 'a`b'; do
  hostile=$(mktemp -d "$work/hostile.XXXXXX")
  mkdir -p "$hostile/apps/delta"
  printf 'image = "ghcr.io/example/delta@sha256:%s"\nport = 7070\negress = "none"\n\n[env]\nK = '\''%s'\''\n' "$digest" "$value" \
    >"$hostile/apps/delta/app.toml"
  if "$validator" render --root "$hostile" --out "$work/hostile-out" >/dev/null 2>&1; then
    bad "env value [$value] is refused"
  else
    ok "env value [$value] is refused"
  fi
done

# The host generator is the ground truth for what a unit means. Where podman is
# installed (the host, not the CI runner), the rendered unit must generate with
# the MCS level, the exact env value and the single publish.
if [[ -x /usr/libexec/podman/quadlet ]]; then
  gen=$(mktemp -d "$work/gen.XXXXXX")
  mkdir -p "$gen/xdg/containers/systemd"
  "$validator" render --root "$tree" --secrets "$tree/secrets.sops.json" --out "$gen/xdg/containers/systemd" >/dev/null 2>&1
  if XDG_CONFIG_HOME="$gen/xdg" /usr/libexec/podman/quadlet -dryrun -user >"$gen/units" 2>"$gen/err"; then
    if grep -q -- '--security-opt label=level:s0:c' "$gen/units" &&
      grep -q -- '--env TZ=UTC' "$gen/units" &&
      grep -q -- '--publish 127.0.0.1:' "$gen/units"; then
      ok 'the host generator accepts the rendered unit'
    else
      bad 'the host generator accepts the rendered unit' "$(grep -E 'security-opt|env|publish' "$gen/units" | head -5)"
    fi
  else
    bad 'the host generator accepts the rendered unit' "$(cat "$gen/err")"
  fi
else
  ok 'the host generator check is skipped without podman'
fi

printf '\n%s checks, %s failed\n' "$((pass + fail))" "$fail"
((fail == 0))
