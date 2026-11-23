#!/usr/bin/env bash
# The SOPS policy checker must pass the real tree and fail each drift shape.
#   tests/secrets/policy.sh
set -euo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root" || exit 1

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$*"; }
no() { fail=$((fail + 1)); printf 'FAIL %s\n' "$*" >&2; }

repo() {
  local dir=$1 profile=$2
  mkdir -p "$dir/secrets"
  git -C "$dir" init -q
  python3 scripts/sops-policy.py render --profile "$profile" --out "$dir/.sops.yaml"
  repo_age=()
  while IFS= read -r line; do repo_age+=("$line"); done < <(
    awk '/^keys:/{f=1} /^creation_rules:/{f=0} f && /age1/{print $NF}' "$dir/.sops.yaml"
  )
}

yaml_cipher() {
  local file=$1
  shift
  {
    printf 'secret: ENC[AES256_GCM,data:x]\n'
    printf 'sops:\n    age:\n'
    for r in "$@"; do
      printf '        - recipient: %s\n          enc: |\n            fake\n' "$r"
    done
  } >"$file"
}

json_cipher() {
  local file=$1
  shift
  {
    printf '{"apps":{},"sops":{"age":['
    local first=true
    for r in "$@"; do
      $first || printf ','
      first=false
      printf '{"recipient":"%s","enc":"fake"}' "$r"
    done
    printf ']}}'
  } >"$file"
}

check() { python3 scripts/sops-policy.py check --repo "$1" >/dev/null 2>&1; }

# Valid platform-shaped repo.
t="$work/valid"
repo "$t" platform
yaml_cipher "$t/secrets/a.yaml" "${repo_age[@]}"
git -C "$t" add -A
if check "$t"; then ok "a canonical ciphertext passes"; else no "a canonical ciphertext passes"; fi

# Missing recipient.
t="$work/missing"
repo "$t" platform
yaml_cipher "$t/secrets/a.yaml" "${repo_age[@]:0:4}"
git -C "$t" add -A
if check "$t"; then no "a missing recipient fails"; else ok "a missing recipient fails"; fi

# Reordered recipients.
t="$work/order"
repo "$t" platform
yaml_cipher "$t/secrets/a.yaml" "${repo_age[1]}" "${repo_age[0]}" "${repo_age[@]:2}"
git -C "$t" add -A
if check "$t"; then no "a reordered recipient list fails"; else ok "a reordered recipient list fails"; fi

# A plaintext file under a matching rule.
t="$work/plain"
repo "$t" platform
yaml_cipher "$t/secrets/a.yaml" "${repo_age[@]}"
printf 'token: hunter2\n' >"$t/secrets/plain.yaml"
git -C "$t" add -A
if check "$t"; then no "a plaintext ciphertext path fails"; else ok "a plaintext ciphertext path fails"; fi

# A ciphertext matched by no rule.
t="$work/unmatched"
repo "$t" platform
yaml_cipher "$t/secrets/a.yaml" "${repo_age[@]}"
yaml_cipher "$t/elsewhere.yaml" "${repo_age[@]}"
git -C "$t" add -A
if check "$t"; then no "an unmatched ciphertext fails"; else ok "an unmatched ciphertext fails"; fi

# Tenant JSON is covered by the apps profile.
t="$work/apps"
repo "$t" apps
json_cipher "$t/secrets.sops.json" "${repo_age[@]}"
git -C "$t" add -A
if check "$t"; then ok "the tenant JSON passes"; else no "the tenant JSON passes"; fi

t="$work/apps-missing"
repo "$t" apps
json_cipher "$t/secrets.sops.json" "${repo_age[@]:0:4}"
git -C "$t" add -A
if check "$t"; then no "the tenant JSON missing a recipient fails"; else ok "the tenant JSON missing a recipient fails"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
