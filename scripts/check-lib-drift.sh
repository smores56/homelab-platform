#!/usr/bin/env bash
# Hold lib/ and the host trees to each other: every shared artifact exists once,
# every host installs it from lib/, and nothing still names the copy it replaced.
#
#   scripts/check-lib-drift.sh
#
# Design #1011 asks for one copy per contract and a comparison that fails on
# drift, and SDLC #1024 lands the artifacts that were duplicated: the containers
# policy with the cosign public key and registries.d, the sudoers pair, and the
# greenboot required check. SDLC #1025 adds the last one: the deploy verifier,
# which existed twice and differed in per-host inputs rather than in behaviour.
# Before this, each of those existed two or three times and nothing compared the
# copies -- a host could run a policy, a gate or a health check nobody had
# reviewed for it.
#
# The comparison is these rules:
#
#   1. one copy. Each shared artifact is found exactly once in the tree, under
#      lib/, plus the test fixture that is deliberately a different key.
#   2. no host keeps a copy. Nothing under a host rootfs holds the policy, the
#      registries.d entry, a sudoers drop-in or a greenboot check, so a host
#      cannot quietly grow its own again.
#   3. every host wires lib/. Each Containerfile names the lib files that host
#      needs, and the image paths it installs them at are the host's data.
#   4. per-host differences are data. The policy composes from the shared
#      contract plus the host's registry table, the greenboot check carries no
#      host at all while its assertions are that host's file, and the deploy
#      verifier carries no host, repository or image name while its policy table
#      is that host's.
#   5. no stale reference. No file in the tree names the path a copy used to
#      have.
#
# Exit 0 when every rule holds; otherwise one `FAIL <what>: <why>` line per
# problem and `N checks, N problems`, in the style of
# scripts/check-edge-unit-paths.sh.
set -uo pipefail

repo=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
lib=$repo/lib

problems=0
checks=0
ok() {
  checks=$((checks + 1))
  printf 'ok   %s\n' "$1"
}
fail() {
  checks=$((checks + 1))
  problems=$((problems + 1))
  printf 'FAIL %s: %s\n' "$1" "$2"
}

# files: every file a copy of a shared artifact could hide in. Only the git
# directory and the one vendored node_modules tree are excluded: a stale copy in
# an untracked editor backup under a host rootfs would be the same drift as a
# committed one.
files() {
  find "$repo" -path "$repo/.git" -prune -o -path "$repo/backrest/node_modules" -prune -o -type f -print
}

# one_copy <what> <expected path> <path regex> [allowed path...]: the artifact is
# at <expected path> and nowhere else except where an allowance says so. This is
# the rule the whole file exists for: a second copy is how the two versions of
# every one of these artifacts came to differ.
one_copy() {
  local what=$1 expected=$2 pattern=$3
  shift 3
  local list unexpected allowed
  list=$(files | grep -E "/$pattern\$" | sed "s|^$repo/||" | sort) || true
  for allowed in "$@"; do
    list=$(printf '%s\n' "$list" | grep -vx -- "$allowed") || true
  done
  if [[ $list == "$expected" ]]; then
    ok "one copy of $what"
  else
    unexpected=$(printf '%s\n' "$list" | tr '\n' ' ')
    fail "one copy of $what" "found [${unexpected% }], want [$expected]"
  fi
}

# --- 1. one copy ---------------------------------------------------------------

# The fixture key is a second *file* with this name on purpose: it lets a render
# be proved without the operator's key, and it is not the artifact.
one_copy 'the cosign public key' lib/containers/cosign.pub 'cosign\.pub' \
  tests/fixtures/cosign.pub
one_copy 'the sops env drop-in' lib/sudoers/20-sops-env '20-sops-env'
one_copy 'the human gate drop-in' lib/sudoers/10-human-gate '10-human-gate'
one_copy 'the agent socket keep' lib/sudoers/11-agent-socket '11-agent-socket'
one_copy 'the containers policy' lib/containers/policy.json 'containers/policy\.json'
one_copy 'the registry trust table' lib/containers/policy.d/smortress.json 'policy\.d/smortress\.json'
one_copy 'the laptop registry trust table' lib/containers/policy.d/smorespro.json 'policy\.d/smorespro\.json'
one_copy 'the registries.d entry' lib/containers/registries.d/ghcr.io-smortress.yaml \
  'registries\.d/ghcr\.io-smortress\.yaml'
