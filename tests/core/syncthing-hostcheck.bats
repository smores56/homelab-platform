#!/usr/bin/env bats
# bats file_tags=core
# The GUI's host check is enforced at boot, not assumed (design #897, T2).
#
# The GUI trusts exactly one address, and the proxy in front of it rewrites Host to
# that address. What must not drift is the GUI's own setting: `insecureSkipHostcheck`
# is host state in config.xml, so a restored config or an experiment can turn it back
# on, and the only defensible steady state is the value this unit writes at every
# boot. These cases prove the write, the read-back that decides the exit status, the
# retry around a starting GUI, and that the API key never reaches output.
#
#   bats tests/core/syncthing-hostcheck.bats
load ../helpers

script=scripts/syncthing-hostcheck.sh
unit=units/systemd/smortress-syncthing-hostcheck.service

setup() {
    [ -r "$script" ]
    work=$BATS_TEST_TMPDIR
    log=$work/curl-calls
    config=$work/config.xml
    : >"$log"
    mkdir -p "$work/bin"
    export CURL_LOG=$log
    export SYNCTHING_CONFIG=$config
    export SYNCTHING_GUI=http://127.0.0.1:8384
    # No real waiting: a case that wants the retry sets the attempt count itself.
    export SYNCTHING_ATTEMPTS=2
    export SYNCTHING_PAUSE=0
    cat >"$config" <<'EOF'
<configuration version="37">
    <gui enabled="true">
        <apikey>sekrit-key</apikey>
    </gui>
</configuration>
EOF
    install_curl
    PATH="$work/bin:$PATH"
}

# The fake curls like the real one for the two endpoints the script uses: it logs
# every invocation (so a case can assert what was sent), answers health with the
# configured exit code, and answers the GUI config with CURL_STATE.
install_curl() {
    cat >"$work/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CURL_LOG"
url=${*: -1}
case $url in
    */rest/noauth/health) exit "${CURL_HEALTH_RC:-0}" ;;
    */rest/config/gui)
        if [[ " $* " == *" -X PATCH "* ]]; then
            exit "${CURL_PATCH_RC:-0}"
        fi
        printf '{"insecureSkipHostcheck": %s}\n' "${CURL_STATE:-false}"
        exit 0
        ;;
esac
exit 0
EOF
    chmod 0755 "$work/bin/curl"
}

run_check() {
    rc=0
    out=$(bash "$script" 2>&1) || rc=$?
}

@test "the PATCH turns the host check off-by-exception to false" {
    run_check
    assert_equal "$rc" 0
    run cat "$log"
    assert_output --partial '-X PATCH'
    assert_output --partial '{"insecureSkipHostcheck": false}'
    assert_output --partial 'http://127.0.0.1:8384/rest/config/gui'
}

@test "the API key comes from config.xml and never reaches output" {
    run_check
    [[ $out != *sekrit-key* ]] || fail "the key was printed"
    run cat "$log"
    assert_output --partial 'X-API-Key: sekrit-key'
}

@test "a setting that is already false is written again, which is the no-op" {
    export CURL_STATE=false
    run_check
    assert_equal "$rc" 0
    run grep -c 'X PATCH' "$log"
    assert_output 1
}

@test "a config with no apikey fails before any request" {
    printf '<configuration/>\n' >"$config"
    run_check
    assert_equal "$rc" 1
    assert_contains "$out" 'no <apikey>'
    run cat "$log"
    assert_output ''
}

@test "a GUI that never answers fails the unit" {
    export CURL_HEALTH_RC=7
    run_check
    assert_equal "$rc" 1
    assert_contains "$out" 'never answered'
    run grep -c 'X PATCH' "$log" || true
    assert_output 0
}

@test "the health check is retried before giving up" {
    export CURL_HEALTH_RC=7
    export SYNCTHING_ATTEMPTS=3
    run_check
    run grep -c '/rest/noauth/health' "$log"
    assert_output 3
}

@test "a refused PATCH fails the unit" {
    export CURL_PATCH_RC=22
    run_check
    assert_equal "$rc" 1
    assert_contains "$out" 'refused the PATCH'
}

@test "a GUI that keeps the bypass fails the unit" {
    export CURL_STATE=true
    run_check
    assert_equal "$rc" 1
    assert_contains "$out" 'still reports insecureSkipHostcheck=true'
}

@test "the unit runs the shipped script as a boot oneshot, after the GUI" {
    run grep -x 'Type=oneshot' "$unit"
    assert_success
    run grep -x 'RemainAfterExit=yes' "$unit"
    assert_success
    run grep -x 'ExecStart=/usr/libexec/syncthing-hostcheck' "$unit"
    assert_success
    run grep -E '^After=.*\bsyncthing\.service\b' "$unit"
    assert_success
}

@test "the proxy requires the enforcement rather than trusting the bypass" {
    run grep -x 'Requires=smortress-syncthing-hostcheck.service' \
        units/systemd/smortress-syncthing-gui-proxy.service
    assert_success
    run grep -E '^After=.*\bsmortress-syncthing-hostcheck\.service\b' \
        units/systemd/smortress-syncthing-gui-proxy.service
    assert_success
}
