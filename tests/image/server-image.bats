#!/usr/bin/env bats
# bats file_tags=image
# The `server-image` area checks, as bats (SDLC #907, T13).
#
# The group was a chain of commands in the old driver:
#
#   scripts/check-server-image.sh
#   scripts/render-ignition.sh --synthetic --check
#   tests/core/ignition-boundary.sh            -> tests/image/ignition-boundary.bats
#   scripts/render-ignition.sh --synthetic --stock --check
#
# The Ignition boundary suite is its own file; this one holds the two commands
# that are assertions by exiting 0. check-server-image.sh prints its own ~770
# per-check `ok` lines and its verdict, so the file does not restate them: what
# the group proved about the image is that command's exit status, and a failure
# here is reproduced with `bash scripts/check-server-image.sh`.
#
# The edge artifact (design #939, T3 and T4) is asserted here as well, because
# both Containerfiles are the same doctrine and the group claims bootc/edge/*:
# what this file proves about the edge is the base tag, the recorded digest, the
# workflow that publishes it, and the rootfs it ships -- the Caddyfile's path, the
# emptied public zone, the sshd policy and the credential-based tailnet join.
# The runtime half (firewalld's state, the zone bindings, 22 unreachable on the
# public interface) is a boot on the box and belongs to bootc/edge/tests/check.sh
# in T5.
#
#   bats tests/image/server-image.bats
load ../helpers

static_checks=scripts/check-server-image.sh
renderer=scripts/render-ignition.sh
edge_containerfile=bootc/edge/Containerfile
edge_workflow=.github/workflows/publish-edge-image.yml
edge_rootfs=bootc/edge/rootfs

# contains <text> <file>: a failure names the line that went missing instead of a
# bare status, because these assertions read files rather than run commands.
contains() {
    grep -qF -- "$1" "$2" || fail "missing '$1' in $2"
}

@test "server image static checks passed" {
    run "$static_checks"
    assert_success
}

# --check only validates the Butane source with the pinned binary; the two forms
# differ in whether the autorebase units survive, so both are the group's claim.
@test "the synthetic render passes --check, stock and FCOS media" {
    run "$renderer" --synthetic --check
    assert_success
    run "$renderer" --synthetic --stock --check
    assert_success
}

# The moving-tag/digest-label doctrine, restated as an assertion: the base arrives
# as BASE_IMAGE, the digest the build resolved arrives as BASE_DIGEST, and the
# label is the only durable record of what the image was built on.
@test "the edge Containerfile takes the base tag and records the resolved digest" {
    contains 'FROM ${BASE_IMAGE}' "$edge_containerfile"
    contains 'ARG BASE_DIGEST' "$edge_containerfile"
    contains 'org.opencontainers.image.base.name="${BASE_IMAGE}"' "$edge_containerfile"
    contains 'org.opencontainers.image.base.digest="${BASE_DIGEST}"' "$edge_containerfile"
}

# A digest-pinned base rots when upstream garbage-collects it and `:latest` is no
# stream, so the build refuses both rather than shipping an image that cannot be
# rebuilt, and it refuses an empty digest rather than one that cannot say what it
# ran on.
@test "the edge build refuses a floating, pinned or unrecorded base" {
    contains '*:latest) echo "BASE_IMAGE must be a stream tag, not :latest' "$edge_containerfile"
    contains 'BASE_IMAGE must be a stream tag, not a digest' "$edge_containerfile"
    contains 'BASE_IMAGE must be a tagged reference' "$edge_containerfile"
    contains 'BASE_DIGEST is empty' "$edge_containerfile"
}

@test "the edge base is a uCore stream tag and the image has its own repository" {
    run bash -c '. bootc/lib/pins.env
        printf "%s\n%s\n" "$EDGE_IMAGE" "$EDGE_IMAGE_REPO"'
    assert_success
    assert_regex "${lines[0]}" '^ghcr\.io/ublue-os/ucore-minimal:[A-Za-z0-9._-]+$'
    assert_equal "${lines[1]}" ghcr.io/smores56/homelab-platform/edge
}

# build-image.sh takes the artifact as its argument, so one script builds and one
# set of guarantees covers both. `--help` and an unknown artifact are its dry
# path: neither reaches a container engine, which is why they run here.
@test "build-image.sh takes an artifact and names the edge Containerfile" {
    run scripts/build-image.sh --help
    assert_success
    assert_output --partial 'scripts/build-image.sh [server|edge]'
    run scripts/build-image.sh nosuch
    assert_failure 2
    assert_output --partial 'unknown artifact nosuch'
    contains 'bootc/edge/Containerfile' scripts/build-image.sh
    contains 'bootc/server/Containerfile' scripts/build-image.sh
}