one_copy 'the laptop registries.d entry' lib/containers/registries.d/ghcr.io-smorespro-image.yaml \
  'registries\.d/ghcr\.io-smorespro-image\.yaml'
one_copy 'the greenboot required check' lib/greenboot/required.d/10-health.sh \
  'greenboot/required\.d/10-health\.sh'
# Both spellings of the verifier's name, because a copy beside a program is the
# shape the second one took: `<dir>/deploy-verify.py` in a host rootfs, and
# `deploy/verify.py` in the tree.
one_copy 'the deploy verifier' lib/deploy/verify.py 'deploy[-/]verify\.py'
for host in server edge; do
  one_copy "the $host deploy policy" "lib/deploy/policy.d/$host.json" \
    "deploy/policy\.d/$host\.json"
  one_copy "the $host greenboot assertions" "lib/greenboot/assertions.d/$host/10-health.sh" \
    "greenboot/assertions\.d/$host/10-health\.sh"
done

# --- 2. no host keeps a copy ---------------------------------------------------

# The host trees are named one by one rather than globbed, so the list is the
# statement of which trees were checked; a fourth host that grows its own copy
# fails here on the day it appears.
for host_root in bootc/server/rootfs bootc/edge/rootfs hosts/laptop/rootfs; do
  for contract in \
    etc/containers/policy.json \
    etc/containers/registries.d \
    etc/sudoers.d/10-human-gate \
    etc/sudoers.d/11-agent-socket \
    etc/sudoers.d/20-sops-env \
    etc/greenboot/check \
    etc/greenboot/assertions.d \
    usr/libexec/deploy-verify.py \
    usr/libexec/deploy-verify; do
    if [[ -e $repo/$host_root/$contract ]]; then
      fail "$host_root holds no copy of $contract" 'the copy is in lib/; a host tree states only what is that host'"'"'s'
    else
      ok "$host_root holds no copy of $contract"
    fi
  done
done

# --- 3. every host wires lib/ --------------------------------------------------

# installs <containerfile> <path>...: the Containerfile names each path. This is
# the half a host cannot silently stop doing: a dropped COPY fails these lines,
# and a COPY of a file the artifact does not have fails the build.
installs() {
  local containerfile=$1
  shift
  local path missing=''
  for path in "$@"; do
    grep -qF -- "$path" "$repo/$containerfile" || missing="$missing $path"
  done
  if [[ -z $missing ]]; then
    ok "$containerfile installs its lib/ files"
  else
    fail "$containerfile installs its lib/ files" "names no COPY of:$missing"
  fi
}

installs bootc/server/Containerfile \
  lib/containers/cosign.pub \
  lib/containers/policy.json \
  lib/containers/render-policy.sh \
  lib/containers/policy.d/smortress.json \
  lib/containers/registries.d/ghcr.io-smortress.yaml \
  lib/sudoers/10-human-gate \
  lib/sudoers/11-agent-socket \
  lib/sudoers/20-sops-env \
  lib/greenboot/required.d/10-health.sh \
  lib/greenboot/assertions.d/server/10-health.sh \
  lib/deploy/verify.py \
  lib/deploy/policy.d/server.json
installs bootc/edge/Containerfile \
  lib/greenboot/required.d/10-health.sh \
  lib/greenboot/assertions.d/edge/10-health.sh \
  lib/deploy/verify.py \
  lib/deploy/policy.d/edge.json
installs hosts/laptop/Containerfile \
  lib/containers/cosign.pub \
  lib/containers/policy.json \
  lib/containers/render-policy.sh \
  lib/containers/policy.d/smorespro.json \
  lib/containers/registries.d/ghcr.io-smorespro-image.yaml \
  lib/sudoers/10-human-gate \
  lib/sudoers/20-sops-env

# The agent-socket keep is the server's factor: its sudo stack is pam_rssh. The
# laptop's is pam_u2f over HID, so the keep there would hand a root command an
# agent it has no use for.
for containerfile in bootc/edge/Containerfile hosts/laptop/Containerfile; do
  if grep -qF 'lib/sudoers/11-agent-socket' "$repo/$containerfile"; then
    fail "$containerfile installs no agent-socket keep" \
      'the keep belongs to the image whose sudo stack is pam_rssh'
  else
    ok "$containerfile installs no agent-socket keep"
  fi
