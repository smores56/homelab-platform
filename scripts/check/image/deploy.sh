# shellcheck shell=bash
# shellcheck disable=SC2016,SC2034,SC2154  # helpers and globals come from the entrypoint
# The feature installs no distribution package: graph and signature questions are
# answered by the GitHub API and bootc's own policy, so the only dnf run in the
# build is the discarded sudo-build stage.
# The last `FROM ${BASE_IMAGE}` is the image, and it may be named (`AS runtime`);
# the earlier one is a discarded build stage, so taking the first match -- or
# refusing to match a named stage -- looks for a package install in the wrong half
# of the file, or fails a correct edit.
runtime_stage_is_clean() { # <containerfile>
  local line
  line=$(grep -nE '^FROM \$\{BASE_IMAGE\}([[:space:]]+AS[[:space:]]+[A-Za-z0-9_.-]+)?[[:space:]]*$' "$1" |
    tail -n 1 | cut -d: -f1)
  [[ -n $line ]] || return 1
  ! awk -v start="$line" 'NR > start && /dnf/' "$1" | grep -q .
}
check "the runtime stage installs no distribution package" \
  runtime_stage_is_clean image/Containerfile
stage_fixture=$(mktemp -d)
printf 'FROM ${BASE_IMAGE} AS sudo-build\nRUN dnf install -y git\nFROM ${BASE_IMAGE} AS runtime\nCOPY image/rootfs/ /\n' \
  >"$stage_fixture/Containerfile"
if runtime_stage_is_clean "$stage_fixture/Containerfile"; then
  ok "a named final stage is still the runtime stage"
else
  bad "a named final stage is still the runtime stage"
fi
printf 'RUN dnf install -y git\n' >>"$stage_fixture/Containerfile"
if runtime_stage_is_clean "$stage_fixture/Containerfile"; then
  bad "a package install in the runtime stage is still refused"
else
  ok "a package install in the runtime stage is still refused"
fi
rm -rf "$stage_fixture"

# A deploy change that does not rebuild the image ships a commit whose host code
# is the previous build's, because the image is the only delivery. Every file the
# receiver ships must therefore sit under a publish path filter. The entry may be
# quoted, single-quoted or bare -- the YAML quoting is not the assertion, the
# coverage is -- so the match is on the glob, not on one spelling of it.
publish_covers() { # <workflow> <top-level dir>
  grep -qE "^[[:space:]]*-[[:space:]]*[\"']?$2/\\*\\*[\"']?[[:space:]]*$" "$1"
}
path_fixture=$(mktemp -d)
for entry in '"scripts/**"' "'scripts/**'" 'scripts/**'; do
  printf '    paths:\n      - %s\n' "$entry" >"$path_fixture/workflow.yml"
  if publish_covers "$path_fixture/workflow.yml" scripts; then
    ok "the path filter accepts the entry $entry"
  else
    bad "the path filter accepts the entry $entry"
  fi
done
printf '    paths:\n      - "scripts/deploy-*.sh"\n' >"$path_fixture/workflow.yml"
if publish_covers "$path_fixture/workflow.yml" scripts; then
  bad "a partial path entry does not cover the directory"
else
  ok "a partial path entry does not cover the directory"
fi
rm -rf "$path_fixture"
publish=.github/workflows/publish-server-image.yml
deploy_files=()
while IFS= read -r file; do deploy_files+=("$file"); done < <(
  printf '%s\n' scripts/deploy-*.sh scripts/smortress-boot-gate.sh image/rootfs/usr/libexec/deploy-*.py \
    image/rootfs/usr/share/smortress/deploy-units.txt \
    image/rootfs/usr/lib/bootupd/grub2-static/configs.d/10-smortress-count.cfg \
    units/systemd/smortress-deploy* units/systemd/smortress-boot-gate.service \
    secrets/boot.json
)
unpublished=
for file in "${deploy_files[@]}"; do
  if [[ ! -e $file ]]; then
    unpublished+="$file(missing) "
    continue
  fi
  publish_covers "$publish" "${file%%/*}" || unpublished+="$file "
