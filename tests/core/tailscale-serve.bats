#!/usr/bin/env bats
# Offline checks for the Serve route generator (SDLC #726, T7 of #701). Run by
# bats, one scenario per test.
#
# Serve is the tenant's only ingress. The core applications own their root
# paths, the two agent gateways own `/apps/agent-local` and `/apps/agent-general`
# on 443, and each `homelab-apps` app gets one `/apps/<name>` path on 443 pointing
# at the loopback port the renderer assigned. This proves the declaration half
# without a tailnet: the fixed core routes, the two core paths, the wallpaper
# library as static files under `/wallpapers`, one route per app, pruning of an
# app that left the plan without touching the static route or a core path, the
# retirement of a host port the script no longer declares, the clearing of a
# Service no declaration makes, a refused claim on a core path, and a refusal to
# build a route from a plan that names a foreign path
# or port. The Service VIP endpoints are counted the same way: each is a core
# declaration, and the fake logs one and records the other.
load ../helpers

script=scripts/tailscale-serve.sh
digest=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

# The fake and the Serve state are per test: each @test runs in its own process,
# so nothing may be left in a global a sibling test would race.
setup() {
    tmp=$BATS_TEST_TMPDIR
    status=$tmp/status.json
    plan=$tmp/plan.json
    log=$tmp/log
    # The wallpaper library is a dataset mount on the host; the case points the
    # script at a scratch directory so the declaration is exercised offline.
    wallpapers=$tmp/wallpapers
    mkdir -p "$wallpapers"

    wallpapers_dir=
    status_fail=
    off_fail=
    clear_fail=
    path_fail=
    service_name_fail=

    # The fake tailscale records argv and answers `serve status --json` from a file
    # the case sets up. `off` is a removal, so the status it prints afterwards is the
    # file rewritten without that handler -- or, with no `--set-path`, without that
    # port at all, because `serve --https=<port> off` retires the port and not one
    # path on it. A target that is an absolute path is Serve's static-file form and
    # lands in `Path`, exactly as the real one does, and a directory mount gains the
    # trailing slash Serve adds itself. A `--service`
    # declaration belongs to the Service VIP and not to the host, so it lands in
    # `Services` keyed `<service>:<port>`: recorded as a host handler it would take
    # that port's root path, which on 443 is Immich's. `serve clear <service>` is the
    # other half -- it retires the whole Service, so the fake drops every entry that
    # holds that name, whether the key carries the handler's port or not, which is the
    # one thing an `off` cannot do.
    cat >"$tmp/tailscale" <<'SH'
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
            clear)
                # `serve clear <service>` removes all config for one Service. The
                # key may be the bare name or the name with its port, so both go.
                [[ ${FAKE_FAIL_CLEAR:-} == 1 ]] && exit 1
                service=${2:-}
                if [[ -z $service ]]; then
                    echo "fake tailscale: clear without a service: $*" >&2
                    exit 2
                fi
                jq --arg name "$service" '
                    .Services //= {}
                    | .Services |= with_entries(select((.key | sub(":[0-9]+$"; "")) != $name))' \
                    "$FAKE_STATUS" >"$FAKE_STATUS.next"
                mv "$FAKE_STATUS.next" "$FAKE_STATUS" ;;
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
                    [[ ${FAKE_FAIL_SERVICE:-} == 1 ||
                        ${FAKE_FAIL_SERVICE_NAME:-} == "$service" ]] && exit 1
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
                if [[ $target == off && -z $path && -z $tcp ]]; then
                    # `serve --https=<port> off` retires the port itself, not one
                    # handler on it: tailscaled drops the Web entry and the port
                    # stops answering. A `--set-path=` off is the branch below.
                    [[ ${FAKE_FAIL_OFF:-} == 1 ]] && exit 1
                    jq --arg key "host:$port" 'del(.Web[$key])' "$FAKE_STATUS" >"$FAKE_STATUS.next"
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
SH
    chmod +x "$tmp/tailscale"
}

# drive: runs the script against the fake, leaving its status in `rc`, its stdout
# in `out` and its stderr in $tmp/stderr. The failure switches are read from the
# case in setup().
drive() {
    local -a vars=(
        FAKE_LOG="$log" FAKE_STATUS="$status" TAILSCALE_BIN="$tmp/tailscale"
        APPS_PLAN="$plan" APPS_SCHEMA="$repo_root/scripts/apps-schema.py"
        WALLPAPERS_DIR="${wallpapers_dir:-$wallpapers}"
    )
    if [[ -n $status_fail ]]; then
        vars+=(FAKE_STATUS_FAIL=1)
    fi
    if [[ -n $off_fail ]]; then
        vars+=(FAKE_FAIL_OFF=1)
    fi
    if [[ -n $clear_fail ]]; then
        vars+=(FAKE_FAIL_CLEAR=1)
    fi
    if [[ -n $path_fail ]]; then
        vars+=(FAKE_FAIL_PATH=1)
    fi
    if [[ -n $service_name_fail ]]; then
        vars+=(FAKE_FAIL_SERVICE_NAME="$service_name_fail")
    fi
    rc=0
    out=$(env "${vars[@]}" bash "$script" 2>"$tmp/stderr") || rc=$?
}

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