done

# --- 4. per-host differences are data ------------------------------------------

# The policy a host ships is the shared contract plus its own registry table, and
# the image asserts at build time that the table names its key by the path the
# image installs. Composing them here is what turns a table that no longer merges
# -- a transport-wide accept, a key at a path nothing installs -- into a failing
# pull request instead of a rejected pull on a booted host.
for host in smortress smorespro; do
  table=$lib/containers/policy.d/$host.json
  rendered=$("$lib/containers/render-policy.sh" "$host" 2>/dev/null) || rendered=''
  if [[ -z $rendered ]]; then
    fail "lib/containers composes $host" "render-policy.sh $host produced nothing"
    continue
  fi
  ok "lib/containers composes $host"
  if [[ $(jq -r '.default[0].type' <<<"$rendered") == reject ]]; then
    ok "$host rejects by default"
  else
    fail "$host rejects by default" 'the default rule is not reject'
  fi
  if [[ $(jq -r '.transports.docker[""] // "absent"' <<<"$rendered") == absent ]]; then
    ok "$host trusts no repository transport-wide"
  else
    fail "$host trusts no repository transport-wide" \
      'an empty docker scope shadows the default reject for every registry'
  fi
  if [[ $(jq -Sc '.transports.docker' <<<"$rendered") == "$(jq -Sc . "$table")" ]] &&
    [[ $(jq -Sc 'del(.transports.docker)' <<<"$rendered") == "$(jq -Sc . "$lib/containers/policy.json")" ]]; then
    ok "$host's policy is the shared contract plus its own table"
  else
    fail "$host's policy is the shared contract plus its own table" \
      "the render is not exactly policy.json plus policy.d/$host.json"
  fi
done

# The greenboot required check is one program and what a host asserts is data. A
# host name in the program is the drift this split exists to prevent, and a second
# assertion file in one directory would run whichever the glob ordered last.
runner=$lib/greenboot/required.d/10-health.sh
if [[ -x $runner ]]; then
  ok 'the greenboot check ships executable'
else
  fail 'the greenboot check ships executable' 'greenboot would skip it silently'
fi
if grep -qE 'smortress|smorespro|smoresnet|sammohr' "$runner"; then
  fail 'the greenboot check carries no host' \
    "a host name in ${runner#"$repo"/} belongs in lib/greenboot/assertions.d/<host>/"
else
  ok 'the greenboot check carries no host'
fi
for host in server edge; do
  dir=$lib/greenboot/assertions.d/$host
  count=$(find "$dir" -maxdepth 1 -name '*.sh' -type f 2>/dev/null | wc -l)
  if [[ $count == 1 ]]; then
    ok "the $host assertions are one file"
  else
    fail "the $host assertions are one file" "$count files in ${dir#"$repo"/}, want exactly one"
  fi
  file=$dir/10-health.sh
  if grep -qE '^assertions\(\)' "$file" 2>/dev/null; then
    ok "the $host assertions define assertions()"
  else
    fail "the $host assertions define assertions()" \
      "${file#"$repo"/} has none, so the shared check would fail every boot"
  fi
  if grep -qE '^budget=' "$file" 2>/dev/null; then
    ok "the $host assertions set a budget"
  else
    fail "the $host assertions set a budget" "${file#"$repo"/} relies on the program's default"
  fi
  if grep -qE '^check_name=' "$file" 2>/dev/null; then
    ok "the $host assertions name the check"
  else
    fail "the $host assertions name the check" "${file#"$repo"/} leaves the verdict unnamed"
  fi
done

# The deploy verifier (SDLC #1025). What a host deploys is its policy table, so a
# host name in the program is the drift the split removes: two copies differing in
# one line is how the server's and the edge's verifiers came to answer differently
# about the same commit. The names checked are the hosts, the owner and the two
# repositories -- everything a line of this program would have had to hardcode.
verifier=$lib/deploy/verify.py
if [[ -x $verifier ]]; then
  ok 'the deploy verifier ships executable'
else
  fail 'the deploy verifier ships executable' 'the drain execs it, and a 0644 one fails with 126'
