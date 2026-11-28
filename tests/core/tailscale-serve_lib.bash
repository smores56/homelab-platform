# The shared half of the Serve route suite (SDLC #726, T7 of #701): the fake
# tailscaled, the Serve state helpers, the drivers and every case helper more
# than one section file calls. Split out of tests/core/tailscale-serve.bats so
# the sections run as parallel files; sourced with `load ./tailscale-serve_lib`.
#
# Serve is the tenant's only ingress. The core applications own their root
# paths, the two agent gateways own `/apps/agent-local` and `/apps/agent-general`
# on 443, and each `homelab-apps` app gets one `/apps/<name>` path on 443 pointing
# at the loopback port the renderer assigned. The section files prove the
# declaration half without a tailnet: the fixed core routes, the two core paths,
# the wallpaper library as static files under `/wallpapers`, one route per app,
# pruning of an app that left the plan, the retirement of a host port the script
# no longer declares, the clearing of a Service no declaration makes, and the
# refusals that keep a foreign path or port off the tailnet.
#
# `repo_root` comes from tests/helpers.bash, which every section file loads, so a
# check of this file alone cannot see where it comes from.
# shellcheck disable=SC2154,SC2034

script=scripts/tailscale-serve.sh
digest=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

# The fake, the Serve state and the plan are per test, not per file: each @test
# runs in its own process and ts_setup writes the fake into that process's
# scratch dir. A section file calls this wrapper because every file has one, and
# anything a run could share once would be built here.
ts_setup_file() { :; }

# The fake and the Serve state are per test: each @test runs in its own process,
# so nothing may be left in a global a sibling test would race.
ts_setup() {
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
  "TCP": {"443": {"HTTPS": true}, "8443": {"HTTPS": true},
          "8444": {"HTTPS": true}, "8445": {"HTTPS": true}},
  "Web": {
    "host:443": {"Handlers": {
      "/": {"Proxy": "http://127.0.0.1:2283"},
      "/apps/agent-local": {"Proxy": "http://127.0.0.1:18001"},
      "/apps/agent-general": {"Proxy": "http://127.0.0.1:18002"},
      "/apps/agent-ui-personal": {"Proxy": "http://127.0.0.1:18006"},
      "/apps/agent-ui-general": {"Proxy": "http://127.0.0.1:18007"}}},
    "host:8443": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:8083"}}},
    "host:8444": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:18008"}}},
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

serves() { # port path target: a handler the Serve state carries
    local got
    got=$(served "$1")
    if ! grep -qx -- "$2 $3" <<<"$got"; then
        printf 'want %s %s in:\n%s\n' "$2" "$3" "$got" >&2
        return 1
    fi
}

# The run a host with no tenant plan makes, and the one every core case below
# shares: the plan is absent, so only the core ingress can be declared.
core_run() { reset_case; drive; }
