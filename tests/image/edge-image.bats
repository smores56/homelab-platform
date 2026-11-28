#!/usr/bin/env bats
# bats file_tags=image
# The edge image's checker, and the mutations it must refuse (SDLC #939, T5).
#
# bootc/edge/tests/check.sh carries the edge's static invariants onto the image:
# the Caddyfile's shape, the firewalld zones, the sshd policy, the units, plus the
# Caddyfile's path, the absent secret, the base-tag doctrine and
# `bootc container lint`. It runs in the `image` area, which is what
# .github/workflows/server-image-static.yml already runs on a bootc/** pull
# request; the checker asserts that wiring itself, and case 30 below reverts it.
#
# A check that cannot fail for the reason it exists is worse than no check, so
# every assertion has at least one mutation here: the fixture is a copy of the
# tree the checker reads, one thing is reverted, and the run must fail naming the
# invariant that owned it.
#
#   bats tests/image/edge-image.bats
load ../helpers

checker=bootc/edge/tests/check.sh

# fixture <dir>: the tree the checker derives from its own location (repo,
# Containerfile, pins, build script, both workflows) and nothing else. The
# unit-path row shells out to scripts/check-edge-unit-paths.sh, which reads the
# table, the bootstrap script and the manual steps the table's reasons name, so a
# fixture without them fails that row for the wrong reason.
fixture() {
    local dir=$1
    mkdir -p "$dir/bootc/edge" "$dir/bootc/lib" "$dir/scripts" "$dir/docs" "$dir/.github/workflows"
    cp -a bootc/edge/. "$dir/bootc/edge/"
    cp bootc/lib/pins.env "$dir/bootc/lib/"
    cp scripts/build-image.sh scripts/check-edge-unit-paths.sh "$dir/scripts/"
    cp docs/manual-steps.md "$dir/docs/"
    cp .github/workflows/publish-edge-image.yml "$dir/.github/workflows/"
    cp .github/workflows/server-image-static.yml "$dir/.github/workflows/"
}

@test "the edge checker passes on the tree as committed" {
    run bash "$checker"
    assert_success
    refute_output --partial 'FAIL'
    # The lint is the image's own analysis: outside the image the run proves the
    # assertions and says so, rather than skipping silently.
    assert_output --partial 'skip bootc container lint'
    assert_output --partial '0 failed'
    # CI invokes it by path, so the mode is part of the contract.
    run git ls-files -s "$checker"
    assert_output --partial '100755'
}

@test "the edge checker skips the lint on request" {
    run bash "$checker" --no-lint
    assert_success
    assert_output --partial 'skip bootc container lint (disabled by --no-lint)'
}

# The same checker runs inside the built image, where there is no repository
# checkout above it: the content rows assert the shipped rootfs, the build-side
# rows say they skipped instead of failing, and the lint is what that run adds.
@test "the edge checker runs against a shipped rootfs with no repository" {
    local img=$BATS_TEST_TMPDIR/image bin=$BATS_TEST_TMPDIR/bin
    mkdir -p "$img" "$bin"
    cp -a bootc/edge/rootfs/. "$img/"
    cp "$checker" "$bin/check.sh"
    run bash "$bin/check.sh" --root "$img" --no-lint
    assert_success
    assert_output --partial 'skip the base is a stream tag'
    assert_output --partial 'skip no secret, key or operator file is in the image'
    assert_output --partial 'skip the shipped zones are parsed by firewalld at build'
}

# mutation_fails <fragment> <path> <op> [arg]: copy the tree, apply one mutation,
# and require the run to fail naming <fragment>. `sed` takes a GNU sed -E script,
# `append` a line, `touch` creates an empty file (its parent too). Other invariants
# may fail too when they share the mutated fact; what matters is that the one
# owning this fact is among them.
mutation_fails() {
    local fragment=$1 path=$2 op=$3 arg=${4:-}
    local dir=$BATS_TEST_TMPDIR/repo file
    rm -rf "$dir"
    fixture "$dir"
    file=$dir/$path
    case $op in
        sed) sed -i -E -- "$arg" "$file" || fail "mutation sed failed: $arg" ;;
        append) printf '%s\n' "$arg" >>"$file" || fail "mutation append failed: $arg" ;;
        touch) mkdir -p "$(dirname "$file")" && : >"$file" || fail "mutation touch failed: $path" ;;
        *) fail "unknown mutation op $op" ;;
    esac
    run bash "$dir/bootc/edge/tests/check.sh" --no-lint
    assert_failure
    assert_output --partial "FAIL $fragment"
}

