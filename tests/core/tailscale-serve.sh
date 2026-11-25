#!/usr/bin/env bash
# Offline checks for the Serve route generator (SDLC #726, T7 of #701).
#
# Serve is the tenant's only ingress. The core applications own their root
# paths, the two agent gateways own `/apps/agent-local` and `/apps/agent-general`
# on 443, and each `homelab-apps` app gets one `/apps/<name>` path on 443 pointing
# at the loopback port the renderer assigned. This proves the declaration half
# without a tailnet: the fixed core routes, the two core paths, the wallpaper
# library as static files under `/wallpapers`, one route per app, pruning of an
# app that left the plan without touching the static route or a core path, a
# refused claim on a core path, and a refusal to build a route from a plan that
# names a foreign path or port. The Service VIP endpoints are counted the same
# way: each is a core declaration, and the fake logs one and records the other.
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
# the file rewritten without that handler. A target that is an absolute path is
# Serve's static-file form and lands in `Path`, exactly as the real one does, and
# a directory mount gains the trailing slash Serve adds itself. A `--service`
# declaration belongs to the Service VIP and not to the host, so it lands in
# `Services` keyed `<service>:<port>`: recorded as a host handler it would take
# that port's root path, which on 443 is Immich's.
cat >"$work/tailscale" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_LOG"
case $1 in
    serve)
        shift
        case ${1:-} in
            status)
                [[ ${FAKE_STATUS_FAIL:-} == 1 ]] && exit 1
                cat "$FAKE_STATUS" ;;
            reset)
                printf '{}\n' >"$FAKE_STATUS" ;;
            *)
                # A declaration ends in a target; `off` removes that path. A
                # `--tcp` forward is not a Web handler: Serve records it under
                # TCP, keyed by the port it listens on.
                path=
                target=
                kind=Proxy
                port=443
                tcp=
                service=
                for arg in "$@"; do
                    case $arg in
                        --set-path=*) path=${arg#--set-path=} ;;
                        --https=*) port=${arg#--https=} ;;
                        --tcp=*) tcp=${arg#--tcp=} ;;
                        --service=*) service=${arg#--service=} ;;
                        http://*) target=$arg ;;
                        tcp://*) target=$arg ;;
                        /*) target=$arg; kind=Path ;;
                        off) target=off ;;
                    esac
                done
                if [[ -n $service ]]; then
                    [[ ${FAKE_FAIL_SERVICE:-} == 1 ]] && exit 1
                    if [[ -z $target || $target == off ]]; then
                        echo "fake tailscale: unparsed service declaration: $*" >&2
                        exit 2
                    fi
                    jq --arg key "$service:${tcp:-$port}" --arg target "$target" '
                        .Services //= {} | .Services[$key] = {"Proxy": $target}' \
                        "$FAKE_STATUS" >"$FAKE_STATUS.next"
                    mv "$FAKE_STATUS.next" "$FAKE_STATUS"
                    exit 0
                fi
                if [[ -n $tcp ]]; then
                    [[ ${FAKE_FAIL_TCP:-} == 1 ]] && exit 1
                    if [[ $target != tcp://* ]]; then
                        echo "fake tailscale: unparsed tcp forward: $*" >&2
                        exit 2
                    fi
                    jq --arg key "$tcp" --arg target "${target#tcp://}" '
                        .TCP //= {} | .TCP[$key] = {"TCPForward": $target}' \
                        "$FAKE_STATUS" >"$FAKE_STATUS.next"
                    mv "$FAKE_STATUS.next" "$FAKE_STATUS"
                    exit 0
                fi
                path=${path:-/}
                if [[ -z $target ]]; then
                    echo "fake tailscale: unparsed serve invocation: $*" >&2
                    exit 2
                fi
                if [[ $kind == Path ]]; then
                    [[ ${FAKE_FAIL_PATH:-} == 1 ]] && exit 1
                    # Serve stats the target and appends the slash itself.
                    [[ -e $target ]] || { echo "fake tailscale: invalid path: $target" >&2; exit 1; }
                    [[ -d $target ]] && path=${path%/}/
                fi
                jq --arg key "host:$port" --arg path "$path" --arg target "$target" --arg kind "$kind" '
                    .Web //= {} | .Web[$key] //= {"Handlers": {}}
                    | if $target == "off"
                      then del(.Web[$key].Handlers[$path])
                      else .Web[$key].Handlers[$path] = {($kind): $target}
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
# The wallpaper library is a dataset mount on the host; the case points the
# script at a scratch directory so the declaration is exercised offline.
wallpapers=$work/wallpapers
mkdir -p "$wallpapers"

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
        APPS_SCHEMA=$root/scripts/apps-schema.py WALLPAPERS_DIR=${WALLPAPERS_DIR:-$wallpapers} \
        bash "$script" >"$work/stdout" 2>"$work/stderr"
}

core_status() {
    cat >"$status" <<'EOF'
{
  "TCP": {"443": {"HTTPS": true}, "8443": {"HTTPS": true}, "10000": {"HTTPS": true},
          "8444": {"HTTPS": true}, "8445": {"HTTPS": true},
          "8446": {"HTTPS": true}, "8447": {"HTTPS": true}},
  "Web": {
    "host:443": {"Handlers": {
      "/": {"Proxy": "http://127.0.0.1:2283"},
      "/apps/agent-local": {"Proxy": "http://127.0.0.1:18001"},
      "/apps/agent-general": {"Proxy": "http://127.0.0.1:18002"},
      "/apps/agent-ui-personal": {"Proxy": "http://127.0.0.1:18006"},
      "/apps/agent-ui-general": {"Proxy": "http://127.0.0.1:18007"}}},
    "host:8443": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:8083"}}},
    "host:10000": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:8384"}}},
    "host:8444": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:18006"}}},
    "host:8445": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:18007"}}},
    "host:8446": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:2283"}}},
    "host:8447": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:8083"}}}
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

static_served() { # port, handler path -> the directory or file it publishes
    jq -r --arg port "$1" --arg path "$2" '.Web[$port].Handlers[$path].Path // empty' "$status" 2>/dev/null
}

service_served() { # <service>:<port> -> the target it advertises
    jq -r --arg key "$1" '.Services[$key].Proxy // empty' "$status" 2>/dev/null
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
# The public edge (design #725) is the reason these two exist: it may not use
# 443, so Immich and OPDShelf are repeated on ports a port-scoped tailnet rule
# can name without also publishing the agent gateways and `/wallpapers`.
serves host:8446 / http://127.0.0.1:2283 '8446 fronts Immich for the public edge'
serves host:8447 / http://127.0.0.1:8083 '8447 fronts OPDShelf for the public edge'
serves host:8448 / http://127.0.0.1:4533 '8448 fronts Navidrome'

# --- the deploy receiver's TCP forward is a core route -----------------------
#
# The CI notify job and the hourly poll are the only callers, and both must reach
# the receiver on a host whose tenant plan is broken: the forward is declared with
# the core routes, before anything that reads the plan, exactly once, and the
# `/apps/` prune never touches it.

tcp_forward() { jq -r '.TCP["8484"].TCPForward // empty' "$status" 2>/dev/null; }
eq "$(tcp_forward)" 127.0.0.1:8484 'the receiver is forwarded on tcp/8484 to its loopback port'
eq "$(grep -cF -- 'serve --bg --tcp=8484 tcp://127.0.0.1:8484' "$log")" 1 \
    'the forward is declared exactly once'
forward_line=$(grep -nF -- '--tcp=8484' "$log" | cut -d: -f1 || true)
wallpapers_line=$(grep -nF -- '--set-path=/wallpapers' "$log" | cut -d: -f1 || true)
if [[ -n $forward_line && -n $wallpapers_line ]] && ((forward_line < wallpapers_line)); then
    ok 'the forward is declared with the core routes, before the plan-dependent routes'
else
    bad 'the forward is declared with the core routes, before the plan-dependent routes' \
        "forward at '$forward_line', wallpapers at '$wallpapers_line'"
fi

# --- the agent UI is a Service VIP, advertised once --------------------------
#
# The Service's address belongs to the tailnet, and it answers only when a tagged
# node advertises the endpoint. The fake keys a `--service` declaration under
# `Services`, so the argv log carries the assertion: the flag has to be there, or
# the declaration lands on the host's own 443 instead of the Service's. It is the
# last core declaration, so a Service the tailnet does not have yet costs the UI
# and not the applications.
service_line=$(grep -nF -- '--service=svc:agent-ui' "$log" | cut -d: -f1 || true)
gateway_line=$(grep -nF -- '--set-path=/apps/agent-local ' "$log" | cut -d: -f1 || true)
eq "$(grep -cF -- 'serve --bg --service=svc:agent-ui --tcp=443 tcp://127.0.0.1:9443' "$log")" 1 \
    'the agent UI Service endpoint is declared exactly once'
if [[ -n $service_line && -n $wallpapers_line && -n $gateway_line ]] &&
    ((service_line > wallpapers_line && service_line > gateway_line)); then
    ok 'the Service endpoint is declared after every other core route'
else
    bad 'the Service endpoint is declared after every other core route' \
        "service at '$service_line', wallpapers at '$wallpapers_line', agent-local at '$gateway_line'"
fi

# --- OPDShelf is the first application off the per-port scheme ---------------
#
# A Service is the application's own name rather than a port on the host's, and
# Tailscale terminates TLS for it and issues the certificate for that name, so
# this is an `--https` declaration and not a `--tcp` forward like the UI's. It is
# a Service, though, so it must never land in `Web`: `host:443` already fronts
# Immich, and a service declaration recorded as a host handler would replace it.
# The 8443 host route stays declared above, as the rollback.
opds_line=$(grep -nF -- '--service=svc:opds' "$log" | cut -d: -f1 || true)
status_line=$(grep -nF -- 'serve status --json' "$log" | cut -d: -f1 || true)
eq "$(grep -cF -- 'serve --bg --service=svc:opds --https=443 http://127.0.0.1:8083' "$log")" 1 \
    'the OPDShelf Service endpoint is declared exactly once, over https/443'
eq "$(service_served svc:opds:443)" 'http://127.0.0.1:8083' \
    'svc:opds advertises OPDShelf on its own port, not a host port'
if [[ -n $opds_line && -n $service_line ]] && ((opds_line > service_line)); then
    ok 'the OPDShelf Service is declared after the agent UI Service'
else
    bad 'the OPDShelf Service is declared after the agent UI Service' \
        "opds at '$opds_line', agent-ui at '$service_line'"
fi
if [[ -n $opds_line && -n $status_line ]] && ((opds_line < status_line)); then
    ok 'the OPDShelf Service is declared before the Serve status read'
else
    bad 'the OPDShelf Service is declared before the Serve status read' \
        "opds at '$opds_line', status at '$status_line'"
fi
eq "$(jq -r '.Web["host:443"].Handlers["/"].Proxy // empty' "$status")" 'http://127.0.0.1:2283' \
    'host:443 still fronts Immich after a Service declaration'
if jq -e '[.Web["host:443"].Handlers[] | .Proxy // empty | select(. == "http://127.0.0.1:8083")] | length == 0' \
    "$status" >/dev/null; then
    ok 'no OPDShelf handler is left on the host 443'
else
    bad 'no OPDShelf handler is left on the host 443' "$(served host:443)"
fi
eq "$(jq -r '.TCP["443"].HTTPS // empty' "$status")" 'true' \
    'a Service declaration leaves the host 443 route alone'

# --- the rest of the core apps get a Service each, the same shape ------------
#
# Immich, Navidrome and the two agent web UIs follow the catalogue off the
# per-port scheme: each declaration is `--https` against a Service of its own, so
# Tailscale terminates TLS for that name, and each is additive -- the host routes
# (443, 8448, 8444, 8445) stay declared above as the rollback. Syncthing's GUI is
# not among them: its Host guard rejects the Serve route it already has.
eq "$(grep -cF -- 'serve --bg --service=svc:immich --https=443 http://127.0.0.1:2283' "$log")" 1 \
    'the Immich Service endpoint is declared exactly once, over https/443'
eq "$(service_served svc:immich:443)" 'http://127.0.0.1:2283' \
    'svc:immich advertises Immich on its own port, not a host port'
eq "$(grep -cF -- 'serve --bg --service=svc:navidrome --https=443 http://127.0.0.1:4533' "$log")" 1 \
    'the Navidrome Service endpoint is declared exactly once, over https/443'
eq "$(service_served svc:navidrome:443)" 'http://127.0.0.1:4533' \
    'svc:navidrome advertises Navidrome on its own port, not a host port'
eq "$(grep -cF -- 'serve --bg --service=svc:assistant --https=443 http://127.0.0.1:18006' "$log")" 1 \
    'the personal web UI Service endpoint is declared exactly once, over https/443'
eq "$(service_served svc:assistant:443)" 'http://127.0.0.1:18006' \
    'svc:assistant advertises the personal UI on its own port, not a host port'
eq "$(grep -cF -- 'serve --bg --service=svc:agent --https=443 http://127.0.0.1:18007' "$log")" 1 \
    'the general web UI Service endpoint is declared exactly once, over https/443'
eq "$(service_served svc:agent:443)" 'http://127.0.0.1:18007' \
    'svc:agent advertises the general UI on its own port, not a host port'
app_services='["svc:immich", "svc:navidrome", "svc:assistant", "svc:agent"]'
if jq -e --argjson names "$app_services" \
    '[.Services // {} | keys[] | select(. | endswith(":443")) | rtrimstr(":443")] as $served
     | ($names - $served) | length == 0' "$status" >/dev/null 2>&1; then
    ok 'every core app Service is recorded under Services, not on a host port'
else
    bad 'every core app Service is recorded under Services, not on a host port' \
        "$(jq -r '.Services // {} | keys | join(" ")' "$status" 2>/dev/null)"
fi
if [[ "$(jq -r '.Web | keys | join(" ")' "$status" 2>/dev/null)" == \
    'host:10000 host:443 host:8443 host:8444 host:8445 host:8446 host:8447 host:8448' ]]; then
    ok 'no app Service declaration opens a host port'
else
    bad 'no app Service declaration opens a host port' \
        "$(jq -r '.Web | keys | join(" ")' "$status" 2>/dev/null)"
fi
serves host:443 / http://127.0.0.1:2283 'host:443 still fronts Immich as the rollback'
serves host:8448 / http://127.0.0.1:4533 'host:8448 still fronts Navidrome as the rollback'
serves host:8444 / http://127.0.0.1:18006 'host:8444 still fronts the personal UI as the rollback'
serves host:8445 / http://127.0.0.1:18007 'host:8445 still fronts the general UI as the rollback'
app_service_lines=$(grep -nE -- '--service=svc:(immich|navidrome|assistant|agent) ' "$log" | cut -d: -f1 || true)
if [[ -n $app_service_lines ]] && ((opds_line < $(head -n1 <<<"$app_service_lines") &&
    $(tail -n1 <<<"$app_service_lines") < status_line)); then
    ok 'the app Services are declared after the catalogue and before the Serve status read'
else
    bad 'the app Services are declared after the catalogue and before the Serve status read' \
        "apps at '$(tr '\n' ' ' <<<"$app_service_lines")', opds at '$opds_line', status at '$status_line'"
fi

# --- the two agent gateways own a fixed path each on 443 ----------------------

serves host:443 /apps/agent-local http://127.0.0.1:18001 'the personal gateway gets /apps/agent-local'
serves host:443 /apps/agent-general http://127.0.0.1:18002 'the general gateway gets /apps/agent-general'
serves host:8444 / http://127.0.0.1:18006 'the personal UI gets its own HTTPS port'
serves host:8445 / http://127.0.0.1:18007 'the general UI gets its own HTTPS port'
agent_declarations=$(grep -cE -- '--set-path=/apps/agent-(local|general) ' "$log")
eq "$agent_declarations" 2 'each agent gateway is declared exactly once'
if grep -qF -- 'http://127.0.0.1:18003' "$log"; then
    bad 'the hosted proxy is never a Serve route'
else
    ok 'the hosted proxy is never a Serve route'
fi

# --- the wallpaper library is static files, not a listener --------------------

reset_case
run
eq "$?" 0 'a host with no tenant plan still declares the wallpaper route'
eq "$(static_served host:443 /wallpapers/)" "$wallpapers" \
    'the wallpaper library is published from its directory, under /wallpapers/'
eq "$(jq -r '.Web["host:443"].Handlers["/wallpapers/"].Proxy // empty' "$status")" \
    '' 'the wallpaper handler carries no loopback target'
if grep -qF -- "--bg --https=443 --set-path=/wallpapers $wallpapers" "$log"; then
    ok 'the declaration is 443, /wallpapers and an absolute path'
else
    bad 'the declaration is 443, /wallpapers and an absolute path' "$(cat "$log")"
fi

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
serves host:443 /apps/agent-local http://127.0.0.1:18001 'pruning leaves the personal gateway path alone'
eq "$(static_served host:443 /wallpapers/)" "$wallpapers" 'pruning leaves the wallpaper route alone'
if grep -E -- ' off$' "$log" | grep -qv -- '--set-path=/apps/'; then
    bad 'pruning only removes /apps/ handlers' "$(grep -E -- ' off$' "$log")"
else
    ok 'pruning only removes /apps/ handlers'
fi

# --- a missing plan prunes every app route -----------------------------------

reset_case
jq '.Web["host:443"].Handlers["/apps/alpha"] = {"Proxy": "http://127.0.0.1:21234"}' "$status" >"$work/s" && mv "$work/s" "$status"
run
eq "$?" 0 'no plan is not an error'
if served host:443 | grep -E '^/apps/' | grep -qvE '^/apps/agent-(local|general) '; then
    bad 'no plan removes every app route' "$(served host:443)"
else
    ok 'no plan removes every app route'
fi
serves host:443 /apps/agent-local http://127.0.0.1:18001 'no plan keeps the core agent path'
serves host:443 / http://127.0.0.1:2283 'no plan keeps the core root route'

# --- Serve status is a nicety, not a precondition for core ingress ----------

reset_case
plan_with "$(jq -cn --argjson a "$(app_entry alpha 21234 4001 1G internet)" '{alpha: $a}')" >"$plan"
if FAKE_STATUS_FAIL=1 run; then ok 'an unreadable status still applies the plan'; else bad 'an unreadable status still applies the plan' "$(cat "$work/stderr")"; fi
if [[ $(grep -c -- '--bg --https=' "$log") == 12 ]]; then
    ok 'the core routes, the two core paths, the wallpaper route and the app route are declared without status'
else
    bad 'the core routes, the two core paths, the wallpaper route and the app route are declared without status' "$(cat "$log")"
fi

# --- an unpublishable wallpaper route fails the run --------------------------

reset_case
if FAKE_FAIL_PATH=1 run; then
    bad 'Serve refusing the wallpaper directory fails the run'
else
    ok 'Serve refusing the wallpaper directory fails the run'
fi
if grep -qF -- 'could not serve' "$work/stderr"; then
    ok 'the failure names the directory it could not publish'
else
    bad 'the failure names the directory it could not publish' "$(cat "$work/stderr")"
fi

reset_case
if WALLPAPERS_DIR=$work/absent run; then
    bad 'a missing wallpaper directory fails the run'
else
    ok 'a missing wallpaper directory fails the run'
fi
if [[ $(grep -c -- '--bg --https=' "$log") == 10 ]]; then
    ok 'a missing wallpaper directory still leaves the core routes declared'
else
    bad 'a missing wallpaper directory still leaves the core routes declared' "$(cat "$log")"
fi

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

# A tenant app that claims a core path would be declared by two loops; the whole
# plan is refused rather than letting the last writer win.
reset_case
plan_with "$(jq -cn --argjson a "$(app_entry agent-local 21234 4001 1G internet)" \
  --argjson b "$(app_entry alpha 21235 4002 1G internet)" '{"agent-local": $a, alpha: $b}')" >"$plan"
if run; then
    bad 'a plan that claims a core path is rejected' "$(cat "$work/stdout")"
else
    ok 'a plan that claims a core path is rejected'
fi
if grep -qF -- 'which a core route owns' "$work/stderr"; then
    ok 'the rejection names the core path'
else
    bad 'the rejection names the core path' "$(cat "$work/stderr")"
fi
if served host:443 | grep -qx '/apps/alpha http://127.0.0.1:21235'; then
    bad 'a plan that claims a core path applies none of its routes' "$(served host:443)"
else
    ok 'a plan that claims a core path applies none of its routes'
fi
serves host:443 /apps/agent-local http://127.0.0.1:18001 'the refused plan leaves the core path alone'

reset_case
printf 'not json\n' >"$plan"
if ! run; then ok 'invalid JSON is rejected'; else bad 'invalid JSON is rejected'; fi
# A rejected plan must still leave the core applications and the wallpapers
# route reachable, and must change no app route.
tenant_traffic=$(grep -E -- '(--set-path=/apps/| off)' "$log" | grep -vE -- '--set-path=/apps/agent-(local|general) ')
if [[ -n $tenant_traffic ]]; then
    bad 'a rejected plan changes no app route' "$tenant_traffic"
else
    ok 'a rejected plan changes no app route'
fi
if [[ $(grep -c -- '--bg --https=' "$log") == 11 ]]; then
    ok 'a rejected plan still declares the core routes, the two core paths and the wallpapers route'
else
    bad 'a rejected plan still declares the core routes and the wallpapers route' "$(cat "$log")"
fi
if grep -qF -- '--tcp=8484 tcp://127.0.0.1:8484' "$log"; then
    ok 'a rejected plan still declares the receiver forward'
else
    bad 'a rejected plan still declares the receiver forward' "$(cat "$log")"
fi
eq "$(tcp_forward)" 127.0.0.1:8484 'a rejected plan leaves the receiver forward in place'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
