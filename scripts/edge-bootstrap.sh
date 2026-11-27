#!/usr/bin/env bash
# The one operator step on a freshly installed public edge (design #939, T10).
#
# It runs on the box as root, over the tailnet, after the edge image has booted.
# The image is the whole host, so what is left for a person is exactly what an
# image may not carry: the operator's Caddy values, the four plaintext secrets,
# the kit's SSH host key, the tailnet node identity and the first deploy record.
# The rest of provision/edge/bootstrap.sh -- packages, firewall, sshd policy, the
# Caddyfile, the units -- is image content now, and bootc/edge/tests/check.sh is
# what asserts it.
#
# The secrets arrive on stdin, never in argv: an argument is in
# /proc/<pid>/cmdline for every user on the box and in the shell's history, and a
# here-document is in neither. The document is KEY=value lines, each optional:
#
#   TS_AUTHKEY=tskey-auth-...     the preauthorized tag:vps join key
#   WEBHOOK_SECRET=...            the receiver's HMAC secret
#   WEBHOOK_SECRET_NEXT=...       the rotation window's secret, if any
#   DEPLOY_PING_URL=https://...   the dead-man capability URL
#
# A key the document omits leaves the file it belongs to alone, so a re-run with
# an empty stdin converges everything else and touches no secret. A value for a
# file that already holds a different one is a rotation, and rotation is --force.
# Nothing else is forced, because nothing else is the operator's to choose: the
# record is the descendancy anchor every later deploy is checked against, so a
# second bootstrap may not move it (`smortress-deploy reconcile` is the verb for
# a record that disagrees with the box); the node ID is what the tailnet says,
# never a name; and the four validations -- a tskey-shaped key, a one-line
# secret, a host key whose public half derives from its private half, and
# `caddy validate` -- are the gates that keep a bad value off the wire, not
# state a flag may overwrite.
#
#   sudo SMORTRESS_FQDN=smortress.<tailnet>.ts.net EDGE_ACME_EMAIL=you@example.com \
#     scripts/edge-bootstrap.sh <<'EOF'
#   TS_AUTHKEY=tskey-auth-...
#   WEBHOOK_SECRET=...
#   DEPLOY_PING_URL=https://hc-ping.com/...
#   EOF
#
# Idempotent: every step writes the same file, starts the same unit, or records
# the same commit, and the summary says what a re-run left alone.
#
# Every knob is environment-overridable so tests/deploy/edge-bootstrap.bats can
# drive this exact code against a throwaway tree. Production sets none of them.
#
# shellcheck disable=SC2154  # deploy-state.sh assigns its own variables at source time
set -euo pipefail
# Nothing this step writes is for anyone but the operator or the service that
# reads it; every mode below is explicit, and this is the net under one that is
# not.
umask 027

self_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# The image installs the output helpers as /usr/libexec/lib/log.sh; a checkout
# has them under scripts/lib.
_smolib=$self_dir/lib/log.sh
[[ -r $_smolib ]] || _smolib=/usr/libexec/lib/log.sh
[[ -r $_smolib ]] || {
  printf 'edge-bootstrap: no output library at %s\n' "$_smolib" >&2
  exit 1
}
# shellcheck source=/dev/null
source "$_smolib"

# The deploy state library is the only writer of state.json: the record shape,
# the journal line and the lock belong to the drain and the boot gate, and a
# second implementation here would be a record nothing else reads. The image
# installs it at /usr/libexec/deploy-state; a checkout has it beside this script.
_state_lib=$self_dir/deploy-state.sh
[[ -r $_state_lib ]] || _state_lib=/usr/libexec/deploy-state
[[ -r $_state_lib ]] || die "no deploy state library at $_state_lib"
# shellcheck source=/dev/null
source "$_state_lib"

