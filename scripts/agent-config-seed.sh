#!/usr/bin/env bash
# Seed each agent deployment's state dataset from the image, before the gateways
# and their facades start. Run by smortress-agent-config.service; never on its own.
#
# Per deployment (personal -> local, general -> general) this does three things:
#
#   1. copies the image's config template in *once* (`cp -n`), because the runtime
#      rewrites config.yaml and an operator edits the copy in the dataset, so
#      reconciling the template onto a live deployment at every boot would silently
#      revert both;
#   2. fills in the facade token while the template's `__FACADE_TOKEN__`
#      placeholder is still in the file, and only then -- a boot after the first
#      one finds no placeholder and rewrites nothing;
#   3. rewrites `.env`'s `API_SERVER_KEY` at every boot, because the runtime has no
#      `_FILE` variant and podman's `type=env` secret keeps the trailing newline the
#      decrypted file ends with, so a Bearer token taken from it never compares
#      equal. These keys are self-issued and revocable; the hosted provider key is
#      not here at all, it is in agent-proxy. The same reason writes `webui.env`:
#      the web UI takes its gateway key and its own password from the environment
#      and has no `_FILE` variant either.
#
# It also creates `<dataset>/memory` for each facade and `<dataset>/webui` with its
# `state` and `workspace` children for the web UI, plus `index` on the personal
# side for the facade's derived source index and the hledger projection's account
# mapping, seeded once from the image and never rewritten. Each container
# bind-mounts a subdirectory rather than the dataset root (the gateway's sessions,
# skills and .env are one level up), and a bind source podman has to create would
# land as root:root 0755 inside a dataset owned by uid 1000 at 0750 -- so the
# container's first write would fail on a directory it is supposed to own. Running
# `install -d` here every boot also re-applies the owner and mode to a directory a
# Restic restore left root-owned.
#
# The token never appears in this script's argv, in an environment variable of a
# child process, or in a log line: it is read with `read` from the decrypted file
# into a shell variable and written straight to the seeded config. `sed
# s|…|$(cat secret)|` is the shape to avoid: a command substitution's arguments are
# part of the process table, and `set -x` would print the whole command.
set -euo pipefail

secrets_dir=${SMORTRESS_SECRETS_DIR:-/run/smortress/secrets}
template_dir=${SMORTRESS_AGENT_TEMPLATE_DIR:-/etc/smortress/agent}
agent_root=${SMORTRESS_AGENT_ROOT:-/var/lib/agent}

#: The one value the image never carries. The template holds the placeholder; the
#: ciphertext holds the token; this script is the only place they meet.
readonly placeholder=__FACADE_TOKEN__
#: The Mirage token's placeholder. It is replaced with `Bearer <token>`, because
#: the workspace MCP route takes an Authorization header and the facade took a
#: header of its own.
readonly mirage_placeholder=__MIRAGE_TOKEN__

die() {
  echo "agent-config-seed: $*" >&2
  exit 1
}

# read_secret FILE -> the file's content, trailing newline dropped, on stdout.
read_secret() {
  local line value=
  while IFS= read -r line || [[ -n $line ]]; do
    value+=$line
  done <"$1"
  printf '%s' "$value"
}

