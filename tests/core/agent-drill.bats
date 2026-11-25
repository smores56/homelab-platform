#!/usr/bin/env bats
# The probe texts are matched as literals, so `$1` must stay unexpanded here.
# shellcheck disable=SC2016
# Offline checks for the agent runtime drill (SDLC #716, T6 of #702), run by bats.
#
# The drill itself needs smortress: live namespaces, root-only secrets and a real
# Restic destination. This checks the half a tree can answer without root: that
# the script parses, refuses to probe unprivileged, documents its three
# subcommands, and that --dry-run really executes nothing. The last group pins
# the property that keeps a probe safe: a path is data, never shell text, so no
# probe script is ever built by interpolating what an operator typed.
#
#   bats tests/core/agent-drill.bats
load ../helpers

script=scripts/agent-runtime-drill.sh

# The shims a dry run must never reach, the record they write, and the script
# itself are per test: each @test runs in its own process.
setup() {
    # The suite is about this one script; the shell suite turned an unreadable
    # path into an immediate non-zero exit.
    [[ -r $script ]] || {
        printf '%s is missing\n' "$script" >&2
        return 1
    }
    install -d -m 0755 "$BATS_TEST_TMPDIR/bin"
    : >"$BATS_TEST_TMPDIR/calls"
    export DRILL_CALLS=$BATS_TEST_TMPDIR/calls

    # A PATH shim for every command the drill would have to run for real. If one
    # of them is reached during a dry run, the record file is no longer empty.
    for name in podman restic setpriv chown python3 stat; do
        cat >"$BATS_TEST_TMPDIR/bin/$name" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "$name \$*" >>"\$DRILL_CALLS"
exit 0
SHIM
        chmod 0755 "$BATS_TEST_TMPDIR/bin/$name"
    done
}

# run_dry <arguments...> -> sets out, rc; --dry-run is always passed
run_dry() {
    : >"$DRILL_CALLS"
    rc=0
    out=$(PATH="$BATS_TEST_TMPDIR/bin:$PATH" "$script" --dry-run "$@" 2>&1) || rc=$?
}

# ------------------------------------------------------------------- shape

@test "the drill is executable" {
    [[ -x $script ]]
}

@test "the drill parses" {
    bash -n "$script"
}

@test "--help exits 0" {
    run_dry --help
    assert_equal "$rc" 0
}

help_documents() { # <subcommand>
    run_dry --help
    grep -q "^  $1" <<<"$out"
}

for subcommand in mounts credentials restore; do
    register "--help documents $subcommand" help_documents "$subcommand"
done

@test "--help names --dry-run" {
    run_dry --help
    grep -q -- '--dry-run' <<<"$out"
}

# Every invocation that touches the host needs root, and says so.
if ((EUID == 0)); then
    printf 'skip the unprivileged refusal checks: this test is running as root\n'
else
    unprivileged_refuses() { # <invocation...>
        rc=0
        # shellcheck disable=SC2086  # the invocation is a word list on purpose
        out=$("$script" $* 2>&1) || rc=$?
        [[ $rc -ne 0 ]]
    }

    unprivileged_names_privilege() { # <invocation...>
        rc=0
        # shellcheck disable=SC2086  # the invocation is a word list on purpose
        out=$("$script" $* 2>&1) || rc=$?
        grep -qiE 'root|sudo' <<<"$out"
    }

    for invocation in 'mounts' 'credentials' 'restore agent-local'; do
        register "$invocation refuses to run unprivileged" unprivileged_refuses "$invocation"
        register "$invocation names the missing privilege" unprivileged_names_privilege "$invocation"
    done
fi

# refuse <arguments...>: the script exits non-zero without a dry run.
refuse() {
    rc=0
    out=$("$script" "$@" 2>&1) || rc=$?
    [[ $rc -ne 0 ]]
}

refuse_dry() {
    rc=0
    out=$("$script" --dry-run "$@" 2>&1) || rc=$?
    [[ $rc -ne 0 ]]
}

@test "an unknown flag is refused" {
    refuse --nonsense
}

@test "restore without a unit is refused" {
    refuse restore
}

@test "restore refuses a unit that is not an agent dataset" {
    refuse_dry restore nonsense
}

@test "restore refuses an unknown backend" {
    refuse_dry restore agent-local --backend bogus
}

@test "mounts refuses a unit" {
    refuse_dry mounts agent-local
}

# ------------------------------------------------------------------ dry run

@test "dry-run mounts exits 0" {
    run_dry mounts
    assert_equal "$rc" 0
}

@test "dry-run mounts executed nothing" {
    run_dry mounts
    [[ ! -s $DRILL_CALLS ]]
}

mounts_plans() { # <path>
    run_dry mounts
    grep -qF -- "$1" <<<"$out"
}

for path in /var/lib/agent/local /var/lib/agent/general /var/srv/files \
    /var/srv/photos /var/srv/repo-archive; do
    register "dry-run mounts plans $path" mounts_plans "$path"
done

@test "dry-run mounts plans a podman exec" {
    run_dry mounts
    grep -qF 'podman exec' <<<"$out"
}

@test "dry-run credentials exits 0" {
    run_dry credentials
    assert_equal "$rc" 0
}