bootc_bin=${BOOTC_BIN:-bootc}
ostree_bin=${OSTREE_BIN:-ostree}
ostree_repo=${OSTREE_REPO:-/sysroot/ostree/repo}
tailscale_bin=${TAILSCALE_BIN:-tailscale}
systemctl_bin=${SYSTEMCTL_BIN:-systemctl}
caddy_bin=${CADDY_BIN:-caddy}
ssh_keygen_bin=${SSH_KEYGEN_BIN:-ssh-keygen}
# The trees this step writes. The secrets directory is the listeners' own knob
# (`DEPLOY_SECRETS_DIR` in the edge units), so the file is written where the unit
# that reads it looks and there is no second place to keep in sync.
secrets_dir=${DEPLOY_SECRETS_DIR:-/etc/smoresnet}
state_dir=${EDGE_STATE_DIR:-/var/lib/smoresnet}
caddy_dir=${EDGE_CADDY_DIR:-/etc/caddy}
caddy_config=${EDGE_CADDY_CONFIG:-/usr/share/smoresnet/Caddyfile}
# caddy.service runs as User=caddy and reads the environment file it is given, so
# that file is root:caddy and nothing else may read it.
caddy_group=${EDGE_CADDY_GROUP:-caddy}
caddy_user=${EDGE_CADDY_USER:-caddy}
ssh_dir=${EDGE_SSH_DIR:-/etc/ssh}
edge_env=$caddy_dir/edge.env
authkey_file=$secrets_dir/tailscale-authkey
webhook_file=$secrets_dir/webhook-secret.yaml
webhook_next_file=$secrets_dir/webhook-secret-next.yaml
ping_file=$secrets_dir/deploy-ping-url
node_id_file=$state_dir/tailnet-node-id
# `tailscale up` lands seconds after the join unit starts, not with it, so the
# node-ID read retries inside a bounded budget and then refuses. A refusal is the
# point: a box that seeds a record and no node identity is a half-bootstrapped
# host nobody notices until the node has to be found in the admin console.
tailnet_wait=${EDGE_TAILNET_WAIT:-30}

document_keys='TS_AUTHKEY WEBHOOK_SECRET WEBHOOK_SECRET_NEXT DEPLOY_PING_URL'
# The four files a document key owns, and the prefix each one carries. The two
# webhook secrets are named .yaml and the receiver accepts either spelling; the
# `value:` form is the one the server's sops manifest and the receiver's own
# tests use, so one secret reads the same on both hosts. The ping URL is written
# bare because deploy_notify takes the first non-empty line as the URL itself.
declare -A target_path=(
  [TS_AUTHKEY]=$authkey_file
  [WEBHOOK_SECRET]=$webhook_file
  [WEBHOOK_SECRET_NEXT]=$webhook_next_file
  [DEPLOY_PING_URL]=$ping_file
)
declare -A target_prefix=(
  [TS_AUTHKEY]=''
  [WEBHOOK_SECRET]='value: '
  [WEBHOOK_SECRET_NEXT]='value: '
  [DEPLOY_PING_URL]=''
)
declare -A offered=()
declare -A seen=()

force=false
# Empty unless the operator names one: sshd's identity is the machine's own, and
# the edge has no plan that keeps a copy of it off the box (design #939: the
# tailnet node key is the identity that is pinned, by node ID, for the one thing
# that needs autonomous access).
host_key=''
commit_override=''

usage() { # [<exit>]
  cat >&2 <<'EOF'
usage: edge-bootstrap [--force] [--commit <40-hex>] [--host-key <path>]

  --force          replace a secret this step already wrote (rotation); the
                   state record, the node ID and every validation stay as they
  --commit <sha>   the commit the booted image was built from, for a host whose
                   image carries no revision label
  --host-key       install this ed25519 host key instead of keeping the one
                   sshd generated at first boot (not needed for a normal edge)

The secret document arrives on stdin: TS_AUTHKEY, WEBHOOK_SECRET,
WEBHOOK_SECRET_NEXT and DEPLOY_PING_URL, one KEY=value per line, all optional.
EOF
  exit "${1:-2}"
}

while (($#)); do
  case $1 in
    --force) force=true ;;
    --commit) commit_override=${2-}; shift ;;
    --commit=*) commit_override=${1#*=} ;;
    --host-key) host_key=${2-}; shift ;;
    --host-key=*) host_key=${1#*=} ;;
    -h | --help) usage 0 ;;
    *) usage ;;
  esac
  shift