core_status() {
    cat >"$status" <<'EOF'
{
  "TCP": {"443": {"HTTPS": true}, "8443": {"HTTPS": true}, "10000": {"HTTPS": true},
          "8444": {"HTTPS": true}, "8445": {"HTTPS": true}},
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
    "host:8445": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:18007"}}}
  }
}
EOF
}

reset_case() {
    : >"$log"
    rm -f "$plan"
    core_status
}

# The number of host ports the script declares, read out of it rather than repeated
# here: three assertions below count the routes a run logs, and every one of them
# moves when an entry leaves core_routes.
core_route_count() {
    sed -n '/^declare -A core_routes=(/,/^)/p' "$script" | grep -cE '^  \[[0-9]+\]='
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

tcp_forward() { jq -r '.TCP["8484"].TCPForward // empty' "$status" 2>/dev/null; }

serves() { # port path target: a handler the Serve state carries
    local got
    got=$(served "$1")
    if ! grep -qx -- "$2 $3" <<<"$got"; then
        printf 'want %s %s in:\n%s\n' "$2" "$3" "$got" >&2
        return 1
    fi
}

# --- core routes always exist -------------------------------------------------

# The run a host with no tenant plan makes, and the one every core case below
# shares: the plan is absent, so only the core ingress can be declared.
core_run() { reset_case; drive; }

@test "a host with no tenant plan still declares the core routes" {
    core_run
    assert_equal "$rc" 0
}

@test "443 still fronts Immich" {
    core_run
    serves host:443 / http://127.0.0.1:2283
}

@test "8443 still fronts OPDShelf" {
    core_run
    serves host:8443 / http://127.0.0.1:8083
}

@test "10000 still fronts Syncthing" {
    core_run
    serves host:10000 / http://127.0.0.1:8384
}

@test "8448 fronts Navidrome" {
    core_run
    serves host:8448 / http://127.0.0.1:4533
}

# --- the deploy receiver's TCP forward is a core route -----------------------
#
# The CI notify job and the hourly poll are the only callers, and both must reach
# the receiver on a host whose tenant plan is broken: the forward is declared with
# the core routes, before anything that reads the plan, exactly once, and the
# `/apps/` prune never touches it.

@test "the receiver is forwarded on tcp/8484 to its loopback port" {
    core_run
    assert_equal "$(tcp_forward)" 127.0.0.1:8484
}

@test "the forward is declared exactly once" {
    core_run
    assert_equal \
        "$(grep -cF -- 'serve --bg --tcp=8484 tcp://127.0.0.1:8484' "$log" || true)" 1
}

@test "the forward is declared with the core routes, before the plan-dependent routes" {
    core_run
    forward_line=$(grep -nF -- '--tcp=8484' "$log" | cut -d: -f1 || true)
    wallpapers_line=$(grep -nF -- '--set-path=/wallpapers' "$log" | cut -d: -f1 || true)
    if [[ -z $forward_line || -z $wallpapers_line ]] || ((forward_line >= wallpapers_line)); then
        printf "forward at '%s', wallpapers at '%s'\n" "$forward_line" "$wallpapers_line" >&2
        return 1
    fi
}

# --- OPDShelf is the first application off the per-port scheme ---------------
#
# A Service is the application's own name rather than a port on the host's, and
# Tailscale terminates TLS for it and issues the certificate for that name, so
# this is an `--https` declaration to the Service and not a handler on the host.
# It is a Service, though, so it must never land in `Web`: `host:443` already
# fronts Immich, and a service declaration recorded as a host handler would
# replace it. The 8443 host route stays declared above, as the rollback.

@test "the OPDShelf Service endpoint is declared exactly once, over https/443" {
    core_run
    assert_equal \
        "$(grep -cF -- 'serve --bg --service=svc:opds --https=443 http://127.0.0.1:8083' "$log" || true)" 1
}

@test "svc:opds advertises OPDShelf on its own port, not a host port" {
    core_run
    assert_equal "$(service_served svc:opds:443)" 'http://127.0.0.1:8083'
}

@test "the first Service is declared after every host route" {
    core_run
    opds_line=$(grep -nF -- '--service=svc:opds' "$log" | cut -d: -f1 || true)
    wallpapers_line=$(grep -nF -- '--set-path=/wallpapers' "$log" | cut -d: -f1 || true)
    if [[ -z $opds_line || -z $wallpapers_line ]] || ((opds_line <= wallpapers_line)); then
        printf "opds at '%s', wallpapers at '%s'\n" "$opds_line" "$wallpapers_line" >&2
        return 1
    fi
}

@test "the OPDShelf Service is declared before the Serve status read" {
    core_run
    opds_line=$(grep -nF -- '--service=svc:opds' "$log" | cut -d: -f1 || true)
    status_line=$(grep -nF -- 'serve status --json' "$log" | cut -d: -f1 || true)
    if [[ -z $opds_line || -z $status_line ]] || ((opds_line >= status_line)); then
        printf "opds at '%s', status at '%s'\n" "$opds_line" "$status_line" >&2
        return 1
    fi
}

@test "host:443 still fronts Immich after a Service declaration" {
    core_run
    assert_equal "$(jq -r '.Web["host:443"].Handlers["/"].Proxy // empty' "$status")" 'http://127.0.0.1:2283'
}

@test "no OPDShelf handler is left on the host 443" {
    core_run
    if ! jq -e '[.Web["host:443"].Handlers[] | .Proxy // empty | select(. == "http://127.0.0.1:8083")] | length == 0' \
        "$status" >/dev/null; then
        served host:443 >&2
        return 1
    fi
}

@test "a Service declaration leaves the host 443 route alone" {
    core_run
    assert_equal "$(jq -r '.TCP["443"].HTTPS // empty' "$status")" 'true'
}

# --- the rest of the core apps get a Service each, the same shape ------------
#
# Immich, Navidrome, the two agent web UIs and the Syncthing GUI follow the
# catalogue off the per-port scheme: each declaration is `--https` against a
# Service of its own, so Tailscale terminates TLS for that name, and each is
# additive -- the host routes (443, 8448, 8444, 8445, 10000) stay declared above
# as the rollback. The GUI is only here because its host check is off: Serve
# forwards the client's Host unchanged (docs/manual-steps.md).

@test "the Immich Service endpoint is declared exactly once, over https/443" {
    core_run
    assert_equal \
        "$(grep -cF -- 'serve --bg --service=svc:immich --https=443 http://127.0.0.1:2283' "$log" || true)" 1
}

@test "svc:immich advertises Immich on its own port, not a host port" {
    core_run
    assert_equal "$(service_served svc:immich:443)" 'http://127.0.0.1:2283'
}

@test "the Navidrome Service endpoint is declared exactly once, over https/443" {
    core_run
    assert_equal \
        "$(grep -cF -- 'serve --bg --service=svc:navidrome --https=443 http://127.0.0.1:4533' "$log" || true)" 1
}

@test "svc:navidrome advertises Navidrome on its own port, not a host port" {
    core_run
    assert_equal "$(service_served svc:navidrome:443)" 'http://127.0.0.1:4533'
}

@test "the personal web UI Service endpoint is declared exactly once, over https/443" {
    core_run
    assert_equal \
        "$(grep -cF -- 'serve --bg --service=svc:assistant --https=443 http://127.0.0.1:18006' "$log" || true)" 1
}

@test "svc:assistant advertises the personal UI on its own port, not a host port" {
    core_run
    assert_equal "$(service_served svc:assistant:443)" 'http://127.0.0.1:18006'
}

@test "the general web UI Service endpoint is declared exactly once, over https/443" {
    core_run
    assert_equal \
        "$(grep -cF -- 'serve --bg --service=svc:agent --https=443 http://127.0.0.1:18007' "$log" || true)" 1
}

@test "svc:agent advertises the general UI on its own port, not a host port" {
    core_run
    assert_equal "$(service_served svc:agent:443)" 'http://127.0.0.1:18007'
}

@test "the Syncthing GUI Service endpoint is declared exactly once, over https/443" {
    core_run
    assert_equal \
        "$(grep -cF -- 'serve --bg --service=svc:sync --https=443 http://127.0.0.1:8384' "$log" || true)" 1
}

@test "svc:sync advertises the Syncthing GUI on its own port, not a host port" {
    core_run
    assert_equal "$(service_served svc:sync:443)" 'http://127.0.0.1:8384'
}

# The terminal is the last Service declared: `fail()` aborts the script, so a
# terminal route that cannot be advertised must not cost any route after it.
@test "the zellij web Service endpoint is declared exactly once, over https/443" {
    core_run
    assert_equal \
        "$(grep -cF -- 'serve --bg --service=svc:terminal --https=443 http://127.0.0.1:8082' "$log" || true)" 1
}

@test "svc:terminal advertises zellij web on its own port, not a host port" {
    core_run
    assert_equal "$(service_served svc:terminal:443)" 'http://127.0.0.1:8082'
}

@test "svc:terminal is the last route declared, so a refused terminal costs no other route" {
    core_run
    terminal_line=$(grep -nF -- '--service=svc:terminal' "$log" | cut -d: -f1 | head -n1 || true)
    last_other_route=$(grep -nE -- 'serve --bg' "$log" | grep -vF -- 'svc:terminal' |
        cut -d: -f1 | sort -n | tail -n1 || true)
    if [[ -z $terminal_line || -z $last_other_route ]] || ((last_other_route >= terminal_line)); then
        printf 'terminal at %q, last other route at %q\\n' "$terminal_line" "$last_other_route" >&2
        return 1
    fi
}

@test "every core Service is recorded under Services, not on a host port" {
    core_run
    app_services='["svc:immich", "svc:navidrome", "svc:assistant", "svc:agent", "svc:sync", "svc:terminal"]'
    if ! jq -e --argjson names "$app_services" \
        '[.Services // {} | keys[] | select(. | endswith(":443")) | rtrimstr(":443")] as $served
         | ($names - $served) | length == 0' "$status" >/dev/null 2>&1; then
        jq -r '.Services // {} | keys | join(" ")' "$status" >&2 || true
        return 1
    fi
}

@test "no app Service declaration opens a host port" {
    core_run
    assert_equal "$(jq -r '.Web | keys | join(" ")' "$status" 2>/dev/null)" \
        'host:10000 host:443 host:8443 host:8444 host:8445 host:8448'
}

@test "host:443 still fronts Immich as the rollback" {
    core_run
    serves host:443 / http://127.0.0.1:2283
}

@test "host:8448 still fronts Navidrome as the rollback" {
    core_run
    serves host:8448 / http://127.0.0.1:4533
}

@test "host:8444 still fronts the personal UI as the rollback" {
    core_run
    serves host:8444 / http://127.0.0.1:18006
}

@test "host:8445 still fronts the general UI as the rollback" {
    core_run
    serves host:8445 / http://127.0.0.1:18007
}

@test "host:10000 still fronts the Syncthing GUI as the rollback" {
    core_run
    serves host:10000 / http://127.0.0.1:8384
}

@test "the app Services are declared after the catalogue and before the Serve status read" {
    core_run
    app_service_lines=$(grep -nE -- '--service=svc:(immich|navidrome|assistant|agent|sync) ' "$log" | cut -d: -f1 || true)
    opds_line=$(grep -nF -- '--service=svc:opds' "$log" | cut -d: -f1 || true)
    status_line=$(grep -nF -- 'serve status --json' "$log" | cut -d: -f1 || true)
    if [[ -z $app_service_lines || -z $opds_line || -z $status_line ]] ||
        ((opds_line >= $(head -n1 <<<"$app_service_lines") ||
            $(tail -n1 <<<"$app_service_lines") >= status_line)); then
        printf "apps at '%s', opds at '%s', status at '%s'\n" \
            "$(tr '\n' ' ' <<<"$app_service_lines")" "$opds_line" "$status_line" >&2
        return 1
    fi
}

# --- the two agent gateways own a fixed path each on 443 ----------------------

@test "the personal gateway gets /apps/agent-local" {
    core_run
    serves host:443 /apps/agent-local http://127.0.0.1:18001
}

@test "the general gateway gets /apps/agent-general" {
    core_run
    serves host:443 /apps/agent-general http://127.0.0.1:18002
}

@test "the personal UI gets its own HTTPS port" {
    core_run
    serves host:8444 / http://127.0.0.1:18006
}

@test "the general UI gets its own HTTPS port" {
    core_run
    serves host:8445 / http://127.0.0.1:18007
}

@test "each agent gateway is declared exactly once" {
    core_run
    assert_equal "$(grep -cE -- '--set-path=/apps/agent-(local|general) ' "$log" || true)" 2
}

@test "the hosted proxy is never a Serve route" {
    core_run
    ! grep -qF -- 'http://127.0.0.1:18003' "$log"
}

# --- the wallpaper library is static files, not a listener --------------------

@test "a host with no tenant plan still declares the wallpaper route" {
    core_run
    assert_equal "$rc" 0
}

@test "the wallpaper library is published from its directory, under /wallpapers/" {
    core_run
    assert_equal "$(static_served host:443 /wallpapers/)" "$wallpapers"
}

@test "the wallpaper handler carries no loopback target" {
    core_run
    assert_equal "$(jq -r '.Web["host:443"].Handlers["/wallpapers/"].Proxy // empty' "$status")" ''
}

@test "the declaration is 443, /wallpapers and an absolute path" {
    core_run
    if ! grep -qF -- "--bg --https=443 --set-path=/wallpapers $wallpapers" "$log"; then
        cat "$log" >&2
        return 1
    fi
}

# --- one path per app --------------------------------------------------------

# A valid plan of two apps, alpha and beta.
plan_run() {
    reset_case
    plan_with "$(jq -cn --argjson a "$(app_entry alpha 21234 4001 1G internet)" \
        --argjson b "$(app_entry beta 22999 4002 1G internet)" '{alpha: $a, beta: $b}')" >"$plan"
    drive
}

@test "a valid plan applies" {
    plan_run
    assert_equal "$rc" 0
}

@test "alpha gets its path on 443" {
    plan_run
    serves host:443 /apps/alpha http://127.0.0.1:21234
}

@test "beta gets its path on 443" {
    plan_run
    serves host:443 /apps/beta http://127.0.0.1:22999
}

@test "the declaration names the https port, path and loopback target" {
    plan_run
    if ! grep -q -- '--https=443 --set-path=/apps/alpha http://127.0.0.1:21234' "$log"; then
        cat "$log" >&2
        return 1
    fi
}

# --- stale routes are pruned -------------------------------------------------

# The Serve state of a host that carried two app routes the plan no longer names.
prune_run() {
    reset_case
    jq '.Web["host:443"].Handlers["/apps/removed"] = {"Proxy": "http://127.0.0.1:21000"}
        | .Web["host:443"].Handlers["/apps/gamma"] = {"Proxy": "http://127.0.0.1:21555"}' "$status" >"$tmp/s" && mv "$tmp/s" "$status"
    plan_with "$(jq -cn --argjson a "$(app_entry alpha 21234 4001 1G internet)" '{alpha: $a}')" >"$plan"
    drive
}

@test "a plan with a removed app applies" {
    prune_run
    assert_equal "$rc" 0
}

@test "a route for an app that left the plan is removed" {
    prune_run
    if served host:443 | grep -q '^/apps/removed '; then
        served host:443 >&2
        return 1
    fi
}

@test "a route for an app that left the plan is pruned" {
    prune_run
    if served host:443 | grep -q '^/apps/gamma '; then
        served host:443 >&2
        return 1
    fi
}

@test "pruning leaves the core root route alone" {
    prune_run
    serves host:443 / http://127.0.0.1:2283
}

@test "pruning leaves the personal gateway path alone" {
    prune_run
    serves host:443 /apps/agent-local http://127.0.0.1:18001
}

@test "pruning leaves the wallpaper route alone" {
    prune_run
    assert_equal "$(static_served host:443 /wallpapers/)" "$wallpapers"
}

@test "pruning only removes /apps/ handlers" {
    prune_run
    if grep -E -- ' off$' "$log" | grep -qv -- '--set-path=/apps/'; then
        grep -E -- ' off$' "$log" >&2
        return 1
    fi
}

# --- a host port that left core_routes is turned off -------------------------
#
# The script is declarative for the routes it declares, but tailscaled's state is
# not: a handler whose declaration is gone keeps answering until something turns
# it off. So a Web port nobody declares is retired on the next run, while every
# port still in core_routes, 443, the receiver's TCP forward and the per-app
# Services are left alone.

# A host that still answers one Web port the script no longer declares.
stale_port_run() {
    reset_case
    jq '.Web["host:9999"] = {"Handlers": {"/": {"Proxy": "http://127.0.0.1:2283"}}}' "$status" \
        >"$tmp/s" && mv "$tmp/s" "$status"
    drive
}

@test "a port the script no longer declares does not fail the run" {
    stale_port_run
    assert_equal "$rc" 0
}

@test "a stale https port is turned off exactly once" {
    stale_port_run
    assert_equal "$(grep -cF -- 'serve --https=9999 off' "$log" || true)" 1
}

@test "the stale port leaves the Serve config, so nothing answers it" {
    stale_port_run
    if ! jq -e '.Web | has("host:9999") | not' "$status" >/dev/null 2>&1; then
        jq -r '.Web | keys | join(" ")' "$status" >&2 || true
        return 1
    fi
}

# The declared ports are read out of the script rather than repeated here, so the
# assertion keeps up when an entry leaves core_routes -- which is the edit this
# reconcile exists to make safe.
declared_ports_of_script() {
    sed -n '/^declare -A core_routes=(/,/^)/p' "$script" |
        grep -oE '\[[0-9]+\]' | tr -dc '0-9\n' | paste -sd'|' -
}

@test "core_routes is readable" {
    stale_port_run
    [[ -n $(declared_ports_of_script) ]]
}

@test "a port core_routes still declares is never turned off" {
    stale_port_run
    declared_ports=$(declared_ports_of_script || true)
    if grep -qE -- "--https=($declared_ports) off$" "$log"; then
        grep -E -- ' off$' "$log" >&2
        return 1
    fi
}

@test "443 is never turned off" {
    stale_port_run
    if grep -qE -- '--https=443 off$' "$log"; then
        grep -E -- ' off$' "$log" >&2
        return 1
    fi
}

@test "the reconcile leaves the receiver forward in place" {
    stale_port_run
    assert_equal "$(tcp_forward)" 127.0.0.1:8484
}

@test "the reconcile leaves the Service endpoints in place" {
    stale_port_run
    assert_equal "$(service_served svc:opds:443)" 'http://127.0.0.1:8083'
}

@test "the reconcile turns off Web ports only" {
    stale_port_run
    if grep -E -- ' off$' "$log" | grep -qE -- '(--tcp=|--service=)'; then
        grep -E -- ' off$' "$log" >&2
        return 1
    fi
}

# The two host ports the public edge used before it proxied the Services (design
# #725) are exactly that case, and a box that still carries them must lose them:
# nothing has any reason to reach Immich or OPDShelf on the host's own address but
# the owner, who has 443 and 8443.
retired_ports_run() {
    reset_case
    jq '.Web["host:8446"] = {"Handlers": {"/": {"Proxy": "http://127.0.0.1:2283"}}}
        | .Web["host:8447"] = {"Handlers": {"/": {"Proxy": "http://127.0.0.1:8083"}}}' \
        "$status" >"$tmp/s" && mv "$tmp/s" "$status"
    drive
}

@test "the retired edge ports do not fail the run" {
    retired_ports_run
    assert_equal "$rc" 0
}

# One test per retired port, from the old suite's `for port in 8446 8447`.
check_retired_port_off_once() {
    retired_ports_run
    assert_equal "$(grep -cF -- "serve --https=$1 off" "$log" || true)" 1
}

for port in 8446 8447; do
    register "the retired edge port $port is turned off exactly once" check_retired_port_off_once "$port"
done

@test "neither retired edge port is left in the Serve config" {
    retired_ports_run
    if ! jq -e '.Web | (has("host:8446") or has("host:8447")) | not' "$status" >/dev/null 2>&1; then
        jq -r '.Web | keys | join(" ")' "$status" >&2 || true
        return 1
    fi
}

# A port Tailscale refuses to turn off is reported and stops the prunes, like a
# stale `/apps/` route that will not go: the run fails rather than leaving the
# rest of the config half-reconciled without saying so.
off_fail_run() {
    reset_case
    jq '.Web["host:9999"] = {"Handlers": {"/": {"Proxy": "http://127.0.0.1:2283"}}}' "$status" \
        >"$tmp/s" && mv "$tmp/s" "$status"
    off_fail=1
    drive
}

@test "a port Serve refuses to turn off fails the run" {
    off_fail_run
    [[ $rc -ne 0 ]]
}

@test "the failure names the port it could not retire" {
    off_fail_run
    if ! grep -qF -- 'could not turn off the stale route https/9999' "$tmp/stderr"; then
        cat "$tmp/stderr" >&2
        return 1
    fi
}

@test "a failed port removal stops the further prunes" {
    off_fail_run
    if grep -qE -- '--set-path=/apps/.* off$' "$log"; then
        grep -E -- ' off$' "$log" >&2
        return 1
    fi
}

# --- a Service no declaration makes is cleared -------------------------------
#
# The same decay in the other map, and the one the tailnet actually carried:
# `svc:agent-ui` was deleted from the tailnet (its Service and VIP are gone with
# the host Caddy), but its handler still answered
# `tcp://agent-ui.<tailnet>.ts.net:443` pointing at 127.0.0.1:9443, where nothing
# listens. A host port is retired by `off`; a whole Service is `clear`, and a
# handler no declaration makes must not survive a run.
stale_service_run() {
    reset_case
    jq '.Services["svc:agent-ui"] = {"Proxy": "http://127.0.0.1:9443"}' "$status" \
        >"$tmp/s" && mv "$tmp/s" "$status"
    drive
}

@test "a Service the script no longer declares does not fail the run" {
    stale_service_run
    assert_equal "$rc" 0
}

@test "a stale Service is cleared exactly once" {
    stale_service_run
    assert_equal "$(grep -cF -- 'serve clear svc:agent-ui' "$log" || true)" 1
}

@test "a run clears the one stale Service and nothing else" {
    stale_service_run
    assert_equal "$(grep -cE -- 'serve clear' "$log" || true)" 1
}

@test "the stale Service leaves the Serve config, so nothing answers its name" {
    stale_service_run
    if ! jq -e '.Services // {} | has("svc:agent-ui") | not' "$status" >/dev/null 2>&1; then
        jq -r '.Services // {} | keys | join(" ")' "$status" >&2 || true
        return 1
    fi
}

@test "clearing a stale Service leaves the declared ones in place" {
    stale_service_run
    assert_equal "$(service_served svc:opds:443)" 'http://127.0.0.1:8083'
}

# The index the reconcile reads is the declarations' index: a `--service=` block
# added to the script without its entry here would be cleared on the next run, and
# an entry with no declaration would pin a route nothing makes. Both are read out
# of the script rather than repeated, so this is the assertion that fails when a
# seventh Service is declared.
declared_services_of_script() {
    sed -n 's/^declared_services=(\(.*\))$/\1/p' "$script" |
        tr -s ' ' '\n' | grep -v '^$' | sort | paste -sd' ' -
}

@test "declared_services is readable" {
    stale_service_run
    [[ -n $(declared_services_of_script) ]]
}

@test "declared_services names exactly the Services the script declares" {
    stale_service_run
    assert_equal "$(grep -oE -- '--service=svc:[A-Za-z0-9._-]+' "$script" | sed 's/^--service=//' |
        sort -u | paste -sd' ' -)" "$(declared_services_of_script)"
}

