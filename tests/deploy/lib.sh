#!/usr/bin/env bash
# The harness the deploy suites share (SDLC #812 item 8).
#
# Eleven tests/deploy/*.sh suites each carried their own copy of `ok`/`bad` and
# the check_* helpers, and the copies were not equivalent: `check_file` asserted
# "exists and is non-empty" in four suites and "exists" in state.sh, and
# `check_grep` meant a fixed string in a file in three suites and an ERE over
# text in notify.sh. A fix that landed in one copy therefore did not reach the
# others. This file is the one implementation; each suite keeps its fixtures, its
# subject and the helpers only it uses.
#
#   # shellcheck source=tests/deploy/lib.sh
#   source "$root/tests/deploy/lib.sh"
#
# The suites run under `set -uo pipefail`; nothing here needs anything else.

pass=0
fail=0

deploy_lib_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

# Put the one fake curl on a suite's PATH. What it needs to do differently is
# the environment it reads (tests/deploy/fake-curl.sh documents the knobs), not
# a copy of the script.
install_fake_curl() { # <bin dir>
  install -m 0755 "$deploy_lib_dir/fake-curl.sh" "$1/curl"
}

ok() { # label
  pass=$((pass + 1))
  printf 'ok   %s\n' "$1"
}

bad() { # label [detail]
  fail=$((fail + 1))
  printf 'FAIL %s\n' "$1" >&2
  [[ -n ${2:-} ]] && printf '     %s\n' "${2//$'\n'/$'\n'     }" >&2
  return 0
}

check_eq() { # got want label
  if [[ $1 == "$2" ]]; then ok "$3"; else bad "$3" "want '$2', got '$1'"; fi
}

check_json() { # doc filter want label
  local got
  got=$(jq -r "$2" <<<"$1" 2>/dev/null)
  check_eq "$got" "$3" "$4"
}

# One contract for "the file exists": non-empty. The `-f` copy in state.sh
# asserted the weaker thing at a single call site (a rotated journal), where an
# empty file would be the bug, so the stronger assertion is the one kept.
check_file() { # path label
  if [[ -s $1 ]]; then ok "$2"; else bad "$2" "missing or empty: $1"; fi
}

check_no_file() { # path label
  if [[ -e $1 ]]; then bad "$2" "$(cat "$1" 2>/dev/null)"; else ok "$2"; fi
}

check_grep() { # file fixed-string label
  if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3" "no '$2' in $1"; fi
}

check_no_grep() { # file fixed-string label
  if grep -qF -- "$2" "$1" 2>/dev/null; then bad "$3" "$(grep -F -- "$2" "$1")"; else ok "$3"; fi
}

# The same assertion for text a suite already holds in a variable, where the
# pattern is an ERE rather than a fixed string.
check_match() { # text ere label
  if grep -qE -- "$2" <<<"$1"; then ok "$3"; else bad "$3" "no /$2/ in: $1"; fi
}

check_no_match() { # text ere label
  if grep -qE -- "$2" <<<"$1"; then bad "$3" "$(grep -E -- "$2" <<<"$1")"; else ok "$3"; fi
}

journal_field() { # event jq-path
  jq -r "select(.event==\"$1\") | $2" "${DEPLOY_STATE_DIR:?}/journal.jsonl" 2>/dev/null
}

journal_events() { # event -> count
  grep -c "\"event\":\"$1\"" "${DEPLOY_STATE_DIR:?}/journal.jsonl" 2>/dev/null || true
}

finish() {
  printf '\n%d passed, %d failed\n' "$pass" "$fail"
  ((fail == 0))
}
