#!/usr/bin/env bats
# bats file_tags=apps
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
#   bats tests/apps/render.bats
#
# The renderer writes into an output directory, and several checks mutate the
# tree (an app arrives, an app is removed, an egress class changes), so every
# test builds its own tenant and its own output directory under
# $BATS_TEST_TMPDIR and renders into it once with `rendered`.
load ../helpers

validator=scripts/apps-schema.py
digest=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

setup() {
    # The validator is the subject of every check; a missing one fails them all
    # instead of passing on an absent binary.
    [ -x "$validator" ]
    work=$BATS_TEST_TMPDIR
    tree=$work/tree
    out=$work/out
    write_tree "$tree"
    mkdir -p "$out"
}

# write_tree <dir>: the tenant every check renders -- one app with every field,
# one internet app with no secrets.
write_tree() {
    mkdir -p "$1/apps/alpha" "$1/apps/beta"
    cat >"$1/secrets.sops.json" <<'JSON'
{"apps": {"alpha": {"api-key": "ENC[x]"}}, "sops": {}}
JSON
    cat >"$1/apps/alpha/app.toml" <<EOF
image = "ghcr.io/example/alpha@sha256:$digest"
port = 8080
egress = "none"
quota = "5G"
secrets = ["api-key"]

[env]
TZ = "UTC"
EOF
    cat >"$1/apps/beta/app.toml" <<EOF
image = "ghcr.io/example/beta@sha256:$digest"
port = 9090
egress = "internet"
EOF
}

# write_gamma <dir>: the unrelated app whose arrival must not move an id.
write_gamma() {
    mkdir -p "$1/apps/gamma"
    cat >"$1/apps/gamma/app.toml" <<EOF
image = "ghcr.io/example/gamma@sha256:$digest"
port = 7070
egress = "internet"
EOF
}

# write_badtree <dir>: a tenant the schema rejects -- a definition with a host
# bind, which is the field the boundary exists to refuse.
write_badtree() {
    mkdir -p "$1/apps/gamma"
    cat >"$1/apps/gamma/app.toml" <<EOF
image = "ghcr.io/example/gamma@sha256:$digest"
port = 7070
egress = "none"
volumes = ["/:/host"]
EOF
}

# render <tree> <out> [args...]: the validator's render. A tree without a tenant
# secrets file is rendered without one, which is what the refused tenants are.
render() {
    local root=$1 target=$2
    shift 2
    if [[ -f $root/secrets.sops.json ]]; then
        "$validator" render --root "$root" --secrets "$root/secrets.sops.json" --out "$target" "$@"
    else
        "$validator" render --root "$root" --out "$target" "$@"
    fi
}

# rendered: render the fixture into $out, failing the check if it cannot.
rendered() {
    local rc=0
    render "$tree" "$out" >"$work/render.log" 2>&1 || rc=$?
    assert_equal "$rc" 0
}

contains() { # file text
    if ! grep -qF -- "$2" "$1"; then
        printf "missing '%s' in %s\n" "$2" "$1" >&2
        return 1
    fi
}