@test "a Service the script declares is never cleared" {
    stale_service_run
    declared_service_re=$(tr ' ' '\n' <<<"$(declared_services_of_script)" | paste -sd'|' -)
    if grep -qE -- "serve clear ($declared_service_re)$" "$log"; then
        grep -E -- 'serve clear' "$log" >&2
        return 1
    fi
}

# A Service Tailscale refuses to clear is reported and stops the further prunes,
# like a port that will not go: the run fails rather than leaving the rest of the
# config half-reconciled in silence.
clear_fail_run() {
    reset_case
    jq '.Services["svc:agent-ui"] = {"Proxy": "http://127.0.0.1:9443"}' "$status" \
        >"$tmp/s" && mv "$tmp/s" "$status"
    clear_fail=1
    drive
}

@test "a Service Serve refuses to clear fails the run" {
    clear_fail_run
    [[ $rc -ne 0 ]]
}

@test "the failure names the Service it could not clear" {
    clear_fail_run
    if ! grep -qF -- 'could not clear the stale Service svc:agent-ui' "$tmp/stderr"; then
        cat "$tmp/stderr" >&2
        return 1
    fi
}

@test "a failed Service clear stops the further prunes" {
    clear_fail_run
    if grep -qE -- '--set-path=/apps/.* off$' "$log"; then
        grep -E -- ' off$' "$log" >&2
        return 1
    fi
}

