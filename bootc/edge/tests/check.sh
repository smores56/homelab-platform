#!/usr/bin/env bash
# Static checks for the public edge image (design #939, T5).
#
#   bootc/edge/tests/check.sh [--root DIR] [--lint|--no-lint]
#
# The image is the edge's whole configuration, so the shape provision/edge/verify.sh
# proves at runtime on the provisioned box is asserted here against the tree the
# image ships: bootc/edge/rootfs, the Containerfile that copies it, the pins it
# builds from, and the workflow that publishes it. tests/image/edge-image.bats
# drives this file and reverts each invariant one at a time, so a check that
# cannot fail for the reason it exists is a failing test rather than a silent one.
#
# Two verify.sh checks have no image-side equivalent and are reported as `skip`
# rows instead of being dropped. Caddy's storage directory is created writable at
# first boot, and unattended upgrades on the Ubuntu box become bootc's update path
# (T7/T10). verify.sh stays the proof of both until T14 deletes provision/edge.
#
# `bootc container lint` is the image's own static analysis and only makes sense
# inside the built image: against a tree it fails on an empty /dev and /sysroot
# (measured 2026-11-25: "Missing API filesystem base directory: /dev"). The step
# therefore runs when this script is inside the image, or when --lint asks for it,
# and prints a skip row everywhere else -- so CI proves every assertion in this
# file and runs no lint, and the lint is a separate command on the built artifact.
# The same split applies to the build-side rows: inside the image there is no
# repository checkout to read, so they report a skip rather than a pass.
# The Caddyfile's {$PLACEHOLDER}s, the Containerfile's ${BASE_DIGEST} and the skip
# rows' backticked commands are the literal text being asserted, not expansions.
# shellcheck disable=SC2016
set -uo pipefail

usage() {
  printf 'usage: %s [--root DIR] [--lint|--no-lint]\n' "${0##*/}"
}

die() {
  printf 'edge-check: %s\n' "$*" >&2
  exit 2
}

root=''
lint=auto
while (($#)); do
  case $1 in
    --root) [[ -n ${2:-} ]] || die '--root needs a directory'; root=$2; shift ;;
    --root=*) root=${1#*=} ;;
    --lint) lint=yes ;;
    --no-lint) lint=no ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown argument $1 (try --help)" ;;
  esac
  shift
done

# The repository is three levels above the checker (bootc/edge/tests/check.sh), so
# a copy of the tree -- which is what the mutation test builds -- reads its own
# copy. Inside the image the script is mounted somewhere with no checkout above
# it, which is the one case the build-side rows skip.
here=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo=$(CDPATH='' cd -- "$here/../../.." && pwd -P)
if [[ -z $root ]]; then
  if [[ -d $repo/bootc/edge/rootfs ]]; then
    root=$repo/bootc/edge/rootfs
  else
    root=/
  fi
fi
[[ -d $root ]] || die "no such root: $root"
doctrine=false
if [[ -f $repo/bootc/edge/Containerfile ]]; then doctrine=true; fi

# The paths every assertion below names, so a moved file fails here once instead
# of at boot on a box whose console is a provider's VNC page.
caddyfile=$root/usr/share/smoresnet/Caddyfile
caddy_unit=$root/usr/lib/systemd/system/caddy.service.d/10-smoresnet.conf
zones=$root/usr/share/smoresnet/firewalld/zones
public_zone=$zones/public.xml
tailscale_zone=$zones/tailscale.xml
zones_helper=$root/usr/libexec/smoresnet-firewall-zones
sshd_dropin=$root/etc/ssh/sshd_config.d/05-edge-hardening.conf
tailscale_up=$root/usr/lib/systemd/system/smoresnet-tailscale-up.service
containerfile=$repo/bootc/edge/Containerfile
pins=$repo/bootc/lib/pins.env
build_script=$repo/scripts/build-image.sh
publish_workflow=$repo/.github/workflows/publish-edge-image.yml

