# shellcheck shell=bash
# shellcheck disable=SC2016,SC2034,SC2154  # helpers and globals come from the entrypoint
# The smores account password (design #767, T3). It was an operator file Ignition
# read at install time; bootc never reconciles /var, so the value ships as
# ciphertext instead and is consumed twice -- by the renderer for the install and
# by a boot unit for the reconcile. Both readers must name the same file, the
# manifest entry must stay `value` (chpasswd -e takes the bare hash), and the
# operator file must be gone from every reader: a leftover requirement would make
# a reinstall fail where the design says it must not.
check "the account hash is a manifest value" \
  grep -qE '^smores-password-hash\.yaml[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+root[[:space:]]+root[[:space:]]+0400[[:space:]]+value$' \
  bootc/server/rootfs/usr/share/smortress/secrets.manifest
check "the renderer reads the hash from ciphertext" \
  has 'secrets/boot.json' scripts/render-ignition.sh
if grep -rIl --exclude=check-server-image.sh --exclude-dir=check 'ignition/operator/smores-password-hash' \
    scripts units image docs ignition >/dev/null 2>&1; then
  bad "the operator hash file is required nowhere"
else
  ok "the operator hash file is required nowhere"
fi
check "the password unit exists" test -s units/systemd/smortress-password.service
check "image enables smortress-password.service" has 'smortress-password.service' bootc/server/Containerfile
check "the password unit requires the decrypt unit" \
  grep -qE '^Requires=.*sops-decrypt\.service' units/systemd/smortress-password.service
check "the password unit is ordered after the decrypt unit" \
  grep -qE '^After=.*sops-decrypt\.service' units/systemd/smortress-password.service
check "the password unit is skipped without its ciphertext" \
  has 'ConditionPathExists=/run/smortress/secrets/smores-password-hash.yaml' \
  units/systemd/smortress-password.service
# The hash belongs in exactly one place outside /etc/shadow, and never in argv:
# chpasswd reads it on stdin. A value in the unit file would be readable by every
# local user, and an argument would be readable from /proc by any of them.
check "the password unit runs the installed guard" \
  has 'ExecStart=/usr/libexec/smortress-password' units/systemd/smortress-password.service
check "the image installs the password guard" has 'scripts/smortress-password.sh' bootc/server/Containerfile
if grep -vE '^[[:space:]]*#' units/systemd/smortress-password.service | grep -qE 'usermod|chpasswd'; then
  bad "the password unit carries no usermod of its own"
else
  ok "the password unit carries no usermod of its own"
fi
# shellcheck disable=SC2016  # the matched text is the guard's own line
check "the guard applies the hash through chpasswd" \
  has '| chpasswd -e' scripts/smortress-password.sh
check "the hash never reaches argv" lacks 'usermod -p' scripts/smortress-password.sh
check "the guard changes only smores" has 'account=smores' scripts/smortress-password.sh
check "the guard refuses a non-sha512crypt value" \
  has 'does not hold a sha512crypt hash' scripts/smortress-password.sh

check "firewall binds tailscale0" has '<interface name="tailscale0"/>' bootc/server/rootfs/etc/firewalld/zones/tailscale.xml
check "firewall permits ssh only on that zone" has '<service name="ssh"/>' bootc/server/rootfs/etc/firewalld/zones/tailscale.xml
# A wildcard *listener* binds every address; `0.0.0.0` inside a CIDR
# (10.0.0.0/8) is a destination and must not trip this.
#
# A Quadlet `Exec=` or `Environment=` address is inside the container's own
# network namespace and is reachable only through a published port (checked
# above) -- unless the unit joins the host network, where the same address is a
# host listener again and nothing may excuse it.
wildcard_hits=
while IFS= read -r line; do
  [[ -n $line ]] || continue
  if [[ $line == *PublishPort=127.0.0.1* ]]; then
    continue
  fi
  file=${line%%:*}
  if [[ $line =~ :[0-9]+:(Exec|Environment)= ]] && ! grep -q '^Network=host' "$file"; then
    continue
  fi
  wildcard_hits+=$line$'\n'
done < <(grep -rInE '\b0\.0\.0\.0\b|\[::\]' units bootc/server/rootfs 2>/dev/null)
if [[ -n $wildcard_hits ]]; then
  bad "no wildcard listener address in units or rootfs"
else
  ok "no wildcard listener address in units or rootfs"
fi