# --- a missing plan prunes every app route -----------------------------------

no_plan_prune_run() {
    reset_case
    jq '.Web["host:443"].Handlers["/apps/alpha"] = {"Proxy": "http://127.0.0.1:21234"}' "$status" >"$tmp/s" && mv "$tmp/s" "$status"
    drive
}

@test "no plan is not an error" {
    no_plan_prune_run
    assert_equal "$rc" 0
}

@test "no plan removes every app route" {
    no_plan_prune_run
    if served host:443 | grep -E '^/apps/' | grep -qvE '^/apps/agent-(local|general) '; then
        served host:443 >&2
        return 1
    fi
}

@test "no plan keeps the core agent path" {
    no_plan_prune_run
    serves host:443 /apps/agent-local http://127.0.0.1:18001
}

@test "no plan keeps the core root route" {
    no_plan_prune_run
    serves host:443 / http://127.0.0.1:2283
}

# --- Serve status is a nicety, not a precondition for core ingress ----------

status_fail_run() {
    reset_case
    plan_with "$(jq -cn --argjson a "$(app_entry alpha 21234 4001 1G internet)" '{alpha: $a}')" >"$plan"
    status_fail=1
    drive
}

@test "an unreadable status still applies the plan" {
    status_fail_run
    assert_equal "$rc" 0
}