done

# Every path below is root's, and `id -u` rather than $EUID so a test can drive
# the refusal without being root.
[[ $(id -u) == 0 ]] || die "run as root; it writes $secrets_dir, $caddy_dir and the SSH host key"

: "${SMORTRESS_FQDN:=}"
: "${EDGE_ACME_EMAIL:=}"
[[ -n $SMORTRESS_FQDN ]] ||
  die "set SMORTRESS_FQDN to the MagicDNS name of smortress (smortress.<tailnet>.ts.net)"
[[ -n $EDGE_ACME_EMAIL ]] || die "set EDGE_ACME_EMAIL for ACME expiry notices"
if [[ -n $commit_override && ! $commit_override =~ ^[0-9a-f]{40}$ ]]; then
  die "--commit takes the 40-character commit the image was built from, not '$commit_override'"
fi

# Each application answers on a Tailscale Service of its own (`svc:immich`,
# `svc:opds`, `svc:recovery`), so the upstream is `<service>.<tailnet>.ts.net` and
# never the host's own name: the host's 443 also carries the agent gateway APIs
# and /wallpapers, and a Service publishes one application with no path prefix.
# The tailnet domain is derived, not hardcoded: the first label of SMORTRESS_FQDN
# is the host and the rest is the tailnet.
tailnet_domain=${SMORTRESS_FQDN#*.}
# A suffix with no dot is not a tailnet name, and an upstream built from it would
# be a 502 that looks like the application is down.
[[ $tailnet_domain == *.* ]] ||
  die "SMORTRESS_FQDN '$SMORTRESS_FQDN' has no tailnet domain (want smortress.<tailnet>.ts.net)"
IMMICH_UPSTREAM=https://immich.$tailnet_domain
OPDS_UPSTREAM=https://opds.$tailnet_domain
RECOVERY_UPSTREAM=https://recovery.$tailnet_domain

# read_document: the secret document off stdin, into $offered.
#
# Every value is validated here and nothing is written until all four have been
# read and checked, so a mistyped key or a truncated paste leaves the box exactly
# as it was instead of half-bootstrapped. No refusal below ever echoes a value: a
# capability URL in a log is a capability URL in a log.
read_document() {
  local line key value
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    [[ -n ${line//[[:space:]]/} ]] || continue
    # The line is not echoed: whatever it is, it is as likely to be the secret
    # without its key as a typo, and this message goes into the operator's scroll
    # buffer and the journal.
    [[ $line == *=* ]] || die "a stdin line is not KEY=value; the document is one KEY=value per line"
    key=${line%%=*}
    value=${line#*=}
    case $key in
      TS_AUTHKEY | WEBHOOK_SECRET | WEBHOOK_SECRET_NEXT | DEPLOY_PING_URL) ;;
      *) die "stdin key '$key' is not one of: $document_keys" ;;
    esac
    [[ -z ${seen[$key]:-} ]] || die "$key appears twice on stdin"
    seen[$key]=1
    offered[$key]=$value
  done
}

validate_document() {
  local key value
  # A key the operator wrote with nothing after it is a paste that lost its
  # value, not a request to keep the file: omitting the line is how a re-run keeps
  # it. The rotation secret is the exception, since its blank means "none".
  for key in $document_keys; do
    [[ -z ${seen[$key]:-} ]] && continue
    [[ $key == WEBHOOK_SECRET_NEXT ]] && continue
    [[ -n ${offered[$key]} ]] || die "$key is blank; omit the line to keep the file it belongs to"
  done
  value=${offered[TS_AUTHKEY]:-}
  if [[ -n $value ]]; then
    # A key that is not tskey-shaped is a paste error or an unrelated token, and
    # tailscaled is where that would fail: a node that never enrolled and nothing
    # on this box saying why.
    [[ $value =~ ^tskey-[a-z]+-[A-Za-z0-9_-]+$ ]] ||
      die "TS_AUTHKEY is not a tailnet auth key (want tskey-auth-...)"
  fi
  for key in $document_keys; do
    value=${offered[$key]:-}
    [[ -n $value ]] || continue
    # One value is one line: a secret with a newline in it would be a file whose
    # second line the receiver reads as YAML, or a ping URL with a suffix.
    [[ $value != *[[:space:]]* ]] || die "$key carries whitespace; its file holds one value on one line"
  done
  value=${offered[DEPLOY_PING_URL]:-}
  if [[ -n $value && $value != https://* ]]; then
    # deploy_notify appends /fail to it, so a plaintext or schemeless value pages
    # nothing while looking configured.
    die "DEPLOY_PING_URL is not an https:// URL"
  fi
}

# check_secrets: what the document asks for, against what is already there. Runs
# before the first write, so a missing secret or an unforced rotation changes
# nothing at all.
check_secrets() {
  local key path want current missing=''
  for key in $document_keys; do
    path=${target_path[$key]}
    want=${target_prefix[$key]}${offered[$key]:-}
    if [[ -z ${offered[$key]:-} ]]; then
      # The rotation secret is optional by definition; the other three are the
      # box's minimum to work at all.
      if [[ ! -s $path && $key != WEBHOOK_SECRET_NEXT ]]; then
        missing="$missing $key"
      fi
      continue
    fi
    [[ -s $path ]] || continue
    current=$(cat -- "$path")
    [[ $current == "$want" ]] && continue
    if ! $force; then
      die "$path already holds a different value; --force rotates a secret this step wrote"
    fi
  done
  [[ -z $missing ]] || die "stdin is missing$missing and there is no file to keep"
}

write_secrets() {
  local key path want
  install -d -m 0700 "$secrets_dir" || die "cannot create $secrets_dir"
  for key in $document_keys; do
    [[ -n ${offered[$key]:-} ]] || continue
    path=${target_path[$key]}
    want=${target_prefix[$key]}${offered[$key]}
    if [[ -s $path && $(cat -- "$path") == "$want" ]]; then
      say "$path already holds this value; left alone"
      continue
    fi
    # atomic_write is the state library's 0600 rename: temp file, fsync, rename,
    # directory fsync. A listener that restarted mid-write would otherwise read a
    # half-written HMAC key and refuse to start.
    printf '%s\n' "$want" | atomic_write "$path" || die "cannot write $path"
    say "wrote $path (0600)"
  done
}

# caddy_validate runs the unit's own ExecStartPre with the values about to be
# installed, before the file they belong to is replaced: a bad environment must
# never take down a proxy that is serving three public names. Caddy substitutes
# the environment at parse time, so an exported value and the file it will read
# are the same input.
caddy_validate() {
  (
    export SMORTRESS_FQDN EDGE_ACME_EMAIL IMMICH_UPSTREAM OPDS_UPSTREAM RECOVERY_UPSTREAM
    "$caddy_bin" validate --config "$caddy_config" --adapter caddyfile >/dev/null
  ) || die "$caddy_bin refused $caddy_config with these values; $edge_env is unchanged"
}

write_edge_env() {
  local tmp
  # The directory has to be traversable by the caddy user, which the environment
  # file's own 0640 root:caddy does not make it: a 0750 root:root directory locks
  # the service out of the file it is told to read.
  install -d -m 0755 "$caddy_dir" || die "cannot create $caddy_dir"
  tmp=$(mktemp "$caddy_dir/.edge.env.XXXXXX") || die "cannot create a temporary file in $caddy_dir"
  {
    printf 'SMORTRESS_FQDN=%s\n' "$SMORTRESS_FQDN"
    printf 'EDGE_ACME_EMAIL=%s\n' "$EDGE_ACME_EMAIL"
    printf 'IMMICH_UPSTREAM=%s\n' "$IMMICH_UPSTREAM"
    printf 'OPDS_UPSTREAM=%s\n' "$OPDS_UPSTREAM"
    printf 'RECOVERY_UPSTREAM=%s\n' "$RECOVERY_UPSTREAM"
  } >"$tmp" || {
    rm -f -- "$tmp"
    die "cannot write $tmp"
  }
  chgrp "$caddy_group" "$tmp" || {
    rm -f -- "$tmp"
    die "cannot give $tmp to group $caddy_group"
  }
  chmod 0640 "$tmp"
  mv -f -- "$tmp" "$edge_env" || die "cannot install $edge_env"
}

# The boot gate and the verifier read state.json for the commit and the digests,
# and neither can derive them from a box whose record is empty: the commit is the
# descendancy anchor, so every deploy is refused with `bootstrap-required` until
# something records it. This is that something, once.
#
# The commit is not in the bootc JSON: bootc reports the digest, the ostree
# checksum and the image's version, and the commit lives in the revision label of
# the image config bootc reads that version from. --commit is the way out for a
# host whose image carries no revision label or that has no ostree CLI.
image_revision() { # <bootc-status-document>
  local checksum config
  checksum=$(jq -er '.status.booted.ostree.checksum // empty' <<<"$1" 2>/dev/null) || return 1
  [[ -n $checksum ]] || return 1
  command -v "$ostree_bin" >/dev/null 2>&1 || return 1
  config=$(timeout --signal=TERM --kill-after=10 30 \
    "$ostree_bin" --repo="$ostree_repo" show \
    --print-metadata-key=ostree.container.image-config "$checksum" 2>/dev/null) || return 1
  # ostree prints the value as the JSON string it holds; a value that is already
  # the object parses as itself.
  jq -er 'if type == "string" then fromjson else . end
    | .config.Labels["org.opencontainers.image.revision"] // empty' <<<"$config" 2>/dev/null
}

seed_state() {
  local doc booted commit recorded
  doc=$(timeout --signal=TERM --kill-after=10 30 "$bootc_bin" status --booted --json 2>/dev/null) ||
    die "cannot read $bootc_bin status --booted"
  booted=$(jq -er '.status.booted.image.imageDigest // empty' <<<"$doc" 2>/dev/null) || booted=''
  [[ $booted =~ ^sha256:[0-9a-f]{64}$ ]] ||
    die "no booted image digest in $bootc_bin status; a record without one is a deployment nothing can judge"

  commit=$commit_override
  if [[ -z $commit ]]; then
    commit=$(image_revision "$doc") || commit=''
  fi
  [[ $commit =~ ^[0-9a-f]{40}$ ]] ||
    die "cannot read the commit this image was built from; re-run with --commit <40-hex>"

  recorded=$(deployed_commit homelab-platform 2>/dev/null) || recorded=''
  if [[ -n $recorded ]]; then
    # Never rewritten, not even with --force: the recorded commit is what every
    # later deploy must descend from, and moving it by hand is the history rewrite
    # the descendancy check exists to prevent. A record that disagrees with the
    # box is `smortress-deploy reconcile --commit $commit`'s job.
    say "state.json already records homelab-platform at $recorded; left alone"
    [[ $recorded == "$commit" ]] ||
      warn "this host booted $commit, not $recorded; the record is not moved here"
    return 0
  fi

  deploy_state_init || die "cannot create $deploy_state_dir"
  deploy_lock_acquire 60 || die "another drain holds $deploy_lock_file; nothing was recorded"
  # bootc reports the digest it fetched, which is the platform manifest; the index
  # digest only exists in a registry tag resolution, and the next real deploy is
  # what records both forms. The record shape itself is the library's.
  journal_append bootstrap-recorded \
    "$(jq -nc --arg repo homelab-platform --arg commit "$commit" \
      --arg by "${SUDO_USER:-$(id -un)}" \
      '{repo:$repo,commit:$commit,operator:$by}')" ||
    {
      deploy_lock_release
      die "cannot journal the bootstrap; the state is unchanged"
    }
  state_record_verified homelab-platform "$commit" '' "$booted" || {
    deploy_lock_release
    die "cannot record homelab-platform at $commit"
  }
  deploy_lock_release
  say "recorded homelab-platform at $commit ($booted)"
}

# The kit's host key is the box's identity across rebuilds: without it sshd
# generates a new pair on every install and every client's known_hosts entry goes
# stale, which the operator can only fix from a console they cannot verify. The
# key is read from a path the operator names, and its public half is derived here
# rather than trusted: a kit whose two halves disagree would install an identity
# the kit does not name.
install_host_key() {
  local derived tmp
  if [[ -z $host_key ]]; then
    # The box keeps the ed25519 pair sshd made for itself at first boot. That is
    # the whole identity this host needs: logins arrive over the tailnet, whose
    # node key is what authenticates the machine, and the pre-join window is
    # minutes of key-only sshd. Carrying a copy in a recovery kit bought a stable
    # `known_hosts` line and cost a credential that had to be fetched, trusted and
    # rotated; the rebuild drill is what showed the trade is not worth it.
    say "keeping the host key sshd generated: no --host-key was given"
    return 0
  fi
  [[ -r $host_key ]] ||
    die "no host key at $host_key; pass a readable ed25519 private key or omit --host-key"
  # stdin closed: a passphrase-protected key would prompt, and a host key that
  # needs a person to type at boot is a key sshd cannot use.
  derived=$("$ssh_keygen_bin" -y -f "$host_key" </dev/null 2>/dev/null) ||
    die "$host_key is not a key $ssh_keygen_bin can read without a passphrase"
  [[ $derived == 'ssh-ed25519 '* ]] || die "$host_key is not an ed25519 key"
  if [[ -r $host_key.pub ]]; then
    [[ $(awk '{ print $1" "$2 }' <<<"$derived") == $(awk '{ print $1" "$2 }' "$host_key.pub") ]] ||
      die "$host_key.pub does not match the public key $host_key derives"
  fi
  install -d -m 0755 "$ssh_dir" || die "cannot create $ssh_dir"
  install -m 0600 "$host_key" "$ssh_dir/ssh_host_ed25519_key" ||
    die "cannot install $ssh_dir/ssh_host_ed25519_key"
  tmp=$(mktemp "$ssh_dir/.ssh_host_ed25519_key.pub.XXXXXX") || die "cannot create a temporary file in $ssh_dir"
  printf '%s\n' "$derived" >"$tmp"
  chmod 0644 "$tmp"
  mv -f -- "$tmp" "$ssh_dir/ssh_host_ed25519_key.pub" ||
    die "cannot install $ssh_dir/ssh_host_ed25519_key.pub"
  # ed25519 is the only host key the kit holds. An rsa or ecdsa pair the base
  # generated at first boot is a second identity no client has ever verified, and
  # sshd presents every pair it finds.
  rm -f -- "$ssh_dir/ssh_host_rsa_key" "$ssh_dir/ssh_host_rsa_key.pub" \
    "$ssh_dir/ssh_host_ecdsa_key" "$ssh_dir/ssh_host_ecdsa_key.pub"
  # A restart, not a reload: a reload keeps the host keys sshd already holds in
  # memory, which is the one thing this step has to change. Sessions already
  # established are not dropped by it.
  "$systemctl_bin" restart sshd || die "cannot restart sshd"
  say "installed $ssh_dir/ssh_host_ed25519_key from $host_key and restarted sshd"
}

# tailnet_node_id: the node's ID once the daemon is running, or a refusal.
#
# The ID, never the name `smoresnet`: a name is freed the moment the old node is
# deleted in the admin console, so the replacement can be raced onto it, and the
# ACL and the rebuild drill both need the identity that cannot be taken over.
tailnet_node_id() {
  local deadline status
  tailnet_id=''
  tailnet_state=''
  deadline=$(($(date +%s) + tailnet_wait))
  while :; do
    if status=$("$tailscale_bin" status --json 2>/dev/null); then
      tailnet_state=$(jq -r '.BackendState // ""' <<<"$status" 2>/dev/null) || tailnet_state=''
      tailnet_id=$(jq -r '.Self.ID // ""' <<<"$status" 2>/dev/null) || tailnet_id=''
      [[ $tailnet_state == Running && -n $tailnet_id ]] && return 0
    fi
    (($(date +%s) >= deadline)) && return 1
    sleep 1
  done
}

pin_node_id() {
  tailnet_node_id ||
    die "the tailnet is not up (${tailnet_state:-no answer from $tailscale_bin}); smoresnet-tailscale-up.service writes /var/lib/smoresnet/tailscale-enrolled only after 'tailscale up' succeeds -- read journalctl -u smoresnet-tailscale-up.service, then re-run"
  install -d -m 0700 "$state_dir" || die "cannot create $state_dir"
  printf '%s\n' "$tailnet_id" | atomic_write "$node_id_file" || die "cannot write $node_id_file"
  say "pinned tailnet node $tailnet_id in $node_id_file"
}

read_document
validate_document
check_secrets

caddy_validate
write_edge_env
# Caddy runs as User=caddy and keeps its account key and certificates under
# /var/lib/caddy. The image creates that directory at boot
# (/etc/tmpfiles.d/smoresnet-edge.conf, 0750 caddy:caddy), and this repeats it at
# the same mode and owner so a box that lost the fragment -- or whose data
# directory came back from the recovery kit under another account -- serves
# before the next boot, not after it. `install -d` on an existing directory of
# the same owner and mode changes nothing, which is what keeps this idempotent.
caddy_home=${EDGE_CADDY_HOME:-/var/lib/caddy}
install -d -o "$caddy_user" -g "$caddy_group" -m 0750 "$caddy_home" ||
  die "cannot create $caddy_home for $caddy_group"
# The unit is skipped until this file exists (ConditionPathExists), so a restart
# is what brings it up; on a box already serving, the restart is also how a
# changed upstream or name reaches Caddy, since `admin off` leaves no reload.
"$systemctl_bin" restart caddy || die "cannot restart caddy"
say "wrote $edge_env (0640 root:$caddy_group) and restarted caddy"

write_secrets
# The join unit reads the key as a systemd credential, not from the command line,
# and is conditioned on the file: the key has to be installed before the start
# that runs `tailscale up` with it. The key stays on the box because the unit
# re-runs on every boot until it has enrolled, and the operator rotates it by
# re-running this step rather than by leaving a reusable credential behind.
"$systemctl_bin" start smoresnet-tailscale-up.service ||
  die "cannot start smoresnet-tailscale-up.service"
say "started smoresnet-tailscale-up.service"
# The forward is conditioned on the enrollment marker, so a boot before the join
# skipped it. Starting it here is what makes the receiver reachable on the tailnet
# in the same run that enrolled the box, rather than after the next reboot.
if [[ -e $state_dir/tailscale-enrolled ]]; then
  "$systemctl_bin" start smoresnet-deploy-forward.service ||
    die "cannot start smoresnet-deploy-forward.service; a notify job cannot reach the receiver until it runs"
  say "started smoresnet-deploy-forward.service (the receiver is on the tailnet)"
fi

install_host_key
pin_node_id
seed_state

say "bootstrap complete; this box now holds"
note "  $edge_env  SMORTRESS_FQDN, EDGE_ACME_EMAIL and the three Service upstreams"
note "  $secrets_dir  the auth key, the webhook secret (and its rotation), the ping URL"
if [[ -n $host_key ]]; then
  note "  $ssh_dir/ssh_host_ed25519_key  the host key you named, installed for sshd"
else
  note "  $ssh_dir/ssh_host_ed25519_key  the identity sshd generated; logins are over the tailnet"
fi
note "  $node_id_file  the tailnet node ID, pinned by ID and not by name"
note "  $deploy_state_file  homelab-platform at the booted commit and digest"
say "still the operator's"
note "  1. scripts/verify-public-edge.sh from a checkout: all three names over TLS, each"
note "     answering as its own application, with certificates above 14 days."
note "  2. tofu before that probe: if this box's public IPv4 is not the one committed in"
note "     tofu/terraform.tfvars, update edge_ipv4, commit and apply first -- the probe"
note "     resolves the three names, and until the records move they answer for whatever"
note "     they point at now. The tailnet policy is applied before the join key is minted,"
note "     for the same reason: a key can only carry a tag its owner may apply."