# substitute_placeholder FILE TOKEN -> FILE on stdout with every placeholder
# replaced. The token is spliced in with parameter expansion, not as a sed or awk
# replacement string, so a `&`, `|` or `\` in a future token format stays literal.
substitute_placeholder() {
  local file=$1 token=$2 line rest
  while IFS= read -r line || [[ -n $line ]]; do
    rest=$line
    line=
    while [[ $rest == *"$placeholder"* ]]; do
      line+=${rest%%"$placeholder"*}${token}
      rest=${rest#*"$placeholder"}
    done
    printf '%s%s\n' "$line" "$rest"
  done <"$file"
}

for spec in personal:local general:general; do
  deployment=${spec%%:*}
  state=${spec##*:}
  home=$agent_root/$state
  config=$home/config.yaml
  template=$template_dir/$state-config.yaml
  facade_token=$secrets_dir/agent-facade-$deployment-token.yaml
  api_key=$secrets_dir/agent-$state-api-key.yaml
  ui_password=$secrets_dir/agent-ui-$deployment-password.yaml

  # A missing dataset means zfs-ready@state-agent-<deployment> did not run, and the
  # copy would land on the root filesystem: a gateway that starts against an empty
  # home that looks configured.
  [[ -d $home ]] || die "$home is missing; zfs-ready@state-agent-$state.service did not run"
  [[ -s $template ]] || die "the image has no config template for $state"
  [[ -s $api_key ]] || die "$api_key is missing; sops-decrypt did not produce it"
  [[ -s $ui_password ]] || die "$ui_password is missing; sops-decrypt did not produce it"

  cp -n "$template" "$config"
  chown 1000:1000 "$config"

  # Only a file that still carries the placeholder is rewritten, so the operator's
  # and the runtime's copy is untouched from the second boot on. Rotating a facade
  # token is therefore `sops`, then remove the seeded config.yaml, then reboot
  # (docs/manual-steps.md section 40.11).
  if grep -qF -- "$placeholder" "$config"; then
    [[ -s $facade_token ]] || die "$facade_token is missing; sops-decrypt did not produce it"
    token=$(read_secret "$facade_token")
    [[ -n $token ]] || die "$facade_token is empty"
    substitute_placeholder "$config" "$token" >"$config.new"
    install -o 1000 -g 1000 -m 0600 "$config.new" "$config"
    rm -f "$config.new"
    unset token
  fi

  sed 's/^/API_SERVER_KEY=/' "$api_key" >"$home/.env.new"
  install -o 1000 -g 1000 -m 0400 "$home/.env.new" "$home/.env"
  rm -f "$home/.env.new"

  # The web UI reads both of these from its environment and offers no `_FILE`
  # variant, so the values are written here and passed with EnvironmentFile=.
  # Builtins only: no `$(cat …)` in an external command's argv.
  ui_password_value=$(read_secret "$ui_password")
  [[ -n $ui_password_value ]] || die "$ui_password is empty"
  api_key_value=$(read_secret "$api_key")
  {
    printf 'HERMES_WEBUI_GATEWAY_API_KEY=%s\n' "$api_key_value"
    printf 'HERMES_WEBUI_PASSWORD=%s\n' "$ui_password_value"
  } >"$home/webui.env.new"
  install -o 1000 -g 1000 -m 0400 "$home/webui.env.new" "$home/webui.env"
  rm -f "$home/webui.env.new"
  unset api_key_value ui_password_value

  install -d -o 1000 -g 1000 -m 0750 "$home/memory" \
    "$home/replica" "$home/webui" "$home/webui/state" "$home/webui/workspace"
  # The source watcher's feed (SDLC #995): the one file the agent reads to learn
  # that a tree changed. Created here because the watcher unit runs with
  # ProtectSystem=strict and a directory Podman or systemd has to create would
  # land root-owned inside a dataset owned by uid 1000 at 0750.
  install -d -o 1000 -g 1000 -m 0750 "$home/watch"

  # The mail half and the derived index exist only on the personal side: every
  # raw collector is personal, and the general deployment has no source to
  # collect or index.
  if [[ $state == local ]]; then
    install -d -o 1000 -g 1000 -m 0750 "$home/quarantine"
    install -d -o 1000 -g 1000 -m 0750 "$home/index" "$home/index/hledger"
    # The projection's account mapping belongs to the operator, so it is seeded
    # once and never rewritten: `cp -n` leaves an edited copy alone at every boot,
    # and `{}` means every account renders as `assets:unknown:<id>` until someone
    # maps it. The unit always has a file to read, which is the point.
    cp -n "$template_dir/hledger-accounts.json" "$home/index/hledger/accounts.json"
    chown 1000:1000 "$home/index/hledger/accounts.json"
    # The bridge's own volume: the Tuta session, the GPG key that unseals it and
    # the TLS certificate a client verifies. 0700 because a copy of it is a copy
    # of the login; a client mounts only cert.pem out of it, as one file.
    install -d -o 1000 -g 1000 -m 0700 "$home/quarantine/tmail"
    # The calendar exporter's sealed session, and the directory it rewrites on
    # every run: the session is the account's access, the dump is disposable.
    install -d -o 1000 -g 1000 -m 0700 "$home/quarantine/tuta-calendar"
    install -d -o 1000 -g 1000 -m 0750 "$home/quarantine/calendar"
    # The browsing profile and the one copy of its History the collector reads.
    # 0700 for the profile because the Sync seed is planted in it and that seed is
    # the chain's key; 0750 for the snapshot because it is browsing history and is
    # replaced on every pass (docs/raw-replicas.md, "Brave").
    install -d -o 1000 -g 1000 -m 0700 "$home/quarantine/brave-profile"
    install -d -o 1000 -g 1000 -m 0750 "$home/quarantine/brave"
  fi

  # Mirage's home, its feed and its token (SDLC #979, T1). The home is the
  # daemon's state -- sessions, the ssh host key, snapshots -- so it is 0750 in
  # the dataset and never shared with the workspace's read paths; the feed is the
  # one directory the container mounts read-only.
  install -d -o 1000 -g 1000 -m 0750 "$home/mirage" "$home/mirage/feed"

  # The daemon has no `_FILE` variant and Podman's `type=env` secret keeps the
  # ciphertext's trailing newline, so the value is written here with the newline
  # dropped and passed with `EnvironmentFile=`. Rewritten every boot, so a
  # rotation lands on the next restart of mirage-personal.
  # Every deployment has its own workspace token, named for the deployment and
  # never shared: a leak on one side must not open the other. The file's name is
  # the only thing that differs, so the body is written once.
  {
    # Named literally, not built from $deployment: scripts/secrets-check.py holds
    # every manifest output to a consumer that names it, and a name assembled at
    # run time is invisible to that check.
    case $deployment in
      personal) mirage_token=$secrets_dir/mirage-personal-token.yaml ;;
      general) mirage_token=$secrets_dir/mirage-general-token.yaml ;;
      *) die "no workspace token for deployment $deployment" ;;
    esac
    [[ -s $mirage_token ]] || die "$mirage_token is missing; sops-decrypt did not produce it"
    mirage_token_value=$(read_secret "$mirage_token")
    [[ -n $mirage_token_value ]] || die "$mirage_token is empty"
    printf 'MIRAGE_AUTH_TOKEN=%s\n' "$mirage_token_value" >"$home/mirage.env.new"
    install -o 1000 -g 1000 -m 0400 "$home/mirage.env.new" "$home/mirage.env"
    rm -f "$home/mirage.env.new"

    # The gateway's MCP entry carries the same value as a bearer header. Only a
    # template that still has the placeholder is rewritten, for the same reason
    # config.yaml is seeded once.
    if grep -qF -- "$mirage_placeholder" "$config"; then
      substitute_placeholder "$config" "Bearer $mirage_token_value" "$mirage_placeholder" >"$config.new"
      install -o 1000 -g 1000 -m 0600 "$config.new" "$config"
      rm -f "$config.new"
    fi
    unset mirage_token_value
  }

  echo "agent-config-seed: $state is seeded" \
    "(config, .env, webui.env, memory, index, UI roots)"
done