# The publish side of the same doctrine: the workflow runs on the edge's own tree
# and the pins it reads, builds the artifact through the one build script, and
# signs the digest it pushed plus the legacy `.sig` tag bootc actually reads.
@test "the edge publish workflow triggers on its tree and signs the digest" {
    run test -s "$edge_workflow"
    assert_success
    contains '- "bootc/edge/**"' "$edge_workflow"
    contains '- "bootc/lib/**"' "$edge_workflow"
    contains 'run: scripts/build-image.sh edge' "$edge_workflow"
    contains 'environment: server-image' "$edge_workflow"
    contains 'cosign sign --key env://COSIGN_PRIVATE_KEY --yes "$image@$digest"' "$edge_workflow"
    contains ':${digest/:/-}.sig' "$edge_workflow"
    contains 'cosign verify --key bootc/server/cosign.pub' "$edge_workflow"
}

# The Caddyfile is image content and the unit is told so. The rule it encodes is
# the one that bites on a bootc host: /etc is merged once from the image and then
# kept, so a Caddyfile under /etc/caddy would be frozen at the install's version
# and no deploy could change a route. `--config` on the unit is what makes the
# /usr/share copy the one Caddy reads.
@test "the edge Caddyfile ships outside /etc and the unit passes --config" {
    run test -s "$edge_rootfs/usr/share/smoresnet/Caddyfile"
    assert_success
    contains '--config /usr/share/smoresnet/Caddyfile' \
        "$edge_rootfs/usr/lib/systemd/system/caddy.service.d/10-smoresnet.conf"
    # The packaged unit's own lines name /etc/caddy/Caddyfile, which the build
    # deletes: a drop-in that resets only ExecStart would leave ExecStartPre
    # validating a file that is not there.
    contains 'ExecStartPre=' "$edge_rootfs/usr/lib/systemd/system/caddy.service.d/10-smoresnet.conf"
    contains "rm -f /etc/caddy/Caddyfile" "$edge_containerfile"
    run test -e "$edge_rootfs/etc/caddy/Caddyfile"
    assert_failure
}

# The reader moved to smortress (SDLC #953), so the edge's third name is a
# tailnet proxy like the other two and the box holds no process, no config
# directory and no credential for the repository. Both halves are asserted here
# because they are the same claim: a route cannot read a corpus, and a reader on
# this box is the credential's old home.
@test "the edge proxies the reader to the tailnet and runs none of its own" {
    contains 'reverse_proxy {$RECOVERY_UPSTREAM}' "$edge_rootfs/usr/share/smoresnet/Caddyfile"
    if grep -qF '127.0.0.1:9898' "$edge_rootfs/usr/share/smoresnet/Caddyfile"; then
        fail "the edge Caddyfile still proxies to the reader on loopback"
    fi
    hits=$(grep -rInE 'RESTIC_PASSWORD|R2_(ACCESS|SECRET)_ACCESS_KEY|AWS_(ACCESS|SECRET)_ACCESS_KEY|restic-password|r2-credentials|backrest\.(service|container)|/etc/backrest' \
        "$edge_rootfs" "$edge_containerfile" || true)
    if [[ -n $hits ]]; then
        printf '%s\n' "$hits" >&2
        fail "the edge image carries a reader or a credential"
    fi
}

# The design's load-bearing firewall claim, as a file: stock `public` ships ssh,
# mdns and dhcpv6-client, so an image that kept that list would publish sshd on
# the internet the moment the NIC was bound to it. The three entries below are the
# whole of what the edge accepts, and ICMP is stated by inversion because that is
# the only way firewalld can name an accepted ICMP type.
@test "the edge public zone is emptied and carries only 443, 41641 and ICMP echo" {
    zone=$edge_rootfs/usr/share/smoresnet/firewalld/zones/public.xml
    run test -s "$zone"
    assert_success
    if grep -q '<service' "$zone"; then
        fail "the public zone carries a service list: stock public includes ssh"
    fi
    contains '<port port="443" protocol="tcp"/>' "$zone"
    contains '<port port="41641" protocol="udp"/>' "$zone"
    contains '<icmp-block-inversion/>' "$zone"
    contains '<icmp-block name="echo-request"/>' "$zone"
    # The public NIC's name is not knowable at build time, so the binding is the
    # boot unit's; a static <interface> here would be a guess that silently
    # publishes nothing (or the wrong interface).
    if grep -q '<interface' "$zone"; then
        fail "the public zone names an interface: its binding is smoresnet-firewall-public.service"
    fi
}

