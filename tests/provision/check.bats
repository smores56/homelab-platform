#!/usr/bin/env bats
# bats file_tags=provision
# Static checks for the smortress autoinstall artifact.
# Runtime proof lives in provision/smortress/verify.sh; this runs in CI.
#
#   bats tests/provision/check.bats
#
# The shell suite this replaced ran every check in one process against the
# checkout; here each assertion is its own test, so a failure names the pinned
# property instead of only the line it came from. Nothing here writes: the
# suite reads provision/ as text.
load ../helpers

art=provision/smortress
edge=provision/edge

# has <needle> <file>: the file must carry the literal text. The needles are
# expectations of literal source text, not expansions.
has() {
    grep -qF -- "$1" "$2" && return 0
    printf '%s not found in %s\n' "$1" "$2" >&2
    return 1
}

# lacks <needle> <file>: the file must not carry the literal text.
lacks() {
    grep -qF -- "$1" "$2" || return 0
    printf '%s found in %s\n' "$1" "$2" >&2
    return 1
}

one_login_key() {
    [[ $(grep -c '^ssh-ed25519 ' "$edge/authorized_keys") == 1 ]]
}

sites_are_three() {
    local got
    got=$(grep -E '^[a-z0-9.-]+[[:space:]]*\{' "$edge/Caddyfile" \
        | sed 's/[[:space:]]*{$//' | sort | tr '\n' ' ')
    [[ $got == 'opds.sammohr.dev photos.sammohr.dev recovery.sammohr.dev ' ]]
}

# A site address that starts with http:// is a listener without TLS. An http://
# upstream inside a TLS site is the opposite and is expected here: the guard
# listens on loopback.
no_plain_http_site() { ! grep -qE '^http://' "$edge/Caddyfile"; }

setup_file() {
    [ -d "$art" ] || {
        printf 'missing %s\n' "$art" >&2
        return 1
    }
    [ -d "$edge" ] || {
        printf 'missing %s\n' "$edge" >&2
        return 1
    }
}

# --- the autoinstall artifact ------------------------------------------------

@test "user-data keeps the disk-serial placeholder" {
    has '__DISK_SERIAL__' "$art/user-data"
}

@test "user-data has no spike-only serial" {
    lacks 'SMORTRESS980' "$art/user-data"
}

@test "user-data installs clevis-tpm2" {
    has 'clevis-tpm2' "$art/user-data"
}

@test "user-data wipes the whole disk" {
    has 'wipe: superblock-recursive' "$art/user-data"
}

@test "user-data adds the data keyslot" {
    has 'luksAddKey' "$art/user-data"
}

@test "user-data backs up the data header" {
    has 'luks-data.header' "$art/user-data"
}

@test "user-data fails a missing ip=dhcp" {
    has "grep -q 'ip=dhcp'" "$art/user-data"
}

@test "provision unit follows the cryptsetup unit" {
    has 'systemd-cryptsetup@luks\x2ddata.service' "$art/user-data"
}

@test "provision unit skips without the mapper" {
    has 'ConditionPathExists=/dev/mapper/luks-data' "$art/user-data"
}

@test "data crypttab entry carries nofail" {
    has 'luks,discard,nofail' "$art/user-data"
}

@test "pool creation sets cachefile=none" {
    has 'zpool create -o cachefile=none' "$art/user-data"
}

@test "installer logs are scrubbed" {
    has '/var/log/installer/*autoinstall*' "$art/user-data"
}

@test "user-data carries the host-key placeholder" {
    has '__HOST_KEY_ESCAPED__' "$art/user-data"
}

@test "user-data derives the host-key pubfile" {
    has 'ssh_host_ed25519_key.pub' "$art/user-data"
}

@test "user-data drops generated rsa/ecdsa host keys" {
    has 'ssh_host_rsa*' "$art/user-data"
}

@test "seed builder requires the host key" {
    has 'SMORTRESS_HOST_KEY is required' "$art/build-seed.sh"
}

@test "seed builder rejects a protected host key" {
    has 'passphrase-protected' "$art/build-seed.sh"
}

@test "seed builder rejects leftover placeholders" {
    has 'unsubstituted placeholder' "$art/build-seed.sh"
}

@test "seed builder writes the seed 0600" {
    has 'chmod 600 "$seed"' "$art/build-seed.sh"
}

@test "seed defaults outside the repo" {
    has '$HOME/.cache/smortress' "$art/build-seed.sh"
}

@test "seed builder verifies the ISO signature" {
    has 'VALIDSIG' "$art/build-seed.sh"
}

@test "spike waits for the swtpm socket" {
    has 'swtpm did not create' "$art/spike.sh"
}

