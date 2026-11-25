#!/usr/bin/env bash
# The one fake `curl` (SDLC #812 item 8).
#
# Seven suites wrote their own stub into $bin, and the seven parsed the same
# argv differently: one never learned --write-out, another treated every
# positional as a URL, a third knew --data-binary only because one suite wanted
# to assert the body. Installing this file instead means a flag or an option's
# arity is fixed once, and the differences a suite genuinely needs are declared
# as environment rather than forked as code:
#
#   FAKE_CURL_LOG             argv of every call, one line each (optional)
#   FAKE_ARGV_LOG             the same, one argument per line (optional)
#   FAKE_FETCH_DIR            --output copies <basename url>.tar.gz from here
#   FAKE_ENDPOINT_MATCH       glob; a URL matching it is answered, not pinged
#   FAKE_ENDPOINT_STATUS_FILE file holding that answer's status; `network` = exit 7
#   FAKE_ENDPOINT_BASE        prefix stripped from the URL to name a body file
#   FAKE_ENDPOINT_BODY_DIR    body files, named <rest of path, / -> _>.json
#   FAKE_ENDPOINT_BODY        body when no body file matches (default {})
#   FAKE_PING_LOG             every URL not answered is recorded here
#   FAKE_PING_BODY=1          record the --data-binary body beside the URL
#   FAKE_CURL_RESPONSE        body printed for a URL that is not answered
#   FAKE_CURL_EXIT            exit status for a URL that is not answered (default 0)
#
# `--fail`/`--fail-with-body` exit 22 on a 4xx/5xx and --write-out prints the
# status, as the real curl does. deploy_notify passes its URL as a config on
# stdin, never in argv, so a URL-less call reads the `url = "..."` line.

set -uo pipefail

[[ -n ${FAKE_CURL_LOG:-} ]] && printf '%s\n' "$*" >>"$FAKE_CURL_LOG"
if [[ -n ${FAKE_ARGV_LOG:-} ]]; then
  for arg in "$@"; do printf '%s\n' "$arg" >>"$FAKE_ARGV_LOG"; done
fi

out=/dev/stdout
write_out=
fail=0
body=
url=
while (($#)); do
  case $1 in
    --output | -o) out=$2; shift 2 ;;
    --write-out) write_out=$2; shift 2 ;;
    --fail | --fail-with-body) fail=1; shift ;;
    --config) shift 2 ;;
    --data-binary | -d) body=${2-}; shift 2 ;;
    -H | --header | --max-time | --retry | --retry-delay | --connect-timeout) shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
if [[ -z $url ]]; then
  url=$(sed -n 's/^url = "\(.*\)"$/\1/p' | head -n 1)
fi

# The codeload fetch: --output names a tarball this suite published.
if [[ -n ${FAKE_FETCH_DIR:-} && -n ${url:-} ]]; then
  if [[ $out != /dev/stdout ]]; then
    src=$FAKE_FETCH_DIR/$(basename -- "$url").tar.gz
    [[ -f $src ]] || {
      printf 'fake-curl: no %s\n' "$src" >&2
      exit 22
    }
    cp -- "$src" "$out"
    exit 0
  fi
fi

answered=0
if [[ -n ${FAKE_ENDPOINT_MATCH:-} ]]; then
  # shellcheck disable=SC2254 # a glob on purpose: the suite names which URLs are endpoints
  case ${url:-} in
    $FAKE_ENDPOINT_MATCH) answered=1 ;;
  esac
fi

if ((answered)); then
  status=200
  if [[ -n ${FAKE_ENDPOINT_STATUS_FILE:-} ]]; then
    status=$(cat "$FAKE_ENDPOINT_STATUS_FILE" 2>/dev/null) || status=200
  fi
  [[ $status == network ]] && exit 7
  answer=${FAKE_ENDPOINT_BODY:-'{}'}
  if [[ -n ${FAKE_ENDPOINT_BODY_DIR:-} ]]; then
    rel=${url#*"${FAKE_ENDPOINT_BASE:-}"}
    file=$FAKE_ENDPOINT_BODY_DIR/${rel//\//_}.json
    [[ -s $file ]] && answer=$(cat -- "$file")
  fi
  [[ -n $write_out ]] && printf '%s' "$status"
  if [[ $out == /dev/stdout ]]; then printf '%s' "$answer"; else printf '%s' "$answer" >"$out"; fi
  if ((fail)) && ((status >= 400)); then exit 22; fi
  exit 0
fi

if [[ -n ${FAKE_PING_LOG:-} ]]; then
  if [[ ${FAKE_PING_BODY:-0} == 1 ]]; then
    printf '%s\t%s\n' "${url:-}" "$body" >>"$FAKE_PING_LOG"
  else
    printf '%s\n' "${url:-}" >>"$FAKE_PING_LOG"
  fi
fi
[[ -n ${FAKE_CURL_RESPONSE:-} ]] && printf '%s\n' "$FAKE_CURL_RESPONSE"
exit "${FAKE_CURL_EXIT:-0}"