# Applications (T5). The image ships the Quadlets and the units that make them
# work, and every application image must be our signed mirror at the pinned
# digest: the default-reject policy has no other path to a running container.
# The list is derived, not written out: a network file left out of the image
# makes the generator drop the container that requests it, which is how
# opdshelf.network reached the first T5 boot missing.
shopt -s nullglob
for q in units/quadlet/*.container units/quadlet/*.network; do
  unit=${q#units/quadlet/}
  [[ $unit == pattern.container ]] && continue
  check "image installs units/quadlet/$unit" has "units/quadlet/$unit" bootc/server/Containerfile
done
check "quadlets live where the generator scans" has '/usr/share/containers/systemd/' bootc/server/Containerfile
check "the placeholder is not installed as a runnable quadlet" \
  lacks 'units/quadlet/pattern.container /usr/share/containers/systemd' bootc/server/Containerfile
for unit in smortress-app-secrets.service smortress-tailscale-serve.service \
  smortress-boot-gate.service; do
  check "image enables $unit" has "$unit" bootc/server/Containerfile
done

# Deploy receiver (#798). A platform deploy ends in a reboot, so the pieces that
# decide whether the new deployment stays are asserted here: the units the image
# starts, the gate unit and its ordering, the counter that is the only rollback
# before userspace, and the list of units the gate requires. A missing unit in
# that list is a gate that checks nothing; a listed unit that is not active on a
# healthy host is a gate that rolls every deployment back.
gate_unit=units/systemd/smortress-boot-gate.service
check "the boot gate unit exists" test -s "$gate_unit"
check "the boot gate runs before boot-complete" \
  grep -qE '^Before=boot-complete\.target' "$gate_unit"
check "the boot gate runs late in boot" grep -qE '^After=.*multi-user\.target' "$gate_unit"
check "the boot gate waits for the decrypt step" \
  grep -qE '^After=.*sops-decrypt\.service' "$gate_unit"
# A template glob is not a valid ordering dependency in systemd, so the apps
# instance is named and multi-user.target carries the rest.
check "the boot gate waits for the apps dataset" \
  grep -qE '^After=.*zfs-ready@raw-apps\.service' "$gate_unit"
check "the boot gate waits for the network" \
  grep -qE '^After=.*network-online\.target' "$gate_unit"
check "the boot gate waits for the Serve routes" \
  grep -qE '^After=.*smortress-tailscale-serve\.service' "$gate_unit"
check "the boot gate wants its inputs without requiring them" \
  grep -qE '^Wants=.*sops-decrypt\.service' "$gate_unit"
check "the boot gate is installed where the loop puts it" \
  has 'ExecStart=/usr/libexec/smortress-boot-gate' "$gate_unit"
check "the image installs the boot gate" has 'scripts/smortress-boot-gate.sh' bootc/server/Containerfile
check "the boot gate is sandboxed" grep -qE '^ProtectSystem=strict' "$gate_unit"
# The gate mutates the grubenv and the ostree deployment it rolls back to, and
# nothing else: a wider writable tree would let a compromised gate rewrite a unit.
check "the boot gate widens /boot and the sysroot tree only" \
  grep -qE '^ReadWritePaths=(-)?/sysroot' "$gate_unit"
check "the drain waits for the boot gate" \
  grep -qE '^After=.*smortress-boot-gate\.service' units/systemd/smortress-deploy.service
check "the drain can write the boot it stages" \
  grep -qE '^ReadWritePaths=(-)?/boot$' units/systemd/smortress-deploy.service
# RestrictSUIDSGID made tar's mode-restoring chmod on directories fail with
# ENOSYS ("Cannot mkdir/open: Function not implemented"), which broke every
# tenant extraction (#824). Both units run as root and execute arbitrary tooling,
# so the filter bought little beyond a false sense of containment.
for unit in units/systemd/smortress-deploy.service units/systemd/smortress-boot-gate.service; do
  check "$unit does not set RestrictSUIDSGID" lacks 'RestrictSUIDSGID=yes' "$unit"
done
suidgid_fixture=$(mktemp)
printf 'RestrictSUIDSGID=yes\n' >"$suidgid_fixture"
if lacks 'RestrictSUIDSGID=yes' "$suidgid_fixture"; then
  bad "a unit that sets RestrictSUIDSGID is refused"
else
  ok "a unit that sets RestrictSUIDSGID is refused"
fi
rm -f "$suidgid_fixture"
# The host needed both of these under #824: the apply's floor must measure the
# writable data root, and the tenant helper must be able to drop to uid 972.
for unit in units/systemd/smortress-deploy.service units/systemd/smortress-boot-gate.service; do
  check "$unit measures the writable data root" \
    grep -qxF 'Environment=APPS_FREE_ROOT_PATH=/var' "$unit"
  check "$unit lets the tenant helper drop privileges" \
    lacks 'NoNewPrivileges=yes' "$unit"
done
nnp_fixture=$(mktemp)
printf 'NoNewPrivileges=yes\n' >"$nnp_fixture"
if lacks 'NoNewPrivileges=yes' "$nnp_fixture"; then
  bad "a unit that sets NoNewPrivileges is refused"
else
  ok "a unit that sets NoNewPrivileges is refused"
fi
rm -f "$nnp_fixture"

# Every program a unit or a script names under /usr/libexec has to be installed by
# the image, and the set is derived rather than listed: the `smortress-src` loop
# installs only what its COPY line names and strips the `.sh`, so `deploy-apps`
# was written in T5 and never listed and the drain's apps child was a path the
# image did not have. A program is installed by one of the three deliveries: the
# rootfs copy, an explicit `/usr/libexec/<name>` destination, or the `.sh` loop --
# except the operator CLI, which is staged under the name the runbook uses.
# A comment that names a retired helper is not a dependency on it; a directive or
# a command that names one is. The derivation is a function so the fixture check
# below can hold both halves: the comment passes, the reference still fails.
libexec_programs() { # <paths...>
  grep -rnE --exclude=check-server-image.sh --exclude-dir=check \
    '/usr/libexec/[A-Za-z0-9._-]*[A-Za-z0-9_-]' "$@" |
    awk '{ line = $0; sub(/^([^:]*:)?[0-9]+:/, "", line); if (line !~ /^[[:space:]]*#/) print line }' |
    grep -oE '/usr/libexec/[A-Za-z0-9._-]*[A-Za-z0-9_-]' | sed 's|.*/||' | sort -u
}
program_fixture=$(mktemp -d)
printf '# /usr/libexec/ghost-helper was retired with the old plane\n' \
  >"$program_fixture/comment.txt"
