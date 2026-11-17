#!/usr/bin/env bash
# Offline checks for the Serve route generator (SDLC #726, T7 of #701).
#
# Serve is the tenant's only ingress. The core applications own their root
# paths; each `homelab-apps` app gets one `/apps/<name>` path on 443 pointing at
# the loopback port the renderer assigned. This proves the declaration half
# without a tailnet: the fixed core routes, one route per app, pruning of an app
# that left the plan, and a refusal to build a route from a plan that names a
# foreign path or port.
#
#   tests/core/tailscale-serve.sh
set -uo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root" || exit 1

script=scripts/tailscale-serve.sh
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
eq() {
  if [[ $1 == "$2" ]]; then ok "$3"; else bad "$3" "got '$1' want '$2'"; fi
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The fake tailscale records argv and answers `serve status --json` from a file
# the case sets up. `off` is a removal, so the status it prints afterwards is
# the file rewritten without that handler.
cat >"$work/tailscale" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_LOG"
case $1 in
    serve)
        shift
        case ${1:-} in
            status)
                cat "$FAKE_STATUS" ;;
            reset)
                printf '{}\n' >"$FAKE_STATUS" ;;
            *)
                # A declaration ends in a target; `off` removes that path.
                path=
                target=
                port=443
                for arg in "$@"; do
                    case $arg in
                        --set-path=*) path=${arg#--set-path=} ;;
                        --https=*) port=${arg#--https=} ;;
                        http://*) target=$arg ;;
                        off) target=off ;;
                    esac
                done
                path=${path:-/}
                if [[ -z $target ]]; then
                    echo "fake tailscale: unparsed serve invocation: $*" >&2
                    exit 2
                fi
                jq --arg key "host:$port" --arg path "$path" --arg target "$target" '
                    .Web //= {} | .Web[$key] //= {"Handlers": {}}
                    | if $target == "off"
                      then del(.Web[$key].Handlers[$path])
                      else .Web[$key].Handlers[$path] = {"Proxy": $target}
                      end' "$FAKE_STATUS" >"$FAKE_STATUS.next"
                mv "$FAKE_STATUS.next" "$FAKE_STATUS" ;;
        esac ;;
    *) echo "fake tailscale: unexpected command: $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$work/tailscale"

status=$work/status.json
plan=$work/plan.json
log=$work/log
digest=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

app_entry() { # name port project quota egress
    jq -cn --arg n "$1" --argjson port "$2" --argjson project "$3" \
        --arg quota "$4" --arg digest "$digest" --arg egress "$5" '{
            image: "ghcr.io/example/\($n)@sha256:\($digest)",
            basePath: "/apps/\($n)",
            dataPath: "/srv/apps/\($n)",
            loopbackPort: $port,
            projectId: $project,
            quota: $quota,
            network: (if $egress == "none" then "smortress-apps" else "pasta" end),
            mcs: "s0:c1,c2",
            secretNames: {},
            unitName: "\($n).container"
        }'
}
plan_with() { jq -cn --argjson apps "$1" '{version: 1, apps: $apps}'; }

run() {
    FAKE_LOG=$log FAKE_STATUS=$status TAILSCALE_BIN=$work/tailscale APPS_PLAN=$plan \
        APPS_SCHEMA=$root/scripts/apps-schema.py \
        bash "$script" >"$work/stdout" 2>"$work/stderr"
}

core_status() {
    cat >"$status" <<'EOF'
{
  "TCP": {"443": {"HTTPS": true}, "8443": {"HTTPS": true}, "10000": {"HTTPS": true}},
  "Web": {
    "host:443": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:2283"}}},
    "host:8443": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:8083"}}},
    "host:10000": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:8384"}}}
  }
}
EOF
}

reset_case() {
    : >"$log"
    rm -f "$plan"
    core_status
}

served() { # port -> handler path or empty
    jq -r --arg port "$1" '.Web[$port].Handlers // {} | to_entries[] | "\(.key) \(.value.Proxy)"' "$status" 2>/dev/null
}

# --- core routes always exist -------------------------------------------------

reset_case
run
eq "$?" 0 'a host with no tenant plan still declares the core routes'
serves() { # path target label
    if served "$1" | grep -qx "$2 $3"; then ok "$4"; else bad "$4" "$(served "$1")"; fi
}
serves host:443 / http://127.0.0.1:2283 '443 still fronts Immich'
serves host:8443 / http://127.0.0.1:8083 '8443 still fronts OPDShelf'
serves host:10000 / http://127.0.0.1:8384 '10000 still fronts Syncthing'

