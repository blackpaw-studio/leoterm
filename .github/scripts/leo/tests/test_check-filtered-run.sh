#!/usr/bin/env bash
# Plain-sh tests for check-filtered-run.sh, the verdict on a filtered
# xcodebuild run that exited 0 (it prints no Swift Testing summary line).
# Run directly:
#   ./test_check-filtered-run.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

readonly script=../check-filtered-run.sh
pass=0
fail=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/bundle.xcresult"
touch "$work/log"

# A stand-in xcrun whose `xcresulttool ... summary` prints $FAKE_SUMMARY.
printf '#!/bin/sh\nprintf "%%s\\n" "$FAKE_SUMMARY"\n' >"$work/bin/xcrun"
chmod +x "$work/bin/xcrun"

# check DESC WANT_STATUS OUTPUT_PATTERN BUNDLE SUMMARY_JSON [LOG_LINE...]
check() {
  local desc="$1" want="$2" pattern="$3" bundle="$4" json="$5"
  shift 5
  printf '%s\n' "$@" >"$work/log"
  local out got
  out="$(PATH="$work/bin:$PATH" FAKE_SUMMARY="$json" bash "$script" "$bundle" "$work/log" 2>&1)" && got=0 || got=1
  if [[ "$got" -eq "$want" ]] && grep -Eq -- "$pattern" <<<"$out"; then
    echo "PASS: $desc"
    pass=$((pass + 1))
  else
    echo "FAIL: $desc (status $got, want $want; output: $out)"
    fail=$((fail + 1))
  fi
}

check "all passed in the bundle" 0 '^27 passed, 0 failed$' "$work/bundle.xcresult" '{"passedTests":27,"failedTests":0}'
check "a failed case fails even at exit 0" 1 '^26 passed, 1 failed$' "$work/bundle.xcresult" '{"passedTests":26,"failedTests":1}'
check "a filter that matched nothing fails" 1 'matched no tests' "$work/bundle.xcresult" '{"passedTests":0,"failedTests":0}'
check "without a bundle the log's case lines are counted" 0 '^2 passed, 0 failed$' "$work/missing.xcresult" '' \
  "Test case 'A.a()' passed on 'My Mac' (0.1 seconds)" "Test case 'A.b()' passed on 'My Mac' (0.1 seconds)"
check "an unreadable summary falls back to the log" 1 '^1 passed, 1 failed$' "$work/bundle.xcresult" 'not json' \
  "Test case 'A.a()' passed on 'My Mac' (0.1 seconds)" "Test case 'A.b()' failed on 'My Mac' (0.1 seconds)"

echo "-- $pass passed, $fail failed --"
[[ "$fail" -eq 0 ]]