ran=0
failed=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; failed=$((failed + 1)); }
note() { printf 'skip %s\n' "$1"; }
check() { # check <name> <command...>
  local name=$1
  shift
  ran=$((ran + 1))
  if "$@"; then ok "$name"; else bad "$name"; fi
}
# check_build <name> <command...>: a row that reads the repository (Containerfile,
# pins, workflows). Inside the image there is no checkout, so it reports a skip
# instead of a failure it cannot mean.
check_build() {
  local name=$1
  shift
  if ! $doctrine; then
    note "$name (build-side: no repository checkout at $repo)"
    return 0
  fi
  check "$name" "$@"
}
count() { grep -cE -- "$1" "$2" 2>/dev/null || true; }

# --- Caddy: the whole of what the edge serves ---------------------------------

# verify.sh's first check, moved to where the failure is cheap: the unit validates
# the same file it runs, and the build validates it before it is in an image.
caddyfile_validated() {
  grep -qE '^ExecStartPre=/usr/bin/caddy validate --config /usr/share/smoresnet/Caddyfile' \
    "$caddy_unit" || return 1
  $doctrine || return 0
  grep -qF 'caddy validate --config /usr/share/smoresnet/Caddyfile' "$containerfile"
}

# Exactly one ACME issuer per public name, and each of them refuses HTTP-01: the
# box never opens 80, so an HTTP challenge is an outage dressed as a slow order.
http01_never_answered() {
  local challenges issuers
  challenges=$(count '^[[:space:]]*disable_http_challenge$' "$caddyfile")
  issuers=$(count '^[[:space:]]*issuer acme \{' "$caddyfile")
  [[ -n $challenges && -n $issuers ]] || return 1
  ((challenges > 0)) && ((challenges == issuers))
}

serves() { grep -qxF "$1 {" "$caddyfile"; }

proxies() { grep -qF "reverse_proxy $1" "$caddyfile"; }

# admin off is what makes a Caddyfile change a commit and a deploy rather than a
# restart on the box: there is no second answer to "what is Caddy serving".
admin_off() { grep -qE '^[[:space:]]*admin off[[:space:]]*$' "$caddyfile"; }

# Every positive grep above still passes with a fourth site appended, and a fourth
# site is a name published by accident.
exactly_three_names() {
  local names
  names=$(grep -E '^[a-z0-9.-]+[[:space:]]*\{' "$caddyfile" |
    sed 's/[[:space:]]*{$//' | sort | tr '\n' ' ')
  [[ $names == 'opds.sammohr.dev photos.sammohr.dev recovery.sammohr.dev ' ]]
}

# 443 on the host's own name carries the agent gateway APIs and /wallpapers/, so
# no name may proxy there; the two public names go to their own Services.
no_site_proxies_443() { ! grep -qF ':443' "$caddyfile"; }

# Anchored: an `http://` upstream inside a TLS site is expected (the recovery
# guard is loopback). A site whose address starts with http:// is a listener with
# no TLS at all.
no_plain_http_site() { ! grep -qE '^http://' "$caddyfile"; }

# Port 80 is never opened, so Caddy must not bind it or redirect to it. Comments
# are dropped: the file explains why it does not bind :80.
no_port_80() {
  grep -qE '^[[:space:]]*auto_https disable_redirects[[:space:]]*$' "$caddyfile" || return 1
  ! grep -vE '^[[:space:]]*#' "$caddyfile" | grep -qE ':80([^0-9]|$)'
}

# verify.sh proves the file is 0640 on the box; in the image the invariant is that
# it is absent. The ACME address and the two Service names are derived from the
# tailnet domain, so they are the operator's and can never be image content.
operator_env_file() {
  grep -qE '^EnvironmentFile=/etc/caddy/edge.env$' "$caddy_unit" || return 1
  [[ ! -e $root/etc/caddy/edge.env ]] || return 1
  $doctrine || return 0
  grep -qF 'test ! -e /etc/caddy/edge.env' "$containerfile"
}