# 22 exists on the tailnet and nowhere else, and the deploy receiver's port is
# declared with it so T11 does not have to widen a zone to make the notify path
# work.
@test "the edge tailscale zone binds tailscale0 and opens 22 and 8484 only" {
    zone=$edge_rootfs/usr/share/smoresnet/firewalld/zones/tailscale.xml
    run test -s "$zone"
    assert_success
    contains '<interface name="tailscale0"/>' "$zone"
    contains '<port port="22" protocol="tcp"/>' "$zone"
    contains '<port port="8484" protocol="tcp"/>' "$zone"
    # Pinned whole rather than one port at a time, exactly as the server's zone is
    # (scripts/check/server/deploy.sh): a port added to this zone is a port open on
    # the only route in, and nothing else would notice.
    ports=$(grep -oE '<port port="[0-9]+" protocol="[a-z]+"/>' "$zone" | tr '\n' ' ')
    [[ $ports == '<port port="22" protocol="tcp"/> <port port="8484" protocol="tcp"/> ' ]] ||
        fail "the tailscale zone opens more than 22 and 8484: $ports"
}

# The zones unit runs before firewalld because the alternative is firewalld
# coming up holding the stock public zone; the two bindings are units because
# firewalld cannot know the interface names at build time. The tailnet one is
# ordered after tailscaled and gated on the enrollment marker, or it would wait
# for an interface that a box with no auth key never creates.
@test "the edge firewall is reasserted by units, before firewalld and after tailscaled" {
    contains 'Before=firewalld.service' \
        "$edge_rootfs/usr/lib/systemd/system/smoresnet-firewall-zones.service"
    contains 'ExecStart=/usr/libexec/smoresnet-firewall-zones' \
        "$edge_rootfs/usr/lib/systemd/system/smoresnet-firewall-zones.service"
    contains '/etc/firewalld/zones/' "$edge_rootfs/usr/libexec/smoresnet-firewall-zones"
    contains 'DefaultZone=drop' "$edge_rootfs/usr/libexec/smoresnet-firewall-zones"
    # NetworkManager re-asserts the zone it reads from the connection profile, so
    # the public binding has to be written there as well as on the interface: a
    # firewalld-only binding is undone by the next activation, which is how
    # smortress's first bring-up lost SSH.
    contains 'connection.zone public' "$edge_rootfs/usr/libexec/smoresnet-firewall-bind"
    contains 'nmcli device reapply' "$edge_rootfs/usr/libexec/smoresnet-firewall-bind"
    contains 'After=firewalld.service tailscaled.service smoresnet-tailscale-up.service' \
        "$edge_rootfs/usr/lib/systemd/system/smoresnet-firewall-tailscale.service"
    contains 'ConditionPathExists=/var/lib/smoresnet/tailscale-enrolled' \
        "$edge_rootfs/usr/lib/systemd/system/smoresnet-firewall-tailscale.service"
    contains 'ExecStart=/usr/libexec/smoresnet-firewall-bind tailscale' \
        "$edge_rootfs/usr/lib/systemd/system/smoresnet-firewall-tailscale.service"
    for unit in smoresnet-firewall-zones smoresnet-firewall-public smoresnet-firewall-tailscale \
        smoresnet-tailscale-up; do
        contains "$unit.service" "$edge_containerfile"
    done
}

# keys only, root by key, no password route even on loopback. The last one is the
# one that is easy to lose: the base ships 90-enable-localhost-passwords.conf, and
# sshd keeps the first value it obtains for a directive re-read in a Match block,
# which is why this file sorts at 05-.
@test "the edge sshd policy is the provisioned one and adds no password route" {
    dropin=$edge_rootfs/etc/ssh/sshd_config.d/05-edge-hardening.conf
    contains 'PasswordAuthentication no' "$dropin"
    contains 'KbdInteractiveAuthentication no' "$dropin"
    contains 'PermitRootLogin prohibit-password' "$dropin"
    contains 'PermitEmptyPasswords no' "$dropin"
    contains 'X11Forwarding no' "$dropin"
    contains 'AllowAgentForwarding no' "$dropin"
    contains 'Match Address 127.0.0.1,::1' "$dropin"
    # No ListenAddress: the interface, not the listener, is the gate, and a
    # tailnet address is per node.
    if grep -qE '^[[:space:]]*ListenAddress' "$dropin"; then
        fail "the edge sshd drop-in names a ListenAddress"
    fi
    # The provider's template sets PermitRootLogin yes and PasswordAuthentication
    # yes; nothing in the image may reproduce either.
    if grep -rlE '^[[:space:]]*PasswordAuthentication[[:space:]]+yes' \
        "$edge_rootfs/etc/ssh" 2>/dev/null | grep -q .; then
        fail "an edge sshd drop-in accepts passwords"
    fi
}