@test "the core routes, the two core paths, the wallpaper route and the app route are declared without status" {
    status_fail_run
    if [[ $(grep -c -- '--bg --https=' "$log") != $(($(core_route_count) + 4)) ]]; then
        cat "$log" >&2
        return 1
    fi
}

# --- an unpublishable wallpaper route fails the run --------------------------

path_fail_run() {
    reset_case
    path_fail=1
    drive
}

@test "Serve refusing the wallpaper directory fails the run" {
    path_fail_run
    [[ $rc -ne 0 ]]
}

@test "the failure names the directory it could not publish" {
    path_fail_run
    if ! grep -qF -- 'could not serve' "$tmp/stderr"; then
        cat "$tmp/stderr" >&2
        return 1
    fi
}

wallpapers_missing_run() {
    reset_case
    wallpapers_dir=$tmp/absent
    drive
}

@test "a missing wallpaper directory fails the run" {
    wallpapers_missing_run
    [[ $rc -ne 0 ]]
}

@test "a missing wallpaper directory still leaves the core routes declared" {
    wallpapers_missing_run
    if [[ $(grep -c -- '--bg --https=' "$log") != $(($(core_route_count) + 2)) ]]; then
        cat "$log" >&2
        return 1
    fi
}

# --- malformed plans fail closed ---------------------------------------------