# The Caddyfile is image content under /usr, and the unit is told so with --config.
# A Caddyfile under /etc/caddy would be frozen at the install's version: bootc
# merges /etc once and keeps it, so no deploy could ever change a route.
caddyfile_outside_etc() {
  [[ -f $caddyfile ]] || return 1
  [[ ! -e $root/etc/caddy/Caddyfile ]] || return 1
  grep -qF -- '--config /usr/share/smoresnet/Caddyfile' "$caddy_unit" || return 1
  # Both packaged Exec lines are reset, or the unit validates one file and runs
  # another.
  grep -qE '^ExecStartPre=$' "$caddy_unit" || return 1
  grep -qE '^ExecStart=$' "$caddy_unit" || return 1
  $doctrine || return 0
  grep -qF 'rm -f /etc/caddy/Caddyfile' "$containerfile"
}

# --- firewalld: the public surface --------------------------------------------

# `drop` is the default because both real bindings are added at runtime: an
# interface firewalld has not been told about yet is refused, not published.
default_zone_drop() {
  grep -qF 'DefaultZone=drop' "$zones_helper" || return 1
  $doctrine || return 0
  grep -qF -- '--set-default-zone=drop' "$containerfile"
}

# The stock public zone ships ssh, mdns and dhcpv6-client, so an image that kept
# that list would publish sshd on the internet the moment the NIC was bound.
public_zone_carries_no_service() {
  ! grep -qF '<service' "$public_zone" &&
    ! grep -qF '<source' "$public_zone" &&
    ! grep -qF '<interface' "$public_zone"
}

# Pinned whole rather than one port at a time: a port added here is a port open on
# the internet-facing interface.
public_zone_ports_are_the_reviewed_two() {
  local ports
  ports=$(grep -oE '<port port="[0-9]+" protocol="[a-z]+"/>' "$public_zone" | tr '\n' ' ')
  [[ $ports == '<port port="443" protocol="tcp"/> <port port="41641" protocol="udp"/> ' ]]
}

# Without 41641/udp every proxied byte is relayed through DERP and Immich uploads
# crawl; the panel's rule is gone, so this zone is the only place it is stated.
direct_wireguard_open() { grep -qF '<port port="41641" protocol="udp"/>' "$public_zone"; }

# 22 is the operator's shell and it exists on exactly one zone: the tailnet's.
no_public_ssh() {
  local zone
  if grep -qF '<port port="22"' "$public_zone"; then return 1; fi
  if grep -qE '<service[[:space:]]+name="ssh"' "$public_zone"; then return 1; fi
  for zone in "$zones"/*.xml; do
    [[ ${zone##*/} == tailscale.xml ]] && continue
    [[ -e $zone ]] || continue
    if grep -qF '<port port="22"' "$zone"; then return 1; fi
  done
  return 0
}