done
if [[ -n $unpublished ]]; then
  bad "every file the receiver ships rebuilds the image: $unpublished"
else
  ok "every file the receiver ships rebuilds the image"
fi

# Every timer this image ships must be enabled here, or it silently never fires.
for timer in units/systemd/*.timer; do
  unit=${timer#units/systemd/}
  pattern="^[[:space:]]*${unit//./\\.}([[:space:]]|;)"
  check "image enables $unit" grep -qE "$pattern" image/Containerfile
done

# Serve topology (review finding G1 of design #748). The wallpaper library is the
# fourth core route and the only one that is not a loopback port: an absolute
# directory target on 443 makes Serve publish it as static files, and a client
# that carries no credential fetches it as `<tailnet>/wallpapers/`. The route
# therefore has to be declared here rather than in a runbook, and the stale-route
# pruning has to stay scoped to the tenant paths.
serve_script=scripts/tailscale-serve.sh
check "Serve declares the wallpaper library as static files" \
  has "serve --bg --https=443 --set-path=/wallpapers \"\$wallpapers\"" "$serve_script"
# The receiver's forward is declared with the core routes: a CI notification has to
# arrive on a host whose tenant plan is unreadable, and a `--tcp` forward is not a
# Web handler, so the `/apps/` prune below cannot remove it.
check "Serve forwards the deploy receiver's loopback port" \
  has 'serve --bg --tcp=8484 tcp://127.0.0.1:8484' "$serve_script"
check "the wallpaper library is the dataset mount point" has 'WALLPAPERS_DIR:-/srv/wallpapers' "$serve_script"
check "stale-route pruning only considers tenant handlers" \
  has 'select(startswith("/apps/"))' "$serve_script"
# Declarative in this script is not declarative in tailscaled: a handler keeps
# answering after the declaration that made it is gone, so a port that a later
# version stops declaring -- the two host ports the edge read before it used the
# Services -- is turned off here or it lingers for good.
check "a port that left core_routes is turned off on the next run" \
  has 'serve --https="$port" off' "$serve_script"
# The same for the other map: a Service whose declaration is gone keeps its handler
# until something clears it, and `svc:agent-ui` answered a Caddy that no longer
# exists long after its Service left the tailnet. A host `off` cannot retire a
# Service, so the pin is on `clear` and on the index it is compared with.
check "a Service that left the declarations is cleared on the next run" \
  has 'serve clear "$name"' "$serve_script"
check "the Services reconcile reads the declared index" \
  has 'declared_services=(' "$serve_script"
if grep -qE -- '--set-path=/wallpapers[^ ]* .*off' "$serve_script"; then
  bad "pruning never removes the wallpaper route"
else
  ok "pruning never removes the wallpaper route"
fi
check "the Serve unit is ordered after the wallpapers dataset is ready" \
  grep -qE '^After=.*zfs-ready@raw-wallpapers\.service' units/systemd/smortress-tailscale-serve.service

# The web terminal (#954) is a session host, so the unit has to hide nothing its
# panes use: the zellij binary, its config and its token database all come from
# the owner's home, the shims need a writable /tmp, and sudo in a pane needs the
# setuid bit NoNewPrivileges would block. The socket directory is the one an SSH
# login resolves, so a browser attaches to the sessions an SSH client started.
terminal_unit=units/systemd/smortress-zellij-web.service
check "the image enables the web terminal" \
  grep -qE '^[[:space:]]+smortress-zellij-web\.service[[:space:]]*\\?$' image/Containerfile
check "the terminal listens on loopback only" \
  has 'web --ip 127.0.0.1 --port 8082' "$terminal_unit"
check "the terminal shares the fixed socket directory" \
  has 'Environment=ZELLIJ_SOCKET_DIR=/run/zellij' "$terminal_unit"
check "the terminal puts the mise shims first on PATH" \
  has 'Environment=PATH=/var/home/smores/.local/share/mise/shims:' "$terminal_unit"
check "the terminal creates main after the server starts" \
  has 'ExecStartPost=-/var/home/smores/.local/share/mise/shims/zellij attach main --create-background' "$terminal_unit"
check "the terminal keeps session daemons across a restart" \
  grep -qx 'KillMode=process' "$terminal_unit"
if grep -qE '^(ProtectHome=(yes|strict|tmpfs)|PrivateTmp=yes|NoNewPrivileges=yes)$' "$terminal_unit"; then
  bad "the terminal unit hides nothing its panes need"
else
  ok "the terminal unit hides nothing its panes need"
fi
check "the terminal owns the socket directory as its runtime directory" \
  has 'RuntimeDirectory=zellij' "$terminal_unit"
check "the terminal keeps the socket directory across a stop" \
  grep -qx 'RuntimeDirectoryPreserve=yes' "$terminal_unit"

# shellcheck source=app-images.sh disable=SC1091
source scripts/app-images.sh
# A table entry is used either as a Quadlet's Image= or as an argument of a
# hand-written unit that runs podman itself (the collectors), and both must name
# the signed mirror at the pinned digest rather than a tag.
for name in $(app_image_names); do
  ref=$(app_image_ref "$name")
  # A hand-written unit names the image on its own continuation line, so the
  # match is anchored: a comment that mentions the reference is not a run.
  pattern="^[[:space:]]+$(printf '%s' "$ref" | sed 's/\\./\\\\./g')[[:space:]]+\\\\$"
  if grep -qF -- "Image=$ref" units/quadlet/*.container ||
     grep -qE "$pattern" units/systemd/*.service; then
    ok "$name runs the signed mirror at its pinned digest"
  else
    bad "$name runs the signed mirror at its pinned digest"
  fi
done
# Agent deployments (#711). The hosted proxy is the one program that holds a
# provider credential, so the checks that matter are that it is the program its
# own image ships, that its upstream cannot be moved at runtime, and that the GPU
# device is declared with the SELinux type the driver needs.
check "the runtime image installs the agent proxy" \
  has 'apps/agent_proxy/proxy.py /usr/libexec/agent-proxy' images/agent-runtime/Containerfile
check "the runtime image makes the agent proxy executable" \
  has 'chmod 0755 /usr/libexec/agent-proxy' images/agent-runtime/Containerfile
# `COPY image/rootfs/ /` is what puts these in the image, so a template that is
# missing from the tree is missing from the image.
check "image rootfs carries the agent config templates" \
  test -s image/rootfs/etc/smortress/agent/local-config.yaml -a -s image/rootfs/etc/smortress/agent/general-config.yaml
for template in local-config.yaml general-config.yaml; do
  # The image ships them through `COPY image/rootfs/ /`, so a template that is not
  # tracked here is not in the image either.
  check "the agent template $template exists" test -s "image/rootfs/etc/smortress/agent/$template"
  # Any `api_key:` with a value would put a credential in a template that both
  # gateways receive.
  if grep -qE '^[[:space:]]*api_key:[[:space:]]*[^[:space:]]' \
      "image/rootfs/etc/smortress/agent/$template"; then
    bad "the agent template $template carries no api key"
  else
    ok "the agent template $template carries no api key"
  fi
done
check "the proxy pins its upstream as a constant" has 'UPSTREAM_HOST = "api.neuralwatt.com"' apps/agent_proxy/proxy.py
# A runtime knob for the host would be the same hole as a request field.
if grep -qE 'environ\[.*(UPSTREAM|PROVIDER)' apps/agent_proxy/proxy.py ||
  grep -qE 'os\.environ\.get\("AGENT_PROXY_UPSTREAM' apps/agent_proxy/proxy.py; then
  bad "the proxy's upstream is not configurable at runtime"
else
  ok "the proxy's upstream is not configurable at runtime"
fi
check "the proxy reads its key from a file" has 'DEFAULT_KEY_FILE = "/run/secrets/agent-hosted-key"' apps/agent_proxy/proxy.py
check "the model container requires the CDI spec unit" \
  grep -qE '^Requires=.*smortress-nvidia-cdi\.service' units/quadlet/agent-model.container
check "the model container is ordered after the CDI spec unit" \
  grep -qE '^After=.*smortress-nvidia-cdi\.service' units/quadlet/agent-model.container
check "the CDI unit runs the documented command" \
  has 'nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml' units/systemd/smortress-nvidia-cdi.service
for unit in smortress-nvidia-cdi.service smortress-agent-config.service \
  smortress-selinux-nvidia-map.service; do
  check "image enables $unit" has "$unit" image/Containerfile
done
# shellcheck disable=SC2016  # the matched text is a line of the seed script
probe "agent config seeding is idempotent" grep -qF 'cp -n "$template" "$config"' scripts/agent-config-seed.sh
# The hledger projection's account mapping is seeded from the image the same way,
# so the template is what an operator's copy starts from and must ship with it.
check "image rootfs carries the hledger account mapping" \
  test -s image/rootfs/etc/smortress/agent/hledger-accounts.json
# shellcheck disable=SC2016  # the matched text is a line of the seed script
probe "the hledger mapping is seeded once and never overwritten" \
  grep -qF 'cp -n "$template_dir/hledger-accounts.json"' scripts/agent-config-seed.sh
# The seed work moved from an ExecStart one-liner into the script, because splicing
# a token into a YAML file from a unit line would put it in the process table.
check "the image installs the seed script" has 'scripts/agent-config-seed.sh' image/Containerfile
check "the seed unit runs the installed script" \
  has 'ExecStart=/usr/libexec/agent-config-seed' units/systemd/smortress-agent-config.service

# The source facades (T2b), the collectors and the hosted proxy live in the
# agent-runtime image (images/agent-runtime/Containerfile, publish-agent-runtime.yml),
# not here: this image must carry no copy of them, which is what keeps an agent-code
# change off the OS rebuild path. The units import them from the image and mount
# nothing from the host, so there is no second copy to drift.
for path in 'apps/agent_facade' 'apps/brave_ingest' 'apps/agent_proxy' \
  'libs/data_plane' '/usr/lib/agent-facade' '/usr/libexec/agent-proxy'; do
  check "the host image ships no $path" lacks "$path" image/Containerfile
done
for q in units/quadlet/agent-facade-personal.container units/quadlet/agent-facade-general.container; do
  check "$q mounts no host copy of the facade" lacks 'Volume=/usr/lib/agent-facade' "$q"
done
check "the proxy unit mounts no host copy of its program" \
  lacks 'Volume=/usr/libexec/agent-proxy' units/quadlet/agent-proxy.container
for unit in units/systemd/smortress-agent-brave-seed.service \
  units/systemd/smortress-agent-collect-brave.service; do
  check "$unit mounts no host copy of the tree" lacks '--volume /usr/lib/agent-facade' "$unit"
done
# The programs' own list has to be complete in the image that does carry them: a
# module left out is an import error at the first start.
for module in apps/agent_facade/*.py apps/brave_ingest/*.py; do
  check "the runtime image installs ${module#apps/}" \
    has "$module" images/agent-runtime/Containerfile
done
check "the runtime image installs the facade libraries" \
  has 'libs/data_plane/ /usr/lib/agent-facade/libs/data_plane/' images/agent-runtime/Containerfile
check "the runtime image installs the proxy" \
  has 'apps/agent_proxy/proxy.py /usr/libexec/agent-proxy' images/agent-runtime/Containerfile
if grep -qE '^COPY.*apps/(agent_facade|agent_proxy)/tests' \
  images/agent-runtime/Containerfile; then
  bad "the runtime image ships no test suite"
else
  ok "the runtime image ships no test suite"
fi
check "the browser unit ships with the egress gate it depends on" \
  has 'units/quadlet/agent-brave.container' image/Containerfile
check "Syncthing's sync port is permitted on the tailscale zone" \
  has '<port port="22000" protocol="tcp"/>' image/rootfs/etc/firewalld/zones/tailscale.xml
check "Syncthing's QUIC port is permitted on the tailscale zone" \
  has '<port port="22000" protocol="udp"/>' image/rootfs/etc/firewalld/zones/tailscale.xml
# The deploy receiver is the one service whose caller is a CI job, so its port has
# to be open on the tailnet zone or the notify path silently times out.
check "the deploy receiver's port is permitted on the tailscale zone" \
  has '<port port="8484" protocol="tcp"/>' image/rootfs/etc/firewalld/zones/tailscale.xml
# The public edge (design #725) proxies the `svc:immich` and `svc:opds` Services,
# so it needs no port of its own and the zone is Syncthing's two plus the
# receiver's one. A `<port>` no route stands behind is an opening on the tailnet
# zone that nothing would notice, so the set is pinned whole rather than one
# retired entry at a time.
zone_ports=$(grep -oE '<port port="[0-9]+" protocol="[a-z]+"/>' \
  image/rootfs/etc/firewalld/zones/tailscale.xml | tr '\n' ' ')
if [[ $zone_ports == '<port port="22000" protocol="tcp"/> <port port="22000" protocol="udp"/> <port port="8484" protocol="tcp"/> ' ]]; then
  ok "the tailscale zone opens only Syncthing and the deploy receiver"
else
  bad "the tailscale zone opens only Syncthing and the deploy receiver" "$zone_ports"
fi

# The apps tenant (#726) is named everywhere and numbered nowhere. sysusers
# allocates its id, so anything that named 1001 — the dataset owner, the user
# manager drop-ins — went stale the moment the id moved, silently.
check "the tenant id is allocated, not demanded" \
  grep -qx 'u apps - "apps tenant" /var/home/apps /usr/sbin/nologin' \
  image/rootfs/etc/sysusers.d/smortress-apps.conf
check "the tenant dataset owner is the account name" test "$(dataset_owner_for raw/apps)" = apps:apps
check "the image ships no per-uid manager drop-in" lacks 'user@1001.service.d' image/Containerfile
check "the image ships no per-uid slice drop-in" lacks 'user-1001.slice.d' image/Containerfile
for gate in smortress-apps-deny smortress-apps-user smortress-apps-egress smortress-apps-quota; do
  check "$gate finishes before a user manager can start" \
    grep -q '^Before=.*systemd-logind.service' "units/systemd/$gate.service"
done

# Every directory the Containerfile copies is baked into the image, so a change
# under it has to rebuild that image. `libs/` was absent from the publish
# workflow's path filter and a collector fix merged without ever being built.
copied=$(awk '/^COPY / { for (i = 2; i <= NF; i++) print $i }' image/Containerfile |
  grep -v '^--' | grep / | cut -d/ -f1 | sort -u)
for directory in $copied; do
  check "the publish workflow rebuilds on ${directory}/ changes" \
    publish_covers .github/workflows/publish-server-image.yml "$directory"
done
# And the reverse, because this is how the reboot loop started: `apps/**` and
# `libs/**` were on that path filter, so every app commit rebuilt and redeployed
# the OS image. Nothing in this Containerfile copies from them any more (the agent
# programs build into agent-runtime, every other app has its own publish workflow),
# so listing them again would republish the host for code it does not carry.
for directory in apps libs; do
  if grep -qF "\"$directory/**\"" .github/workflows/publish-server-image.yml; then
    bad "the publish workflow does not rebuild on ${directory}/ changes"
  else
    ok "the publish workflow does not rebuild on ${directory}/ changes"
  fi
done

# Repository-wide CI rules that new files must not evade.
probe "workflow actions are SHA-pinned" scripts/check-action-pins.sh
probe "PR workflows hold no secrets" scripts/check-pr-secret-boundary.sh

if ((fail)); then
  echo "server image static checks failed" >&2
  exit 1
fi
echo "server image static checks passed"

check "the image installs the deploy-apps modules" \
  has 'COPY scripts/deploy/apps/ /usr/libexec/deploy/apps/' image/Containerfile