mutations() {
    while IFS='|' read -r description fragment path op arg; do
        [[ -n $description ]] || continue
        case $description in '#'*) continue ;; esac
        register "a mutation is refused: $description" mutation_fails "$fragment" "$path" "$op" "$arg"
    done <<'EOF'
the unit stops validating the Caddyfile|the Caddyfile validates at build and before every start|bootc/edge/rootfs/usr/lib/systemd/system/caddy.service.d/10-smoresnet.conf|sed|\#^ExecStartPre=/usr/bin/caddy validate#d
the photos name is renamed|Caddy serves photos.sammohr.dev|bootc/edge/rootfs/usr/share/smoresnet/Caddyfile|sed|s#^photos\.sammohr\.dev#photos.example.dev#
the opds name is renamed|Caddy serves opds.sammohr.dev|bootc/edge/rootfs/usr/share/smoresnet/Caddyfile|sed|s#^opds\.sammohr\.dev#opds.example.dev#
the recovery name is renamed|Caddy serves recovery.sammohr.dev|bootc/edge/rootfs/usr/share/smoresnet/Caddyfile|sed|s#^recovery\.sammohr\.dev#recovery.example.dev#
Immich proxies the host instead of its Service|Caddy proxies Immich to the Service upstream|bootc/edge/rootfs/usr/share/smoresnet/Caddyfile|sed|s#reverse_proxy \{\$IMMICH_UPSTREAM\}#reverse_proxy https://smortress.example#
OPDShelf proxies the host instead of its Service|Caddy proxies OPDShelf to the Service upstream|bootc/edge/rootfs/usr/share/smoresnet/Caddyfile|sed|s#reverse_proxy \{\$OPDS_UPSTREAM\}#reverse_proxy https://smortress.example#
recovery proxies to a reader on the box|Caddy proxies the recovery name to the Service upstream|bootc/edge/rootfs/usr/share/smoresnet/Caddyfile|sed|s#reverse_proxy \{\$RECOVERY_UPSTREAM\}#reverse_proxy http://127.0.0.1:9898#
the HTTP-01 challenge comes back|Caddy never answers the HTTP-01 challenge|bootc/edge/rootfs/usr/share/smoresnet/Caddyfile|sed|\#disable_http_challenge#d
the admin API comes back|Caddy has no admin API|bootc/edge/rootfs/usr/share/smoresnet/Caddyfile|sed|\#admin off#d
a fourth public name is added|Caddy serves exactly the three public names|bootc/edge/rootfs/usr/share/smoresnet/Caddyfile|append|fourth.sammohr.dev {
a site proxies 443|no site proxies 443|bootc/edge/rootfs/usr/share/smoresnet/Caddyfile|append|:443 {
a site answers plain HTTP|no site answers plain HTTP|bootc/edge/rootfs/usr/share/smoresnet/Caddyfile|append|http://photos.sammohr.dev {
Caddy redirects from 80 again|Caddy never binds port 80|bootc/edge/rootfs/usr/share/smoresnet/Caddyfile|sed|\#auto_https disable_redirects#d
the operator env file ships in the image|the Caddy environment file is the operator's, at /etc/caddy/edge.env|bootc/edge/rootfs/etc/caddy/edge.env|touch|
the unit stops reading the env file|the Caddy environment file is the operator's, at /etc/caddy/edge.env|bootc/edge/rootfs/usr/lib/systemd/system/caddy.service.d/10-smoresnet.conf|sed|\#^EnvironmentFile=/etc/caddy/edge.env#d
a Caddyfile is shipped under /etc|the Caddyfile ships outside /etc|bootc/edge/rootfs/etc/caddy/Caddyfile|touch|
the default zone becomes public|the default firewalld zone is drop|bootc/edge/rootfs/usr/libexec/smoresnet-firewall-zones|sed|s#DefaultZone=drop#DefaultZone=public#g
the public zone gains the stock ssh service|the public zone carries no service|bootc/edge/rootfs/usr/share/smoresnet/firewalld/zones/public.xml|append|<service name="ssh"/>
the public zone opens 80|443 is the only public service|bootc/edge/rootfs/usr/share/smoresnet/firewalld/zones/public.xml|append|<port port="80" protocol="tcp"/>
41641 is opened over tcp|41641/udp is open for a direct WireGuard path|bootc/edge/rootfs/usr/share/smoresnet/firewalld/zones/public.xml|sed|s#port="41641" protocol="udp"#port="41641" protocol="tcp"#
the public zone opens 22|22 is never accepted from a public interface|bootc/edge/rootfs/usr/share/smoresnet/firewalld/zones/public.xml|append|<port port="22" protocol="tcp"/>
tailscale0 is no longer bound|the tailnet interface is the only interface accepted|bootc/edge/rootfs/usr/share/smoresnet/firewalld/zones/tailscale.xml|sed|\#<interface name="tailscale0"/>#d
ICMP echo is blocked again|the public zone accepts ICMP echo, by block inversion|bootc/edge/rootfs/usr/share/smoresnet/firewalld/zones/public.xml|sed|\#<icmp-block name="echo-request"/>#d
the build stops parsing the zones|the shipped zones are parsed by firewalld at build|bootc/edge/Containerfile|sed|\#firewall-offline-cmd --check-config#d
sshd accepts a password|sshd refuses passwords|bootc/edge/rootfs/etc/ssh/sshd_config.d/05-edge-hardening.conf|sed|s#^PasswordAuthentication no#PasswordAuthentication yes#
root logs in with a password|sshd refuses a root password login|bootc/edge/rootfs/etc/ssh/sshd_config.d/05-edge-hardening.conf|sed|s#^PermitRootLogin prohibit-password#PermitRootLogin yes#
a firewall unit is no longer enabled|every unit the edge needs is enabled|bootc/edge/Containerfile|sed|\#^[[:space:]]*smoresnet-firewall-public\.service#d
an auth key enters the image|no secret, key or operator file is in the image|bootc/edge/rootfs/etc/ssh/sshd_config.d/05-edge-hardening.conf|append|tskey-auth-k123CNTRL-0123456789abcdef
the base becomes :latest|the base is a stream tag and the build records its digest|bootc/lib/pins.env|sed|s#^EDGE_TAG=stable#EDGE_TAG=latest#
the base becomes a pinned digest|the base is a stream tag and the build records its digest|bootc/lib/pins.env|sed|s#^EDGE_TAG=stable#stable@sha256:0000000000000000000000000000000000000000000000000000000000000000#
the PR workflow stops covering the edge tree|a pull_request workflow runs this checker on the edge tree|.github/workflows/server-image-static.yml|sed|\#^ *- "bootc/\*\*"$#d
the poll timer is no longer enabled|the quarter-hour poll backstop ships and its timer is enabled|bootc/edge/Containerfile|sed|\#^[[:space:]]*smoresnet-deploy-poll\.timer#d
the poll asks for a repository the edge does not run|the quarter-hour poll backstop ships and its timer is enabled|bootc/edge/rootfs/usr/lib/systemd/system/smoresnet-deploy-poll.service|sed|s#^Environment=DEPLOY_POLL_REPOS=homelab-platform$#Environment=DEPLOY_POLL_REPOS=homelab-platform homelab-apps#
the poll waits for a sops unit the image does not ship|the quarter-hour poll backstop ships and its timer is enabled|bootc/edge/rootfs/usr/lib/systemd/system/smoresnet-deploy-poll.service|sed|s#^After#Requires=sops-decrypt.service\nAfter#
the poll goes back to a daily window|the quarter-hour poll backstop ships and its timer is enabled|bootc/edge/rootfs/usr/lib/systemd/system/smoresnet-deploy-poll.timer|sed|s#^OnCalendar=\*-\*-\* \*:0/15:00$#OnCalendar=*-*-* 03:00:00 America/New_York#
the queue no longer starts the drain|the queue starts the drain when a request lands|bootc/edge/rootfs/usr/lib/systemd/system/smoresnet-deploy.path|sed|\#^DirectoryNotEmpty=#d
the drain installs itself at boot|the queue starts the drain when a request lands|bootc/edge/rootfs/usr/lib/systemd/system/smoresnet-deploy.service|sed|s#^Before=shutdown.target$#Before=shutdown.target\n\n[Install]\nWantedBy=multi-user.target#
the boot gate's state directory is not created|every path the units name is created before boot|bootc/edge/rootfs/etc/tmpfiles.d/smoresnet-edge.conf|sed|\#^d /var/lib/smoresnet #d
the Caddy storage directory is not created|every path the units name is created before boot|bootc/edge/rootfs/etc/tmpfiles.d/smoresnet-edge.conf|sed|\#^d /var/lib/caddy #d
a unit's state directory loses its row|every path the units name is created before boot|bootc/edge/unit-paths.tsv|sed|\#^/var/lib/smoresnet[[:space:]]#d
a unit names a path nothing creates|every path the units name is created before boot|bootc/edge/rootfs/usr/lib/systemd/system/smoresnet-deploy-poll.service|append|ReadWritePaths=/var/lib/nothere
the caddy unit stops naming its storage directory|every path the units name is created before boot|bootc/edge/rootfs/usr/lib/systemd/system/caddy.service.d/10-smoresnet.conf|sed|\#^ReadWritePaths=/var/lib/caddy#d
EOF
}

mutations