reject_run() { # plan body
    reset_case
    printf '%s\n' "$1" >"$plan"
    drive
}

@test "a non-object plan is rejected" {
    reject_run '[]'
    [[ $rc -ne 0 ]]
}

@test "a plan whose base path is not /apps/<name> is rejected" {
    reject_run '{"apps": {"alpha": {"basePath": "/elsewhere", "loopbackPort": 21234, "projectId": 4001, "quota": "1G"}}}'
    [[ $rc -ne 0 ]]
}

@test "a plan whose path disagrees with its name is rejected" {
    reject_run '{"apps": {"alpha": {"basePath": "/apps/beta", "loopbackPort": 21234, "projectId": 4001, "quota": "1G"}}}'
    [[ $rc -ne 0 ]]
}

@test "a loopback port outside the tenant range is rejected" {
    reject_run '{"apps": {"alpha": {"basePath": "/apps/alpha", "loopbackPort": 2283, "projectId": 4001, "quota": "1G"}}}'
    [[ $rc -ne 0 ]]
}

@test "a non-numeric loopback port is rejected" {
    reject_run '{"apps": {"alpha": {"basePath": "/apps/alpha", "loopbackPort": "21234", "projectId": 4001, "quota": "1G"}}}'
    [[ $rc -ne 0 ]]
}

