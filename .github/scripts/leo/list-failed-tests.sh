#!/usr/bin/env bash
# Lists the tests a full Swift Testing run reported as failed, one
# `Suite/test()` per line: usage list-failed-tests.sh LOG [TESTS_DIR]
# (TESTS_DIR defaults to ./Tests; run from macos/).
#
# The log names a failing test (`✘ Test name() failed after ...`) and, on
# other lines, the failing suites (`✘ Suite Name failed after ...`) -- but
# never which suite a test belongs to. A test is placed in the failing suite
# whose body declares `func name(` (a file may hold several suites). One that
# no failing suite declares, or that more than one does, prints as `?/name()`:
# the caller can't rerun it by name, and a guess could pass a rerun that never
# ran the test that failed.
set -euo pipefail

log="${1:?usage: list-failed-tests.sh LOG [TESTS_DIR]}"
tests_dir="${2:-Tests}"

# `✘ Test run with N tests ...` is the run's own summary, not a test.
tests="$(sed -nE '/^✘ Test run with /d; s/^✘ Test (.+) failed after [0-9.]+ seconds.*$/\1/p' "$log" | sort -u)"
suites="$(sed -nE 's/^✘ Suite ([A-Za-z0-9_]+) failed after .*$/\1/p' "$log" | sort -u)"

suite_file() {
  grep -rlE "(struct|class|enum|actor) $1([^A-Za-z0-9_]|$)" "$tests_dir" 2>/dev/null | head -1 || true
}

# The lines of suite $2 in file $1: its declaration, and any `extension` of it,
# each to the closing brace at its own indentation.
suite_body() {
  awk -v n="$2" '
    !inside && ($0 ~ ("(struct|class|enum|actor) " n "([^A-Za-z0-9_]|$)") || $0 ~ ("extension ([A-Za-z0-9_]+[.])*" n "([^A-Za-z0-9_]|$)")) {
      inside = 1
      match($0, /^[ \t]*/)
      indent = substr($0, 1, RLENGTH)
      print
      if ($0 ~ /\{.*\}[ \t]*$/) inside = 0
      next
    }
    inside { print; if ($0 == indent "}") inside = 0 }
  ' "$1"
}

while IFS= read -r test; do
  [[ -n "$test" ]] || continue
  base="${test%%(*}"
  owners=()
  while IFS= read -r suite; do
    [[ -n "$suite" ]] || continue
    file="$(suite_file "$suite")"
    [[ -n "$file" ]] || continue
    # Not `suite_body | grep -q`: grep exiting early SIGPIPEs awk, and pipefail then fails the test.
    body="$(suite_body "$file" "$suite")"
    if grep -qE "func $base\(" <<<"$body"; then owners+=("$suite"); fi
  done <<<"$suites"
  if [[ ${#owners[@]} -eq 1 ]]; then echo "${owners[0]}/$test"; else echo "?/$test"; fi
done <<<"$tests"