# One interface element in the whole set of shipped zones, and it is tailscale0:
# the public NIC's name is not knowable at build time, so its binding is a unit.
tailnet_is_the_only_interface() {
  grep -qF '<interface name="tailscale0"/>' "$tailscale_zone" || return 1
  [[ $(grep -hoF '<interface' "$zones"/*.xml | wc -l) -eq 1 ]]
}

# firewalld can only state "accept this ICMP type" by inverting the block list, so
# echo-request is the accepted type and path-MTU diagnosis keeps working.
public_zone_accepts_icmp_echo() {
  grep -qF '<icmp-block-inversion/>' "$public_zone" &&
    grep -qF '<icmp-block name="echo-request"/>' "$public_zone"
}

# firewalld's own validator is the only thing that proves the shipped zones parse;
# the staged copies it reads are removed so no zone is left in /etc for bootc to
# freeze.
zones_parse_at_build() { grep -qF 'firewall-offline-cmd --check-config' "$containerfile"; }

# --- sshd: keys only, root by key ---------------------------------------------

# The base ships 90-enable-localhost-passwords.conf for Cockpit, so the drop-in
# sorts at 05- and repeats `no` inside its loopback Match block; nothing in the
# tree may enable a password anywhere.
sshd_refuses_passwords() {
  local dropin
  grep -qE '^PasswordAuthentication no$' "$sshd_dropin" || return 1
  for dropin in "$root"/etc/ssh/sshd_config.d/*.conf; do
    [[ -e $dropin ]] || continue
    if grep -qE '^[[:space:]]*PasswordAuthentication[[:space:]]+yes' "$dropin"; then return 1; fi
  done
  return 0
}

# No ListenAddress either: the interface is the gate, and the tailnet address is
# per node, so a listener could only be bound to every address or the wrong one.
sshd_refuses_a_root_password() {
  grep -qE '^PermitRootLogin prohibit-password$' "$sshd_dropin" || return 1
  grep -qE '^PermitEmptyPasswords no$' "$sshd_dropin" || return 1
  ! grep -qE '^[[:space:]]*ListenAddress' "$sshd_dropin"
}

# --- the boot: every unit the design depends on ------------------------------

# verify.sh asks systemctl; the image's answer is the enable list plus the unit
# files themselves. A unit that is shipped but not enabled never runs, and a name
# in the enable list with no file fails the build, which is why both halves are
# asserted.
units_enabled() {
  local unit
  for unit in smoresnet-firewall-zones smoresnet-firewall-public \
    smoresnet-firewall-tailscale smoresnet-tailscale-up; do
    [[ -f $root/usr/lib/systemd/system/$unit.service ]] || return 1
  done
  $doctrine || return 0
  for unit in caddy firewalld tailscaled smoresnet-firewall-zones \
    smoresnet-firewall-public smoresnet-firewall-tailscale smoresnet-tailscale-up; do
    grep -qF -- "$unit.service" "$containerfile" || return 1
  done
  return 0
}

# --- the image itself: no secret, and a base that can be rebuilt --------------

# The one thing the image must never carry: the operator's auth key, the Caddy
# environment file, an age identity, or any private key. The unit reads the key as
# a systemd credential from a path bootc deliberately does not reconcile.
no_secret_in_the_image() {
  local path
  for path in etc/smoresnet/tailscale-authkey etc/caddy/edge.env etc/sops/age/keys.txt; do
    if [[ -e $root/$path ]]; then return 1; fi
  done
  if grep -rqIE 'tskey-|BEGIN [A-Z ]*PRIVATE KEY|AGE-SECRET-KEY|^sops:' "$root"; then return 1; fi
  grep -qF 'LoadCredential=tailscale-authkey' "$tailscale_up"
}

# The base is the moving uCore stream tag: a pinned digest rots the moment upstream
# garbage-collects it and `:latest` is not a stream, so both are refused here and
# in the build, and the digest the tag resolved to is recorded in a label.
base_is_a_stream_tag() {
  local base
  # shellcheck source=/dev/null
  base=$(set +u; . "$pins" >/dev/null 2>&1; printf '%s' "${EDGE_IMAGE:-}")
  [[ $base =~ ^ghcr\.io/ublue-os/ucore-minimal:[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
  [[ $base != *:latest ]] || return 1
  grep -qF -- '*:latest) echo "BASE_IMAGE must be a stream tag, not :latest' "$containerfile" || return 1
  grep -qF 'BASE_IMAGE must be a stream tag, not a digest' "$containerfile" || return 1
  grep -qF 'org.opencontainers.image.base.digest="${BASE_DIGEST}"' "$containerfile" || return 1
  grep -qF 'BASE_DIGEST' "$build_script" || return 1
  grep -qF 'BASE_DIGEST' "$publish_workflow"
}

# The quoted filters of a workflow's `paths:` blocks.
workflow_filters() { sed -n '/^ *paths:/,/^ *[a-z-]*:$/p' "$1" | sed -n 's/^ *- "\(.*\)"$/\1/p'; }

# The checker is only as good as the CI that runs it. The area that carries this
# file is `image` (tests/image/, `# bats file_tags=image`), and the workflow that
# runs that area on a pull_request has to trigger on the tree this file reads -- a
# filter that misses bootc/edge keeps publishing an image nobody checked.
pull_request_runs_this_checker() {
  local workflow filter path hit covered
  for workflow in "$repo"/.github/workflows/*.yml; do
    [[ -e $workflow ]] || continue
    grep -qE '^  pull_request:' "$workflow" || continue
    grep -qE -- "--filter-tags ['\"]?image['\"]?([[:space:]]|$)" "$workflow" || continue
    covered=1
    for path in bootc/edge/Containerfile bootc/edge/rootfs/usr/share/smoresnet/Caddyfile bootc/lib/pins.env; do
      hit=0
      while IFS= read -r filter; do
        # shellcheck disable=SC2254 # the filter is a glob by design
        case $path in $filter) hit=1 ;; esac
      done < <(workflow_filters "$workflow")
      [[ $hit -eq 1 ]] || covered=0
    done
    [[ $covered -eq 1 ]] && return 0
  done
  return 1
}

# --- run ----------------------------------------------------------------------

check 'the Caddyfile validates at build and before every start' caddyfile_validated
check 'Caddy serves photos.sammohr.dev' serves photos.sammohr.dev
check 'Caddy serves opds.sammohr.dev' serves opds.sammohr.dev
check 'Caddy serves recovery.sammohr.dev' serves recovery.sammohr.dev
check 'Caddy proxies Immich to the Service upstream' proxies '{$IMMICH_UPSTREAM}'
check 'Caddy proxies OPDShelf to the Service upstream' proxies '{$OPDS_UPSTREAM}'
check 'Caddy proxies the recovery name to the loopback guard' proxies 'http://127.0.0.1:9898'
check 'Caddy never answers the HTTP-01 challenge' http01_never_answered
check 'Caddy has no admin API' admin_off
check 'Caddy serves exactly the three public names' exactly_three_names
check 'no site proxies 443' no_site_proxies_443
check 'no site answers plain HTTP' no_plain_http_site
check 'Caddy never binds port 80' no_port_80
check "the Caddy environment file is the operator's, at /etc/caddy/edge.env" operator_env_file
check 'the Caddyfile ships outside /etc' caddyfile_outside_etc
check 'the default firewalld zone is drop' default_zone_drop
check 'the public zone carries no service' public_zone_carries_no_service
check '443 is the only public service' public_zone_ports_are_the_reviewed_two
check '41641/udp is open for a direct WireGuard path' direct_wireguard_open
check '22 is never accepted from a public interface' no_public_ssh
check 'the tailnet interface is the only interface accepted' tailnet_is_the_only_interface
check 'the public zone accepts ICMP echo, by block inversion' public_zone_accepts_icmp_echo
check_build 'the shipped zones are parsed by firewalld at build' zones_parse_at_build
check 'sshd refuses passwords' sshd_refuses_passwords
check 'sshd refuses a root password login' sshd_refuses_a_root_password
check 'every unit the edge needs is enabled' units_enabled
check_build 'no secret, key or operator file is in the image' no_secret_in_the_image
check_build 'the base is a stream tag and the build records its digest' base_is_a_stream_tag
check_build 'a pull_request workflow runs this checker on the edge tree' pull_request_runs_this_checker

# The two verify.sh invariants the image cannot state, kept visible so the port is
# not mistaken for the whole of the provisioned box's proof.
note "Caddy's storage directory is writable by its user (runtime: created at first boot; provision/edge/verify.sh proves it)"
note 'unattended upgrades are on (runtime: bootc updates the image, T7/T10; nothing in an image to assert)'

# `bootc container lint` is the image's own analysis and only works inside it.
inside_image() { [[ -f /run/.containerenv || -f /.dockerenv ]]; }
if [[ $lint == no ]]; then
  note 'bootc container lint (disabled by --no-lint)'
elif ! command -v bootc >/dev/null 2>&1; then
  note 'bootc container lint (bootc is not installed; it runs inside the built image)'
elif [[ $lint != yes ]] && ! inside_image; then
  note 'bootc container lint (not inside the built image; run `podman run --rm <image> bootc container lint`)'
else
  check 'bootc container lint passes' bootc container lint
fi

printf '\n%d checks, %d failed\n' "$ran" "$failed"
((failed == 0))