@test "spike passes swtpm not-need-init" {
    has 'not-need-init' "$art/spike.sh"
}

# --- the public edge (design #725) -------------------------------------------
# Its bootstrap is the only provisioning step a panel with no cloud-init will
# ever get, so the properties the design depends on are pinned here rather than
# trusted to a console session.

@test "the edge serves photos" {
    has 'photos.sammohr.dev {' "$edge/Caddyfile"
}

@test "the edge serves opds" {
    has 'opds.sammohr.dev {' "$edge/Caddyfile"
}

@test "the edge refuses HTTP-01" {
    has 'disable_http_challenge' "$edge/Caddyfile"
}

@test "the edge has no admin API" {
    has 'admin off' "$edge/Caddyfile"
}

@test "the edge proxies Immich to a Service upstream" {
    has 'reverse_proxy {$IMMICH_UPSTREAM}' "$edge/Caddyfile"
}

@test "the edge proxies OPDShelf to a Service upstream" {
    has 'reverse_proxy {$OPDS_UPSTREAM}' "$edge/Caddyfile"
}

# The reader runs on smortress (SDLC #953), so all three names are tailnet
# proxies and the bootstrap writes the third upstream into the same environment
# file Caddy substitutes from.
@test "the edge proxies the reader to a Service upstream" {
    has 'reverse_proxy {$RECOVERY_UPSTREAM}' "$edge/Caddyfile"
    has 'RECOVERY_UPSTREAM=https://recovery.$tailnet_domain' "$edge/bootstrap.sh"
    has 'RECOVERY_UPSTREAM=$RECOVERY_UPSTREAM' "$edge/bootstrap.sh"
}

@test "the verify refuses a box with no reader upstream" {
    has ': "${RECOVERY_UPSTREAM:?/etc/caddy/edge.env has no RECOVERY_UPSTREAM}"' "$edge/verify.sh"
}

@test "the verify proves the reader is a Service, not a loopback process" {
    has 'grep -qF "reverse_proxy {\$RECOVERY_UPSTREAM}" /etc/caddy/Caddyfile' "$edge/verify.sh"
    has 'no reader listens on this box' "$edge/verify.sh"
}

# The watchdog moved with the reader: neither the script nor the unit it was
# installed as may survive here, because either one is a reader dependency on the
# public box.
@test "the bootstrap installs no reader and no watchdog" {
    lacks 'backrest-watchdog' "$edge/bootstrap.sh"
    lacks 'backrest.service' "$edge/bootstrap.sh"
    [ ! -e "$edge/backrest-watchdog.sh" ]
}

@test "the edge declares no plain HTTP site" {
    no_plain_http_site
}

# The same question asked of the installed Caddyfile on the box: an unanchored
# `http://` there would match the recovery guard's loopback upstream and fail a
# healthy box.
@test "the verify anchors its plain-HTTP check to a site address" {
    has "grep -qE '^http://'" "$edge/verify.sh"
}

# Caddy's home cannot be created by the caddy user, and a missing one costs every
# certificate: the bootstrap makes it and the verify proves it is writable.
@test "the bootstrap creates Caddy's storage directory for its user" {
    has 'install -d -o caddy -g caddy -m 0750 /var/lib/caddy' "$edge/bootstrap.sh"
}

@test "the verify proves Caddy can write its storage directory" {
    has 'runuser -u caddy -- test -w /var/lib/caddy' "$edge/verify.sh"
}

# The upstreams are variables now, so the Caddyfile names no host and no port at
# all: this pin is what keeps a literal 443 from being typed back in, and the
# derivation below is what keeps the target off the host's own address.
@test "the edge never proxies 443" {
    lacks ':443' "$edge/Caddyfile"
}

@test "the edge serves exactly the three names" {
    sites_are_three
}

@test "the edge firewall drops by default" {
    has 'policy drop' "$edge/nftables.conf"
}

@test "the edge firewall admits 443" {
    has 'tcp dport 443 accept' "$edge/nftables.conf"
}

@test "the edge firewall admits WireGuard" {
    has 'udp dport 41641 accept' "$edge/nftables.conf"
}

@test "the edge firewall trusts the tailnet interface" {
    has 'iifname "tailscale0" accept' "$edge/nftables.conf"
}

@test "the edge firewall never admits 22 publicly" {
    lacks 'tcp dport 22 accept' "$edge/nftables.conf"
}

@test "the bootstrap joins with the edge tag" {
    has '--advertise-tags=tag:vps' "$edge/bootstrap.sh"
}

@test "the bootstrap fixes the node hostname" {
    has '--hostname=smoresnet' "$edge/bootstrap.sh"
}