fi
if grep -qE 'smortress|smorespro|smoresnet|sammohr|smores56|homelab-platform|homelab-apps' "$verifier"; then
  fail 'the deploy verifier carries no host' \
    "a host, repository or image name in ${verifier#"$repo"/} belongs in lib/deploy/policy.d/<host>.json"
else
  ok 'the deploy verifier carries no host'
fi
if grep -qE 'decisions\.(ROLES|role|allows)\b' "$verifier"; then
  fail 'the deploy verifier picks no role' \
    "${verifier#"$repo"/} names a role the shared table defines, so the host would be in the program again"
else
  ok 'the deploy verifier picks no role'
fi

# A host that runs no deploy installs no verifier and no table: the laptop's
# updates are its own, and a verifier there would be a program with no queue to
# read and a policy nobody could fill in.
if grep -qE 'lib/deploy(/verify\.py|/policy\.d/)' "$repo/hosts/laptop/Containerfile"; then
  fail 'hosts/laptop/Containerfile installs no deploy verifier' \
    'the laptop has no deploy queue; the verifier belongs to the hosts that drain one'
else
  ok 'hosts/laptop/Containerfile installs no deploy verifier'
fi

# The table has to say what the rest of the deploy plane already says. The drain
# refuses a queued entry the role does not allow (`decisions.allows`, and the
# shell spelling in bootc/lib/deploy/drain.sh), so a verifier with a wider
# allowlist would answer for a commit the queue never hands it, and a narrower one
# would refuse a request the queue accepted. The image repository is the other
# half: a verdict that resolved a tag out of the other host's repository would
# stage an image nobody signed for this host.
policy_agrees() {
  local host=$1 out
  if ! out=$(python3 - "$lib/deploy/policy.d/$host.json" "$repo/bootc/lib/deploy" <<'PY'
import json, sys

path, shared = sys.argv[1], sys.argv[2]
sys.path.insert(0, shared)
import decisions

with open(path, encoding="utf-8") as handle:
    table = json.load(handle)
role = decisions.role(table["role"])
problems = []
if sorted(table["repos"]) != sorted(role.repos):
    problems.append(
        f"repos {sorted(table['repos'])} are not the {role.name} role's {sorted(role.repos)}"
    )
# The platform is the one repository with an image: an apps commit has no reboot
# and no artifact to resolve, so a table that gave it one would send the tenant
# apply through a registry.
want = {decisions.PLATFORM: role.image_repo}
if table.get("images", {}) != want:
    problems.append(f"images {table.get('images', {})} are not {want}")
print("; ".join(problems))
PY
  ); then
    fail "the $host deploy policy is readable" "the comparison could not run it: $out"
    return
  fi
  if [[ -z $out ]]; then
    ok "the $host deploy policy agrees with the shared role table"
  else
    fail "the $host deploy policy agrees with the shared role table" "$out"
  fi
}
for host in server edge; do
  policy_agrees "$host"
done

# --- 5. no stale reference -----------------------------------------------------

# The paths the copies used to have. A script, a workflow or a document that still
# names one is a reader of a file that no longer exists, and the failure it would
# cause -- a missing key, a policy nothing reads -- only shows up on a booted host.
stale=(
  'bootc/server/cosign.pub'
  'hosts/laptop/cosign.pub'
  'bootc/server/rootfs/etc/containers/policy.json'
  'hosts/laptop/rootfs/etc/containers/policy.json'
  'rootfs/etc/containers/registries.d'
  'rootfs/etc/sudoers.d/10-human-gate'
  'rootfs/etc/sudoers.d/11-agent-socket'
  'rootfs/etc/sudoers.d/20-sops-env'
  '10-smortress-health.sh'
  '10-edge-health.sh'
  'rootfs/usr/libexec/deploy-verify.py'
)
for pattern in "${stale[@]}"; do
  hit=$(grep -rIlF --exclude-dir=.git --exclude-dir=node_modules --exclude=check-lib-drift.sh --exclude=lib-drift.bats -- "$pattern" "$repo" 2>/dev/null |
    sed "s|^$repo/||" | sort | tr '\n' ' ') || true
  if [[ -z ${hit// /} ]]; then
    ok "nothing names the retired path $pattern"
  else
    fail "nothing names the retired path $pattern" "named by: ${hit% }"
  fi
done

printf '\n%d checks, %d problems\n' "$checks" "$problems"
((problems == 0))