@test "a path traversal in the app name is rejected" {
    reject_run '{"apps": {"../etc": {"basePath": "/apps/../etc", "loopbackPort": 21234, "projectId": 4001, "quota": "1G"}}}'
    [[ $rc -ne 0 ]]
}

@test "an app entry that is not an object is rejected" {
    reject_run '{"apps": {"alpha": "x"}}'
    [[ $rc -ne 0 ]]
}

# A tenant app that claims a core path would be declared by two loops; the whole
# plan is refused rather than letting the last writer win.
core_claim_run() {
    reset_case
    plan_with "$(jq -cn --argjson a "$(app_entry agent-local 21234 4001 1G internet)" \
        --argjson b "$(app_entry alpha 21235 4002 1G internet)" '{"agent-local": $a, alpha: $b}')" >"$plan"
    drive
}

@test "a plan that claims a core path is rejected" {
    core_claim_run
    [[ $rc -ne 0 ]]
}

@test "the rejection names the core path" {
    core_claim_run
    if ! grep -qF -- 'which a core route owns' "$tmp/stderr"; then
        cat "$tmp/stderr" >&2
        return 1
    fi
}

@test "a plan that claims a core path applies none of its routes" {
    core_claim_run
    if served host:443 | grep -qx '/apps/alpha http://127.0.0.1:21235'; then
        served host:443 >&2
        return 1
    fi
}

