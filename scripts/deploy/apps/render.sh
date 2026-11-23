# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154  # globals are assigned by the entrypoint
# deploy-apps/render.sh: sourced by scripts/deploy-apps.sh; no shebang.
fetch_commit() { # <commit> <dest>
  bounded "$fetch_timeout" "$curl_bin" --fail --silent --show-error --location \
    --connect-timeout 30 --retry 2 --output "$2" "$apps_fetch_base/$1"
}

# 0: wrote <out>; 10: the commit carries no tenant secrets; 1: cannot decrypt.
decrypt_tenant_secrets() { # <tree> <out>
  local src=$1/secrets.sops.json out=$2 rc=0
  if [[ ! -e $src ]]; then
    return 10
  fi
  [[ -s $src ]] || {
    warn "$src is empty"
    return 1
  }
  [[ -s $age_key ]] || {
    warn "$age_key is missing; stage the age identity from the recovery kit"
    return 1
  }
  SOPS_AGE_KEY_FILE="$age_key" bounded "$sops_timeout" "$sops_bin" --decrypt \
    --input-type json --output-type json "$src" >"$out.tmp" || rc=$?
  if ((rc != 0)); then
    warn "cannot decrypt $src with $age_key"
    rm -f -- "$out.tmp"
    return 1
  fi
  chmod 0600 "$out.tmp" || return 1
  mv -f -- "$out.tmp" "$out"
}

render_commit() { # <tree> <secrets|""> <out>
  local -a args=(render --root "$1" --out "$3")
  if [[ -n $2 ]]; then args+=(--secrets "$2"); fi
  # --allow-empty is the deploy's alone, and it is unconditional here: an empty
  # `apps/` the validator accepted is a tenant an operator emptied, and without
  # the flag the last app could never be removed. A missing or unreadable `apps/`
  # is still refused by the validator that ran above.
  args+=(--allow-empty)
  bounded "$schema_timeout" "$schema_bin" "${args[@]}"
}

# --- free space --------------------------------------------------------------
# df reports 1K blocks; the available column is the fourth field of the second
# line in the POSIX form.
available_bytes() { # <path>
  local blocks
  blocks=$(bounded "$df_timeout" "$df_bin" -P -k -- "$1" | awk 'NR == 2 { print $4 }') || return 1
  [[ $blocks =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$((blocks * 1024))"
}

# An immutable image root always reports its own size as 100% full: on composefs,
# erofs or squashfs nothing is ever written to `/`, so a space floor there says
# nothing about the apply. Measured on smortress: `df /` on composefs is 8.3M with
# 0 available, which refused every apply while /var had 63G.
immutable_mount() { # <path>
  local fstype opts
  fstype=$(timeout --signal=TERM --kill-after=5 10 "$findmnt_bin" -no FSTYPE --target "$1" 2>/dev/null) || return 1
  case $fstype in
    composefs | erofs | squashfs | iso9660) return 0 ;;
    overlay | overlayfs)
      # A writable overlay is a real disk; only the read-only composefs root is
      # the case the guard must skip.
      opts=$(timeout --signal=TERM --kill-after=5 10 "$findmnt_bin" -no OPTIONS --target "$1" 2>/dev/null) || return 1
      [[ ,$opts, == *,ro,* ]] && return 0
      ;;
  esac
  return 1
}

check_space() {
  local pair path need got
  for pair in "$home_path:$home_need" "$root_path:$root_need" "$var_path:$var_need"; do
    path=${pair%%:*}
    need=${pair##*:}
    immutable_mount "$path" && continue
    if ! got=$(available_bytes "$path"); then
      warn "cannot read the free space on $path"
      return 1
    fi
    if ((got < need)); then
      warn "$path has $got bytes free, below the $need byte floor for an apps apply"
      return 1
    fi
  done
  return 0
}

# --- the plan and its consumers ----------------------------------------------
install_plan() { # <file>
  install -d -m 0700 "$(dirname -- "$apps_plan")" || return 1
  atomic_write "$apps_plan" <"$1"
}

plan_apps() { # <plan> -> one name per line
  jq -r '(.apps // {}) | keys[]' "$1"
}

plan_units() { # <render dir> -> one unit basename per line
  local file
  for file in "$1"/*.container "$1"/*.network; do
    [[ -f $file ]] || continue
    basename -- "$file"
  done
}

app_unit() { printf '%s.container\n' "$1"; }
app_service() { printf '%s.service\n' "$1"; }

# The schema's APP_NAME, verbatim from scripts/apps-schema.py. A name becomes a
# unit instance (`smortress-app-ingress@<name>`, `<name>.service`), a file in the
# tenant's unit directory and a Serve path, so a plan outside it is one this
# script refuses to act on -- the renderer never emits one, but the sets guarded
# below are state, not render output: the previous unit set is files found in the
# tenant's own home and `apply.json` is a document an operator can edit.
app_name_ok() { # <name>
  [[ $1 =~ ^[a-z]([a-z0-9-]{0,29}[a-z0-9])?$ ]]
}

# A unit file this platform writes: `<app>.container` for a schema-valid name, or
# the internal network it renders while an egress-none app exists.
unit_name_ok() { # <basename>
  case $1 in
    smortress-apps.network) return 0 ;;
    *.container) app_name_ok "${1%.container}" ;;
    *) return 1 ;;
  esac
}

refuse_name() { # <name> <sink> <what>
  journal_append apps-name-refused "$(jq -nc --arg name "$1" --arg sink "$2" \
    '{name:$name,sink:$sink}')" || warn "cannot journal the refused name"
  warn "refusing the $3 '$1' for $2: it is not a name this deploy writes"
}

require_app_name() { # <name> <sink>
  app_name_ok "$1" && return 0
  refuse_name "$1" "$2" "app name"
  return 1
}

require_unit_name() { # <basename> <sink>
  unit_name_ok "$1" && return 0
  refuse_name "$1" "$2" "unit name"
  return 1
}

in_list() { # <needle> <haystack...>
  local needle=$1 item
  shift
  for item in "$@"; do
    [[ $item == "$needle" ]] && return 0
  done
  return 1
}

json_list() {
  if (($# == 0)); then
    printf '[]\n'
    return 0
  fi
  jq -nc '$ARGS.positional' --args -- "$@"
}

# --- snapshots and hashes ----------------------------------------------------