# The join reads a credential, never an argument or an environment variable, and
# turns Tailscale SSH off in the same command so a restored node state cannot
# resurrect it.
@test "the edge joins the tailnet from a credential with Tailscale SSH off" {
    unit=$edge_rootfs/usr/lib/systemd/system/smoresnet-tailscale-up.service
    contains 'LoadCredential=tailscale-authkey:/etc/smoresnet/tailscale-authkey' "$unit"
    contains '--auth-key=file:${CREDENTIALS_DIRECTORY}/tailscale-authkey' "$unit"
    contains '--ssh=false' "$unit"
    contains 'ConditionPathExists=/etc/smoresnet/tailscale-authkey' "$unit"
    # The key is the operator's: the unit reads it, the image must not carry it.
    run test -e "$edge_rootfs/etc/smoresnet/tailscale-authkey"
    assert_failure
    # The marker is what makes the boot after a failed join try again, and what
    # the tailscale0 binding is conditioned on.
    contains 'ConditionPathExists=!/var/lib/smoresnet/tailscale-enrolled' "$unit"
    contains 'touch /var/lib/smoresnet/tailscale-enrolled' "$unit"
}

# COPY preserves the mode, so a helper committed 0644 is a unit that fails
# 203/EXEC at boot rather than at review time -- the failure the server's rootfs
# programs are checked for.
@test "the edge rootfs programs are committed executable" {
    for program in "$edge_rootfs/usr/libexec/smoresnet-firewall-zones" \
        "$edge_rootfs/usr/libexec/smoresnet-firewall-bind" \
        "$edge_rootfs/usr/libexec/edge-boot-gate"; do
        mode=$(git ls-files -s "$program" | cut -d' ' -f1)
        [[ $mode == 100755 ]] || fail "$program is committed as ${mode:-untracked}, not 100755"
    done
    contains 'chmod 0755 /usr/libexec/smoresnet-firewall-zones /usr/libexec/smoresnet-firewall-bind' \
        "$edge_containerfile"
    contains 'chmod 0755 /usr/libexec/edge-boot-gate' "$edge_containerfile"
}

# The boot gate is enabled like every other unit in the image, and it reads two
# files that have to arrive with it: the shared deploy state library under the
# name the server's smortress-src loop gives it, and the list of units whose
# failure is a verdict (design #939, T7).
@test "the edge image enables the boot gate and ships what it reads" {
    contains '      edge-boot-gate.service \' "$edge_containerfile"
    contains 'COPY scripts/deploy-state.sh /usr/libexec/deploy-state' "$edge_containerfile"
    contains 'COPY scripts/lib/ /usr/libexec/lib/' "$edge_containerfile"
    contains 'ExecStart=/usr/libexec/edge-boot-gate' \
        "$edge_rootfs/usr/lib/systemd/system/edge-boot-gate.service"
    contains 'caddy.service' "$edge_rootfs/usr/share/smoresnet/deploy-units.txt"
}

@test "the edge Containerfile copies the whole rootfs and gates the build on it" {
    contains 'COPY bootc/edge/rootfs/ /' "$edge_containerfile"
    contains 'dnf5 -y --setopt=install_weak_deps=False install caddy' "$edge_containerfile"
    # firewalld's own validator is the only thing that proves the shipped zones
    # parse; the copies it checks are removed so the image leaves no zone in /etc
    # for bootc to freeze.
    contains 'firewall-offline-cmd --set-default-zone=drop' "$edge_containerfile"
    contains 'firewall-offline-cmd --check-config' "$edge_containerfile"
    contains 'rm -f /etc/firewalld/zones/public.xml /etc/firewalld/zones/tailscale.xml' \
        "$edge_containerfile"
    contains 'caddy validate --config /usr/share/smoresnet/Caddyfile' "$edge_containerfile"
    contains 'sshd -t -o HostKey="$tmp/hostkey"' "$edge_containerfile"
}

# The path filter exists so a change to what the image is built from republishes
# it. A tree the Containerfile copies and the filter does not name keeps the last
# build that touched something else -- the image is stale, not absent, and nothing
# notices. So the filter list is checked against the Containerfile's own COPY
# lines instead of being trusted to stay in step by hand.
@test "the edge publish workflow triggers on every path its Containerfile copies" {
    filters=()
    while IFS= read -r line; do
        filters+=("$line")
    done < <(sed -n '/^    paths:/,/^  workflow_dispatch:/p' "$edge_workflow" |
        sed -n 's/^ *- "\(.*\)"$/\1/p')
    ((${#filters[@]} > 0)) || fail "no paths: filters found in $edge_workflow"
    while read -r instruction src _; do
        [[ $instruction == COPY ]] || continue
        covered=false
        for filter in "${filters[@]}"; do
            # shellcheck disable=SC2254 # the filter is a glob by design
            case $src in $filter) covered=true ;; esac
        done
        $covered || fail "COPY $src is not matched by a path filter in $edge_workflow"
    done < <(grep '^COPY ' "$edge_containerfile")
}