@test "the refused plan leaves the core path alone" {
    core_claim_run
    serves host:443 /apps/agent-local http://127.0.0.1:18001
}

invalid_json_run() {
    reset_case
    printf 'not json\n' >"$plan"
    drive
}

@test "invalid JSON is rejected" {
    invalid_json_run
    [[ $rc -ne 0 ]]
}

# A rejected plan must still leave the core applications and the wallpapers
# route reachable, and must change no app route.
@test "a rejected plan changes no app route" {
    invalid_json_run
    tenant_traffic=$(grep -E -- '(--set-path=/apps/| off)' "$log" | grep -vE -- '--set-path=/apps/agent-(local|general) ' || true)
    if [[ -n $tenant_traffic ]]; then
        printf '%s\n' "$tenant_traffic" >&2
        return 1
    fi
}

@test "a rejected plan still declares the core routes, the two core paths and the wallpapers route" {
    invalid_json_run
    if [[ $(grep -c -- '--bg --https=' "$log") != $(($(core_route_count) + 3)) ]]; then
        cat "$log" >&2
        return 1
    fi
}

@test "a rejected plan still declares the receiver forward" {
    invalid_json_run
    if ! grep -qF -- '--tcp=8484 tcp://127.0.0.1:8484' "$log"; then
        cat "$log" >&2
        return 1
    fi
}

@test "a rejected plan leaves the receiver forward in place" {
    invalid_json_run
    assert_equal "$(tcp_forward)" 127.0.0.1:8484
}

# The consequence of being last, on the case that matters: the tenant routes and
# the prune have already run, so a Service the tailnet refuses costs the terminal.
refused_terminal_run() {
    reset_case
    plan_with "$(jq -cn --argjson a "$(app_entry alpha 21234 4001 1G internet)" '{alpha: $a}')" >"$plan"
    service_name_fail=svc:terminal
    drive
}

@test "a refused terminal Service fails the run" {
    refused_terminal_run
    assert_equal "$rc" 1
}

@test "a refused terminal still leaves the tenant route declared" {
    refused_terminal_run
    serves host:443 /apps/alpha http://127.0.0.1:21234
}

@test "a refused terminal advertises nothing" {
    refused_terminal_run
    if [[ -n $(service_served svc:terminal:443) ]]; then
        service_served svc:terminal:443 >&2
        return 1
    fi
}