@test "the bootstrap sets the OS hostname" {
    has 'hostnamectl set-hostname smoresnet' "$edge/bootstrap.sh"
}

@test "the bootstrap disables the template's unused daemons" {
    has 'multipathd ModemManager udisks2 upower rsyslog' "$edge/bootstrap.sh"
}

@test "the bootstrap installs the repository login key" {
    has 'authorized_keys' "$edge/bootstrap.sh"
}

@test "the bootstrap validates the ruleset before applying it" {
    has 'nft -c -f /etc/nftables.conf' "$edge/bootstrap.sh"
}

@test "the bootstrap validates the Caddyfile before enabling Caddy" {
    has 'caddy validate --config /etc/caddy/Caddyfile' "$edge/bootstrap.sh"
}

@test "the Caddy config directory is traversable by the caddy user" {
    has 'install -d -m 0755 /etc/caddy' "$edge/bootstrap.sh"
}

@test "sshd hardening sorts before cloud-init" {
    has '05-edge-hardening.conf' "$edge/bootstrap.sh"
}

@test "the bootstrap refuses a Caddy older than 2.6" {
    has 'is too old; the Caddyfile needs 2.6' "$edge/bootstrap.sh"
}

@test "the bootstrap unmasks the packaged Caddy unit" {
    has 'systemctl unmask caddy' "$edge/bootstrap.sh"
}

@test "the bootstrap restores the kit's host key" {
    has 'EDGE_HOST_KEY' "$edge/bootstrap.sh"
}

@test "the bootstrap drops the template's other host keys" {
    has 'rm -f /etc/ssh/ssh_host_rsa_key' "$edge/bootstrap.sh"
}

@test "the verify proves the node carries the edge tag" {
    has 'tag:vps' "$edge/verify.sh"
}

@test "the verify proves the tailnet name" {
    has 'startswith("smoresnet.")' "$edge/verify.sh"
}

@test "the repository login key is one ed25519 line" {
    one_login_key
}

@test "the verify proves nothing listens on 80" {
    has 'sport = :80' "$edge/verify.sh"
}

# The upstream half of the edge is two Tailscale Services, so what the bootstrap
# must derive and what the verify must probe are pinned here: a Service name is
# `<service>.<tailnet>.ts.net`, and the tailnet domain is the one SMORTRESS_FQDN
# already carries, never a second name typed into either file.
@test "the bootstrap derives the Immich upstream from the tailnet domain" {
    has 'IMMICH_UPSTREAM=https://immich.$tailnet_domain' "$edge/bootstrap.sh"
}

@test "the bootstrap derives the OPDShelf upstream from the tailnet domain" {
    has 'OPDS_UPSTREAM=https://opds.$tailnet_domain' "$edge/bootstrap.sh"
}

@test "the bootstrap refuses a hostname with no tailnet domain" {
    has 'has no tailnet domain' "$edge/bootstrap.sh"
}

# The host's own name and 443 must stay out of the upstream list: a Service is a
# different address, and that one also carries the agent paths and /wallpapers.
@test "the bootstrap never points an upstream at the host's own name" {
    lacks '_UPSTREAM=https://$SMORTRESS_FQDN' "$edge/bootstrap.sh"
}

@test "the bootstrap writes the Immich upstream to the Caddy environment" {
    has 'IMMICH_UPSTREAM=$IMMICH_UPSTREAM' "$edge/bootstrap.sh"
}

@test "the bootstrap writes the OPDShelf upstream to the Caddy environment" {
    has 'OPDS_UPSTREAM=$OPDS_UPSTREAM' "$edge/bootstrap.sh"
}

@test "the verify probes the Service names on 443" {
    has '-connect "$immich_name:443"' "$edge/verify.sh"
}

@test "the verify refuses an environment file without the upstreams" {
    has 'has no IMMICH_UPSTREAM' "$edge/verify.sh"
}

# --- the suite's own lint ----------------------------------------------------
# has/lacks are invoked through the tests, the grep patterns are literal, and the
# suite itself is in the set: shellcheck reads .bats as bash.

shellcheck_suite() {
    shellcheck -e SC2329,SC2016 "$art"/*.sh "$edge"/*.sh tests/provision/check.bats
}

yamllint_suite() {
    yamllint -c .yamllint.yaml "$art/user-data"
}

if command -v shellcheck >/dev/null 2>&1; then
    register "shellcheck clean" shellcheck_suite
else
    register_skip "shellcheck clean" "shellcheck is not installed"
fi

if command -v yamllint >/dev/null 2>&1; then
    register "yamllint parses user-data" yamllint_suite
else
    register_skip "yamllint parses user-data" "yamllint is not installed"
fi
