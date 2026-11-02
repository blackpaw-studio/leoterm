#!/usr/bin/env bash
# Plain-sh tests for check-test-log.sh, the post-run gate on the unit-test
# log (B-297: focus-gate skips warn, real failures and incomplete runs fail).
# Run directly:
#   ./test_check-test-log.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

readonly script=../check-test-log.sh
readonly summary_ok='✔ Test run with 3592 tests in 358 suites passed after 90.1 seconds.'
readonly skip_line='focus-gate-skip: needs a key window: a plain probe window couldn'"'"'t become key'
pass=0
fail=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# check DESC WANT_STATUS RC OUTPUT_PATTERN LOG_LINE...: runs the script on a
# log made of LOG_LINEs; the output must match OUTPUT_PATTERN (grep -E).
check() {
  local desc="$1" want="$2" rc="$3" pattern="$4"
  shift 4
  printf '%s\n' "$@" >"$work/log"
  local out got
  local host=""
  [[ "$desc" == *"are required" || "$desc" == *"when host tests are required" ]] && host=1
  out="$(LEO_HOST_TESTS="$host" bash "$script" "$work/log" "$rc" 2>&1)" && got=0 || got=1
  if [[ "$got" -eq "$want" ]] && grep -Eq -- "$pattern" <<<"$out"; then
    echo "PASS: $desc"
    pass=$((pass + 1))
  else
    echo "FAIL: $desc (status $got, want $want; output: $out)"
    fail=$((fail + 1))
  fi
}

check "a clean run passes" 0 0 'All tests passed' "$summary_ok"
check "a focus-gate skip warns and still passes" 0 0 '^::warning::1 focus-gate check\(s\) skipped: needs a key window' \
  "$skip_line" "$summary_ok"
check "the warning counts every skip" 0 0 '^::warning::5 focus-gate' \
  "$skip_line" "$skip_line" "$skip_line" "$skip_line" "$skip_line" "$summary_ok"
check "an ordinary skip does not warn" 0 0 '^All tests passed' '➜ Test example() skipped.' "$summary_ok"
check "skipped tests are listed by name in a group" 0 0 '^::group::Skipped tests \(2\)$' \
  '➜ Suite LeoWKBrowserPageTests skipped: host tier' '➜ Test example() skipped.' "$summary_ok"
check "the skip count is a notice" 0 0 '^::notice::2 test\(s\) skipped' \
  '➜ Suite LeoWKBrowserPageTests skipped: host tier' '➜ Test example() skipped.' "$summary_ok"
check "the skipped names appear in the output" 0 0 'LeoWKBrowserPageTests' \
  '➜ Suite LeoWKBrowserPageTests skipped: host tier' "$summary_ok"
check "no skips prints no group" 0 0 '^All tests passed' "$summary_ok"
check "a host-tier skip fails when host tests are required" 1 0 'host tier skipped host-only' \
  '➜ Suite LeoWKBrowserPageTests skipped: host tier: set LEO_HOST_TESTS=1' "$summary_ok"
check "a host-tier skip is fine when host tests are not required" 0 0 '^All tests passed' \
  '➜ Suite LeoWKBrowserPageTests skipped: host tier: set LEO_HOST_TESTS=1' "$summary_ok"
check "a focus-gate skip is not a host-tier skip, even when host tests are required" 0 0 'focus-gate check' \
  "$skip_line" '➜ Suite LeoChatCopyTests skipped: needs a key window: a plain probe window couldn'"'"'t become key' "$summary_ok"
check "a failed test fails the run" 1 0 'failures reported' '✘ Test foo() failed after 0.1 seconds with 1 issue.' "$summary_ok"
check "a missing summary fails" 1 0 'without a summary' 'noise'
check "a timeout fails" 1 124 'timed out' '◇ Test foo() started.'
check "a non-zero host status fails" 1 6 'exited with status 6' "$summary_ok"

echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
