#!/usr/bin/env bash
# The probe texts are matched as literals, so `$1` must stay unexpanded here.
# shellcheck disable=SC2016
# Offline checks for the agent runtime drill (SDLC #716, T6 of #702).
#
# The drill itself needs smortress: live namespaces, root-only secrets and a real
# Restic destination. This checks the half a tree can answer without root: that
# the script parses, refuses to probe unprivileged, documents its three
# subcommands, and that --dry-run really executes nothing. The last group pins
# the property that keeps a probe safe: a path is data, never shell text, so no
# probe script is ever built by interpolating what an operator typed.
#
#   tests/core/agent-drill.sh
set -uo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root" || exit 1

script=scripts/agent-runtime-drill.sh
[[ -r $script ]] || {
  printf 'FAIL %s is missing\n' "$script" >&2
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
check() { # check <label> <command...>
  local label=$1
  shift
  if "$@"; then ok "$label"; else bad "$label"; fi
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
install -d -m 0755 "$work/bin"
: >"$work/calls"
export DRILL_CALLS=$work/calls

# A PATH shim for every command the drill would have to run for real. If one of
# them is reached during a dry run, the record file is no longer empty.
for name in podman restic setpriv chown python3 stat; do
  cat >"$work/bin/$name" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "$name \$*" >>"\$DRILL_CALLS"
exit 0
SHIM
  chmod 0755 "$work/bin/$name"
done

run_dry() { # run_dry <arguments...> -> sets out, rc; --dry-run is always passed
  : >"$work/calls"
  out=$(PATH="$work/bin:$PATH" "$script" --dry-run "$@" 2>&1)
  rc=$?
  return 0
}

# ------------------------------------------------------------------- shape
check 'the drill is executable' test -x "$script"
check 'the drill parses' bash -n "$script"

run_dry --help
check '--help exits 0' test "$rc" -eq 0
for subcommand in mounts credentials restore; do
  check "--help documents $subcommand" grep -q "^  $subcommand" <<<"$out"
done
check '--help names --dry-run' grep -q -- '--dry-run' <<<"$out"

# Every invocation that touches the host needs root, and says so.
if ((EUID == 0)); then
  printf 'skip the unprivileged refusal checks: this test is running as root\n'
else
  for invocation in 'mounts' 'credentials' 'restore agent-local'; do
    # shellcheck disable=SC2086  # the invocation is a word list on purpose
    out=$("$script" $invocation 2>&1)
    rc=$?
    check "$invocation refuses to run unprivileged" test "$rc" -ne 0
    check "$invocation names the missing privilege" grep -qiE 'root|sudo' <<<"$out"
  done
fi

out=$("$script" --nonsense 2>&1)
check 'an unknown flag is refused' test $? -ne 0
out=$("$script" restore 2>&1)
check 'restore without a unit is refused' test $? -ne 0
out=$("$script" --dry-run restore nonsense 2>&1)
check 'restore refuses a unit that is not an agent dataset' test $? -ne 0
out=$("$script" --dry-run restore agent-local --backend bogus 2>&1)
check 'restore refuses an unknown backend' test $? -ne 0
out=$("$script" --dry-run mounts agent-local 2>&1)
check 'mounts refuses a unit' test $? -ne 0

# ------------------------------------------------------------------ dry run
run_dry mounts
check 'dry-run mounts exits 0' test "$rc" -eq 0
check 'dry-run mounts executed nothing' test ! -s "$work/calls"
for path in /var/lib/agent/local /var/lib/agent/general /var/srv/files \
  /var/srv/photos /var/srv/repo-archive; do
  check "dry-run mounts plans $path" grep -qF -- "$path" <<<"$out"
done
check 'dry-run mounts plans a podman exec' grep -qF 'podman exec' <<<"$out"

run_dry credentials
check 'dry-run credentials exits 0' test "$rc" -eq 0
check 'dry-run credentials executed nothing' test ! -s "$work/calls"
for secret in restic-password r2-credentials age-identity; do
  check "dry-run credentials plans the $secret probe" grep -qF -- "$secret" <<<"$out"
done

run_dry restore agent-local --backend all
check 'dry-run restore --backend all exits 0' test "$rc" -eq 0
check 'dry-run restore executed nothing' test ! -s "$work/calls"
for backend in ssd hdd r2; do
  check "dry-run restore plans $backend" grep -qF -- "$backend agent-local" <<<"$out"
done
check 'dry-run restore plans the restore-drill helper' \
  grep -qF 'smortress-restic-restore-drill' <<<"$out"
# One restore writes tens of GiB. The default target belongs on a data disk: a
# restore that fills the root filesystem takes every service down with it.
check 'the default restore target is on a data disk' \
  grep -qE 'restoring into /var/lib/restic/(ssd|hdd)/' <<<"$out"
check 'the drill no longer roots its default target at /var/tmp' \
  test -z "$(grep -n 'default: /var/tmp' <<<"$("$script" --help 2>&1)")"

run_dry restore agent-general --target /var/tmp/agent-drill-proof
check 'dry-run restore honours --target' \
  grep -qF -- '/var/tmp/agent-drill-proof' <<<"$out"

run_dry
check 'a dry run with no subcommand is a usage error' test "$rc" -ne 0

# -------------------------------------------------------------- static pins
# A probe script is a constant and the path arrives as $1: that is what keeps an
# operator-typed path from being parsed as shell. Every -c form must therefore be
# `-c "$probe" _ "$path"`, never a string built by interpolation.
c_lines=$(grep -c 'sh -c ' "$script")
shaped=$(grep -cE 'sh -c "\$[a-z_]+" _ "\$[a-z_]+"' "$script")
check 'every probe script is passed as a constant with positional arguments' \
  test "$c_lines" -eq "$shaped"
probe_vars=$(grep -E '^(tree|file)_probe=' "$script" |
  grep -oE '\$\{?[A-Za-z0-9_]+' | sort -u)
check 'the probe scripts reference only their positional argument' \
  test "$probe_vars" = '$1'
check 'nothing is eval-ed' test "$(grep -cE '(^|[^[:alnum:]_])eval([^[:alnum:]_]|$)' "$script")" -eq 0

execs=$(grep -c 'podman exec' "$script")
uid_execs=$(grep -c 'podman exec --user' "$script")
check 'every podman exec names the uid it probes as' test "$execs" -eq "$uid_execs"

check 'the tree probe lists to /dev/null, never to the operator' \
  grep -qF 'ls -A -- "$1" >/dev/null 2>&1' "$script"
check 'the file probe reads to /dev/null, never to the operator' \
  grep -qF 'cat -- "$1" >/dev/null 2>&1' "$script"
check 'no secret is printed with cat, head, tail or strings' \
  test "$(grep -cE '(^|[^[:alnum:]_])(cat|head|tail|strings|xxd) ("|\$)' "$script")" -eq 0

check 'the restore unit is an allowlist of the two agent datasets' \
  grep -qE '^ *agent-local \| agent-general\)' "$script"
check 'the backend is an allowlist of the three destinations' \
  grep -qF 'ssd | hdd | r2' "$script"
check 'a restore target inside a live dataset is refused' \
  grep -qF 'inside the live dataset' "$script"
check 'the drill never runs restic directly, only the restore-drill helper' \
  test "$(grep -cE '[^_-]restic (-r|snapshots|dump|stats|backup)' "$script")" -eq 0
check 'the restored tree is chowned to 1000:1000 before it is trusted' \
  grep -qF 'chown -R 1000:1000' "$script"
check 'a second restore into the same target is asserted' \
  grep -qF 'refuses a second restore into the same target' "$script"
check 'the FTS index is rebuilt from the restored records' \
  grep -qF 'MemoryIndex' "$script"

check 'an absent oneshot collector is classified, not failed' \
  bash -c 'grep -q "^container_is_transient()" "$1" && grep -q "container_is_transient \"\$container\"" "$1"' _ "$script"
check 'the transient rule keys on oneshot units, not on --rm' \
  bash -c 'grep -q "Type=oneshot" "$1" && ! grep -qE "\|\| grep -qE -- .--rm" "$1"' _ "$script"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
