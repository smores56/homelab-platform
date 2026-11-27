#!/usr/bin/env bats
# bats file_tags=core
# A container is ordered after the readiness instance of the dataset it
# mounts, and after no other.
#
# One file of the suite that was tests/core/app-quadlets.bats, split so bats can
# run the sections as parallel files (a file is one job). The tables, the
# file-scope sources and every checker more than one section calls are in
# tests/core/app-quadlets_lib.bash; the checkers only this file uses stay here.
#
#   bats tests/core/app-quadlets-readiness.bats
load ../helpers
load ./app-quadlets_lib

setup_file() { aq_setup_file; }
setup() { aq_setup; }

# 2. A container that mounts a dataset is ordered after that dataset's
#    readiness instance, and requires no instance for a dataset it does not
#    mount. One that mounts no dataset (the machine learning cache) needs no
#    readiness at all. The table maps a volume path to an instance.
#
# A volume may name the dataset root or a directory inside it (the facades mount
# `state/agent-*/memory`, because the gateway's sessions and .env are one level
# up), so containment is what decides which instance a volume needs.
#
# The loop below asks that question once per volume, and the table answers it per
# dataset, so the map is built once for the whole pass. A `declare -A` is local
# to the scope bats sources this file into -- exactly the scope this loop runs
# in -- and no test body reads it: a checker sources the table and builds its own.
declare -A readiness_of_alias=()
for _key in "${dataset_order[@]}"; do
  _mountpoint=${dataset_mount[$_key]}
  readiness_of_alias[$_mountpoint]=${_key//\//-}
  case $_mountpoint in
    # The two spellings `mountpoint_aliases` prints. A checker calls that helper
    # rather than restating the rule, so a disagreement shows up as a failure
    # rather than as a quiet mis-mapping.
    */var/srv/*) readiness_of_alias[${_mountpoint/\/var\/srv//srv}]=${_key//\//-} ;;
  esac
done
unset _key _mountpoint

requires_readiness() { # quadlet instance
  # shellcheck source=/dev/null
  source scripts/storage-layout.sh
  local q=$1 instance=$2 key alias volume mounts=0
  local -A readiness_of_alias=()
  for key in "${dataset_order[@]}"; do
    while IFS= read -r alias; do
      readiness_of_alias[$alias]=${key//\//-}
    done < <(mountpoint_aliases "$key")
  done
  while IFS= read -r line; do
    case $line in
      Volume=*) ;;
      *) continue ;;
    esac
    volume=${line#Volume=}
    volume=${volume%%:*}
    for alias in "${!readiness_of_alias[@]}"; do
      if [[ $volume == "$alias" || $volume == "$alias"/* ]] &&
        [[ ${readiness_of_alias[$alias]} == "$instance" ]]; then
        mounts=1
      fi
    done
  done <"$q"
  if ((!mounts)); then
    printf '%s mounts no dataset that needs zfs-ready@%s\n' "$q" "$instance" >&2
    return 1
  fi
  grep -qE "^Requires=.*zfs-ready@$instance.service" "$q"
}

for _q in "${app_quadlets[@]}"; do
  _needed=' '
  _volumes=' '
  _declared=' '
  while IFS= read -r _line; do
    _rest=$_line
    # The instances the file declares, whether or not it mounts their dataset.
    while [[ $_rest =~ zfs-ready@([a-z-]*)\.service ]]; do
      _instance=${BASH_REMATCH[1]}
      _rest=${_rest#*"${BASH_REMATCH[0]}"}
      case $_declared in
        *" $_instance "*) ;;
        *) _declared="$_declared$_instance " ;;
      esac
    done
    case $_line in
      Volume=*) ;;
      *) continue ;;
    esac
    _volume=${_line#Volume=}
    _volume=${_volume%%:*}
    case " $_volumes " in
      *" $_volume "*) continue ;;
    esac
    _volumes="$_volumes $_volume"
    _instance=''
    for _alias in "${!readiness_of_alias[@]}"; do
      if [[ $_volume == "$_alias" || $_volume == "$_alias"/* ]]; then
        _instance=${readiness_of_alias[$_alias]}
        break
      fi
    done
    if [[ -z $_instance ]]; then
      continue
    fi
    _needed="$_needed$_instance "
    registered "$_q requires zfs-ready@$_instance" requires_readiness "$_q" "$_instance"
  done <"$_q"
  # A requirement for a dataset the file does not mount is dead, and the shell
  # suite only spoke up when it found one; the same check covers it here, and a
  # tree with none registers nothing.
  for _instance in $_declared; do
    if [[ $_needed != *" $_instance "* ]]; then
      registered "$_q requires zfs-ready@$_instance" requires_readiness "$_q" "$_instance"
    fi
  done
done
unset _q _line _rest _volume _volumes _declared _instance _needed _alias