@test "dry-run credentials executed nothing" {
    run_dry credentials
    [[ ! -s $DRILL_CALLS ]]
}

credentials_plans() { # <secret>
    run_dry credentials
    grep -qF -- "$1" <<<"$out"
}

for secret in restic-password r2-credentials age-identity; do
    register "dry-run credentials plans the $secret probe" credentials_plans "$secret"
done

@test "dry-run restore --backend all exits 0" {
    run_dry restore agent-local --backend all
    assert_equal "$rc" 0
}

@test "dry-run restore executed nothing" {
    run_dry restore agent-local --backend all
    [[ ! -s $DRILL_CALLS ]]
}

restore_plans() { # <backend>
    run_dry restore agent-local --backend all
    grep -qF -- "$1 agent-local" <<<"$out"
}

for backend in ssd hdd r2; do
    register "dry-run restore plans $backend" restore_plans "$backend"
done

@test "dry-run restore plans the restore-drill helper" {
    run_dry restore agent-local --backend all
    grep -qF 'smortress-restic-restore-drill' <<<"$out"
}

# One restore writes tens of GiB. The default target belongs on a data disk: a
# restore that fills the root filesystem takes every service down with it.
@test "the default restore target is on a data disk" {
    run_dry restore agent-local --backend all
    grep -qE 'restoring into /var/lib/restic/(ssd|hdd)/' <<<"$out"
}

@test "the default drill root is only chosen from a mounted disk" {
    grep -qF 'mountpoint -q "$candidate"' "$script"
}

@test "a restore target on the root filesystem is refused" {
    grep -qF 'resolves to the root filesystem' "$script"
}

@test "the drill no longer roots its default target at /var/tmp" {
    rc=0
    help_out=$("$script" --help 2>&1) || rc=$?
    assert_equal "$(grep -n 'default: /var/tmp' <<<"$help_out")" ""
}

@test "dry-run restore honours --target" {
    run_dry restore agent-general --target /var/tmp/agent-drill-proof
    grep -qF -- '/var/tmp/agent-drill-proof' <<<"$out"
}

@test "a dry run with no subcommand is a usage error" {
    run_dry
    [[ $rc -ne 0 ]]
}

# -------------------------------------------------------------- static pins

# A probe script is a constant and the path arrives as $1: that is what keeps an
# operator-typed path from being parsed as shell. Every -c form must therefore be
# `-c "$probe" _ "$path"`, never a string built by interpolation.
@test "every probe script is passed as a constant with positional arguments" {
    c_lines=$(grep -c 'sh -c ' "$script")
    shaped=$(grep -cE 'sh -c "\$[a-z_]+" _ "\$[a-z_]+"' "$script")
    assert_equal "$c_lines" "$shaped"
}

@test "the probe scripts reference only their positional argument" {
    probe_vars=$(grep -E '^(tree|file)_probe=' "$script" |
        grep -oE '\$\{?[A-Za-z0-9_]+' | sort -u)
    assert_equal "$probe_vars" '$1'
}

@test "nothing is eval-ed" {
    assert_equal "$(grep -cE '(^|[^[:alnum:]_])eval([^[:alnum:]_]|$)' "$script")" 0
}

@test "every podman exec names the uid it probes as" {
    execs=$(grep -c 'podman exec' "$script")
    uid_execs=$(grep -c 'podman exec --user' "$script")
    assert_equal "$execs" "$uid_execs"
}

@test "the tree probe lists to /dev/null, never to the operator" {
    grep -qF 'ls -A -- "$1" >/dev/null 2>&1' "$script"
}

@test "the file probe reads to /dev/null, never to the operator" {
    grep -qF 'cat -- "$1" >/dev/null 2>&1' "$script"
}

@test "no secret is printed with cat, head, tail or strings" {
    assert_equal "$(grep -cE '(^|[^[:alnum:]_])(cat|head|tail|strings|xxd) ("|\$)' "$script")" 0
}

@test "the restore unit is an allowlist of the two agent datasets" {
    grep -qE '^ *agent-local \| agent-general\)' "$script"
}

@test "the backend is an allowlist of the three destinations" {
    grep -qF 'ssd | hdd | r2' "$script"
}

@test "a restore target inside a live dataset is refused" {
    grep -qF 'inside the live dataset' "$script"
}

@test "the drill never runs restic directly, only the restore-drill helper" {
    assert_equal "$(grep -cE '[^_-]restic (-r|snapshots|dump|stats|backup)' "$script")" 0
}

@test "the restored tree is chowned to 1000:1000 before it is trusted" {
    grep -qF 'chown -R 1000:1000' "$script"
}

@test "a second restore into the same target is asserted" {
    grep -qF 'refuses a second restore into the same target' "$script"
}

@test "the FTS index is rebuilt from the restored records" {
    grep -qF 'MemoryIndex' "$script"
}

@test "an absent oneshot collector is classified, not failed" {
    bash -c 'grep -q "^container_is_transient()" "$1" && grep -q "container_is_transient \"\$container\"" "$1"' _ "$script"
}

@test "the transient rule keys on oneshot units, not on --rm" {
    bash -c 'grep -q "Type=oneshot" "$1" && ! grep -qE "\|\| grep -qE -- .--rm" "$1"' _ "$script"
}