# --- one path per app --------------------------------------------------------

reset_case
plan_with "$(jq -cn --argjson a "$(app_entry alpha 21234 4001 1G internet)" \
  --argjson b "$(app_entry beta 22999 4002 1G internet)" '{alpha: $a, beta: $b}')" >"$plan"
run
eq "$?" 0 'a valid plan applies'
serves host:443 /apps/alpha http://127.0.0.1:21234 'alpha gets its path on 443'
serves host:443 /apps/beta http://127.0.0.1:22999 'beta gets its path on 443'
if grep -q -- '--https=443 --set-path=/apps/alpha http://127.0.0.1:21234' "$log"; then
    ok 'the declaration names the https port, path and loopback target'
else
    bad 'the declaration names the https port, path and loopback target' "$(cat "$log")"
fi

# --- stale routes are pruned -------------------------------------------------

reset_case
jq '.Web["host:443"].Handlers["/apps/removed"] = {"Proxy": "http://127.0.0.1:21000"}
    | .Web["host:443"].Handlers["/apps/gamma"] = {"Proxy": "http://127.0.0.1:21555"}' "$status" >"$work/s" && mv "$work/s" "$status"
plan_with "$(jq -cn --argjson a "$(app_entry alpha 21234 4001 1G internet)" '{alpha: $a}')" >"$plan"
run
eq "$?" 0 'a plan with a removed app applies'
if served host:443 | grep -q '^/apps/removed '; then
    bad 'a route for an app that left the plan is removed' "$(served host:443)"
else
    ok 'a route for an app that left the plan is removed'
fi
if served host:443 | grep -q '^/apps/gamma '; then
    bad 'a route for an app that left the plan is pruned' "$(served host:443)"
else
    ok 'a route for an app that left the plan is pruned'
fi
serves host:443 / http://127.0.0.1:2283 'pruning leaves the core root route alone'

# --- a missing plan prunes every app route -----------------------------------

reset_case
jq '.Web["host:443"].Handlers["/apps/alpha"] = {"Proxy": "http://127.0.0.1:21234"}' "$status" >"$work/s" && mv "$work/s" "$status"
run
eq "$?" 0 'no plan is not an error'
if served host:443 | grep -q '^/apps/'; then
    bad 'no plan removes every app route' "$(served host:443)"
else
    ok 'no plan removes every app route'
fi
serves host:443 / http://127.0.0.1:2283 'no plan keeps the core root route'

# --- malformed plans fail closed ---------------------------------------------

rejected() { # description, plan body
    reset_case
    printf '%s\n' "$2" >"$plan"
    if run; then bad "$1" "$(cat "$work/stderr")"; else ok "$1"; fi
}

rejected 'a non-object plan is rejected' '[]'
rejected 'a plan whose base path is not /apps/<name> is rejected' \
    '{"apps": {"alpha": {"basePath": "/elsewhere", "loopbackPort": 21234, "projectId": 4001, "quota": "1G"}}}'
rejected 'a plan whose path disagrees with its name is rejected' \
    '{"apps": {"alpha": {"basePath": "/apps/beta", "loopbackPort": 21234, "projectId": 4001, "quota": "1G"}}}'
rejected 'a loopback port outside the tenant range is rejected' \
    '{"apps": {"alpha": {"basePath": "/apps/alpha", "loopbackPort": 2283, "projectId": 4001, "quota": "1G"}}}'
rejected 'a non-numeric loopback port is rejected' \
    '{"apps": {"alpha": {"basePath": "/apps/alpha", "loopbackPort": "21234", "projectId": 4001, "quota": "1G"}}}'
rejected 'a path traversal in the app name is rejected' \
    '{"apps": {"../etc": {"basePath": "/apps/../etc", "loopbackPort": 21234, "projectId": 4001, "quota": "1G"}}}'
rejected 'an app entry that is not an object is rejected' \
    '{"apps": {"alpha": "x"}}'

reset_case
printf 'not json\n' >"$plan"
if ! run; then ok 'invalid JSON is rejected'; else bad 'invalid JSON is rejected'; fi
# A rejected plan must still leave the core applications reachable, and must
# change no app route.
if grep -qE -- '(--set-path| off)' "$log"; then
    bad 'a rejected plan changes no app route' "$(cat "$log")"
else
    ok 'a rejected plan changes no app route'
fi
if [[ $(grep -c -- '--bg --https=' "$log") == 3 ]]; then
    ok 'a rejected plan still declares the core routes'
else
    bad 'a rejected plan still declares the core routes' "$(cat "$log")"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
