#!/usr/bin/env bash
# Fail when this repository's SOPS policy is not the one canonical in dotfiles
# (SDLC #1032, design #1012).
#
#   scripts/check-sops-drift.sh [--canonical-dir DIR]
#
# `scripts/sops-policy.py` is canonical in smores56/dotfiles and vendored here,
# and `.sops.yaml` is that script's `render --profile platform`. Nothing compared
# either copy to its source, so the recipients a host decrypts with and the
# recipients this repository encrypts to could drift apart with every check
# still green: the failure would land on a booted host that cannot read a
# secret, or on a ciphertext no machine identity was ever added to.
#
# The comparison is these rules:
#
#   1. the vendored policy is the canonical policy. Byte for byte: it is copied,
#      never edited here, so a local fix is the drift this rule exists for.
#   2. the committed config is the canonical render. `.sops.yaml` must be
#      exactly what the canonical policy renders for the platform profile, so a
#      hand edit to a recipient or a rule fails here instead of at the next
#      `sops` run.
#
# The comparison is pinned to a dotfiles commit, not a branch: floating `main`
# would fail this repository on an unrelated dotfiles change and teach everyone
# to re-run CI until it passes. The pin and how to bump it are on `dotfiles_ref`
# below, and hosts/server/runbook.md 3.6 has the operator's side.
#
# `--canonical-dir DIR` reads the canonical policy from a checkout of that
# revision instead of fetching it, which is how the test suite runs offline. CI
# omits it: smores56/dotfiles is public, so the fetch needs no token and a
# `pull_request` job can still read it.
#
# Exit 0 when both rules hold; otherwise one `FAIL <what>: <why>` line per
# problem and `N checks, N problems`, in the style of
# scripts/check-lib-drift.sh.
set -uo pipefail

repo=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

# The canonical policy. Public repository, so no credential is involved:
# scripts/check-pr-secret-boundary.sh keeps secrets out of `pull_request` runs
# and this check never needs one. A private canonical repository would move this
# job off `pull_request` instead of widening that ban.
dotfiles_repo=https://github.com/smores56/dotfiles.git
# Bump only when the canonical policy itself changes. This is the dotfiles
# commit that last touched scripts/sops-policy.py:
#   git -C <dotfiles> log -1 --format=%H -- scripts/sops-policy.py
dotfiles_ref=67c2c296855de34a42a6bb4ea745c15f5b1a0fa2

# PROFILES["platform"] in the policy names the config path; a render of the
# wrong profile would be a different file, so the pair is stated here.
profile=platform
config=$repo/.sops.yaml
vendored=$repo/scripts/sops-policy.py

usage() {
  printf 'usage: %s [--canonical-dir DIR]\n' "${0##*/}"
}

canonical=''
while (($#)); do
  case $1 in
    --canonical-dir)
      canonical=${2:?--canonical-dir needs a path}
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

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

tmp=$(mktemp -d) || exit 1
trap 'rm -rf -- "$tmp"' EXIT

# fetch_canonical: the pinned revision's tree, so the two rules below read the
# policy as it is in dotfiles rather than a branch that moved. Shallow, since
# only one file is read and CI runs this on every pull request.
fetch_canonical() {
  GIT_TERMINAL_PROMPT=0 git init --quiet "$tmp/canonical" &&
    GIT_TERMINAL_PROMPT=0 git -C "$tmp/canonical" fetch --quiet --depth 1 \
      "$dotfiles_repo" "$dotfiles_ref" &&
    GIT_TERMINAL_PROMPT=0 git -C "$tmp/canonical" -c advice.detachedHead=false \
      checkout --quiet FETCH_HEAD
}

if [[ -z $canonical ]]; then
  if fetch_canonical; then
    canonical=$tmp/canonical
  else
    fail 'the canonical policy is readable' \
      "git fetch $dotfiles_repo $dotfiles_ref failed; it is a public repository, so this is the network, not credentials"
  fi
fi

source=$canonical/scripts/sops-policy.py
if [[ -n $canonical && ! -f $source ]]; then
  fail 'the canonical policy exists at the pinned ref' \
    "no scripts/sops-policy.py under $canonical; the pin names a tree the policy has left"
  source=''
fi

# --- 1. the vendored policy is the canonical policy ---------------------------

if [[ -n $source ]]; then
  if cmp -s "$vendored" "$source"; then
    ok 'the vendored policy is the canonical one'
  else
    fail 'the vendored policy is the canonical one' \
      "scripts/sops-policy.py differs from $dotfiles_repo@$dotfiles_ref:scripts/sops-policy.py; copy the canonical file, never edit this one"
  fi
fi

# --- 2. the committed config is the canonical render --------------------------

# The render comes from the canonical script, not the vendored one: what a host
# decrypts with is the policy, and rule 1 is what holds the vendored copy to it.
if [[ -n $source ]]; then
  if [[ ! -f $config ]]; then
    fail "the committed config is the canonical $profile render" \
      '.sops.yaml is missing; every secrets/ ciphertext is keyed by it'
  elif python3 "$source" render --profile "$profile" >"$tmp/rendered" 2>"$tmp/render.err"; then
    if cmp -s "$config" "$tmp/rendered"; then
      ok "the committed config is the canonical $profile render"
    else
      fail "the committed config is the canonical $profile render" \
        '.sops.yaml differs from the pinned policy; render it again rather than editing a recipient'
      diff -u "$config" "$tmp/rendered" | sed -n '3,14p' | sed 's/^/     /'
    fi
  else
    fail "the canonical policy renders profile $profile" \
      "$(head -n1 "$tmp/render.err")"
  fi
fi

printf '\n%d checks, %d problems\n' "$checks" "$problems"
((problems == 0))