if [[ -n $(libexec_programs "$program_fixture/comment.txt") ]]; then
  bad "a comment naming /usr/libexec/<name> is not a dependency" \
    "$(libexec_programs "$program_fixture/comment.txt")"
else
  ok "a comment naming /usr/libexec/<name> is not a dependency"
fi
printf 'ExecStart=/usr/libexec/ghost-helper\n' >"$program_fixture/code.txt"
if [[ $(libexec_programs "$program_fixture/code.txt") == ghost-helper ]]; then
  ok "a real /usr/libexec/<name> reference is still a dependency"
else
  bad "a real /usr/libexec/<name> reference is still a dependency" \
    "$(libexec_programs "$program_fixture/code.txt")"
fi
rm -rf "$program_fixture"
# shellcheck disable=SC2013  # the derived names are paths and contain no blanks
for program in $(libexec_programs units bootc/server/rootfs scripts/*.sh); do
  if [[ -f bootc/server/rootfs/usr/libexec/$program ]]; then
    check "the image ships /usr/libexec/$program" test -x "bootc/server/rootfs/usr/libexec/$program"
  elif [[ $program == smortress-deploy ]]; then
    check "the image installs /usr/libexec/$program" \
      has 'scripts/deploy-cli.sh /usr/libexec/smortress-src/smortress-deploy.sh' bootc/server/Containerfile
  elif grep -qF "/usr/libexec/$program" bootc/server/Containerfile; then
    ok "the image installs /usr/libexec/$program"
  elif grep -qF "/usr/libexec/$program" images/agent-runtime/Containerfile; then
    # The agent programs ship in their own image (publish-agent-runtime).
    ok "the runtime image installs /usr/libexec/$program"
  else
    check "the image installs /usr/libexec/$program" has "scripts/$program.sh" bootc/server/Containerfile
  fi
done
# `COPY` preserves the mode, so a rootfs program committed non-executable is a
# unit that fails with 203/EXEC at the first boot rather than at review time. The
# same holds for every shell helper: the install loop strips the `.sh` and the
# unit runs the result, which is how smortress-boot-gate.sh shipped 100644 and
# would have failed the boot gate with 203/EXEC on the first boot after a deploy.
for program in bootc/lib/deploy/deploy-receiver.py \
  bootc/server/rootfs/usr/libexec/deploy-verify.py scripts/*.sh; do
  check "$program is committed executable" \
    test "$(git ls-files -s "$program" | cut -d' ' -f1)" = 100755
done
check "the loop installs every staged helper 0755" \
  has 'install -m 0755 "$f" "/usr/libexec/$(basename "${f%.sh}")"' bootc/server/Containerfile
# The deploy's own programs: the two python helpers ship in the rootfs (the loop
# would drop them), and the shell helpers go through it.
for program in deploy-state deploy-drain deploy-platform deploy-apps deploy-poll deploy-heartbeat; do
  check "the image installs scripts/$program.sh" has "scripts/$program.sh" bootc/server/Containerfile
done
for program in deploy-poll deploy-heartbeat; do
  check "a unit runs the installed $program" has "/usr/libexec/$program" units/systemd
done
# deploy-apps has no unit of its own: the drain runs it for a queued apps request.
# It reaches it through the library's one resolver now, so the assertion follows
# the call, not a literal path that only the old inline probe carried.
check "the drain resolves the installed deploy-apps" has 'deploy_resolve' scripts/deploy-drain.sh
check "the resolver searches /usr/libexec" has '/usr/libexec' scripts/deploy-state.sh

# The units the image starts at boot. The drain is the exception and is asserted
# as such: it is a queue-triggered oneshot with no [Install] section, so enabling
# it would fail the build and starting it at boot would drain an empty queue.
receiver_unit=units/systemd/smortress-deploy-listener.service
check "the receiver unit exists" test -s "$receiver_unit"
check "the receiver runs the installed program" \
  has 'ExecStart=/usr/bin/python3 /usr/libexec/deploy-receiver.py' "$receiver_unit"
check "the receiver refuses to start without the decrypt step" \
  grep -qE '^Requires=sops-decrypt\.service' "$receiver_unit"
for unit in smortress-deploy-listener.service smortress-deploy.path \
  smortress-boot-gate.service smortress-deploy-poll.timer \
  smortress-deploy-heartbeat.timer smortress-deploy-retry.timer; do
  check "image enables $unit" has "$unit" bootc/server/Containerfile
done
check "the queue path triggers the drain" \
  grep -qxF 'Unit=smortress-deploy.service' units/systemd/smortress-deploy.path
check "the queue path watches the receiver's queue" \
  grep -qxF 'DirectoryNotEmpty=/var/lib/homelab/deploy/queue' units/systemd/smortress-deploy.path
check "the drain is triggered by the queue, not enabled at boot" \
  lacks 'WantedBy=' units/systemd/smortress-deploy.service
# A oneshot that its own trigger starts must not also be enabled: an enabled
# drain runs its snapshot gate on an empty queue, and an enabled poll service
# fires once at boot with no timer behind it.
for unit in smortress-deploy.service smortress-deploy-poll.service \
  smortress-deploy-heartbeat.service; do
  check "the image leaves $unit to its trigger" lacks "$unit" bootc/server/Containerfile
done
check "the poll timer starts the poll service" \
  grep -qxF 'Unit=smortress-deploy-poll.service' units/systemd/smortress-deploy-poll.timer
check "the heartbeat timer starts the heartbeat service" \
  grep -qxF 'Unit=smortress-deploy-heartbeat.service' units/systemd/smortress-deploy-heartbeat.timer
# The tenant prober is a timer and a timer-triggered oneshot: enabling the timer
# is the whole delivery, because a timer the image does not enable never fires.
# Enabling the service instead would run it once at boot and never again, which is
# the coupling this split removes.
check "the image enables the tenant prober's timer" \
  grep -qE '^[[:space:]]*smortress-apps-health\.timer([[:space:]]|;)' bootc/server/Containerfile
check "the image leaves the tenant prober to its timer" \
  lacks 'smortress-apps-health.service' bootc/server/Containerfile
check "the prober timer starts the prober" \
  grep -qxF 'Unit=smortress-apps-health.service' units/systemd/smortress-apps-health.timer
# Fail-safe: no prober unit may become a host-gate requirement (asserted where
# the gate's list is read). The service is a oneshot that reads `inactive`
# between runs, so listing it would fail the gate on every boot, and a listed
# timer would let a tenant-side probe fault roll the host image back -- the
# coupling this split removes. Both must cost a journal line.
check "the prober is not ordered into the boot" \
  lacks 'boot-complete.target' units/systemd/smortress-apps-health.service
# The probe reads Serve's routes, and Serve is re-declared at boot after the plan
# is read: probing first would report every base path missing on a healthy host.
check "the prober waits for the Serve routes" \
  grep -qE '^After=.*smortress-tailscale-serve\.service' units/systemd/smortress-apps-health.service
# A deferred entry is retried by this timer, not by the path unit re-firing the
# drain: without it a rate-limited deploy would wait for the next event.
check "the retry timer starts the drain service" \
  grep -qxF 'Unit=smortress-deploy.service' units/systemd/smortress-deploy-retry.timer
check "the retry timer fires every five minutes" \
  grep -qxF 'OnCalendar=*-*-* *:0/5:00' units/systemd/smortress-deploy-retry.timer
check "the tmpfiles entry creates the queue" \
  has 'd /var/lib/homelab/deploy/queue 0700 root root -' bootc/server/rootfs/etc/tmpfiles.d/smortress.conf

# The three secrets the deploy path reads are `value` scalars: the listener
# compares the raw key, the heartbeat hands the bare URL to curl and sops-decrypt
# writes the scalar alone, so a `yaml` entry would compare a document.
for name in webhook-secret webhook-secret-next deploy-ping-url; do
  check "$name is a manifest value" \
    grep -qE "^${name//./\\.}\.yaml[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+root[[:space:]]+root[[:space:]]+0400[[:space:]]+value$" \
    bootc/server/rootfs/usr/share/smortress/secrets.manifest
done

# The gate's list is only meaningful if every line is active on a healthy host:
# a unit the image does not enable is inactive at every boot, and so is one that
# skips itself through a negated condition (the enrollment unit, after its
# marker). Both are a gate that rolls back every deployment.
units_file=bootc/server/rootfs/usr/share/smortress/deploy-units.txt
check "the gate's unit list ships in the image" test -s "$units_file"
check "the unit list is shipped by the rootfs copy" has 'COPY bootc/server/rootfs/ /' bootc/server/Containerfile
check "the gate requires the decrypt step" grep -qxF 'sops-decrypt.service' "$units_file"
check "the gate requires the pool" grep -qxF 'smortress-zpool.service' "$units_file"
if grep -vE '^[[:space:]]*#' "$units_file" | grep -qiE 'deploy'; then
  bad "the gate requires no deploy unit (its secret is seeded after the first deploy)"
else
  ok "the gate requires no deploy unit (its secret is seeded after the first deploy)"
fi
# A unit that reads the tenant's plan must not be judged here: both of them exit 1
# on an app definition, and `is-failed` on one would denylist the platform digest
# and roll a healthy host back for an app's fault.
for unit in smortress-tailscale-serve.service smortress-apps-quota.service \
  smortress-app-ingress-reconcile.service; do
  check "the gate judges no unit that reads the tenant's plan: $unit" lacks "$unit" "$units_file"
done
# The prober is the other half of the same split, and it must fail safe: the
# oneshot reads `inactive` between runs and the timer may be failed for a
# tenant's fault, so either one in this list would roll back a healthy host.
for unit in smortress-apps-health.service smortress-apps-health.timer; do
  check "the gate requires no prober unit: $unit" lacks "$unit" "$units_file"
done
while IFS= read -r unit; do
  [[ -n $unit ]] || continue
  pattern="(^|[[:space:]])${unit//./\\.}([[:space:]]|;)"
  check "the gate lists only units the image enables: $unit" grep -qE "$pattern" bootc/server/Containerfile
  if [[ -f units/systemd/$unit ]] &&
    grep -qE '^[[:space:]]*ConditionPathExists[[:space:]]*=[[:space:]]*!' "units/systemd/$unit"; then
    bad "the gate lists no unit that skips itself: $unit"
  else
    ok "the gate lists no unit that skips itself: $unit"
  fi
done < <(awk '!/^[[:space:]]*#/ { print $1 }' "$units_file")
# That loop only judges the list one way: every line must be enabled and must not
# skip itself. Nothing noticed the reverse, so a new long-running daemon could be
# enabled by the image and assert nothing at all. Derive the candidates from the
# image's own enable block and make each one a written decision. A name with no
# file under units/ and no local template is a distro unit: this tree does not
# declare it, so neither its Type nor its activity is ours to read. A
# `ConditionPathExists=!` unit (or a bare oneshot) reads `inactive` on a healthy
# host -- the same reason the list excludes it -- but that exemption is the name
# set `self_skipping` below, never the directive: a directive is how a unit was
# written, while a name in that set is a decision about this host.
#
# The enable block is shell, so read it the way the shell does: a trailing
# backslash joins the next line, `#` ends a comment, `;` and `&&` separate
# commands, and a unit name may be quoted. Matching `systemctl enable \` at end of
# line instead loses the scrub timer, which is enabled on one line with a quoted
# instance, and a quoting filter on the name skips it a second time.
#
# The command is found wherever the shell would find it: `RUN`, `sudo` and `exec`
# in front of `systemctl` are skipped, and so are the options systemctl accepts
# before its subcommand (`--no-reload`, `--now`), because each shape enables a unit
# as surely as the bare form and each one used to leave this set without it. A `#`
# or `;` inside a quoted argument is out of scope, not handled quietly: the split
# above would cut the argument in half, and the Containerfile is linted shell with
# no enable line that quotes one -- a line that did would have to teach this
# parser, which is the review this comment exists to force.
image_enabled_units() { # <Containerfile>
  local line buffer='' segment word word_i
  local -a words
  while IFS= read -r line; do
    line=${line%%#*}
    line=${line//&&/;}
    if [[ $line == *\\ ]]; then
      buffer+="${line%\\} "
      continue
    fi
    buffer+=$line
    while [[ -n $buffer ]]; do
      segment=${buffer%%;*}
      if [[ $segment == "$buffer" ]]; then buffer=; else buffer=${buffer#*;}; fi
      read -r -a words <<<"$segment" || continue
      ((${#words[@]} >= 2)) || continue
      word_i=0
      while ((word_i < ${#words[@]})); do
        case ${words[word_i]} in
          RUN | sudo | exec) word_i=$((word_i + 1)) ;;
          *) break ;;
        esac
      done
      [[ ${words[word_i]-} == systemctl ]] || continue
      word_i=$((word_i + 1))
      while [[ ${words[word_i]-} == -* ]]; do
        word_i=$((word_i + 1))
      done
      [[ ${words[word_i]-} == enable ]] || continue
      for word in "${words[@]:word_i+1}"; do
        word=${word//\"/}
        word=${word//\'/}
        [[ -n $word ]] && printf '%s\n' "$word"
      done
    done
  done <"$1"
}
declare -A enabled=()
while IFS= read -r unit; do
  [[ -n $unit ]] || continue
  enabled[$unit]=1
done < <(image_enabled_units bootc/server/Containerfile)
# A parser that finds nothing must not pass the loop below vacuously, and one unit
# the enable block certainly names anchors the rest: a regression in the parser is
# a broken check, never a new exemption to write.
if [[ -n ${enabled[sops-decrypt.service]:-} ]]; then
  ok "the enable parser finds the units the image enables"
else
  bad "the enable parser finds the units the image enables"
fi
if ((${#enabled[@]} > 0)); then
  ok "the enable parser reads a non-empty unit set"
else
  bad "the enable parser reads a non-empty unit set"
fi
# The units that legitimately read `inactive` on a healthy host, by name. This set
# is written out rather than derived from the directives the loop used to honour
# (`ConditionPathExists=!`, a bare `Type=oneshot`): derived, any new unit carried
# the exemption for free, and a template-level condition exempted every instance at
# once -- a whole class of units excused by one line in one file. A unit with such
# a directive that is not named here falls through to the list/allowlist decision,
# so an unknown name fails instead of disappearing.
declare -A self_skipping=(
  [smortress-tailscale-up.service]='enrolls the tailnet once: its negated enrollment marker makes it inactive after the first boot, when the work is done'
  [smortress-access-bootstrap.service]='holds SSH open on the wired LAN until enrollment: the same marker makes it inactive on every later boot'
  [smortress-boot-gate.service]='the gate cannot require itself: a bare one-shot reads `inactive` between runs, so listing it would roll back every deployment it judged'
  [smortress-agent-brave-seed.service]='seeds the browsing profile once: a bare one-shot, and an agent-plane fault must not roll the platform digest back'
)
# The same staleness rule as unlisted_why: a name here that the image no longer
# enables is an exemption that outlived its unit and reads like a decision.
for unit in "${!self_skipping[@]}"; do
  if [[ -z ${enabled[$unit]:-} ]]; then
    bad "the gate's self-skipping names are enabled units: $unit (stale exemption: the enable block does not name it, so drop the entry)"
  fi
done
# An instance has no file of its own -- `zfs-ready@raw-files.service` is enabled by
# `zfs-ready@.service` -- so classify it from its template rather than skipping the
# instance, which would exempt every per-dataset instance from the check. The
# instance is any `%i`, dots included: a dataset or a variant name can carry one
# (`zfs-ready@raw-git.v2.service`), and refusing it would file the instance as a
# distro unit and skip it.
local_unit_file() { # <unit>
  local unit=$1 template
  if [[ -f units/systemd/$unit ]]; then
    printf 'units/systemd/%s\n' "$unit"
    return 0
  fi
  if [[ $unit =~ ^([^@]+)@(.+)\.service$ ]]; then
    template=units/systemd/${BASH_REMATCH[1]}@.service
    if [[ -f $template ]]; then
      printf '%s\n' "$template"
      return 0
    fi
  fi
  return 1
}
# Long-running units the image enables that stay out of the list, each with the
# reason it is not a serving signal for the gate. Listing one would change what
# "serving" means for this host, so the decision is recorded here instead of being
# an omission. None of these reasons promises a page: the gate's only `is-failed`
# consumer asks about the units in the list above, so an unlisted fault is a
# journal line and nothing else. Every key names an enabled unit, because a reason
# nobody reads is how an exemption turns permanent (the loop below fails a stale
# key), and a pattern would read as a decision while hiding the next instance.
declare -A unlisted_why=(
  [smortress-cryptsetup-hdd.service]='best-effort HDD unlock (ExecStart=-) is green with the backup disk unplugged, so it asserts nothing about the disk'
  [smortress-tailscale-ssh-off.service]='ConditionPathExists on tailscaled.state: a missing state file makes systemd skip it before the first enrollment, and a skip reads inactive'
  [smortress-agent-config.service]='seeds the agent state datasets: an agent-plane fault must not roll the platform digest back'
  [smortress-agent-job-provision.service]='provisions the rootless job runners: an agent-plane fault must not roll the platform digest back'
  [smortress-agent-shell-bridge.service]='serves the agent shell socket: an agent-plane fault must not roll the platform digest back'
  [smortress-agent-shell-bridge-personal.service]='serves the personal agent shell socket: an agent-plane fault must not roll the platform digest back'
  [smortress-nvidia-cdi.service]='ConditionPathExists on /usr/bin/nvidia-ctk: on a host with no NVIDIA tooling the unit is skipped, not failed'
  [smortress-selinux-nvidia-map.service]='ConditionPathExists on the model CIL module: without SELinux or that module it is skipped, not failed'
  [smortress-selinux-agent-shell.service]='ConditionPathExists on the shell CIL module: without SELinux or that module it is skipped, not failed'
  [smortress-agent-mail-stream.service]='ConditionPathExists on the Tuta bridge cert: without the cert it is skipped, not failed, until the bridge is provisioned'
  [smortress-restic-init.service]='initialises the Restic repositories: a backup-plane fault must not roll the platform digest back'
  # The two Restic repository mounts are enabled and long-running, and `nofail` is
  # what makes them the opposite of a serving signal: an absent or unpowered backup
  # disk is a red destination, not a failed host. The hourly verifier pings the
  # backup check red when a destination is not current, so the plane pages on its
  # own and a missing disk must not roll the platform digest back.
  [var-lib-restic-ssd.mount]='the SSD Restic repository: nofail by design, and the hourly verifier pages the backup check red when it is not mounted, so a missing backup disk must not roll the platform digest back'
  [var-lib-restic-hdd.mount]='the HDD Restic repository: nofail by design, and the verifier pages the backup check red, so an unplugged or unpowered backup disk must not roll the platform digest back'
  # The readiness instances are one mount probe per dataset and only `raw-apps` is
  # in the list above, because the tenant apply chain is ordered after it. The rest
  # fail on their own path, and a dataset that is not mounted is a storage-plane
  # fault no image rollback can fix.
  [zfs-ready@raw-files.service]='mount probe for raw/files: a storage-plane fault must not roll the platform digest back'
  [zfs-ready@raw-photos.service]='mount probe for raw/photos: a storage-plane fault must not roll the platform digest back'
  [zfs-ready@raw-books.service]='mount probe for raw/books: a storage-plane fault must not roll the platform digest back'
  [zfs-ready@raw-music.service]='mount probe for raw/music: a storage-plane fault must not roll the platform digest back'
  [zfs-ready@raw-wallpapers.service]='mount probe for raw/wallpapers: a storage-plane fault must not roll the platform digest back'
  [zfs-ready@raw-git.service]='mount probe for raw/git: a storage-plane fault must not roll the platform digest back'
  [zfs-ready@raw-repo-archive.service]='mount probe for raw/repo-archive: a storage-plane fault must not roll the platform digest back'
  [zfs-ready@state-immich-postgres.service]='mount probe for state/immich-postgres: a storage-plane fault must not roll the platform digest back'
  [zfs-ready@state-immich-dumps.service]='mount probe for state/immich-dumps: a storage-plane fault must not roll the platform digest back'
  [zfs-ready@state-syncthing-config.service]='mount probe for state/syncthing-config: a storage-plane fault must not roll the platform digest back'
  [zfs-ready@state-opdshelf.service]='mount probe for state/opdshelf: a storage-plane fault must not roll the platform digest back'
  [zfs-ready@state-navidrome.service]='mount probe for state/navidrome: a storage-plane fault must not roll the platform digest back'
  [zfs-ready@state-agent-local.service]='mount probe for state/agent-local: a storage-plane fault must not roll the platform digest back'
  [zfs-ready@state-agent-general.service]='mount probe for state/agent-general: a storage-plane fault must not roll the platform digest back'
  [zfs-ready@state-agent-model.service]='mount probe for state/agent-model: a storage-plane fault must not roll the platform digest back'
)
# Judge a candidate whatever kind of unit it is. A `.service` carries a `Type`; a
# `.mount` or a `.socket` carries none and is long-running by definition, which is
# exactly the case this check exists for: `var-lib-restic-ssd.mount` was enabled,
# long-running and in neither the list nor the table, and a `*.socket` would have
# slipped through the same hole. The directive skips that used to drop a candidate
# here are now the `self_skipping` name set: this loop no longer reads a unit file
# to decide whether to judge the unit, only whether this tree declares it.
declare -A consulted=()
while IFS= read -r unit; do
  case $unit in
    *.service | *.mount | *.socket) ;;
    *) continue ;;
  esac
  local_unit_file "$unit" >/dev/null || continue
  [[ -n ${self_skipping[$unit]:-} ]] && continue
  # The deploy units are the third exclusion the list header names: their secrets
  # are seeded by hand after the first landing, so none of them is a serving signal
  # and none is judgeable here. The path unit and the three timers are already
  # outside the suffix filter above; they stay in the case so the decision survives
  # a wider filter.
  case $unit in
    smortress-deploy-listener.service | smortress-deploy.path | \
      smortress-deploy-poll.timer | smortress-deploy-heartbeat.timer | \
      smortress-deploy-retry.timer) continue ;;
  esac
  # And the plan readers plus the prober: their failures belong to the tenant, so
  # none may decide the platform digest. The prober's timer is outside the suffix
  # filter above and its oneshot reads `inactive` between runs, so neither is a
  # candidate here; this case states that for the service the filter now reaches.
  case $unit in
    smortress-tailscale-serve.service | smortress-apps-quota.service | \
      smortress-app-ingress-reconcile.service | \
      smortress-apps-health.service) continue ;;
  esac
  consulted[$unit]=1
  if grep -qxF -- "$unit" "$units_file" || [[ -n ${unlisted_why[$unit]:-} ]]; then
    ok "the gate's list accounts for the enabled unit: $unit"
  else
    bad "the gate's list omits a long-running unit the image enables: $unit (list it if it is a serving signal, else add it to unlisted_why with a reason)"
  fi
done < <(printf '%s\n' "${!enabled[@]}" | sort)
# The predicate above matches on a non-empty value, so a bare key cannot excuse a
# unit; this catches the other half, a key for a unit the image stopped enabling,
# which is an exemption that outlived its reason and reads like a decision.
for unit in "${!unlisted_why[@]}"; do
  if [[ -z ${enabled[$unit]:-} ]]; then
    bad "the gate's unlisted reasons name a unit the image enables: $unit (stale exemption: the enable block does not name it, so drop the entry)"
  fi
done
# And a key is only a decision if the loop read it: a reason for an enabled unit
# that the filters above drop before the list/allow decision (a self-skipping
# name, a deploy unit, the prober) passes the staleness guard while nothing
# consults it, which is how an exemption turns permanent.
for unit in "${!unlisted_why[@]}"; do
  if [[ -z ${consulted[$unit]:-} ]]; then
    bad "the gate's unlisted reasons are consulted: $unit (never consulted: the loop drops this unit before the list/allow decision, so the reason is read by nothing)"
  fi
done
count_cfg=bootc/server/rootfs/usr/lib/bootupd/grub2-static/configs.d/10-smortress-count.cfg
check "the boot counter snippet ships where bootupd reads it" test -s "$count_cfg"
check "the snippet clears boot_success on every boot" has 'set boot_success=0' "$count_cfg"
check "the snippet counts three attempts" has 'set boot_counter=3' "$count_cfg"
check "the snippet selects the previous deployment at zero" has 'set default=1' "$count_cfg"
check "a hung PID 1 reboots" \
  has 'RuntimeWatchdogSec=1min' bootc/server/rootfs/etc/systemd/system.conf.d/10-watchdog.conf
# A panic must not reboot until a bootloader counter can fall back: otherwise a
# kernel panic loops the same image forever with no userspace to roll back.
check "no panic reboot without a counter" no_file_exists bootc/server/rootfs/etc/sysctl.d/10-panic.conf
