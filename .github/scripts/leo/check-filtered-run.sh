#!/usr/bin/env bash
# Verdict for a filtered run (`xcodebuild test-without-building -only-testing`)
# that exited 0. That path prints no Swift Testing "Test run with N tests"
# summary, so counts come from the result bundle, falling back to the log's
# "Test case ... passed/failed" lines. Prints "N passed, M failed" and exits 1
# when anything failed or nothing ran (a filter that matched no test).
# Usage: check-filtered-run.sh RESULT_BUNDLE LOG
set -euo pipefail

bundle="${1:?usage: check-filtered-run.sh RESULT_BUNDLE LOG}"
log="${2:?usage: check-filtered-run.sh RESULT_BUNDLE LOG}"

passed="" failed=""
if [[ -d "$bundle" ]] && summary="$(xcrun xcresulttool get test-results summary --path "$bundle" --compact 2>/dev/null)"; then
  counts="$(python3 -I -c '
import json, sys
d = json.loads(sys.stdin.read())
print(d["passedTests"], d["failedTests"])' <<<"$summary" 2>/dev/null || true)"
  read -r passed failed <<<"$counts"
fi
if [[ -z "$passed" ]]; then
  passed="$(grep -cE "^Test case '.*' passed" "$log" || true)"
  failed="$(grep -cE "^Test case '.*' failed" "$log" || true)"
fi

echo "$passed passed, $failed failed"
if [[ "$failed" -gt 0 ]]; then
  echo "::error::$failed test case(s) failed despite a zero exit status"
  exit 1
fi
if [[ "$passed" -eq 0 ]]; then
  echo "::error::the test filter matched no tests"
  exit 1
fi