lacks() { # file text
    if grep -qF -- "$2" "$1"; then
        printf "unexpected '%s' in %s\n" "$2" "$1" >&2
        return 1
    fi
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

@test "render succeeds on a valid tree" {
    local rc=0
    render "$tree" "$out" >"$work/render.log" 2>&1 || rc=$?
    assert_equal "$rc" 0
}

@test "one Quadlet per app" {
    rendered
    [[ -f $out/alpha.container ]]
}

@test "the image is the digest-pinned one" {
    rendered
    contains "$out/alpha.container" "Image=ghcr.io/example/alpha@sha256:$digest"
}

@test "nothing is published: ingress is root-owned" {
    rendered
    lacks "$out/alpha.container" 'PublishPort='
}

# Quadlet links a container to a Quadlet network only when the value carries
# the .network suffix, and it names the created network after NetworkName, so
# both halves must agree or the container starts against a network that does
# not exist and never pulls in the unit that creates it.
@test "egress none joins the internal network" {
    rendered
    contains "$out/alpha.container" 'Network=smortress-apps.network'
}

@test "the network keeps its planned name" {
    rendered
    contains "$out/smortress-apps.network" 'NetworkName=smortress-apps'
}

@test "the internal network has no route out" {
    rendered
    contains "$out/smortress-apps.network" 'Internal=true'
}

@test "the only bind is the app data directory, relabelled" {
    rendered
    contains "$out/alpha.container" 'Volume=/srv/apps/alpha:/data:Z'
}

@test "the root filesystem is read-only" {
    rendered
    contains "$out/alpha.container" 'ReadOnly=true'
}

@test "no-new-privileges is set" {
    rendered
    contains "$out/alpha.container" 'NoNewPrivileges=true'
}

@test "all capabilities are dropped" {
    rendered
    contains "$out/alpha.container" 'DropCapability=ALL'
}

# Dropping every capability removes CAP_NET_BIND_SERVICE, so an image that
# listens below 1024 would fail to bind. The sysctl opens low ports to the
# unprivileged user inside the namespace instead of re-granting the cap.
@test "low ports bind without capabilities" {
    rendered
    contains "$out/alpha.container" 'Sysctl=net.ipv4.ip_unprivileged_port_start=0'
}

@test "a per-app MCS level is set" {
    rendered
    contains "$out/alpha.container" 'SecurityLabelLevel=s0:c'
}

@test "declared env reaches the unit" {
    rendered
    contains "$out/alpha.container" 'Environment=TZ=UTC'
}

@test "secrets mount under their own name" {
    rendered
    contains "$out/alpha.container" 'Secret=app-alpha-api-key,type=mount,target=/run/secrets/api-key'
}

@test "the unit is a rootless user unit" {
    rendered
    contains "$out/alpha.container" 'WantedBy=default.target'
}

@test "the unit names the root-owned tenant policy" {
    rendered
    contains "$out/alpha.container" 'PodmanArgs=--signature-policy=/usr/share/smortress/apps-policy.json'
}

@test "nothing binds every address" {
    rendered
    lacks "$out/alpha.container" '0.0.0.0'
}

@test "nothing uses the host network" {
    rendered
    lacks "$out/alpha.container" 'Network=host'
}

# The tenant's limits are properties of each app unit, not of a numeric
# user-<uid>.slice drop-in that stops applying when sysusers reallocates the id.
# MemoryHigh is the soft ceiling systemd reclaims against; MemoryMax is the hard
# one. Both per app, so the tenant's total is the sum of what it runs.
unit_carries_limit() { # limit
    rendered
    contains "$out/alpha.container" "$1"
}

for limit in 'MemoryHigh=' 'MemoryMax=' 'CPUQuota=' 'TasksMax='; do
    register "the app unit carries $limit" unit_carries_limit "$limit"
done

@test "egress internet renders pasta" {
    rendered
    contains "$out/beta.container" 'Network=pasta'
}

@test "an app with no secrets gets none" {
    rendered
    lacks "$out/beta.container" 'Secret='
}

# Nothing in a rendered unit may name the tenant by number: a uid here would be
# the fixed id the account no longer has.
@test "no rendered unit names the tenant by id" {
    rendered
    local alpha=$out/alpha.container beta=$out/beta.container
    if grep -qE '=(1001|1001:1001)$|user@[0-9]+' "$alpha" "$beta"; then
        grep -nE '1001|user@[0-9]+' "$alpha" "$beta" >&2
        return 1
    fi
}

@test "the loopback port comes from the platform range" {
    rendered
    local alpha_port
    alpha_port=$(jq -r '.apps.alpha.loopbackPort' "$out/plan.json")
    if [[ ! $alpha_port =~ ^[0-9]+$ ]] || ((alpha_port < 20000 || alpha_port >= 30000)); then
        printf "got '%s'\n" "$alpha_port" >&2
        return 1
    fi
}

@test "two apps get different loopback ports" {
    rendered
    assert_not_equal "$(jq -r '.apps.alpha.loopbackPort' "$out/plan.json")" \
        "$(jq -r '.apps.beta.loopbackPort' "$out/plan.json")"
}

@test "two apps get different MCS levels" {
    rendered
    local alpha_level beta_level
    alpha_level=$(sed -n 's/^SecurityLabelLevel=//p' "$out/alpha.container")
    beta_level=$(sed -n 's/^SecurityLabelLevel=//p' "$out/beta.container")
    if [[ -z $alpha_level || -z $beta_level || $alpha_level == "$beta_level" ]]; then
        printf "alpha='%s' beta='%s'\n" "$alpha_level" "$beta_level" >&2
        return 1
    fi
}

@test "exactly one bind and no published port" {
    rendered
    local alpha=$out/alpha.container
    [[ $(grep -c '^Volume=' "$alpha") == 1 && $(grep -c '^PublishPort=' "$alpha") == 0 ]]
}

@test "the plan names the Serve path, egress class and quota" {
    rendered
    jq -e '.apps.alpha.basePath == "/apps/alpha" and .apps.alpha.egress == "none" and .apps.alpha.quota == "5G"' \
        "$out/plan.json" >/dev/null
}

@test "the plan gives each app a ZFS project id" {
    rendered
    local alpha_project
    alpha_project=$(jq -r '.apps.alpha.projectId' "$out/plan.json")
    if [[ ! $alpha_project =~ ^[0-9]+$ ]] || ((alpha_project < 1 || alpha_project > 4294967295)); then
        printf "got '%s'\n" "$alpha_project" >&2
        return 1
    fi
}

@test "two apps get different project ids" {
    rendered
    assert_not_equal "$(jq -r '.apps.alpha.projectId' "$out/plan.json")" \
        "$(jq -r '.apps.beta.projectId' "$out/plan.json")"
}

# An app arriving must not move another app's quota accounting.
@test "an unrelated app does not move an existing project id" {
    rendered
    local alpha_project
    alpha_project=$(jq -r '.apps.alpha.projectId' "$out/plan.json")
    write_gamma "$tree"
    render "$tree" "$work/gamma" >/dev/null 2>&1
    assert_equal "$(jq -r '.apps.alpha.projectId' "$work/gamma/plan.json")" "$alpha_project"
}

# Determinism: a second render of the same tree is byte-identical, so a deploy
# can diff it.
@test "rendering twice produces identical output" {
    rendered
    cp -r "$out" "$work/first"
    render "$tree" "$out" >/dev/null 2>&1
    diff -r "$work/first" "$out"
}

# --check is the drift gate the deploy uses.
@test "--check passes against its own output" {
    rendered
    render "$tree" "$out" --check >/dev/null 2>&1
}

@test "--check fails on drift" {
    rendered
    printf 'tampered\n' >>"$out/alpha.container"
    local rc=0
    render "$tree" "$out" --check >/dev/null 2>&1 || rc=$?
    assert_not_equal "$rc" 0
}

# A rejected definition must not produce a partial plan.
@test "a schema error stops the render" {
    local badtree=$work/badtree
    write_badtree "$badtree"
    local rc=0
    render "$badtree" "$work/badout" >/dev/null 2>&1 || rc=$?
    assert_not_equal "$rc" 0
}

@test "a rejected tree writes no files" {
    local badtree=$work/badtree
    write_badtree "$badtree"
    mkdir -p "$work/badout"
    render "$badtree" "$work/badout" >/dev/null 2>&1 || true
    assert_equal "$(ls -A "$work/badout")" ''
}

# A symlinked target would let the deploy write into a directory it does not own.
@test "a symlinked output directory is refused" {
    mkdir -p "$work/realout"
    ln -s "$work/realout" "$work/linkout"
    local rc=0
    render "$tree" "$work/linkout" >/dev/null 2>&1 || rc=$?
    assert_not_equal "$rc" 0
}

@test "the symlink target stays untouched" {
    mkdir -p "$work/realout"
    ln -s "$work/realout" "$work/linkout"
    render "$tree" "$work/linkout" >/dev/null 2>&1 || true
    assert_equal "$(ls -A "$work/realout")" ''
}

# A network file this renderer wrote is removed when the last no-egress app
# becomes internet, so the marker must match what render_network emits.
@test "a stale network file is removed with the last no-egress app" {
    local nonet=$work/nonet
    mkdir -p "$nonet"
    render "$tree" "$nonet" >/dev/null 2>&1
    sed -i 's/^egress = "none"$/egress = "internet"/' "$tree/apps/alpha/app.toml"
    render "$tree" "$nonet" >/dev/null 2>&1
    [[ ! -f $nonet/smortress-apps.network ]]
}

# --- ownership of the output directory -----------------------------------

# A foreign unit in the target directory is never overwritten or deleted.
@test "a foreign unit in the output directory is refused" {
    local foreign=$work/foreign
    mkdir -p "$foreign"
    printf '[Container]\nImage=example\n' >"$foreign/other.container"
    local rc=0
    render "$tree" "$foreign" >/dev/null 2>&1 || rc=$?
    assert_not_equal "$rc" 0
}

@test "the foreign unit survives" {
    local foreign=$work/foreign
    mkdir -p "$foreign"
    printf '[Container]\nImage=example\n' >"$foreign/other.container"
    render "$tree" "$foreign" >/dev/null 2>&1 || true
    [[ -f $foreign/other.container ]]
}

# A stale unit this renderer wrote is removed when its app disappears.
@test "a removed app loses its unit and the network stays while it is still used" {
    local stale=$work/stale
    mkdir -p "$stale"
    render "$tree" "$stale" >/dev/null 2>&1
    rm -rf "$tree/apps/beta"
    render "$tree" "$stale" >/dev/null 2>&1
    if [[ -f $stale/beta.container || ! -f $stale/smortress-apps.network ]]; then
        ls "$stale" >&2
        return 1
    fi
}

# An empty tenant is refused rather than rendered as an empty plan.
@test "an empty tenant is refused" {
    local emptytree=$work/emptytree
    mkdir -p "$emptytree/apps"
    local rc=0
    render "$emptytree" "$work/emptyout" >/dev/null 2>&1 || rc=$?
    assert_not_equal "$rc" 0
}

# --allow-empty is the deploy's escape hatch for removing the last app: it is
# the same tree, and it has to produce the empty plan (which is what stops every
# unit and prunes every Serve route) instead of writing nothing.
@test "an empty tenant renders with --allow-empty" {
    local emptytree=$work/emptytree
    mkdir -p "$emptytree/apps"
    render "$emptytree" "$work/emptyout" --allow-empty >"$work/empty.log" 2>&1
    assert_equal "$(jq -r '.apps | length' "$work/emptyout/plan.json")" 0
}

@test "the empty plan has no unit" {
    local emptytree=$work/emptytree
    mkdir -p "$emptytree/apps"
    render "$emptytree" "$work/emptyout" --allow-empty >/dev/null 2>&1
    assert_equal "$(find "$work/emptyout" -maxdepth 1 -type f -name '*.container' -print -quit)" ''
}

# The flag means "there is nothing to render", not "skip validation": a bad
# definition is still a rejection.
@test "--allow-empty does not weaken validation" {
    local badtree=$work/badtree
    write_badtree "$badtree"
    local rc=0
    render "$badtree" "$work/badout-empty" --allow-empty >/dev/null 2>&1 || rc=$?
    assert_not_equal "$rc" 0
}

@test "--allow-empty writes nothing for a rejected tree" {
    local badtree=$work/badtree
    write_badtree "$badtree"
    render "$badtree" "$work/badout-empty" --allow-empty >/dev/null 2>&1 || true
    if [[ -e $work/badout-empty ]] && [[ -n $(ls -A "$work/badout-empty" 2>/dev/null) ]]; then
        ls "$work/badout-empty" >&2
        return 1
    fi
}

# --out pointing at a file is a diagnostic, not a traceback.
@test "--out pointing at a file is refused" {
    rendered
    : >"$work/outfile"
    local rc=0
    render "$tree" "$work/outfile" >"$work/outfile.log" 2>&1 || rc=$?
    assert_not_equal "$rc" 0
    ! grep -q 'Traceback' "$work/outfile.log"
}

# Hostile env values cannot reach the unit: the validator refuses them.
env_value_is_refused() { # value
    local hostile rc=0
    hostile=$(mktemp -d "$work/hostile.XXXXXX")
    mkdir -p "$hostile/apps/delta"
    printf 'image = "ghcr.io/example/delta@sha256:%s"\nport = 7070\negress = "none"\n\n[env]\nK = '\''%s'\''\n' "$digest" "$1" \
        >"$hostile/apps/delta/app.toml"
    render "$hostile" "$work/hostile-out" >/dev/null 2>&1 || rc=$?
    assert_not_equal "$rc" 0
}

for value in 'hello world' "trail\\" '100%n' 'a"b' 'a#b' 'a`b'; do
    registered "env value [$value] is refused" env_value_is_refused "$value"
done

# The host generator is the ground truth for what a unit means. Where podman is
# installed (the host, not the CI runner), the rendered unit must generate with
# the MCS level, the exact env value and the single publish.
generator_units() { # prints the generated units, or fails with quadlet's error
    local gen
    gen=$(mktemp -d "$work/gen.XXXXXX")
    mkdir -p "$gen/xdg/containers/systemd"
    render "$tree" "$gen/xdg/containers/systemd" >/dev/null 2>&1
    XDG_CONFIG_HOME="$gen/xdg" /usr/libexec/podman/quadlet -dryrun -user >"$gen/units" 2>"$gen/err" || {
        cat "$gen/err" >&2
        return 1
    }
    cat "$gen/units"
}

host_generator_accepts() {
    local units
    units=$(generator_units)
    assert_contains "$units" '--security-opt label=level:s0:c'
    assert_contains "$units" '--env TZ=UTC'
    assert_contains "$units" '--sysctl net.ipv4.ip_unprivileged_port_start=0'
    if [[ $units == *'--publish'* ]]; then
        printf 'the generated unit publishes:\n%s\n' "$(grep -F -- '--publish' <<<"$units")" >&2
        return 1
    fi
}

generator_check_skipped() {
    [[ ! -x /usr/libexec/podman/quadlet ]]
}

generated_service_carries() { # limit
    local units
    units=$(generator_units)
    grep -q "^$1=" <<<"$units"
}

if [[ -x /usr/libexec/podman/quadlet ]]; then
    register 'the host generator accepts the rendered unit' host_generator_accepts
    # The limits have to survive into the generated service, which is the unit
    # the user manager actually starts.
    for limit in MemoryHigh MemoryMax CPUQuota TasksMax; do
        register "the generated service carries $limit" generated_service_carries "$limit"
    done
else
    register 'the host generator check is skipped without podman' generator_check_skipped
fi
